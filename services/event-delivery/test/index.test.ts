import { describe, expect, test } from "bun:test";
import {
  deliverPending,
  EventDeliveryError,
  handleIncomingEvents,
} from "../src/index.ts";
import { FakeDatabaseClient } from "./fake-database-client.ts";

function seedPending(
  db: FakeDatabaseClient,
  count: number,
  aggregatorNodeId = 7,
  startAt = 0,
) {
  for (let i = 0; i < count; i++) {
    const hlc = `hlc-${String(startAt + i).padStart(3, "0")}`;
    db.pendingRows.push({ aggregatorNodeId, eventHlc: hlc });
    db.streamRows.push({ _struo_hlc: hlc, a: i });
  }
}

describe("deliverPending", () => {
  test("returns 0 and makes no HTTP call when nothing is pending", async () => {
    const db = new FakeDatabaseClient();
    let called = false;
    const fetchImpl = (async (_url: string | URL, _init?: RequestInit) => {
      called = true;
      return new Response("{}", { status: 200 });
    }) as typeof fetch;

    const count = await deliverPending(
      db,
      7,
      { baseUrl: "https://x" },
      "s",
      undefined,
      fetchImpl,
    );
    expect(count).toBe(0);
    expect(called).toBe(false);
  });

  test("delivers pending rows and deletes only that aggregator's rows on success", async () => {
    const db = new FakeDatabaseClient();
    seedPending(db, 3, 7);
    seedPending(db, 1, 12, 100); // a different aggregator's own pending row

    let deliveredBody: unknown;
    const fetchImpl = (async (_url: string | URL, init?: RequestInit) => {
      deliveredBody = JSON.parse(String(init?.body));
      return new Response("{}", { status: 200 });
    }) as typeof fetch;

    const count = await deliverPending(
      db,
      7,
      { baseUrl: "https://aggregator.example.com" },
      "s",
      undefined,
      fetchImpl,
    );

    expect(count).toBe(3);
    expect((deliveredBody as { rows: unknown[] }).rows.length).toBe(3);
    // Only aggregator 7's rows were delivered/deleted; aggregator 12's
    // own pending row is untouched.
    expect(db.pendingRows.length).toBe(1);
    expect(db.pendingRows[0]!.aggregatorNodeId).toBe(12);
  });

  test("respects batchSize", async () => {
    const db = new FakeDatabaseClient();
    seedPending(db, 5, 7);
    const fetchImpl = (async (_url: string | URL, _init?: RequestInit) =>
      new Response("{}", { status: 200 })) as typeof fetch;

    const count = await deliverPending(
      db,
      7,
      { baseUrl: "https://x" },
      "s",
      2,
      fetchImpl,
    );
    expect(count).toBe(2);
    expect(db.pendingRows.length).toBe(3);
  });

  test("leaves pending rows untouched when delivery fails", async () => {
    const db = new FakeDatabaseClient();
    seedPending(db, 2, 7);
    const fetchImpl = (async (_url: string | URL, _init?: RequestInit) =>
      new Response("server error", { status: 500 })) as typeof fetch;

    await expect(
      deliverPending(db, 7, { baseUrl: "https://x" }, "s", undefined, fetchImpl),
    ).rejects.toThrow(EventDeliveryError);
    expect(db.pendingRows.length).toBe(2);
  });
});

describe("handleIncomingEvents", () => {
  test("forwards to insertForwardedEvents with this aggregator's own downstream fan-out", async () => {
    const db = new FakeDatabaseClient();
    const rows = [{ _struo_hlc: "hlc-000", a: 1 }];
    await handleIncomingEvents(db, "s", rows, () => [99]);

    expect(db.forwardedInserts.length).toBe(1);
    expect(db.forwardedInserts[0]).toEqual({
      stream: "s",
      rows,
      aggregatorNodeIds: [99],
    });
  });
});
