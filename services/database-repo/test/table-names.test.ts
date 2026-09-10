import { describe, expect, test } from "bun:test";
import {
  migrationHistoryTableName,
  pendingAggregationsTableName,
} from "../src/table-names.ts";

// Mirrors domain/shared/test/lang/catalog_test.gleam's own coverage of
// the Gleam originals this ports.

describe("migrationHistoryTableName", () => {
  test("derives the expected name", () => {
    expect(migrationHistoryTableName("sensor_reading")).toBe(
      "_struo_sensor_reading_migration_history",
    );
  });
});

describe("pendingAggregationsTableName", () => {
  test("derives the expected name", () => {
    expect(pendingAggregationsTableName("sensor_reading")).toBe(
      "_struo_sensor_reading_pending_aggregations",
    );
  });
});
