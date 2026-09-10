// Builds the SQL for `insertForwardedEvents` (index.ts) — split out as a
// pure function (string/params in, no I/O) so it's testable without a
// real Postgres instance, and because it mirrors
// `domain/streams/src/lang/dml_codegen.gleam`'s own `WITH ins AS (...)`
// fan-out shape closely enough that keeping them side by side (rather
// than buried inside a class method) makes that mirroring easy to see
// and check. See "Decisions carried over from discussion" in
// documentation/plans/architecture/event-store-implementation-plan.md
// for why forwarded events are parameterized rows rather than raw SQL
// text: every value here is a bind parameter, never interpolated, so
// this can only ever produce row inserts, not arbitrary SQL.

import { quoteIdentifier } from "./identifier.ts";
import { pendingAggregationsTableName } from "./table-names.ts";

export interface BuiltInsert {
  sql: string;
  params: unknown[];
}

/** Indents every line of `text` by 2 spaces — same role as
 *  `dml_codegen.gleam`'s own `indent`: nest an already-formatted
 *  statement inside a `WITH ... AS (...)` block uniformly. */
function indent(text: string): string {
  return text
    .split("\n")
    .map((line) => `  ${line}`)
    .join("\n");
}

/** `rows` must be non-empty and every row must have exactly the same
 *  set of columns (in the order the first row's own keys iterate in) —
 *  a forwarded batch always comes from one collector's own single
 *  `INSERT`, whose rows share one column list by construction, so this
 *  is a caller-misuse check, not a data-shape one to tolerate.
 *
 *  With no `aggregatorNodeIds`, this is a plain parameterized bulk
 *  `INSERT ... ON CONFLICT DO NOTHING` — no bookkeeping-table fan-out.
 *  With at least one, it's wrapped in a `WITH ins AS (...)` CTE exactly
 *  like `dml_codegen.insert_to_sql`'s own aggregator fan-out, fanning
 *  out into `stream`'s `_pending_aggregations` table. There is no
 *  `RETURNING` case to handle here (unlike the Gleam side): a forwarded
 *  event's caller never asks for one back — it just needs the rows
 *  stored (and re-forwarded further, if this aggregator itself forwards
 *  on) — so the fan-out `INSERT` is always the final, top-level
 *  statement when aggregators are configured. */
export function buildForwardedInsertSql(
  stream: string,
  rows: Record<string, unknown>[],
  aggregatorNodeIds: number[],
): BuiltInsert {
  if (rows.length === 0) {
    throw new Error("insertForwardedEvents: rows must not be empty");
  }

  const columns = Object.keys(rows[0]!);
  if (columns.length === 0) {
    throw new Error("insertForwardedEvents: rows must have at least one column");
  }

  const params: unknown[] = [];
  const valueRows = rows.map((row, rowIndex) => {
    const placeholders = columns.map((column) => {
      if (!(column in row)) {
        throw new Error(
          `insertForwardedEvents: row ${rowIndex} is missing column "${column}"`,
        );
      }
      params.push(row[column]);
      return `$${params.length}`;
    });
    return `(${placeholders.join(", ")})`;
  });

  const insertSql =
    `INSERT INTO ${quoteIdentifier(stream)} (${columns.map(quoteIdentifier).join(", ")})\n` +
    `VALUES\n  ${valueRows.join(",\n  ")}\n` +
    `ON CONFLICT DO NOTHING`;

  if (aggregatorNodeIds.length === 0) {
    return { sql: `${insertSql};`, params };
  }

  const pendingTable = quoteIdentifier(pendingAggregationsTableName(stream));
  const idsArray = aggregatorNodeIds.join(", ");
  const sql =
    `WITH ins AS (\n${indent(`${insertSql}\n  RETURNING *`)}\n)\n` +
    `INSERT INTO ${pendingTable} (aggregator_node_id, event_hlc)\n` +
    `SELECT a.aggregator_node_id, ins.${quoteIdentifier("_struo_hlc")}\n` +
    `FROM ins CROSS JOIN unnest(ARRAY[${idsArray}]) AS a(aggregator_node_id);`;

  return { sql, params };
}
