import { describe, expect, test } from "bun:test";
import { effectiveRetentionStrategy, SchemaMismatchError, start } from "../src/index.ts";
import type { StreamConfig } from "../src/config.ts";
import { FakeDatabaseClient } from "./fake-database-client.ts";

function baseConfig() {
  return {
    databaseUrl: "postgres://localhost/struodb",
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
    const db = new FakeDatabaseClient();
    const store = await start(baseConfig(), { db });

    expect(db.execCalls.some((sql) => sql.includes("CREATE TABLE sensor_reading"))).toBe(
      true,
    );

    await store.createEvents("INSERT INTO sensor_reading (reading) VALUES (1.0);");
    expect(db.execCalls.some((sql) => sql.includes("INSERT INTO sensor_reading"))).toBe(
      true,
    );
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
    const db = new FakeDatabaseClient();
    const fetchImpl = (async (_url: string | URL, _init?: RequestInit) =>
      new Response(
        JSON.stringify({ migration: config.streams.sensor_reading.migration }),
        { status: 200 },
      )) as typeof fetch;

    const store = await start(config, { db, fetchImpl });
    expect(store).toBeDefined();
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
    const db = new FakeDatabaseClient();
    const fetchImpl = (async (_url: string | URL, _init?: RequestInit) =>
      new Response(
        JSON.stringify({ migration: "CREATE STREAM sensor_reading (different INT);" }),
        { status: 200 },
      )) as typeof fetch;

    await expect(start(config, { db, fetchImpl })).rejects.toThrow(SchemaMismatchError);
  });

  test("an invalid config throws before ever touching a database", async () => {
    const db = new FakeDatabaseClient();
    await expect(start({ nodeId: -1 }, { db })).rejects.toThrow();
    expect(db.execCalls.length).toBe(0);
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
