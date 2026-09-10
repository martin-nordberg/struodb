import { describe, expect, test } from "bun:test";
import { emptyCatalog, migrateStream, SchemaMigrationError } from "../src/index.ts";
import { FakeDatabaseClient } from "./fake-database-client.ts";

const createSource = "CREATE STREAM sensor_reading (reading REAL);";
const alterSource = "ALTER STREAM sensor_reading ADD COLUMN units VARCHAR(32) OPTIONAL;";

describe("migrateStream", () => {
  test("a fresh migration creates all 3 tables and records one hash", async () => {
    const db = new FakeDatabaseClient();
    await migrateStream(db, emptyCatalog(), "sensor_reading", createSource);

    const sql = db.execCalls.join("\n\n");
    expect(sql).toContain("CREATE TABLE sensor_reading");
    expect(sql).toContain("CREATE TABLE _struo_sensor_reading_migration_history");
    expect(sql).toContain("CREATE TABLE _struo_sensor_reading_pending_aggregations");

    const hashes = await db.query<{ hash: string }>(
      "SELECT hash FROM _struo_sensor_reading_migration_history",
    );
    expect(hashes.length).toBe(1);
  });

  test("a second call (fresh catalog, same database) with an appended ALTER only runs the new statement", async () => {
    const db = new FakeDatabaseClient();
    await migrateStream(db, emptyCatalog(), "sensor_reading", createSource);
    db.execCalls = [];

    await migrateStream(
      db,
      emptyCatalog(),
      "sensor_reading",
      createSource + alterSource,
    );

    const sql = db.execCalls.join("\n\n");
    expect(sql).not.toContain("CREATE TABLE");
    expect(sql).toContain("ALTER TABLE sensor_reading");

    const hashes = await db.query<{ hash: string }>(
      "SELECT hash FROM _struo_sensor_reading_migration_history",
    );
    expect(hashes.length).toBe(2);
  });

  test("a tampered historical statement throws a hash_mismatch SchemaMigrationError", async () => {
    const db = new FakeDatabaseClient();
    await migrateStream(db, emptyCatalog(), "sensor_reading", createSource);

    const tampered = "CREATE STREAM sensor_reading (reading REAL, notes VARCHAR(200) OPTIONAL);";
    await expect(
      migrateStream(db, emptyCatalog(), "sensor_reading", tampered),
    ).rejects.toThrow(SchemaMigrationError);

    try {
      await migrateStream(db, emptyCatalog(), "sensor_reading", tampered);
      throw new Error("expected migrateStream to throw");
    } catch (err) {
      expect(err).toBeInstanceOf(SchemaMigrationError);
      expect((err as SchemaMigrationError).kind).toBe("hash_mismatch");
    }
  });

  test("an ordinary language error surfaces as a language_error SchemaMigrationError", async () => {
    const db = new FakeDatabaseClient();
    try {
      await migrateStream(db, emptyCatalog(), "sensor_reading", "not valid StruoQL");
      throw new Error("expected migrateStream to throw");
    } catch (err) {
      expect(err).toBeInstanceOf(SchemaMigrationError);
      expect((err as SchemaMigrationError).kind).toBe("language_error");
    }
  });

  test("the catalog already containing the stream is a structural_error", async () => {
    const db = new FakeDatabaseClient();
    const catalogAfter = await migrateStream(
      db,
      emptyCatalog(),
      "sensor_reading",
      createSource,
    );

    try {
      await migrateStream(db, catalogAfter, "sensor_reading", createSource);
      throw new Error("expected migrateStream to throw");
    } catch (err) {
      expect(err).toBeInstanceOf(SchemaMigrationError);
      expect((err as SchemaMigrationError).kind).toBe("structural_error");
    }
  });
});
