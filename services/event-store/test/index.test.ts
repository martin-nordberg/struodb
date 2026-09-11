import { describe, expect, test } from "bun:test";
import { connect } from "database-repo";
import { effectiveRetentionStrategy, SchemaMismatchError, start } from "../src/index.ts";
import type { StreamConfig } from "../src/config.ts";

// Real, in-memory PGLite instances (see database-repo's own test suite
// for why this is possible now) rather than a fake — `streamStats`
// needs real admin-stats queries to run against, which a hand-rolled
// fake can't support without becoming a second database implementation
// in miniature.

function baseConfig() {
  return {
    databaseUrl: "pglite://",
    nodeId: 1,
    aggregators: {
      "7": { baseUrl: "https://aggregator-7.example.com" },
    },
    streams: {
      sensor_reading: {
        migration: "CREATE STREAM sensor_reading (reading REAL);",
        aggregators: [] as unknown[],
      },
    },
  };
}

describe("start", () => {
  test("initializes correctly with a stream that has no aggregators", async () => {
    const db = connect("pglite://");
    const store = await start(baseConfig(), { db });

    await store.createEvents("INSERT INTO sensor_reading (reading) VALUES (1.0);");

    const stats = await store.streamStats("sensor_reading");
    expect(stats.migrationStepCount).toBe(1);
    expect(stats.eventCount).toBe(1);
    expect(stats.aggregatorNodeIds).toEqual([]);
    expect(stats.pendingByAggregator).toEqual({});

    await store.close();
  });

  test("registers with a configured aggregator and accepts a matching migration", async () => {
    const config = baseConfig();
    config.streams.sensor_reading.aggregators = [
      {
        nodeId: 7,
        aggregationStrategy: { kind: "sentImmediately" },
        retentionStrategy: { kind: "indefinite" },
      },
    ];
    const db = connect("pglite://");
    const fetchImpl = (async (_url: string | URL, _init?: RequestInit) =>
      new Response(
        JSON.stringify({ migration: config.streams.sensor_reading.migration }),
        { status: 200 },
      )) as typeof fetch;

    const store = await start(config, { db, fetchImpl });
    expect(store).toBeDefined();

    const stats = await store.streamStats("sensor_reading");
    expect(stats.aggregatorNodeIds).toEqual([7]);
    expect(stats.pendingByAggregator).toEqual({ 7: 0 });

    await store.close();
  });

  test("throws SchemaMismatchError when the aggregator reports a different migration", async () => {
    const config = baseConfig();
    config.streams.sensor_reading.aggregators = [
      {
        nodeId: 7,
        aggregationStrategy: { kind: "sentImmediately" },
        retentionStrategy: { kind: "indefinite" },
      },
    ];
    const db = connect("pglite://");
    const fetchImpl = (async (_url: string | URL, _init?: RequestInit) =>
      new Response(
        JSON.stringify({ migration: "CREATE STREAM sensor_reading (different INT);" }),
        { status: 200 },
      )) as typeof fetch;

    await expect(start(config, { db, fetchImpl })).rejects.toThrow(SchemaMismatchError);
    await db.close();
  });

  test("an invalid config throws before ever opening a database connection", async () => {
    // No `db` override needed: `parseConfig` runs before `start` would
    // ever call `connect`/touch `options.db`.
    await expect(start({ nodeId: -1 })).rejects.toThrow();
  });
});

describe("effectiveRetentionStrategy", () => {
  function streamConfig(
    ...retentionStrategies: StreamConfig["aggregators"][number]["retentionStrategy"][]
  ): StreamConfig {
    return {
      migration: "",
      aggregators: retentionStrategies.map((retentionStrategy, i) => ({
        nodeId: i,
        aggregationStrategy: { kind: "sentImmediately" },
        retentionStrategy,
      })),
    };
  }

  test("indefinite if any aggregator asks for it", () => {
    const result = effectiveRetentionStrategy(
      streamConfig({ kind: "removedAfterAggregation", threshold: 1 }, { kind: "indefinite" }),
    );
    expect(result).toEqual({ kind: "indefinite" });
  });

  test("no aggregators at all is treated as indefinite", () => {
    expect(effectiveRetentionStrategy(streamConfig())).toEqual({ kind: "indefinite" });
  });

  test("takes the largest threshold across removedAfterAggregation entries", () => {
    const result = effectiveRetentionStrategy(
      streamConfig(
        { kind: "removedAfterAggregation", threshold: 1 },
        { kind: "removedAfterAggregation", threshold: 2 },
      ),
    );
    expect(result).toEqual({ kind: "removedAfterAggregation", threshold: 2 });
  });

  test("promotes to timeLimited if any entry is timeLimited, taking the largest interval", () => {
    const result = effectiveRetentionStrategy(
      streamConfig(
        { kind: "removedAfterAggregation", threshold: 1 },
        { kind: "timeLimited", threshold: 2, intervalMs: 1000 },
        { kind: "timeLimited", threshold: 1, intervalMs: 5000 },
      ),
    );
    expect(result).toEqual({ kind: "timeLimited", threshold: 2, intervalMs: 5000 });
  });
});
