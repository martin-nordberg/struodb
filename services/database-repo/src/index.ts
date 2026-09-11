// The "Database Repository" component (event-stores.md §2.4/§2.7.3) —
// the one package in services/* that actually talks to PostgreSQL.
// Every other services/* package calls it; it depends on nothing else in
// services/*. See
// documentation/plans/architecture/event-store-implementation-plan.md,
// Phase 7, and
// documentation/plans/architecture/event-collector-implementation-plan.md,
// Phase 2, for `execStatement`/PGLite.

import { SQL } from "bun";
import { buildForwardedInsertSql } from "./forwarded-insert.ts";
import { PGliteClient } from "./pglite-client.ts";

export { quoteIdentifier } from "./identifier.ts";
export {
  migrationHistoryTableName,
  pendingAggregationsTableName,
} from "./table-names.ts";
export { buildForwardedInsertSql } from "./forwarded-insert.ts";
export type { BuiltInsert } from "./forwarded-insert.ts";
export {
  migrationStepCount,
  pendingCountsByAggregator,
  streamEventCount,
} from "./admin-stats.ts";

export interface StatementResult<
  Row extends Record<string, unknown> = Record<string, unknown>,
> {
  rows: Row[];
  /** Rows affected by a non-`SELECT` statement — for a statement *with*
   *  `RETURNING`, this equals `rows.length`; without one, it's the only
   *  way to learn how many rows a plain `INSERT`/`UPDATE`/`DELETE`
   *  touched. Both backing implementations expose this: `Bun.SQL`
   *  attaches `affectedRows`/`count` to the array it resolves with
   *  (confirmed against the installed Bun 1.4 runtime — not part of its
   *  public `.d.ts`, hence the cast in `BunSqlClient` below), and
   *  PGLite's own `query()` result carries `affectedRows` directly. */
  affectedRows: number;
}

export interface DatabaseClient {
  /** Executes arbitrary generated DDL/DML SQL text (from
   *  `ddl_codegen`/`dml_codegen` output) with no return value expected.
   *  May contain more than one `;`-separated statement (schema
   *  migration's own multi-`CREATE`/`ALTER TABLE` blobs rely on this). */
  exec(sql: string): Promise<void>;

  /** Runs `sql` (Postgres-native `$1`/`$2`/... positional placeholders)
   *  and returns rows as plain objects (column name -> value) — used for
   *  `RETURNING` output and for reading pending-aggregation/
   *  migration-history rows back. */
  query<Row extends Record<string, unknown>>(
    sql: string,
    params?: unknown[],
  ): Promise<Row[]>;

  /** Runs exactly one SQL statement (no trailing `;`-separated batch —
   *  that's what `exec` is still for) and returns both its rows and its
   *  affected-row-count. Added alongside `query`/`exec`, which every
   *  other existing caller (`schema-migration`, `event-delivery`,
   *  `event-obsolescence`) keeps using unchanged — this is the one
   *  method `event-creation`'s per-statement path uses, to execute each
   *  of `dml_facade.apply_insert`'s reported statements individually and
   *  report an accurate result for each. */
  execStatement<Row extends Record<string, unknown>>(
    sql: string,
    params?: unknown[],
  ): Promise<StatementResult<Row>>;

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
 *  PostgreSQL" rows). Every caller depends on the `DatabaseClient`
 *  interface above, never this class directly — `connect` below is the
 *  only thing that ever constructs one, alongside `PGliteClient`. */
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

  async execStatement<Row extends Record<string, unknown>>(
    sql: string,
    params: unknown[] = [],
  ): Promise<StatementResult<Row>> {
    const result = (await this.#sql.unsafe<Row[]>(sql, params)) as Row[] & {
      affectedRows?: number;
      count?: number;
    };
    return {
      rows: result,
      affectedRows: result.affectedRows ?? result.count ?? result.length,
    };
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

const PGLITE_SCHEME = "pglite://";

/** Dispatches purely on `databaseUrl`'s scheme — `pglite://<path>` (or
 *  the bare scheme with nothing after it, for an in-memory instance —
 *  tests only) selects `PGliteClient`; anything else (today,
 *  `postgres://`/`postgresql://`) selects `BunSqlClient`. This is the
 *  *only* place either implementation's name appears — every caller
 *  above `database-repo` (including `event-collector-service`, the
 *  actual deployable) only ever sees `DatabaseClient`. Swapping a
 *  collector from PGLite to real PostgreSQL later is changing this one
 *  config value, never any package's code or dependencies — see
 *  documentation/plans/architecture/event-collector-implementation-plan.md's
 *  "Decisions carried over from discussion". */
export function connect(databaseUrl: string): DatabaseClient {
  if (databaseUrl.startsWith(PGLITE_SCHEME)) {
    return new PGliteClient(databaseUrl.slice(PGLITE_SCHEME.length));
  }
  return new BunSqlClient(databaseUrl);
}
