import { describe, expect, test } from "bun:test";
import { HlcClock } from "../src/hlc-clock.ts";

// Ports clock_keeper_test.gleam's assertions to the TypeScript-held
// state that replaced the actor — see hlc-clock.ts's header comment.

describe("HlcClock", () => {
  test("rejects a node id of the wrong length", () => {
    expect(() => HlcClock.create("abc")).toThrow();
  });

  test("rejects a node id containing a non-base-62 character", () => {
    expect(() => HlcClock.create("aB-x9")).toThrow();
  });

  test("next() is strictly increasing under a fixed now", () => {
    const clock = HlcClock.create("aaaaa", () => 1_700_000_000_000);
    const first = clock.next();
    const second = clock.next();
    expect(second > first).toBe(true);
    // Fixed `now`: only the counter should have advanced, so the two
    // encoded values share the same 8-character time prefix.
    expect(second.slice(0, 8)).toBe(first.slice(0, 8));
  });

  test("nextParts() decomposes the same draw next() would encode", () => {
    const clock = HlcClock.create("aaaaa", () => 1_700_000_000_000);
    const parts = clock.nextParts();
    expect(parts.encoded.length).toBe(15);
    expect(parts.physical_time_ms).toBe(1_700_000_000_000);
    // The clock's initial state already has physical_time_ms == now(), so
    // even the first draw takes the "counter didn't roll over" branch of
    // advance() (see hlc/clock.gleam), landing on 1, not 0.
    expect(parts.counter).toBe(1);
  });

  test("merge() with an older remote value advances the counter, not the time", () => {
    const clock = HlcClock.create("aaaaa", () => 1_700_000_000_000);
    const local = clock.next();
    // A remote value at local's own time, counter 0, from another node —
    // behind local's own counter, so merge should just increment it.
    const olderRemote = local.slice(0, 8) + "00" + "bbbbb";
    const merged = clock.merge(olderRemote);
    expect(merged > local).toBe(true);
    expect(merged.slice(0, 8)).toBe(local.slice(0, 8));
  });

  test("merge() rejects a malformed remote value", () => {
    const clock = HlcClock.create("aaaaa", () => 1_700_000_000_000);
    expect(() => clock.merge("bad!")).toThrow();
  });
});
