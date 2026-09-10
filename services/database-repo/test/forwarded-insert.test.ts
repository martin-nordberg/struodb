import { describe, expect, test } from "bun:test";
import { buildForwardedInsertSql } from "../src/forwarded-insert.ts";

// Pure SQL-string-building tests — no real Postgres needed. Mirrors
// domain/streams/src/lang/dml_codegen.gleam's own `WITH ins AS (...)`
// fan-out shape (see dml_codegen_test.gleam's own aggregator-fan-out
// tests), since this is the TypeScript-side equivalent for events that
// never go through StruoQL/dml_facade.

describe("buildForwardedInsertSql", () => {
  test("with no aggregators, renders a plain parameterized bulk insert", () => {
    const result = buildForwardedInsertSql(
      "s",
      [{ _struo_hlc: "abc", a: 1 }],
      [],
    );
    expect(result.sql).toBe(
      "INSERT INTO s (_struo_hlc, a)\nVALUES\n  ($1, $2)\nON CONFLICT DO NOTHING;",
    );
    expect(result.params).toEqual(["abc", 1]);
  });

  test("with aggregators, wraps in a WITH ins AS (...) fan-out", () => {
    const result = buildForwardedInsertSql(
      "s",
      [{ _struo_hlc: "abc", a: 1 }],
      [7, 12],
    );
    expect(result.sql).toBe(
      "WITH ins AS (\n" +
        "  INSERT INTO s (_struo_hlc, a)\n" +
        "  VALUES\n    ($1, $2)\n" +
        "  ON CONFLICT DO NOTHING\n" +
        "    RETURNING *\n" +
        ")\n" +
        "INSERT INTO _struo_s_pending_aggregations (aggregator_node_id, event_hlc)\n" +
        "SELECT a.aggregator_node_id, ins._struo_hlc\n" +
        "FROM ins CROSS JOIN unnest(ARRAY[7, 12]) AS a(aggregator_node_id);",
    );
    expect(result.params).toEqual(["abc", 1]);
  });

  test("quotes an identifier that needs it", () => {
    const result = buildForwardedInsertSql("MixedCase", [{ a: 1 }], []);
    expect(result.sql.startsWith('INSERT INTO "MixedCase"')).toBe(true);
  });

  test("flattens placeholders across multiple rows in order", () => {
    const result = buildForwardedInsertSql(
      "s",
      [
        { a: 1, b: 2 },
        { a: 3, b: 4 },
      ],
      [],
    );
    expect(result.sql).toContain("VALUES\n  ($1, $2),\n  ($3, $4)");
    expect(result.params).toEqual([1, 2, 3, 4]);
  });

  test("throws on an empty rows array", () => {
    expect(() => buildForwardedInsertSql("s", [], [])).toThrow();
  });

  test("throws when a later row is missing a column the first row has", () => {
    expect(() =>
      buildForwardedInsertSql("s", [{ a: 1 }, { b: 2 }], []),
    ).toThrow();
  });
});
