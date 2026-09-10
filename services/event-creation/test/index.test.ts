import { describe, expect, test } from "bun:test";
import { HlcClock } from "hlc-clock";
import { createEvents, EventCreationError } from "../src/index.ts";
import { FakeDatabaseClient } from "./fake-database-client.ts";

// Test-only: builds a realistic Catalog via the real language front end
// (schema/ddl_facade), the same "go through the real thing rather than
// hand-build a Catalog" pattern domain/streams/test/dml_facade_test.gleam
// already uses one layer down — production code in src/index.ts never
// imports schema's compiled output at all.
// @ts-expect-error — no .d.ts for compiled Gleam output.
import * as schemaFacade from "../../../domain/schema/build/dev/javascript/schema/ddl_facade.mjs";

function catalogWithSensorReading(): unknown {
  const [, catalog] = schemaFacade.apply_ddl(
    schemaFacade.empty_catalog(),
    "CREATE STREAM sensor_reading (reading REAL);",
  );
  return catalog;
}

function testClock(): HlcClock {
  return HlcClock.create(7, () => 1_700_000_000_000);
}

describe("createEvents", () => {
  test("a valid INSERT with no aggregators executes a plain insert", async () => {
    const db = new FakeDatabaseClient();
    await createEvents(
      db,
      testClock(),
      catalogWithSensorReading(),
      "INSERT INTO sensor_reading (reading) VALUES (42.5);",
      () => [],
    );
    expect(db.execCalls.length).toBe(1);
    expect(db.execCalls[0]).toContain("INSERT INTO sensor_reading");
    expect(db.execCalls[0]).not.toContain("pending_aggregations");
  });

  test("a valid INSERT with aggregators executes the fan-out SQL", async () => {
    const db = new FakeDatabaseClient();
    await createEvents(
      db,
      testClock(),
      catalogWithSensorReading(),
      "INSERT INTO sensor_reading (reading) VALUES (42.5);",
      () => [7, 12],
    );
    expect(db.execCalls.length).toBe(1);
    expect(db.execCalls[0]).toContain("_struo_sensor_reading_pending_aggregations");
    expect(db.execCalls[0]).toContain("unnest(ARRAY[7, 12])");
  });

  test("a semantic error throws EventCreationError without touching the database", async () => {
    const db = new FakeDatabaseClient();
    await expect(
      createEvents(
        db,
        testClock(),
        catalogWithSensorReading(),
        "INSERT INTO nonexistent (a) VALUES (1);",
        () => [],
      ),
    ).rejects.toThrow(EventCreationError);
    expect(db.execCalls.length).toBe(0);
  });
});
