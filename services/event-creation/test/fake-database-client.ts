import type { DatabaseClient } from "database-repo";

/** Records every `exec` call; `createEvents` never calls `query`/
 *  `insertForwardedEvents` itself, so those are unimplemented here. */
export class FakeDatabaseClient implements DatabaseClient {
  execCalls: string[] = [];

  async exec(sql: string): Promise<void> {
    this.execCalls.push(sql);
  }

  async query<Row extends Record<string, unknown>>(): Promise<Row[]> {
    throw new Error("FakeDatabaseClient: query not used by this test");
  }

  async insertForwardedEvents(): Promise<void> {
    throw new Error("FakeDatabaseClient: insertForwardedEvents not used by this test");
  }

  async close(): Promise<void> {}
}
