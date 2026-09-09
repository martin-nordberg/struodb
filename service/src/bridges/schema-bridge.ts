// The only file (besides streams-bridge.ts) allowed to import
// domain/schema's compiled JS output directly — isolating the untyped
// boundary Gleam's lack of emitted .d.ts files creates to one file per
// domain package, per the migration plan's "TypeScript bridge" design.
//
// @ts-expect-error — no .d.ts for compiled Gleam output.
import * as schemaFacade from "../../../domain/schema/build/dev/javascript/schema/ddl_facade.mjs";
// `List` is Gleam's own compiled linked-list representation (see its
// class in prelude.mjs) — `apply_migration`'s `previous_hashes`
// parameter is a Gleam `List(String)`, not a native JS array, so
// `applyMigration` below converts via `List.fromArray` before crossing
// the boundary. `applyDdl` above needs no such conversion: none of its
// parameters are Gleam lists.
// @ts-expect-error — no .d.ts for compiled Gleam output.
import { List } from "../../../domain/schema/build/dev/javascript/prelude.mjs";

/** `domain/schema/src/ddl_facade.gleam`'s `Catalog` — opaque here too:
 *  never constructed or inspected, only stored and passed back into
 *  `applyDdl`/`streams-bridge.ts`'s `applyInsert` unchanged. See that
 *  Gleam module's header comment for why threading it this way (rather
 *  than a JSON snapshot) is the deliberate design, not a shortcut. */
export type CatalogHandle = unknown;

export function emptyCatalog(): CatalogHandle {
  return schemaFacade.empty_catalog();
}

/** `source` is StruoQL `CREATE STREAM`/`ALTER STREAM` text. Returns
 *  `[resultJson, updatedCatalog]` — `resultJson` is
 *  `{"ok": true, "sql": "..."}` or `{"ok": false, "error": "..."}`;
 *  `updatedCatalog` is `catalog` unchanged on failure. */
export function applyDdl(
  catalog: CatalogHandle,
  source: string,
): [string, CatalogHandle] {
  return schemaFacade.apply_ddl(catalog, source);
}

/** Stream-scoped counterpart to `applyDdl` — see
 *  `ddl_facade.apply_migration`'s own doc comment for the full contract.
 *  `source` is `stream`'s *entire* `CREATE STREAM` + `ALTER STREAM`
 *  history in one string; `previousHashes` is the hash codes an
 *  external migration-history store already has recorded as applied for
 *  `stream`, in order; `catalog` must not already contain `stream`.
 *  Returns `[resultJson, updatedCatalog]` — `resultJson` is
 *  `{"ok": true, "kind": "ok", "sql": "...", "hashes": [...]}` on
 *  success, or `{"ok": false, "kind": "hash_mismatch" | "language_error"
 *  | "structural_error", "error": "...", ...}` on failure;
 *  `updatedCatalog` is `catalog` unchanged on failure. */
export function applyMigration(
  catalog: CatalogHandle,
  stream: string,
  previousHashes: string[],
  source: string,
): [string, CatalogHandle] {
  return schemaFacade.apply_migration(
    catalog,
    stream,
    List.fromArray(previousHashes),
    source,
  );
}
