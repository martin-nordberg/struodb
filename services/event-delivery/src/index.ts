// The "Event Delivery" component (event-stores.md §2.4/§2.7.6) —
// implements §2.6.4's "Event Aggregation" logic: queries pending rows
// for a given (stream, aggregator) pair, delivers them over HTTP, and
// deletes only the delivered rows once the delivery actually succeeds.
// Also the aggregator-side receiving half, `handleIncomingEvents`,
// which is what turns a delivered batch into `database-repo`'s own
// structured, parameterized bulk insert — see "Decisions carried over
// from discussion" in
// documentation/plans/architecture/event-store-implementation-plan.md
// for why forwarded events cross the wire as rows, never SQL text.

import {
  pendingAggregationsTableName,
  quoteIdentifier,
  type DatabaseClient,
} from "database-repo";

export interface AggregatorEndpoint {
  baseUrl: string;
}

export class EventDeliveryError extends Error {
  readonly status: number;

  constructor(status: number, body: string) {
    super(`event delivery failed (HTTP ${status}): ${body}`);
    this.name = "EventDeliveryError";
    this.status = status;
  }
}

/** Delivers up to `batchSize` (unlimited if omitted) pending rows for
 *  `stream`/`aggregatorNodeId`, oldest first, to `aggregator`'s events
 *  endpoint, deleting only the delivered rows from
 *  `_pending_aggregations` once the HTTP call actually succeeds — a
 *  failed delivery leaves every pending row untouched, so a later retry
 *  redelivers the same batch rather than losing it. Returns the number
 *  of rows delivered (`0` if there was nothing pending).
 *
 *  The two-step query (`_pending_aggregations` first, then the stream
 *  table) keeps `ORDER BY event_hlc LIMIT` on the pending table's own
 *  primary key (`catalog.pending_aggregations_table_name`'s own doc
 *  comment on its column order), rather than joining the two tables and
 *  losing that index-backed ordering. */
export async function deliverPending(
  db: DatabaseClient,
  aggregatorNodeId: number,
  aggregator: AggregatorEndpoint,
  stream: string,
  batchSize?: number,
  fetchImpl: typeof fetch = fetch,
): Promise<number> {
  const pendingTable = quoteIdentifier(pendingAggregationsTableName(stream));
  const streamTable = quoteIdentifier(stream);
  const hlcColumn = quoteIdentifier("_struo_hlc");

  const rows = await db.query<Record<string, unknown>>(
    `SELECT * FROM ${streamTable}
     WHERE ${hlcColumn} IN (
       SELECT event_hlc FROM ${pendingTable}
       WHERE aggregator_node_id = $1
       ORDER BY event_hlc
       ${batchSize !== undefined ? "LIMIT $2" : ""}
     )`,
    batchSize !== undefined ? [aggregatorNodeId, batchSize] : [aggregatorNodeId],
  );
  if (rows.length === 0) {
    return 0;
  }

  const res = await fetchImpl(
    `${aggregator.baseUrl}/streams/${encodeURIComponent(stream)}/events`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ rows }),
    },
  );
  if (!res.ok) {
    throw new EventDeliveryError(res.status, await res.text());
  }

  const eventHlcs = rows.map((row) => row["_struo_hlc"]);
  await db.query(
    `DELETE FROM ${pendingTable} WHERE aggregator_node_id = $1 AND event_hlc = ANY($2)`,
    [aggregatorNodeId, eventHlcs],
  );
  return rows.length;
}

/** Aggregator side: turns a delivered batch into a parameterized bulk
 *  insert via `database-repo`'s `insertForwardedEvents` — no SQL text
 *  crosses the wire, no StruoQL re-parsing. `aggregatorNodeIdsForStream`
 *  is this aggregator's *own* downstream fan-out, for a stream it
 *  itself forwards on further (chained aggregation); an aggregator with
 *  no further aggregators of its own passes a function that always
 *  returns `[]`. */
export async function handleIncomingEvents(
  db: DatabaseClient,
  stream: string,
  rows: Record<string, unknown>[],
  aggregatorNodeIdsForStream: (stream: string) => number[],
): Promise<void> {
  await db.insertForwardedEvents(
    stream,
    rows,
    aggregatorNodeIdsForStream(stream),
  );
}
