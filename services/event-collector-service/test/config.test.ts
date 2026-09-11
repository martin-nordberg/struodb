import { describe, expect, test } from "bun:test";
import { ConfigError } from "event-store";
import { parseEventCollectorConfig } from "../src/config.ts";

function validConfig(): unknown {
  return {
    eventStore: {
      databaseUrl: "pglite://",
      nodeId: 1,
      streams: {},
      aggregators: {},
    },
    port: 3000,
  };
}

describe("parseEventCollectorConfig", () => {
  test("a valid config round-trips, defaulting sweepIntervalMs", () => {
    const config = parseEventCollectorConfig(validConfig());
    expect(config.port).toBe(3000);
    expect(config.sweepIntervalMs).toBe(60_000);
    expect(config.eventStore.nodeId).toBe(1);
  });

  test("an explicit sweepIntervalMs is honored", () => {
    const raw = validConfig() as Record<string, unknown>;
    raw.sweepIntervalMs = 5000;
    const config = parseEventCollectorConfig(raw);
    expect(config.sweepIntervalMs).toBe(5000);
  });

  test("a missing port is reported", () => {
    const raw = validConfig() as Record<string, unknown>;
    delete raw.port;
    expect(() => parseEventCollectorConfig(raw)).toThrow(ConfigError);
  });

  test("a non-positive-integer port is reported", () => {
    const raw = validConfig() as Record<string, unknown>;
    raw.port = 0;
    expect(() => parseEventCollectorConfig(raw)).toThrow(ConfigError);
  });

  test("a non-positive-integer sweepIntervalMs is reported", () => {
    const raw = validConfig() as Record<string, unknown>;
    raw.sweepIntervalMs = -1;
    expect(() => parseEventCollectorConfig(raw)).toThrow(ConfigError);
  });

  test("an invalid nested eventStore field surfaces its issues prefixed with eventStore.", () => {
    const raw = validConfig() as Record<string, unknown>;
    raw.eventStore = { ...(raw.eventStore as Record<string, unknown>), nodeId: -1 };
    try {
      parseEventCollectorConfig(raw);
      throw new Error("expected parseEventCollectorConfig to throw");
    } catch (err) {
      expect(err).toBeInstanceOf(ConfigError);
      const configError = err as ConfigError;
      expect(configError.issues.some((i) => i.startsWith("eventStore.nodeId"))).toBe(
        true,
      );
    }
  });

  test("a non-object top-level value is rejected", () => {
    expect(() => parseEventCollectorConfig("not an object")).toThrow(ConfigError);
    expect(() => parseEventCollectorConfig(null)).toThrow(ConfigError);
  });

  test("multiple simultaneous errors (port and eventStore) are all listed", () => {
    const raw = validConfig() as Record<string, unknown>;
    delete raw.port;
    raw.eventStore = { ...(raw.eventStore as Record<string, unknown>), nodeId: -1 };
    try {
      parseEventCollectorConfig(raw);
      throw new Error("expected parseEventCollectorConfig to throw");
    } catch (err) {
      expect(err).toBeInstanceOf(ConfigError);
      const configError = err as ConfigError;
      expect(configError.issues.length).toBeGreaterThanOrEqual(2);
    }
  });
});
