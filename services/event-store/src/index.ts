// The composite "Event Store" component (event-stores.md
// §2.1/§2.7.7-§2.7.8) — composes every other services/* package and
// owns Event Store Configuration parsing (§2.5) and Application
// Initialization (§2.6.2). See
// documentation/plans/architecture/event-store-implementation-plan.md,
// Phase 13.

import {
  registerWithAggregator,
  type AggregatorEndpoint,
} from "aggregator-registration";
import {
  connect,
  migrationStepCount,
  pendingCountsByAggregator,
  streamEventCount,
  type DatabaseClient,
} from "database-repo";
import {
  createEvents,
  type CatalogHandle,
  type InsertStatementResult,
} from "event-creation";
import { deliverPending } from "event-delivery";
import { sweepStream, type RetentionStrategy } from "event-obsolescence";
import { HlcClock } from "hlc-clock";
import {
  emptyCatalog,
  migrateStream,
  type CatalogHandle as SchemaCatalogHandle,
} from "schema-migration";
import {
  parseConfig,
  type EventStoreConfig,
  type StreamConfig,
} from "./config.ts";

export { parseConfig, ConfigError } from "./config.ts";
export type { InsertStatementResult } from "event-creation";
export type {
  EventStoreConfig,
  StreamConfig,
  StreamAggregatorConfig,
  AggregationStrategy,
  RetentionStrategy,
  AggregatorConfig,
} from "./config.ts";

/** Backs event-collectors.md §3.3.1's admin endpoint — see
 *  `EventStore.streamStats`'s own doc comment. */
export interface StreamStats {
  name: string;
  migrationStepCount: number;
  eventCount: number;
  aggregatorNodeIds: number[];
  pendingByAggregator: Record<number, number>;
}

export class SchemaMismatchError extends Error {
  constructor(stream: string, aggregatorNodeId: number) {
    super(
      `stream "${stream}"'s locally configured migration does not match the ` +
        `migration reported by aggregator ${aggregatorNodeId} — schema drift ` +
        `between this collector's config and that aggregator's own schema`,
    );
    this.name = "SchemaMismatchError";
  }
}

/** Picks the single most conservative `RetentionStrategy` across a
 *  stream's configured aggregators, to actually run the sweep with —
 *  event-stores.md §2.5 declares a retention strategy *per aggregator
 *  entry*, but deleting a stream row is a whole-stream action with no
 *  per-aggregator granularity (`_pending_aggregations`' `ON DELETE
 *  CASCADE` drops every aggregator's own pending row for that event at
 *  once, not just one aggregator's). "Most conservative" here means:
 *  `indefinite` if *any* aggregator asks for it (never auto-delete
 *  unless every aggregator agrees it's safe to), otherwise the largest
 *  `threshold` (hardest to satisfy) and, if any entry is `timeLimited`,
 *  the largest `intervalMs` too. This is a deliberate interpretation of
 *  an underspecified corner of event-stores.md, not a settled design —
 *  worth confirming against the spec's own intent before relying on it
 *  for a stream whose aggregators actually configure *different*
 *  retention strategies. */
export function effectiveRetentionStrategy(
  streamConfig: StreamConfig,
): RetentionStrategy {
  const strategies = streamConfig.aggregators.map((a) => a.retentionStrategy);
  if (strategies.length === 0 || strategies.some((s) => s.kind === "indefinite")) {
    return { kind: "indefinite" };
  }

  const threshold = Math.max(
    ...strategies.map((s) => (s.kind === "indefinite" ? 0 : s.threshold)),
  );
  const timeLimited = strategies.filter(
    (s): s is Extract<RetentionStrategy, { kind: "timeLimited" }> =>
      s.kind === "timeLimited",
  );
  if (timeLimited.length === 0) {
    return { kind: "removedAfterAggregation", threshold };
  }
  const intervalMs = Math.max(...timeLimited.map((s) => s.intervalMs));
  return { kind: "timeLimited", threshold, intervalMs };
}

/** Every aggregator node id configured for `stream`, excluding any
 *  entry whose `aggregationStrategy.kind === "sharedDatabase"` (that
 *  aggregator shares the same database, so an event is visible to it
 *  immediately — no pending row, no delivery, ever needed for it). */
function aggregatorNodeIdsForStream(
  config: EventStoreConfig,
  stream: string,
): number[] {
  const streamConfig = config.streams[stream];
  if (!streamConfig) return [];
  return streamConfig.aggregators
    .filter((a) => a.aggregationStrategy.kind !== "sharedDatabase")
    .map((a) => a.nodeId);
}

export class EventStore {
  #db: DatabaseClient;
  #clock: HlcClock;
  #catalog: CatalogHandle;
  #config: EventStoreConfig;

  constructor(
    db: DatabaseClient,
    clock: HlcClock,
    catalog: CatalogHandle,
    config: EventStoreConfig,
  ) {
    this.#db = db;
    this.#clock = clock;
    this.#catalog = catalog;
    this.#config = config;
  }

  /** Implements event-stores.md §2.6.3: the one method application code
   *  calls per incoming `INSERT` — what
   *  `services/http-event-creation`'s HTTP ingress calls per request.
   *  Returns one result per statement in `source` — see
   *  `event-creation.createEvents`'s own doc comment for the full
   *  contract, including why a plain insert count sometimes needs
   *  correcting rather than reading a database driver's own
   *  affected-row-count directly. */
  async createEvents(source: string): Promise<InsertStatementResult[]> {
    return createEvents(this.#db, this.#clock, this.#catalog, source, (stream) =>
      aggregatorNodeIdsForStream(this.#config, stream),
    );
  }

  /** Backs event-collectors.md §3.3.1's admin endpoint for one stream —
   *  schema migration step count, currently stored event count,
   *  configured aggregator ids, and pending-aggregation counts per
   *  aggregator (every *configured* aggregator gets a key, `0` if it
   *  has nothing pending right now, unlike `pendingCountsByAggregator`'s
   *  own raw return value, which only mentions aggregators that
   *  currently have at least one pending row). */
  async streamStats(stream: string): Promise<StreamStats> {
    const streamConfig = this.#config.streams[stream];
    if (!streamConfig) {
      throw new Error(`streamStats: unknown stream "${stream}"`);
    }
    const [steps, events, pending] = await Promise.all([
      migrationStepCount(this.#db, stream),
      streamEventCount(this.#db, stream),
      pendingCountsByAggregator(this.#db, stream),
    ]);
    const aggregatorNodeIds = streamConfig.aggregators.map((a) => a.nodeId);
    const pendingByAggregator: Record<number, number> = {};
    for (const nodeId of aggregatorNodeIds) {
      pendingByAggregator[nodeId] = pending[nodeId] ?? 0;
    }
    return {
      name: stream,
      migrationStepCount: steps,
      eventCount: events,
      aggregatorNodeIds,
      pendingByAggregator,
    };
  }

  /** `streamStats` for every configured stream — the whole payload
   *  event-collectors.md §3.3.1's `GET /api/admin` endpoint returns. */
  async allStreamStats(): Promise<StreamStats[]> {
    return Promise.all(
      Object.keys(this.#config.streams).map((stream) => this.streamStats(stream)),
    );
  }

  /** Implements one iteration of event-stores.md §2.6.4 for a single
   *  (stream, aggregator) pair — a real "Aggregation loop" (batching by
   *  size/time/immediately, per `AggregationStrategy`) is future work a
   *  real event-collector process would drive by calling this on a
   *  schedule or after each `createEvents`; see the implementation
   *  plan's "Open questions" on where a `batchBySize` count would
   *  actually be tracked. `batchSize` here is taken directly from the
   *  aggregator's own `AggregationStrategy` when it's `batchBySize`,
   *  unlimited otherwise. */
  async deliverPendingFor(stream: string, aggregatorNodeId: number): Promise<number> {
    const streamConfig = this.#config.streams[stream];
    const aggregatorEntry = streamConfig?.aggregators.find(
      (a) => a.nodeId === aggregatorNodeId,
    );
    const endpoint = this.#config.aggregators[String(aggregatorNodeId)];
    if (!streamConfig || !aggregatorEntry || !endpoint) {
      throw new Error(
        `deliverPendingFor: stream "${stream}" has no configured aggregator ${aggregatorNodeId}`,
      );
    }
    if (aggregatorEntry.aggregationStrategy.kind === "sharedDatabase") {
      return 0; // shares the database directly — nothing to deliver.
    }
    const batchSize =
      aggregatorEntry.aggregationStrategy.kind === "batchBySize"
        ? aggregatorEntry.aggregationStrategy.size
        : undefined;
    return deliverPending(this.#db, aggregatorNodeId, endpoint, stream, batchSize);
  }

  /** Implements event-stores.md §2.6.5 for every configured stream —
   *  "at some fixed interval," per that section; a real caller decides
   *  the schedule (see `startBackgroundLoops` below). Returns the total
   *  rows deleted across every stream. */
  async sweepAll(now: () => number = Date.now): Promise<number> {
    let total = 0;
    for (const [stream, streamConfig] of Object.entries(this.#config.streams)) {
      const strategy = effectiveRetentionStrategy(streamConfig);
      total += await sweepStream(
        this.#db,
        stream,
        strategy,
        streamConfig.aggregators.length,
        now,
      );
    }
    return total;
  }

  /** Opt-in — `start()` below does not call this itself, so a test (or
   *  a caller that wants to drive delivery/obsolescence manually) never
   *  has stray timers to clean up. A real event-collector process calls
   *  this once at startup and `stop()` at shutdown. `sweepIntervalMs`
   *  is event-stores.md §2.6.5's own "fixed interval," left to the
   *  caller to choose; `batchByTime` aggregators get their own
   *  `deliverPendingFor` call on their configured `intervalMs`. */
  startBackgroundLoops(sweepIntervalMs: number): { stop: () => void } {
    const timers: ReturnType<typeof setInterval>[] = [];
    timers.push(setInterval(() => void this.sweepAll(), sweepIntervalMs));

    for (const [stream, streamConfig] of Object.entries(this.#config.streams)) {
      for (const aggregator of streamConfig.aggregators) {
        if (aggregator.aggregationStrategy.kind === "batchByTime") {
          const intervalMs = aggregator.aggregationStrategy.intervalMs;
          timers.push(
            setInterval(
              () => void this.deliverPendingFor(stream, aggregator.nodeId),
              intervalMs,
            ),
          );
        }
      }
    }

    return {
      stop: () => {
        for (const timer of timers) clearInterval(timer);
      },
    };
  }

  async close(): Promise<void> {
    await this.#db.close();
  }
}

/** Implements event-stores.md §2.6.2's "Application Initialization":
 *  parses `configJson`, connects to the database, migrates each
 *  configured stream, and — for each of that stream's aggregators —
 *  registers with it and checks its reported migration against this
 *  collector's own locally configured one (see `SchemaMismatchError`'s
 *  doc comment above for why this checks rather than re-applies it:
 *  `schema-migration.migrateStream` cannot be called a second time for
 *  a stream the working `catalog` already contains — `ddl_facade
 *  .apply_migration`'s own contract, see
 *  `documentation/plans/lang/migration-plan.md`'s still-open question
 *  on this). Throws (never partially started) if any stream's
 *  migration or any aggregator's schema check fails. */
export async function start(
  configJson: unknown,
  options?: {
    /** Overrides the real `Bun.SQL`-backed connection `connect()` would
     *  otherwise open — the one seam this function needs for tests to
     *  drive it without a live Postgres (see
     *  documentation/plans/architecture/event-store-implementation-plan.md's
     *  own "Test plan" note on this being the pragmatic substitute). */
    db?: DatabaseClient;
    /** Overrides `fetch` for every `registerWithAggregator` call this
     *  makes — same reasoning, for tests without a live aggregator. */
    fetchImpl?: typeof fetch;
  },
): Promise<EventStore> {
  const config = parseConfig(configJson);
  const db = options?.db ?? connect(config.databaseUrl);
  const clock = HlcClock.create(config.nodeId);
  let catalog: SchemaCatalogHandle = emptyCatalog();

  for (const [stream, streamConfig] of Object.entries(config.streams)) {
    catalog = await migrateStream(db, catalog, stream, streamConfig.migration);

    for (const aggregatorEntry of streamConfig.aggregators) {
      if (aggregatorEntry.aggregationStrategy.kind === "sharedDatabase") {
        continue;
      }
      const endpoint: AggregatorEndpoint | undefined =
        config.aggregators[String(aggregatorEntry.nodeId)];
      if (!endpoint) {
        throw new Error(
          `start: stream "${stream}" references aggregator ${aggregatorEntry.nodeId}, ` +
            `which has no entry in config.aggregators (parseConfig should have caught this)`,
        );
      }
      const { migration } = await registerWithAggregator(
        endpoint,
        stream,
        options?.fetchImpl,
      );
      if (migration !== streamConfig.migration) {
        throw new SchemaMismatchError(stream, aggregatorEntry.nodeId);
      }
    }
  }

  return new EventStore(db, clock, catalog as CatalogHandle, config);
}
