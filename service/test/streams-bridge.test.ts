import { describe, expect, test } from "bun:test";
import { applyDdl, emptyCatalog } from "../src/bridges/schema-bridge.ts";
import { applyInsert } from "../src/bridges/streams-bridge.ts";
import { HlcClock } from "../src/hlc-clock.ts";

// Thin: confirms a real compiled-Gleam round trip through the bridge —
// including the `() => clock.nextParts()` closure crossing back into
// Gleam — works and renders the JSON shape dml_facade.gleam promises.
// Not re-testing dml_semantics/dml_codegen logic itself (that's
// dml_facade_test.gleam and the existing lang/ suites' job).

describe("streams-bridge", () => {
  test("applyInsert on a valid INSERT returns ok JSON", () => {
    const clock = HlcClock.create("aaaaa", () => 1_700_000_000_000);
    const [, catalog] = applyDdl(emptyCatalog(), "CREATE STREAM s (a INT);");

    const resultJson = applyInsert(clock, catalog, "INSERT INTO s (a) VALUES (1);");
    const result = JSON.parse(resultJson);
    expect(result.ok).toBe(true);
    expect(String(result.sql)).toContain("INSERT INTO s");
  });

  test("applyInsert against an unknown stream returns error JSON", () => {
    const clock = HlcClock.create("aaaaa", () => 1_700_000_000_000);
    const resultJson = applyInsert(
      clock,
      emptyCatalog(),
      "INSERT INTO nonexistent (a) VALUES (1);",
    );
    const result = JSON.parse(resultJson);
    expect(result.ok).toBe(false);
    expect(typeof result.error).toBe("string");
  });
});
