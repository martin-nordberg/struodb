import { describe, expect, test } from "bun:test";
import {
  migrationStepCount,
  pendingCountsByAggregator,
  streamEventCount,
} from "../src/admin-stats.ts";
import { connect } from "../src/index.ts";

describe("admin-stats", () => {
  test("streamEventCount, migrationStepCount, pendingCountsByAggregator", async () => {
    const db = connect("pglite://");
    await db.exec(`
      CREATE TABLE sensor_reading (_struo_hlc CHAR(15) PRIMARY KEY, a INTEGER);
      CREATE TABLE _struo_sensor_reading_migration_history (seq INTEGER PRIMARY KEY, hash CHAR(64));
      CREATE TABLE _struo_sensor_reading_pending_aggregations (
        aggregator_node_id INTEGER NOT NULL,
        event_hlc CHAR(15) NOT NULL REFERENCES sensor_reading(_struo_hlc) ON DELETE CASCADE,
        PRIMARY KEY (aggregator_node_id, event_hlc)
      );
    `);

    // One CREATE STREAM + one ALTER STREAM applied so far.
    await db.execStatement(
      "INSERT INTO _struo_sensor_reading_migration_history (seq, hash) VALUES ($1, $2), ($3, $4)",
      [0, "a".repeat(64), 1, "b".repeat(64)],
    );

    await db.insertForwardedEvents(
      "sensor_reading",
      [
        { _struo_hlc: "000000000000001", a: 1 },
        { _struo_hlc: "000000000000002", a: 2 },
        { _struo_hlc: "000000000000003", a: 3 },
      ],
      [7, 12],
    );
    // Aggregator 7 has already received event 1.
    await db.query(
      "DELETE FROM _struo_sensor_reading_pending_aggregations WHERE aggregator_node_id = 7 AND event_hlc = $1",
      ["000000000000001"],
    );

    expect(await streamEventCount(db, "sensor_reading")).toBe(3);
    expect(await migrationStepCount(db, "sensor_reading")).toBe(2);
    expect(await pendingCountsByAggregator(db, "sensor_reading")).toEqual({
      7: 2,
      12: 3,
    });

    await db.close();
  });

  test("a stream with no pending rows at all reports an empty object", async () => {
    const db = connect("pglite://");
    await db.exec(`
      CREATE TABLE s (_struo_hlc CHAR(15) PRIMARY KEY);
      CREATE TABLE _struo_s_pending_aggregations (
        aggregator_node_id INTEGER NOT NULL,
        event_hlc CHAR(15) NOT NULL REFERENCES s(_struo_hlc) ON DELETE CASCADE,
        PRIMARY KEY (aggregator_node_id, event_hlc)
      );
    `);
    expect(await pendingCountsByAggregator(db, "s")).toEqual({});
    expect(await streamEventCount(db, "s")).toBe(0);
    await db.close();
  });
});
