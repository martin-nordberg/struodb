import { describe, expect, test } from "bun:test";
import { sweepStream } from "../src/index.ts";
import { FakeDatabaseClient } from "./fake-database-client.ts";

describe("sweepStream", () => {
  test("indefinite never deletes and never queries the database", async () => {
    const db = new FakeDatabaseClient();
    db.seedStreamRow("s", "hlc-000", new Date(0));
    const deleted = await sweepStream(db, "s", { kind: "indefinite" }, 2);
    expect(deleted).toBe(0);
    expect(db.queryCalls).toBe(0);
  });

  test("removedAfterAggregation deletes an event once enough (not necessarily all) pending rows are gone", async () => {
    const db = new FakeDatabaseClient();
    // Fully delivered to both aggregators.
    db.seedStreamRow("s", "fully-delivered", new Date());
    // Delivered to neither aggregator yet.
    db.seedStreamRow("s", "not-delivered", new Date());
    db.seedPending("s", "not-delivered", 7);
    db.seedPending("s", "not-delivered", 12);

    // threshold 1 of 2 aggregators: at most 2-1=1 pending row may remain.
    const deleted = await sweepStream(
      db,
      "s",
      { kind: "removedAfterAggregation", threshold: 1 },
      2,
    );

    expect(deleted).toBe(1);
    const remaining = db.streamRows.get("s")!.map((r) => r._struo_hlc);
    expect(remaining).toEqual(["not-delivered"]);
  });

  test("deleting an event cascades away its own remaining pending rows for slower aggregators", async () => {
    const db = new FakeDatabaseClient();
    db.seedStreamRow("s", "e1", new Date());
    db.seedPending("s", "e1", 7); // delivered to 7 already removed elsewhere — only 12 still pending
    // Only one pending row (for aggregator 12) — threshold 1 of 2 is met.
    const deleted = await sweepStream(
      db,
      "s",
      { kind: "removedAfterAggregation", threshold: 1 },
      2,
    );
    expect(deleted).toBe(1);
    expect(db.pendingRows.get("s")).toEqual([]);
  });

  test("timeLimited only deletes rows both old enough and sufficiently delivered", async () => {
    const db = new FakeDatabaseClient();
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
    const now = new Date();

    db.seedStreamRow("s", "old-and-delivered", oneHourAgo);
    db.seedStreamRow("s", "old-but-not-delivered", oneHourAgo);
    db.seedPending("s", "old-but-not-delivered", 7);
    db.seedPending("s", "old-but-not-delivered", 12);
    db.seedStreamRow("s", "recent-and-delivered", now);

    const deleted = await sweepStream(
      db,
      "s",
      { kind: "timeLimited", threshold: 1, intervalMs: 30 * 60 * 1000 },
      2,
    );

    expect(deleted).toBe(1);
    const remaining = db.streamRows.get("s")!.map((r) => r._struo_hlc).sort();
    expect(remaining).toEqual(["old-but-not-delivered", "recent-and-delivered"]);
  });
});
