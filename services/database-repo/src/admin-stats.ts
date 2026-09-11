// Read-only reporting queries backing the admin endpoint
// (event-collectors.md §3.3.1) — plain functions, not part of the
// `DatabaseClient` interface itself, since these are queries against
// tables the interface's other methods already assume exist, not a
// data-access primitive every implementation must define. See
// documentation/plans/architecture/event-collector-implementation-plan.md,
// Phase 3.

import { quoteIdentifier } from "./identifier.ts";
import {
  migrationHistoryTableName,
  pendingAggregationsTableName,
} from "./table-names.ts";
import type { DatabaseClient } from "./index.ts";

// count(*)'s Postgres `bigint` result comes back as a numeric string
// over the wire (both `Bun.SQL` and PGLite) to avoid silent precision
// loss above `Number.MAX_SAFE_INTEGER` — the `Number(...)` conversions
// below are a deliberate, accepted simplification (an event count
// realistically never approaches that range); revisit if that
// assumption ever stops holding.

export async function streamEventCount(
  db: DatabaseClient,
  stream: string,
): Promise<number> {
  const rows = await db.query<{ count: string }>(
    `SELECT count(*) FROM ${quoteIdentifier(stream)}`,
  );
  return Number(rows[0]?.count ?? 0);
}

export async function migrationStepCount(
  db: DatabaseClient,
  stream: string,
): Promise<number> {
  const rows = await db.query<{ count: string }>(
    `SELECT count(*) FROM ${quoteIdentifier(migrationHistoryTableName(stream))}`,
  );
  return Number(rows[0]?.count ?? 0);
}

/** Keyed by aggregator node id — an aggregator with zero pending rows
 *  right now simply has no key, not a zero entry (the query only
 *  returns aggregators that actually have pending rows); a caller
 *  wanting every *configured* aggregator represented (even at 0) fills
 *  in the gaps itself from its own config, same as
 *  `EventStore.streamStats` does. */
export async function pendingCountsByAggregator(
  db: DatabaseClient,
  stream: string,
): Promise<Record<number, number>> {
  const rows = await db.query<{ aggregator_node_id: number; count: string }>(
    `SELECT aggregator_node_id, count(*) FROM ${quoteIdentifier(pendingAggregationsTableName(stream))} GROUP BY aggregator_node_id`,
  );
  const result: Record<number, number> = {};
  for (const row of rows) {
    result[row.aggregator_node_id] = Number(row.count);
  }
  return result;
}
