import { describe, expect, test } from "bun:test";
import { HlcClock, MAX_NODE_ID } from "../src/hlc-clock.ts";

// Ports clock_keeper_test.gleam's assertions to the TypeScript-held
// state that replaced the actor — see hlc-clock.ts's header comment.

describe("HlcClock", () => {
  test("rejects a negative node id", () => {
    expect(() => HlcClock.create(-1)).toThrow();
  });

  test("rejects a node id larger than MAX_NODE_ID", () => {
    expect(() => HlcClock.create(MAX_NODE_ID + 1)).toThrow();
  });

  test("accepts a node id of 0", () => {
    expect(() => HlcClock.create(0)).not.toThrow();
  });

  test("accepts a node id of MAX_NODE_ID", () => {
    expect(() => HlcClock.create(MAX_NODE_ID)).not.toThrow();
  });

  test("next() is strictly increasing under a fixed now", () => {
    const clock = HlcClock.create(7, () => 1_700_000_000_000);
    const first = clock.next();
    const second = clock.next();
    expect(second > first).toBe(true);
    // Fixed `now`: only the counter should have advanced, so the two
    // encoded values share the same 8-character time prefix.
    expect(second.slice(0, 8)).toBe(first.slice(0, 8));
  });

  test("nextParts() decomposes the same draw next() would encode", () => {
    const clock = HlcClock.create(7, () => 1_700_000_000_000);
    const parts = clock.nextParts();
    expect(parts.encoded.length).toBe(15);
    expect(parts.physical_time_ms).toBe(1_700_000_000_000);
    // The clock's initial state already has physical_time_ms == now(), so
    // even the first draw takes the "counter didn't roll over" branch of
    // advance() (see hlc/clock.gleam), landing on 1, not 0.
    expect(parts.counter).toBe(1);
    // Round-trips through the 5-character base-62 field and back.
    expect(parts.node_id).toBe(7);
  });

  test("merge() with an older remote value advances the counter, not the time", () => {
    const clock = HlcClock.create(7, () => 1_700_000_000_000);
    const local = clock.next();
    // A remote value at local's own time, counter 0, from another node —
    // behind local's own counter, so merge should just increment it.
    const olderRemote = local.slice(0, 8) + "00" + "bbbbb";
    const merged = clock.merge(olderRemote);
    expect(merged > local).toBe(true);
    expect(merged.slice(0, 8)).toBe(local.slice(0, 8));
  });

  test("merge() rejects a malformed remote value", () => {
    const clock = HlcClock.create(7, () => 1_700_000_000_000);
    expect(() => clock.merge("bad!")).toThrow();
  });

  describe("thresholdForTime", () => {
    test("is exactly 15 characters", () => {
      expect(HlcClock.thresholdForTime(1_700_000_000_000).length).toBe(15);
    });

    test("a real value drawn at the same millisecond sorts >= it", () => {
      const clock = HlcClock.create(7, () => 1_700_000_000_000);
      const threshold = HlcClock.thresholdForTime(1_700_000_000_000);
      expect(clock.next() >= threshold).toBe(true);
    });

    test("a real value from the previous millisecond sorts < it", () => {
      const clock = HlcClock.create(7, () => 1_699_999_999_999);
      const threshold = HlcClock.thresholdForTime(1_700_000_000_000);
      expect(clock.next() < threshold).toBe(true);
    });
  });
});
