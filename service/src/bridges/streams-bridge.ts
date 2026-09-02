// The only file (besides schema-bridge.ts) allowed to import
// domain/streams's compiled JS output directly — see schema-bridge.ts's
// header comment for why this split exists.
//
// @ts-expect-error — no .d.ts for compiled Gleam output.
import * as streamsFacade from "../../../domain/streams/build/dev/javascript/streams/dml_facade.mjs";
import type { HlcClock } from "../hlc-clock.ts";
import type { CatalogHandle } from "./schema-bridge.ts";

/** `source` is StruoQL `INSERT` text. `clock` supplies one fresh HLC
 *  value per row inserted, via `clock.nextParts()` — this is the one
 *  place a TypeScript-held `HlcClock` and a compiled Gleam `HlcParts`
 *  actually meet; see `hlc-clock.ts`'s header comment. Returns JSON:
 *  `{"ok": true, "sql": "..."}` or `{"ok": false, "error": "..."}`.
 *  `INSERT` never changes a stream's shape, so — unlike
 *  `schema-bridge.ts`'s `applyDdl` — there is no updated catalog to
 *  hand back. */
export function applyInsert(
  clock: HlcClock,
  catalog: CatalogHandle,
  source: string,
): string {
  return streamsFacade.apply_insert(catalog, source, () => clock.nextParts());
}
