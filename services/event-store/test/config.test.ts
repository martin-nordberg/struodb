import { describe, expect, test } from "bun:test";
import { ConfigError, parseConfig } from "../src/config.ts";

function validConfig(): unknown {
  return {
    databaseUrl: "postgres://localhost/struodb",
    nodeId: 1,
    aggregators: {
      "7": { baseUrl: "https://aggregator-7.example.com" },
    },
    streams: {
      sensor_reading: {
        migration: "CREATE STREAM sensor_reading (reading REAL);",
        aggregators: [
          {
            nodeId: 7,
            aggregationStrategy: { kind: "batchBySize", size: 100 },
            retentionStrategy: { kind: "removedAfterAggregation", threshold: 1 },
          },
        ],
      },
    },
  };
}

describe("parseConfig", () => {
  test("a valid config round-trips", () => {
    const config = parseConfig(validConfig());
    expect(config.databaseUrl).toBe("postgres://localhost/struodb");
    expect(config.nodeId).toBe(1);
    expect(config.streams.sensor_reading?.aggregators[0]?.nodeId).toBe(7);
    expect(config.aggregators["7"]?.baseUrl).toBe(
      "https://aggregator-7.example.com",
    );
  });

  test("a config missing databaseUrl throws ConfigError", () => {
    const bad = validConfig() as Record<string, unknown>;
    delete bad.databaseUrl;
    expect(() => parseConfig(bad)).toThrow(ConfigError);
  });

  test("a negative nodeId is rejected", () => {
    const bad = validConfig() as Record<string, unknown>;
    bad.nodeId = -1;
    expect(() => parseConfig(bad)).toThrow(ConfigError);
  });

  test("a nodeId larger than MAX_NODE_ID is rejected", () => {
    const bad = validConfig() as Record<string, unknown>;
    bad.nodeId = 916_132_832;
    expect(() => parseConfig(bad)).toThrow(ConfigError);
  });

  test("a stream aggregator referencing an undeclared top-level aggregator is rejected", () => {
    const bad = validConfig() as any;
    bad.streams.sensor_reading.aggregators[0].nodeId = 99;
    expect(() => parseConfig(bad)).toThrow(ConfigError);
  });

  test("a threshold greater than the stream's aggregator count is rejected", () => {
    const bad = validConfig() as any;
    bad.streams.sensor_reading.aggregators[0].retentionStrategy.threshold = 2;
    expect(() => parseConfig(bad)).toThrow(ConfigError);
  });

  test("a threshold of 1 is accepted even though it's a minority of a larger aggregator set", () => {
    const cfg = validConfig() as any;
    cfg.aggregators["8"] = { baseUrl: "https://aggregator-8.example.com" };
    cfg.streams.sensor_reading.aggregators.push({
      nodeId: 8,
      aggregationStrategy: { kind: "sentImmediately" },
      retentionStrategy: { kind: "indefinite" },
    });
    cfg.streams.sensor_reading.aggregators[0].retentionStrategy.threshold = 1;
    expect(() => parseConfig(cfg)).not.toThrow();
  });

  test("an unknown aggregation strategy kind is rejected", () => {
    const bad = validConfig() as any;
    bad.streams.sensor_reading.aggregators[0].aggregationStrategy = {
      kind: "bogus",
    };
    expect(() => parseConfig(bad)).toThrow(ConfigError);
  });

  test("sharedDatabase needs no extra fields", () => {
    const cfg = validConfig() as any;
    cfg.streams.sensor_reading.aggregators[0].aggregationStrategy = {
      kind: "sharedDatabase",
    };
    cfg.streams.sensor_reading.aggregators[0].retentionStrategy = {
      kind: "indefinite",
    };
    expect(() => parseConfig(cfg)).not.toThrow();
  });

  test("multiple simultaneous errors are all listed in one thrown message", () => {
    const bad = validConfig() as Record<string, unknown>;
    delete bad.databaseUrl;
    (bad as any).nodeId = -1;
    try {
      parseConfig(bad);
      throw new Error("expected parseConfig to throw");
    } catch (err) {
      expect(err).toBeInstanceOf(ConfigError);
      const configError = err as ConfigError;
      expect(configError.issues.length).toBeGreaterThanOrEqual(2);
      expect(configError.issues.some((i) => i.startsWith("databaseUrl"))).toBe(
        true,
      );
      expect(configError.issues.some((i) => i.startsWith("nodeId"))).toBe(true);
    }
  });

  test("a non-object top-level value is rejected", () => {
    expect(() => parseConfig("not an object")).toThrow(ConfigError);
    expect(() => parseConfig(null)).toThrow(ConfigError);
  });
});
