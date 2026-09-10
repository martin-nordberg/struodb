// Event Store Configuration — resolves
// documentation/docs/specifications/architecture/event-stores.md §2.5's
// `TODO: Define a JSON format for the above`. See
// documentation/plans/architecture/event-store-implementation-plan.md,
// Phase 6.

import { MAX_NODE_ID } from "hlc-clock";

export interface EventStoreConfig {
  databaseUrl: string;
  /** This node's own identity — plain integer, `0 <= nodeId <=
   *  MAX_NODE_ID`. Fed to `HlcClock.create` as-is; never base-62 text at
   *  this layer — see "Decisions carried over from discussion" in the
   *  implementation plan. */
  nodeId: number;
  streams: Record<string, StreamConfig>;
  /** Keyed by node id (as a decimal string — plain JSON object keys are
   *  always strings) rather than by an arbitrary name, since a node id
   *  is already this system's one identity for a node. */
  aggregators: Record<string, AggregatorConfig>;
}

export interface StreamConfig {
  /** Full `CREATE STREAM` + `ALTER STREAM` history, in order, one
   *  string — exactly `schema-migration`'s `migrateStream`'s own
   *  `source` input. */
  migration: string;
  aggregators: StreamAggregatorConfig[];
}

export interface StreamAggregatorConfig {
  /** Same bounded integer space as `EventStoreConfig.nodeId` — this is
   *  the *other* node's identity, one it would itself pass to its own
   *  `HlcClock.create` were it acting as a collector. Must have a
   *  matching entry in the top-level `aggregators` map. */
  nodeId: number;
  aggregationStrategy: AggregationStrategy;
  retentionStrategy: RetentionStrategy;
}

export type AggregationStrategy =
  | { kind: "sentImmediately" }
  | { kind: "batchBySize"; size: number }
  | { kind: "batchByTime"; intervalMs: number }
  | { kind: "sharedDatabase" };

export type RetentionStrategy =
  | { kind: "indefinite" }
  | { kind: "removedAfterAggregation"; threshold: number }
  | { kind: "timeLimited"; threshold: number; intervalMs: number };

export interface AggregatorConfig {
  baseUrl: string;
}

/** Thrown by `parseConfig` — `issues` lists every problem found, not
 *  just the first, since this runs once at startup against a config
 *  file a human edits by hand (see the implementation plan's own note:
 *  "not fail-fast ... since ... a human edits by hand"). */
export class ConfigError extends Error {
  readonly issues: string[];

  constructor(issues: string[]) {
    super(`invalid Event Store Configuration:\n${issues.map((i) => `  - ${i}`).join("\n")}`);
    this.name = "ConfigError";
    this.issues = issues;
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNodeId(value: unknown): value is number {
  return (
    typeof value === "number" &&
    Number.isInteger(value) &&
    value >= 0 &&
    value <= MAX_NODE_ID
  );
}

class Validator {
  issues: string[] = [];

  fail(path: string, message: string): void {
    this.issues.push(`${path}: ${message}`);
  }

  nodeId(path: string, value: unknown): number | undefined {
    if (!isNodeId(value)) {
      this.fail(
        path,
        `must be an integer between 0 and ${MAX_NODE_ID} (got ${JSON.stringify(value)})`,
      );
      return undefined;
    }
    return value;
  }

  string(path: string, value: unknown): string | undefined {
    if (typeof value !== "string") {
      this.fail(path, `must be a string (got ${JSON.stringify(value)})`);
      return undefined;
    }
    return value;
  }

  positiveInt(path: string, value: unknown): number | undefined {
    if (typeof value !== "number" || !Number.isInteger(value) || value <= 0) {
      this.fail(path, `must be a positive integer (got ${JSON.stringify(value)})`);
      return undefined;
    }
    return value;
  }

  aggregationStrategy(path: string, value: unknown): AggregationStrategy | undefined {
    if (!isPlainObject(value) || typeof value.kind !== "string") {
      this.fail(path, `must be an object with a "kind" field`);
      return undefined;
    }
    switch (value.kind) {
      case "sentImmediately":
      case "sharedDatabase":
        return { kind: value.kind };
      case "batchBySize": {
        const size = this.positiveInt(`${path}.size`, value.size);
        return size === undefined ? undefined : { kind: "batchBySize", size };
      }
      case "batchByTime": {
        const intervalMs = this.positiveInt(`${path}.intervalMs`, value.intervalMs);
        return intervalMs === undefined
          ? undefined
          : { kind: "batchByTime", intervalMs };
      }
      default:
        this.fail(
          path,
          `unknown aggregation strategy kind "${value.kind}" (expected one of ` +
            `sentImmediately, batchBySize, batchByTime, sharedDatabase)`,
        );
        return undefined;
    }
  }

  /** `aggregatorCount` bounds `threshold` — see "Decisions carried over
   *  from discussion" in the implementation plan: a plain threshold
   *  count, `1 <= threshold <= aggregatorCount`, not necessarily a
   *  majority despite event-stores.md's own "quorum" wording there. */
  retentionStrategy(
    path: string,
    value: unknown,
    aggregatorCount: number,
  ): RetentionStrategy | undefined {
    if (!isPlainObject(value) || typeof value.kind !== "string") {
      this.fail(path, `must be an object with a "kind" field`);
      return undefined;
    }
    const threshold = (thresholdPath: string): number | undefined => {
      const t = this.positiveInt(thresholdPath, value.threshold);
      if (t !== undefined && t > aggregatorCount) {
        this.fail(
          thresholdPath,
          `must be <= this stream aggregator's total aggregator count (${aggregatorCount}), got ${t}`,
        );
        return undefined;
      }
      return t;
    };
    switch (value.kind) {
      case "indefinite":
        return { kind: "indefinite" };
      case "removedAfterAggregation": {
        const t = threshold(`${path}.threshold`);
        return t === undefined
          ? undefined
          : { kind: "removedAfterAggregation", threshold: t };
      }
      case "timeLimited": {
        const t = threshold(`${path}.threshold`);
        const intervalMs = this.positiveInt(`${path}.intervalMs`, value.intervalMs);
        return t === undefined || intervalMs === undefined
          ? undefined
          : { kind: "timeLimited", threshold: t, intervalMs };
      }
      default:
        this.fail(
          path,
          `unknown retention strategy kind "${value.kind}" (expected one of ` +
            `indefinite, removedAfterAggregation, timeLimited)`,
        );
        return undefined;
    }
  }
}

/** Parses and fully validates `json` as an `EventStoreConfig`. Throws
 *  `ConfigError` (listing every problem found) rather than returning a
 *  `Result`-shaped value — there is no reasonable partial config to hand
 *  back to a caller, and the one real caller (`services/event-store`'s
 *  own `start()`) has nothing sensible to do but fail startup anyway. */
export function parseConfig(json: unknown): EventStoreConfig {
  const v = new Validator();

  if (!isPlainObject(json)) {
    throw new ConfigError(["config must be a JSON object"]);
  }

  const databaseUrl = v.string("databaseUrl", json.databaseUrl);
  const nodeId = v.nodeId("nodeId", json.nodeId);

  const aggregators: Record<string, AggregatorConfig> = {};
  if (!isPlainObject(json.aggregators)) {
    v.fail("aggregators", "must be an object");
  } else {
    for (const [key, value] of Object.entries(json.aggregators)) {
      const path = `aggregators.${key}`;
      if (!isNodeId(Number(key)) || String(Number(key)) !== key) {
        v.fail(path, `key must be a plain integer node id (0..${MAX_NODE_ID})`);
        continue;
      }
      if (!isPlainObject(value)) {
        v.fail(path, "must be an object");
        continue;
      }
      const baseUrl = v.string(`${path}.baseUrl`, value.baseUrl);
      if (baseUrl !== undefined) {
        aggregators[key] = { baseUrl };
      }
    }
  }

  const streams: Record<string, StreamConfig> = {};
  if (!isPlainObject(json.streams)) {
    v.fail("streams", "must be an object");
  } else {
    for (const [streamName, value] of Object.entries(json.streams)) {
      const path = `streams.${streamName}`;
      if (!isPlainObject(value)) {
        v.fail(path, "must be an object");
        continue;
      }
      const migration = v.string(`${path}.migration`, value.migration);
      if (!Array.isArray(value.aggregators)) {
        v.fail(`${path}.aggregators`, "must be an array");
        continue;
      }
      const aggregatorCount = value.aggregators.length;
      const streamAggregators: StreamAggregatorConfig[] = [];
      value.aggregators.forEach((entry: unknown, index: number) => {
        const entryPath = `${path}.aggregators[${index}]`;
        if (!isPlainObject(entry)) {
          v.fail(entryPath, "must be an object");
          return;
        }
        const aggNodeId = v.nodeId(`${entryPath}.nodeId`, entry.nodeId);
        const aggregationStrategy = v.aggregationStrategy(
          `${entryPath}.aggregationStrategy`,
          entry.aggregationStrategy,
        );
        const retentionStrategy = v.retentionStrategy(
          `${entryPath}.retentionStrategy`,
          entry.retentionStrategy,
          aggregatorCount,
        );
        if (
          aggNodeId !== undefined &&
          aggregationStrategy !== undefined &&
          retentionStrategy !== undefined
        ) {
          if (!(String(aggNodeId) in aggregators)) {
            v.fail(
              `${entryPath}.nodeId`,
              `references aggregator node id ${aggNodeId}, which has no entry in the top-level "aggregators" map`,
            );
            return;
          }
          streamAggregators.push({
            nodeId: aggNodeId,
            aggregationStrategy,
            retentionStrategy,
          });
        }
      });
      if (migration !== undefined) {
        streams[streamName] = { migration, aggregators: streamAggregators };
      }
    }
  }

  if (v.issues.length > 0) {
    throw new ConfigError(v.issues);
  }

  return {
    databaseUrl: databaseUrl!,
    nodeId: nodeId!,
    streams,
    aggregators,
  };
}
