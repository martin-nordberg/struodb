// The only file (besides schema-bridge.ts) allowed to import
// domain/streams's compiled JS output directly — see schema-bridge.ts's
// header comment for why this split exists.
//
// @ts-expect-error — no .d.ts for compiled Gleam output.
import * as streamsFacade from "../../../domain/streams/build/dev/javascript/streams/dml_facade.mjs";
// `List` is Gleam's own compiled linked-list representation — see
// schema-bridge.ts's own comment on `applyMigration`'s `previousHashes`
// for why this conversion is needed. `apply_insert`'s
// `aggregators_for_stream` parameter is a `fn(String) -> List(Int)`, so
// `applyInsert` below wraps the caller's plain-array-returning function
// in one that converts on every call, not just once up front.
// @ts-expect-error — no .d.ts for compiled Gleam output.
import { List } from "../../../domain/streams/build/dev/javascript/prelude.mjs";
import type { HlcClock } from "hlc-clock";
import type { CatalogHandle } from "./schema-bridge.ts";

/** `source` is StruoQL `INSERT` text. `clock` supplies one fresh HLC
 *  value per row inserted, via `clock.nextParts()` — this is the one
 *  place a TypeScript-held `HlcClock` and a compiled Gleam `HlcParts`
 *  actually meet; see the `hlc-clock` package's header comment.
 *  `aggregatorNodeIdsForStream` returns the configured aggregator node
 *  ids for a given stream name (event-stores.md §2.5) — a stream with
 *  none renders exactly as it always has; one with at least one fans out
 *  into that stream's `_pending_aggregations` table alongside the
 *  ordinary `INSERT` (see `dml_codegen.insert_to_sql`'s own doc
 *  comment). Returns JSON: `{"ok": true, "sql": "..."}` or `{"ok":
 *  false, "error": "..."}`. `INSERT` never changes a stream's shape, so
 *  — unlike `schema-bridge.ts`'s `applyDdl` — there is no updated
 *  catalog to hand back. */
export function applyInsert(
  clock: HlcClock,
  catalog: CatalogHandle,
  source: string,
  aggregatorNodeIdsForStream: (stream: string) => number[],
): string {
  return streamsFacade.apply_insert(
    catalog,
    source,
    () => clock.nextParts(),
    (stream: string) => List.fromArray(aggregatorNodeIdsForStream(stream)),
  );
}
