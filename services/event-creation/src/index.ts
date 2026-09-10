// The "StruoQL Event Creation" component (event-stores.md §2.4/§2.7.2)
// — implements §2.6.3's "Event Creation" logic directly, wrapping
// `dml_facade.apply_insert` and `database-repo`. See
// documentation/plans/architecture/event-store-implementation-plan.md,
// Phase 9.
//
// The one file in this package allowed to import compiled Gleam output
// directly — see root CLAUDE.md's "Facades and the TypeScript boundary"
// note on this rule now applying per-package.
//
// @ts-expect-error — no .d.ts for compiled Gleam output.
import * as streamsFacade from "../../../domain/streams/build/dev/javascript/streams/dml_facade.mjs";
// `List` is Gleam's own compiled linked-list representation — see
// `service/src/bridges/streams-bridge.ts`'s own comment on this same
// conversion for `apply_insert`'s `aggregators_for_stream` parameter.
// @ts-expect-error — no .d.ts for compiled Gleam output.
import { List } from "../../../domain/streams/build/dev/javascript/prelude.mjs";
import type { DatabaseClient } from "database-repo";
import type { HlcClock } from "hlc-clock";

/** `domain/schema/src/ddl_facade.gleam`'s `Catalog`, opaque here too —
 *  the same `unknown` alias `schema-migration`'s own `CatalogHandle`
 *  is, kept as a separate local type rather than a cross-package import
 *  since the two packages are otherwise independent (see the
 *  implementation plan's Phase 8/9 dependency notes) and there's
 *  nothing behind the alias to share beyond the name. */
export type CatalogHandle = unknown;

export class EventCreationError extends Error {
  constructor(detail: string) {
    super(`event creation failed: ${detail}`);
    this.name = "EventCreationError";
  }
}

/** Implements event-stores.md §2.6.3: transpiles every `INSERT`
 *  statement in `source` (validated against `catalog`), drawing one
 *  fresh HLC value per row from `clock`, and executes the resulting SQL
 *  — including any `_pending_aggregations` fan-out — via `db`.
 *  `aggregatorNodeIdsForStream` is typically built by `services/
 *  event-store` from `StreamConfig.aggregators`, excluding any entry
 *  whose `aggregationStrategy.kind === "sharedDatabase"` (that
 *  aggregator shares the same database, so it never needs a pending
 *  row of its own — see the implementation plan's Phase 6 note). */
export async function createEvents(
  db: DatabaseClient,
  clock: HlcClock,
  catalog: CatalogHandle,
  source: string,
  aggregatorNodeIdsForStream: (stream: string) => number[],
): Promise<void> {
  const resultJson = streamsFacade.apply_insert(
    catalog,
    source,
    () => clock.nextParts(),
    (stream: string) => List.fromArray(aggregatorNodeIdsForStream(stream)),
  );
  const result = JSON.parse(resultJson);
  if (!result.ok) {
    throw new EventCreationError(result.error);
  }
  await db.exec(result.sql);
}
