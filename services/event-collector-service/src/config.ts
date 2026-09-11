// Configuration for the standalone collector deployable itself, wrapping
// `EventStoreConfig` rather than extending it — `port`/`sweepIntervalMs`
// are collector-app concerns, not "event store" ones (an aggregator
// process would use `EventStoreConfig` too, with no HTTP port of its
// own). See
// documentation/plans/architecture/event-collector-implementation-plan.md,
// Phase 7.

import {
  ConfigError,
  parseConfig as parseEventStoreConfig,
  type EventStoreConfig,
} from "event-store";

export interface EventCollectorConfig {
  eventStore: EventStoreConfig;
  port: number;
  /** event-stores.md §2.6.5's "fixed interval," in milliseconds —
   *  passed straight to `EventStore.startBackgroundLoops`. */
  sweepIntervalMs: number;
}

const DEFAULT_SWEEP_INTERVAL_MS = 60_000;

/** Throws `ConfigError` (re-exported from `event-store`) listing every
 *  problem found, including every issue `parseEventStoreConfig` itself
 *  finds in the nested `eventStore` field (prefixed `eventStore.` so
 *  its origin stays clear) — same "collect everything, don't fail
 *  fast" reasoning `event-store`'s own `parseConfig` already
 *  documents. */
export function parseEventCollectorConfig(json: unknown): EventCollectorConfig {
  if (typeof json !== "object" || json === null || Array.isArray(json)) {
    throw new ConfigError(["config must be a JSON object"]);
  }
  const obj = json as Record<string, unknown>;
  const issues: string[] = [];

  let eventStore: EventStoreConfig | undefined;
  try {
    eventStore = parseEventStoreConfig(obj.eventStore);
  } catch (err) {
    if (!(err instanceof ConfigError)) throw err;
    issues.push(...err.issues.map((i) => `eventStore.${i}`));
  }

  const port = obj.port;
  if (typeof port !== "number" || !Number.isInteger(port) || port <= 0) {
    issues.push(`port: must be a positive integer (got ${JSON.stringify(port)})`);
  }

  const sweepIntervalMs = obj.sweepIntervalMs ?? DEFAULT_SWEEP_INTERVAL_MS;
  if (
    typeof sweepIntervalMs !== "number" ||
    !Number.isInteger(sweepIntervalMs) ||
    sweepIntervalMs <= 0
  ) {
    issues.push(
      `sweepIntervalMs: must be a positive integer if given (got ${JSON.stringify(obj.sweepIntervalMs)})`,
    );
  }

  if (issues.length > 0) {
    throw new ConfigError(issues);
  }
  return {
    eventStore: eventStore!,
    port: port as number,
    sweepIntervalMs: sweepIntervalMs as number,
  };
}
