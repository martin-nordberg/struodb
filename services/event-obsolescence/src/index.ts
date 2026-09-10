// The "Event Obsolescence" component (event-stores.md §2.4/§2.7.7) —
// implements §2.6.5's retention sweep. See
// documentation/plans/architecture/event-store-implementation-plan.md,
// Phase 12.
//
// Note on `timeLimited`: event-stores.md §2.3.4 is explicit that this
// strategy means `_struo_created_at` (PostgreSQL's own insert-time
// `clock_timestamp()`), *not* the HLC's own embedded
// `_struo_hlc_timestamp` — an HLC's physical-time component can run
// ahead of true wall-clock time after a merge (hlc-spec.md), which is
// exactly the wrong notion of "age" for a retention policy. This module
// therefore compares a plain wall-clock `Date` against
// `_struo_created_at` directly; it does not need `hlc-clock` at all.
// (An earlier draft of this plan added `hlc/clock.gleam`'s
// `threshold_for_time`/`HlcClock.thresholdForTime` for exactly this
// purpose, on the assumption a `_struo_hlc`-based age cutoff would be
// used — removed once none of the currently-specified retention
// strategies turned out to need one, rather than kept unreachable; see
// `documentation/plans/lang/migration-plan.md`'s `EmptyMigration` for
// the precedent this follows.)

import {
  pendingAggregationsTableName,
  quoteIdentifier,
  type DatabaseClient,
} from "database-repo";

export type RetentionStrategy =
  | { kind: "indefinite" }
  | { kind: "removedAfterAggregation"; threshold: number }
  | { kind: "timeLimited"; threshold: number; intervalMs: number };

/** Runs one retention sweep for `stream` under `strategy`, returning the
 *  number of rows deleted. `aggregatorCount` is that stream's *total*
 *  configured aggregator count (`StreamConfig.aggregators.length`) —
 *  needed to translate `strategy.threshold` ("delivered to at least this
 *  many aggregators") into "at most `aggregatorCount - threshold`
 *  pending rows remain for this event." Deleting a stream row this way
 *  relies on the table's own `ON DELETE CASCADE` (`catalog
 *  .pending_aggregations_table_name`'s own doc comment) to drop any
 *  aggregators' still-pending rows along with it — event-stores.md
 *  §2.2's own note 2 on that trade-off applies here unchanged: a
 *  `threshold` below `aggregatorCount` means some aggregators may never
 *  receive the event, by design. `now` is injectable so tests don't
 *  depend on real wall-clock timing. */
export async function sweepStream(
  db: DatabaseClient,
  stream: string,
  strategy: RetentionStrategy,
  aggregatorCount: number,
  now: () => number = Date.now,
): Promise<number> {
  if (strategy.kind === "indefinite") {
    return 0;
  }

  const streamTable = quoteIdentifier(stream);
  const hlcColumn = quoteIdentifier("_struo_hlc");
  const pendingTable = quoteIdentifier(pendingAggregationsTableName(stream));
  const maxRemainingPending = aggregatorCount - strategy.threshold;

  const params: unknown[] = [maxRemainingPending];
  const conditions = [
    `(SELECT count(*) FROM ${pendingTable} p WHERE p.event_hlc = s.${hlcColumn}) <= $1`,
  ];

  if (strategy.kind === "timeLimited") {
    params.push(new Date(now() - strategy.intervalMs));
    conditions.push(`s.${quoteIdentifier("_struo_created_at")} < $${params.length}`);
  }

  const rows = await db.query<{ deleted: number }>(
    `DELETE FROM ${streamTable} s WHERE ${conditions.join(" AND ")} RETURNING 1 AS deleted`,
    params,
  );
  return rows.length;
}
