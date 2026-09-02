import { describe, expect, test } from "bun:test";
import { applyDdl, emptyCatalog } from "../src/bridges/schema-bridge.ts";

// Thin: confirms a real compiled-Gleam round trip through the bridge
// works and renders the JSON shape ddl_facade.gleam promises — not
// re-testing ddl_semantics/ddl_codegen logic itself (that's
// ddl_facade_test.gleam and the existing lang/ suites' job).

describe("schema-bridge", () => {
  test("applyDdl on a valid CREATE STREAM returns ok JSON and an updated catalog", () => {
    const [resultJson, updatedCatalog] = applyDdl(
      emptyCatalog(),
      "CREATE STREAM s (a INT);",
    );
    const result = JSON.parse(resultJson);
    expect(result.ok).toBe(true);
    expect(String(result.sql)).toContain("CREATE TABLE");
    expect(updatedCatalog).not.toBe(emptyCatalog());
  });

  test("applyDdl on an unknown stream returns error JSON", () => {
    const [resultJson] = applyDdl(
      emptyCatalog(),
      "ALTER STREAM nonexistent ADD COLUMN b INT OPTIONAL;",
    );
    const result = JSON.parse(resultJson);
    expect(result.ok).toBe(false);
    expect(typeof result.error).toBe("string");
  });

  test("the catalog returned by applyDdl threads into a second call", () => {
    const [, afterCreate] = applyDdl(emptyCatalog(), "CREATE STREAM s (a INT);");
    const [resultJson] = applyDdl(
      afterCreate,
      "ALTER STREAM s ADD COLUMN b INT OPTIONAL;",
    );
    const result = JSON.parse(resultJson);
    expect(result.ok).toBe(true);
    expect(String(result.sql)).toContain("ALTER TABLE");
  });
});
