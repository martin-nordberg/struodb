import { describe, expect, test } from "bun:test";
import { EventCreationError } from "event-creation";
import type { InsertStatementResult, StreamStats } from "event-store";
import { createApp, type EventCreationBackend } from "../src/index.ts";

function backendWith(overrides: Partial<EventCreationBackend>): EventCreationBackend {
  return {
    createEvents: async () => {
      throw new Error("createEvents not stubbed");
    },
    allStreamStats: async () => [],
    ...overrides,
  };
}

describe("POST /api/events", () => {
  test("a count result renders as {\"count\": N}", async () => {
    const app = createApp(
      backendWith({
        createEvents: async (): Promise<InsertStatementResult[]> => [
          { kind: "count", count: 3 },
        ],
      }),
    );
    const res = await app.request("/api/events", {
      method: "POST",
      body: "INSERT INTO s (a) VALUES (1);",
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual([{ count: 3 }]);
  });

  test("a rows result renders as the RETURNING rows array verbatim", async () => {
    const app = createApp(
      backendWith({
        createEvents: async (): Promise<InsertStatementResult[]> => [
          { kind: "rows", rows: [{ _struo_hlc: "abc" }] },
        ],
      }),
    );
    const res = await app.request("/api/events", {
      method: "POST",
      body: "INSERT INTO s (a) VALUES (1) RETURNING _struo_hlc;",
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual([[{ _struo_hlc: "abc" }]]);
  });

  test("multiple statements render multiple entries in order", async () => {
    const app = createApp(
      backendWith({
        createEvents: async (): Promise<InsertStatementResult[]> => [
          { kind: "count", count: 1 },
          { kind: "rows", rows: [{ a: 1 }] },
        ],
      }),
    );
    const res = await app.request("/api/events", { method: "POST", body: "..." });
    expect(await res.json()).toEqual([{ count: 1 }, [{ a: 1 }]]);
  });

  test("EventCreationError responds 400 with the error message", async () => {
    const app = createApp(
      backendWith({
        createEvents: async () => {
          throw new EventCreationError("unknown stream");
        },
      }),
    );
    const res = await app.request("/api/events", { method: "POST", body: "bad" });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({
      error: "event creation failed: unknown stream",
    });
  });

  test("an unexpected error responds 500", async () => {
    const app = createApp(
      backendWith({
        createEvents: async () => {
          throw new Error("boom");
        },
      }),
    );
    const res = await app.request("/api/events", { method: "POST", body: "x" });
    expect(res.status).toBe(500);
  });
});

describe("GET /api/admin", () => {
  test("returns {streams: [...]} matching allStreamStats verbatim", async () => {
    const stats: StreamStats[] = [
      {
        name: "sensor_reading",
        migrationStepCount: 2,
        eventCount: 5,
        aggregatorNodeIds: [7],
        pendingByAggregator: { 7: 1 },
      },
    ];
    const app = createApp(backendWith({ allStreamStats: async () => stats }));
    const res = await app.request("/api/admin");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ streams: stats });
  });
});
