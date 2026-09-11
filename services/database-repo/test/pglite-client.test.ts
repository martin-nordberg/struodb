import { describe, expect, test } from "bun:test";
import { connect } from "../src/index.ts";

// Real, in-memory PGLite instances — no external Postgres server, no
// fake. See documentation/plans/architecture/
// event-collector-implementation-plan.md's "Decisions carried over from
// discussion" on why this is possible now (PGLite runs embedded,
// in-process) where every earlier implementation phase needed a
// hand-rolled fake.

describe("connect(\"pglite://\")", () => {
  test("exec runs a multi-statement CREATE TABLE blob", async () => {
    const db = connect("pglite://");
    await db.exec(`
      CREATE TABLE a (id INTEGER);
      CREATE TABLE b (id INTEGER);
    `);
    const tables = await db.query<{ table_name: string }>(
      "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name",
    );
    expect(tables.map((t) => t.table_name)).toEqual(["a", "b"]);
    await db.close();
  });

  test("query reads rows back with parameters", async () => {
    const db = connect("pglite://");
    await db.exec("CREATE TABLE t (a INTEGER, b TEXT)");
    await db.execStatement("INSERT INTO t (a, b) VALUES ($1, $2)", [1, "x"]);
    const rows = await db.query<{ a: number; b: string }>(
      "SELECT a, b FROM t WHERE a = $1",
      [1],
    );
    expect(rows).toEqual([{ a: 1, b: "x" }]);
    await db.close();
  });

  test("execStatement on a plain INSERT (no RETURNING) reports affectedRows with empty rows", async () => {
    const db = connect("pglite://");
    await db.exec("CREATE TABLE t (a INTEGER)");
    const result = await db.execStatement(
      "INSERT INTO t (a) VALUES (1), (2), (3)",
    );
    expect(result.affectedRows).toBe(3);
    expect(result.rows).toEqual([]);
    await db.close();
  });

  test("execStatement on INSERT ... RETURNING reports both rows and affectedRows", async () => {
    const db = connect("pglite://");
    await db.exec("CREATE TABLE t (a INTEGER)");
    const result = await db.execStatement<{ a: number }>(
      "INSERT INTO t (a) VALUES (1), (2) RETURNING a",
    );
    expect(result.affectedRows).toBe(2);
    expect(result.rows.map((r) => r.a).sort()).toEqual([1, 2]);
    await db.close();
  });

  test("insertForwardedEvents populates the stream and pending_aggregations tables, ON CONFLICT DO NOTHING included", async () => {
    const db = connect("pglite://");
    await db.exec(`
      CREATE TABLE s (_struo_hlc CHAR(15) PRIMARY KEY, a INTEGER);
      CREATE TABLE _struo_s_pending_aggregations (
        aggregator_node_id INTEGER NOT NULL,
        event_hlc CHAR(15) NOT NULL REFERENCES s(_struo_hlc) ON DELETE CASCADE,
        PRIMARY KEY (aggregator_node_id, event_hlc)
      );
    `);

    await db.insertForwardedEvents(
      "s",
      [{ _struo_hlc: "000000000000001", a: 1 }],
      [7, 12],
    );
    // Redelivering the same event is a no-op, not an error.
    await db.insertForwardedEvents(
      "s",
      [{ _struo_hlc: "000000000000001", a: 1 }],
      [7, 12],
    );

    const streamRows = await db.query("SELECT * FROM s");
    expect(streamRows.length).toBe(1);
    const pendingRows = await db.query<{ aggregator_node_id: number }>(
      "SELECT aggregator_node_id FROM _struo_s_pending_aggregations ORDER BY aggregator_node_id",
    );
    expect(pendingRows.map((r) => r.aggregator_node_id)).toEqual([7, 12]);
    await db.close();
  });

  test("close does not throw", async () => {
    const db = connect("pglite://");
    await expect(db.close()).resolves.toBeUndefined();
  });
});
