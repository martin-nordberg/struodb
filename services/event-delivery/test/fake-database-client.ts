import type { DatabaseClient, StatementResult } from "database-repo";

/** A minimal in-memory fake standing in for a real Postgres — see
 *  documentation/plans/architecture/event-store-implementation-plan.md's
 *  own test-plan note on this being the pragmatic substitute where no
 *  live database is available. Understands only the query shapes
 *  `deliverPending`/`handleIncomingEvents` actually issue. */
export class FakeDatabaseClient implements DatabaseClient {
  pendingRows: { aggregatorNodeId: number; eventHlc: string }[] = [];
  streamRows: Record<string, unknown>[] = [];
  forwardedInserts: {
    stream: string;
    rows: Record<string, unknown>[];
    aggregatorNodeIds: number[];
  }[] = [];

  async exec(): Promise<void> {
    throw new Error("FakeDatabaseClient: exec not used by this test");
  }

  async query<Row extends Record<string, unknown>>(
    sql: string,
    params: unknown[] = [],
  ): Promise<Row[]> {
    if (sql.trimStart().startsWith("SELECT * FROM")) {
      const aggregatorNodeId = params[0] as number;
      const batchSize = params[1] as number | undefined;
      let hlcs = this.pendingRows
        .filter((p) => p.aggregatorNodeId === aggregatorNodeId)
        .map((p) => p.eventHlc)
        .sort();
      if (batchSize !== undefined) {
        hlcs = hlcs.slice(0, batchSize);
      }
      return this.streamRows.filter((row) =>
        hlcs.includes(row["_struo_hlc"] as string),
      ) as Row[];
    }
    if (sql.startsWith("DELETE FROM")) {
      const aggregatorNodeId = params[0] as number;
      const eventHlcs = params[1] as string[];
      this.pendingRows = this.pendingRows.filter(
        (p) =>
          !(p.aggregatorNodeId === aggregatorNodeId && eventHlcs.includes(p.eventHlc)),
      );
      return [] as Row[];
    }
    throw new Error(`FakeDatabaseClient: unhandled query: ${sql}`);
  }

  async execStatement<Row extends Record<string, unknown>>(): Promise<StatementResult<Row>> {
    throw new Error("FakeDatabaseClient: execStatement not used by this test");
  }

  async insertForwardedEvents(
    stream: string,
    rows: Record<string, unknown>[],
    aggregatorNodeIds: number[],
  ): Promise<void> {
    this.forwardedInserts.push({ stream, rows, aggregatorNodeIds });
  }

  async close(): Promise<void> {}
}
