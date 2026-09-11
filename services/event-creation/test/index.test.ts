import { describe, expect, test } from "bun:test";
import { connect, type DatabaseClient } from "database-repo";
import { HlcClock } from "hlc-clock";
import { createEvents, EventCreationError } from "../src/index.ts";

// Real, in-memory PGLite instances (see database-repo's own test suite
// for why this is possible now) rather than a fake — the real risk
// this package's own logic runs is whether `execStatement`'s
// `affectedRows` means what the aggregator-count correction assumes,
// which a fake can't actually exercise.
//
// Also builds a realistic Catalog via the real language front end
// (schema/ddl_facade), the same "go through the real thing rather than
// hand-build a Catalog" pattern domain/streams/test/dml_facade_test.gleam
// already uses one layer down — production code in src/index.ts never
// imports schema's compiled output at all.
// @ts-expect-error — no .d.ts for compiled Gleam output.
import * as schemaFacade from "../../../domain/schema/build/dev/javascript/schema/ddl_facade.mjs";

async function setUp(): Promise<{ db: DatabaseClient; catalog: unknown }> {
  const db = connect("pglite://");
  const [resultJson, catalog] = schemaFacade.apply_ddl(
    schemaFacade.empty_catalog(),
    "CREATE STREAM sensor_reading (reading REAL);",
  );
  const result = JSON.parse(resultJson);
  await db.exec(result.sql);
  return { db, catalog };
}

function testClock(): HlcClock {
  return HlcClock.create(7, () => 1_700_000_000_000);
}

describe("createEvents", () => {
  test("a stream with no aggregators, no RETURNING: one count per row inserted", async () => {
    const { db, catalog } = await setUp();
    const results = await createEvents(
      db,
      testClock(),
      catalog,
      "INSERT INTO sensor_reading (reading) VALUES (42.5), (1.0);",
      () => [],
    );
    expect(results).toEqual([{ kind: "count", count: 2 }]);
    await db.close();
  });

  test("2 aggregators, no RETURNING, 3 rows: reports 3, not 6 — the aggregator-count correction", async () => {
    const { db, catalog } = await setUp();
    const results = await createEvents(
      db,
      testClock(),
      catalog,
      "INSERT INTO sensor_reading (reading) VALUES (1), (2), (3);",
      () => [7, 12],
    );
    expect(results).toEqual([{ kind: "count", count: 3 }]);

    const pending = await db.query(
      "SELECT * FROM _struo_sensor_reading_pending_aggregations",
    );
    // The real proof: 3 rows x 2 aggregators actually landed in the
    // bookkeeping table, even though the reported count above is 3.
    expect(pending.length).toBe(6);
    await db.close();
  });

  test("2 aggregators with RETURNING: rows, unaffected by aggregator count", async () => {
    const { db, catalog } = await setUp();
    const results = await createEvents(
      db,
      testClock(),
      catalog,
      "INSERT INTO sensor_reading (reading) VALUES (1), (2), (3) RETURNING _struo_hlc;",
      () => [7, 12],
    );
    expect(results.length).toBe(1);
    const result = results[0]!;
    expect(result.kind).toBe("rows");
    if (result.kind === "rows") {
      expect(result.rows.length).toBe(3);
    }
    await db.close();
  });

  test("two statements targeting streams with different aggregator counts get independent, correct results", async () => {
    const db = connect("pglite://");
    const [createResultJson, catalog] = schemaFacade.apply_ddl(
      schemaFacade.empty_catalog(),
      "CREATE STREAM s (a INT); CREATE STREAM t (a INT);",
    );
    const createResult = JSON.parse(createResultJson);
    await db.exec(createResult.sql);

    const results = await createEvents(
      db,
      testClock(),
      catalog,
      "INSERT INTO s (a) VALUES (1), (2); INSERT INTO t (a) VALUES (3);",
      (stream) => (stream === "s" ? [7] : []),
    );
    expect(results).toEqual([
      { kind: "count", count: 2 },
      { kind: "count", count: 1 },
    ]);
    await db.close();
  });

  test("a semantic error throws EventCreationError without touching the database", async () => {
    const { db, catalog } = await setUp();
    await expect(
      createEvents(
        db,
        testClock(),
        catalog,
        "INSERT INTO nonexistent (a) VALUES (1);",
        () => [],
      ),
    ).rejects.toThrow(EventCreationError);
    const rows = await db.query("SELECT * FROM sensor_reading");
    expect(rows.length).toBe(0);
    await db.close();
  });
});
