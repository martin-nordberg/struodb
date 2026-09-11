// A `DatabaseClient` backed by PGLite — real PostgreSQL, embedded
// in-process via WASM, no external server. See
// documentation/plans/architecture/event-collector-implementation-plan.md,
// Phase 2, "Decisions carried over from discussion" on why this exists
// and why nothing above `database-repo` ever imports this file directly
// (only `connect`, in `index.ts`, does).

import { PGlite } from "@electric-sql/pglite";
import { buildForwardedInsertSql } from "./forwarded-insert.ts";
import type { DatabaseClient, StatementResult } from "./index.ts";

/** `dataDir` is everything after `pglite://` in the connection URL —
 *  empty means PGLite's own in-memory mode (tests only; a "standalone"
 *  collector meant to retain events across restarts should always be
 *  configured with a real filesystem path in production). PGLite embeds
 *  real PostgreSQL with no external server process, so this talks to it
 *  through PGLite's own `query`/`exec` API — structurally similar to
 *  `Bun.SQL`'s but not the same calls; see each method below. */
export class PGliteClient implements DatabaseClient {
  #db: PGlite;

  constructor(dataDir: string) {
    this.#db = new PGlite(dataDir === "" ? undefined : dataDir);
  }

  async exec(sql: string): Promise<void> {
    // PGLite's own multi-statement runner — used for schema migration's
    // batched CREATE/ALTER TABLE blobs, which may contain more than one
    // `;`-separated statement in one call.
    await this.#db.exec(sql);
  }

  async query<Row extends Record<string, unknown>>(
    sql: string,
    params: unknown[] = [],
  ): Promise<Row[]> {
    const result = await this.#db.query<Row>(sql, params);
    return result.rows;
  }

  async execStatement<Row extends Record<string, unknown>>(
    sql: string,
    params: unknown[] = [],
  ): Promise<StatementResult<Row>> {
    const result = await this.#db.query<Row>(sql, params);
    return { rows: result.rows, affectedRows: result.affectedRows ?? result.rows.length };
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
    await this.#db.query(sql, params);
  }

  async close(): Promise<void> {
    await this.#db.close();
  }
}
