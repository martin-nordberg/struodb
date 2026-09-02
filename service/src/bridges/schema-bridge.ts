// The only file (besides streams-bridge.ts) allowed to import
// domain/schema's compiled JS output directly — isolating the untyped
// boundary Gleam's lack of emitted .d.ts files creates to one file per
// domain package, per the migration plan's "TypeScript bridge" design.
//
// @ts-expect-error — no .d.ts for compiled Gleam output.
import * as schemaFacade from "../../../domain/schema/build/dev/javascript/schema/ddl_facade.mjs";

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
