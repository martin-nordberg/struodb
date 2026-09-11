// The "StruoQL Event Creation" component (event-stores.md §2.4/§2.7.2)
// — implements §2.6.3's "Event Creation" logic directly, wrapping
// `dml_facade.apply_insert` and `database-repo`. See
// documentation/plans/architecture/event-store-implementation-plan.md,
// Phase 9, and
// documentation/plans/architecture/event-collector-implementation-plan.md,
// Phase 4, for the per-statement result rework below.
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

/** One `INSERT` statement's execution result — a `RETURNING` clause
 *  yields its rows directly; without one, an accurate insert count
 *  (see `createEvents`'s own doc comment for why that count sometimes
 *  needs correcting, not just reading off the database driver
 *  directly). */
export type InsertStatementResult =
  | { kind: "rows"; rows: Record<string, unknown>[] }
  | { kind: "count"; count: number };

interface FacadeStatementResult {
  sql: string;
  stream_name: string;
  has_returning: boolean;
}

/** Implements event-stores.md §2.6.3: transpiles every `INSERT`
 *  statement in `source` (validated against `catalog`), drawing one
 *  fresh HLC value per row from `clock`, and executes each resulting
 *  statement individually via `database-repo`'s `execStatement` —
 *  including any `_pending_aggregations` fan-out — returning one
 *  `InsertStatementResult` per statement, in order.
 *
 *  For a statement with no `RETURNING` clause on a stream that has
 *  aggregators configured, the executed SQL's own affected-row-count
 *  is *not* the number of stream rows inserted: `dml_codegen`'s
 *  generated SQL (see `insert_to_sql`'s own doc comment) ends with the
 *  `_pending_aggregations` fan-out `INSERT` as its top-level statement
 *  in that case, and its row count is `(rows inserted) × (aggregator
 *  count)` — `CROSS JOIN unnest(ARRAY[...])` always produces exactly
 *  one row per aggregator id per input row, deterministically. Dividing
 *  by that statement's own aggregator count (looked up here, not
 *  reported by the Gleam facade — see
 *  documentation/plans/architecture/event-collector-implementation-plan.md's
 *  "Decisions carried over from discussion") recovers the exact insert
 *  count. A statement *with* `RETURNING` never needs this: its
 *  top-level statement is a plain `SELECT ... FROM ins`, whose row
 *  count already equals the insert count directly.
 *
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
): Promise<InsertStatementResult[]> {
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

  const results: InsertStatementResult[] = [];
  for (const stmt of result.statements as FacadeStatementResult[]) {
    const { rows, affectedRows } = await db.execStatement(stmt.sql);
    if (stmt.has_returning) {
      results.push({ kind: "rows", rows });
    } else {
      const aggregatorCount = aggregatorNodeIdsForStream(stmt.stream_name).length;
      const count = aggregatorCount > 0 ? affectedRows / aggregatorCount : affectedRows;
      results.push({ kind: "count", count });
    }
  }
  return results;
}
