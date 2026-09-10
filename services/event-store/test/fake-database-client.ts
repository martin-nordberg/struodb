import type { DatabaseClient } from "database-repo";

// Same crude-but-sufficient fake as services/schema-migration/test/
// fake-database-client.ts (see its own header comment) — duplicated
// rather than shared, since each package's test suite stays
// self-contained and this is genuinely tiny. Understands `exec`'s
// `CREATE TABLE` tracking (for schema-migration's `migrateStream`, which
// `start()` calls) and every `db.exec` call it's given, for asserting
// against directly (e.g. a later `createEvents` call's `INSERT`).

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
      return [{ exists: this.#tables.has(unquote(String(params[0]))) } as unknown as Row];
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
