// A minimal in-memory fake of `database-repo`'s `DatabaseClient`, since
// no real Postgres instance is available in this environment (see
// documentation/plans/architecture/event-store-implementation-plan.md's
// own "Test plan" note on needing one for the real thing) — enough to
// drive `migrateStream`'s actual control flow (existence check, reading
// history back in order, recording new rows) without a live database.
// Deliberately narrow: understands only the 3 query shapes
// `migrateStream` actually issues.

import type { DatabaseClient } from "database-repo";

function unquote(name: string): string {
  return name.startsWith('"')
    ? name.slice(1, -1).replaceAll('""', '"')
    : name;
}

export class FakeDatabaseClient implements DatabaseClient {
  execCalls: string[] = [];
  #tables = new Set<string>();
  #historyRows = new Map<string, { seq: number; hash: string }[]>();

  async exec(sql: string): Promise<void> {
    this.execCalls.push(sql);
    const re = /CREATE TABLE ("(?:[^"]|"")+"|[a-zA-Z_][a-zA-Z0-9_]*)/g;
    for (const match of sql.matchAll(re)) {
      this.#tables.add(unquote(match[1]!));
    }
  }

  async query<Row extends Record<string, unknown>>(
    sql: string,
    params: unknown[] = [],
  ): Promise<Row[]> {
    if (sql.startsWith("SELECT to_regclass")) {
      const name = unquote(String(params[0]));
      return [{ exists: this.#tables.has(name) } as unknown as Row];
    }
    if (sql.startsWith("SELECT hash FROM")) {
      const name = unquote(sql.match(/FROM ("(?:[^"]|"")+"|[a-zA-Z_][a-zA-Z0-9_]*)/)![1]!);
      const rows = this.#historyRows.get(name) ?? [];
      return rows
        .slice()
        .sort((a, b) => a.seq - b.seq)
        .map((r) => ({ hash: r.hash })) as unknown as Row[];
    }
    if (sql.startsWith("INSERT INTO") && sql.includes("(seq, hash)")) {
      const name = unquote(sql.match(/INSERT INTO ("(?:[^"]|"")+"|[a-zA-Z_][a-zA-Z0-9_]*)/)![1]!);
      const rows = this.#historyRows.get(name) ?? [];
      for (let i = 0; i < params.length; i += 2) {
        rows.push({ seq: params[i] as number, hash: params[i + 1] as string });
      }
      this.#historyRows.set(name, rows);
      return [] as Row[];
    }
    throw new Error(`FakeDatabaseClient: unhandled query: ${sql}`);
  }

  async insertForwardedEvents(): Promise<void> {
    throw new Error("FakeDatabaseClient: insertForwardedEvents not used by this test");
  }

  async close(): Promise<void> {}
}
