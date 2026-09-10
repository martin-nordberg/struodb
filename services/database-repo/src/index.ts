// The "Database Repository" component (event-stores.md §2.4/§2.7.3) —
// the one package in services/* that actually talks to PostgreSQL.
// Every other services/* package calls it; it depends on nothing else in
// services/*. See
// documentation/plans/architecture/event-store-implementation-plan.md,
// Phase 7.

import { SQL } from "bun";
import { buildForwardedInsertSql } from "./forwarded-insert.ts";

export { quoteIdentifier } from "./identifier.ts";
export {
  migrationHistoryTableName,
  pendingAggregationsTableName,
} from "./table-names.ts";
export { buildForwardedInsertSql } from "./forwarded-insert.ts";
export type { BuiltInsert } from "./forwarded-insert.ts";

export interface DatabaseClient {
  /** Executes arbitrary generated DDL/DML SQL text (from
   *  `ddl_codegen`/`dml_codegen` output) with no return value expected. */
  exec(sql: string): Promise<void>;

  /** Runs `sql` (Postgres-native `$1`/`$2`/... positional placeholders)
   *  and returns rows as plain objects (column name -> value) — used for
   *  `RETURNING` output and for reading pending-aggregation/
   *  migration-history rows back. */
  query<Row extends Record<string, unknown>>(
    sql: string,
    params?: unknown[],
  ): Promise<Row[]>;

  /** Parameterized bulk insert of already-resolved rows (every column,
   *  including the 5 system ones) into `stream`, `ON CONFLICT DO
   *  NOTHING`, fanning out into that stream's `_pending_aggregations`
   *  table for `aggregatorNodeIds` — the TypeScript-side equivalent of
   *  `dml_codegen`'s own CTE shape, for events arriving already
   *  HLC-stamped from a peer, which never go through StruoQL/
   *  `dml_facade` at all. See `forwarded-insert.ts`. */
  insertForwardedEvents(
    stream: string,
    rows: Record<string, unknown>[],
    aggregatorNodeIds: number[],
  ): Promise<void>;

  close(): Promise<void>;
}

/** `Bun.SQL`-backed `DatabaseClient` — a real PostgreSQL connection (see
 *  event-stores.md §2.3.1's "PostgreSQL in Container"/"Standalone
 *  PostgreSQL" rows). A PGLite-backed implementation of this same
 *  interface is explicitly deferred — see the implementation plan's
 *  "Scope" — every caller here depends on the `DatabaseClient` interface
 *  above, never this class directly, so adding one later needs no
 *  caller-side change. */
class BunSqlClient implements DatabaseClient {
  #sql: SQL;

  constructor(databaseUrl: string) {
    this.#sql = new SQL(databaseUrl);
  }

  async exec(sql: string): Promise<void> {
    await this.#sql.unsafe(sql);
  }

  async query<Row extends Record<string, unknown>>(
    sql: string,
    params: unknown[] = [],
  ): Promise<Row[]> {
    return (await this.#sql.unsafe<Row[]>(sql, params)) as Row[];
  }

  async insertForwardedEvents(
    stream: string,
    rows: Record<string, unknown>[],
    aggregatorNodeIds: number[],
  ): Promise<void> {
    const { sql, params } = buildForwardedInsertSql(
      stream,
      rows,
      aggregatorNodeIds,
    );
    await this.#sql.unsafe(sql, params);
  }

  async close(): Promise<void> {
    await this.#sql.close();
  }
}

export function connect(databaseUrl: string): DatabaseClient {
  return new BunSqlClient(databaseUrl);
}
