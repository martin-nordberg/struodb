// The "StruoQL Schema Migration" component (event-stores.md §2.4/§2.7.1)
// — implements §2.6.1's "Schema Migration Sub-Logic" directly, wrapping
// `ddl_facade.apply_migration` (already implemented — see
// documentation/plans/lang/migration-plan.md) and `database-repo`. See
// documentation/plans/architecture/event-store-implementation-plan.md,
// Phase 8.
//
// The one file in this package allowed to import compiled Gleam output
// directly — see root CLAUDE.md's "Facades and the TypeScript boundary"
// note on this rule now applying per-package.
//
// @ts-expect-error — no .d.ts for compiled Gleam output.
import * as schemaFacade from "../../../domain/schema/build/dev/javascript/schema/ddl_facade.mjs";
// `List` is Gleam's own compiled linked-list representation — see
// `service/src/bridges/schema-bridge.ts`'s own comment on this same
// conversion for `applyMigration`'s `previousHashes`.
// @ts-expect-error — no .d.ts for compiled Gleam output.
import { List } from "../../../domain/schema/build/dev/javascript/prelude.mjs";
import { migrationHistoryTableName, quoteIdentifier, type DatabaseClient } from "database-repo";

/** `domain/schema/src/ddl_facade.gleam`'s `Catalog` — opaque here too,
 *  exactly like `service/src/bridges/schema-bridge.ts`'s own
 *  `CatalogHandle`: never constructed or inspected, only stored and
 *  threaded from one call to the next. */
export type CatalogHandle = unknown;

export function emptyCatalog(): CatalogHandle {
  return schemaFacade.empty_catalog();
}

/** One of `apply_migration`'s 3 failure `"kind"`s — see
 *  `ddl_facade.apply_migration`'s own doc comment for the full JSON
 *  contract this wraps. */
export type SchemaMigrationErrorKind =
  | "hash_mismatch"
  | "language_error"
  | "structural_error";

export class SchemaMigrationError extends Error {
  readonly kind: SchemaMigrationErrorKind;
  readonly statementIndex?: number;

  constructor(result: {
    kind: SchemaMigrationErrorKind;
    error: string;
    statement_index?: number;
  }) {
    super(`schema migration failed (${result.kind}): ${result.error}`);
    this.name = "SchemaMigrationError";
    this.kind = result.kind;
    this.statementIndex = result.statement_index;
  }
}

async function tableExists(db: DatabaseClient, table: string): Promise<boolean> {
  const rows = await db.query<{ exists: boolean }>(
    "SELECT to_regclass($1) IS NOT NULL AS exists",
    [quoteIdentifier(table)],
  );
  return rows[0]?.exists ?? false;
}

/** Implements event-stores.md §2.6.1's 4 steps: read `stream`'s
 *  recorded migration hashes back (its `_migration_history` table may
 *  not exist yet — the very first call for a stream is what creates
 *  it, alongside the stream's own table, via `result.sql` below), call
 *  `apply_migration` to get the not-yet-applied suffix, run that SQL,
 *  and record the new hashes. `catalog` must not already contain
 *  `stream` — see `ddl_facade.apply_migration`'s own doc comment on why
 *  this always replays a stream's *entire* history rather than
 *  threading forward incrementally. */
export async function migrateStream(
  db: DatabaseClient,
  catalog: CatalogHandle,
  stream: string,
  source: string,
): Promise<CatalogHandle> {
  const historyTable = migrationHistoryTableName(stream);

  const previousHashes = (await tableExists(db, historyTable))
    ? (
        await db.query<{ hash: string }>(
          `SELECT hash FROM ${quoteIdentifier(historyTable)} ORDER BY seq`,
        )
      ).map((row) => row.hash)
    : [];

  const [resultJson, updatedCatalog] = schemaFacade.apply_migration(
    catalog,
    stream,
    List.fromArray(previousHashes),
    source,
  );
  const result = JSON.parse(resultJson);
  if (!result.ok) {
    throw new SchemaMigrationError(result);
  }

  if (result.sql !== "") {
    await db.exec(result.sql);

    const newHashes: string[] = result.hashes;
    if (newHashes.length > 0) {
      const startSeq = previousHashes.length;
      const params: unknown[] = [];
      const valueRows = newHashes.map((hash, i) => {
        params.push(startSeq + i, hash);
        return `($${params.length - 1}, $${params.length})`;
      });
      await db.query(
        `INSERT INTO ${quoteIdentifier(historyTable)} (seq, hash) VALUES ${valueRows.join(", ")}`,
        params,
      );
    }
  }

  return updatedCatalog;
}
