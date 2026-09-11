import type { DatabaseClient, StatementResult } from "database-repo";

interface StreamRow {
  _struo_hlc: string;
  _struo_created_at: Date;
  [key: string]: unknown;
}

function unquote(name: string): string {
  return name.startsWith('"')
    ? name.slice(1, -1).replaceAll('""', '"')
    : name;
}

/** A minimal in-memory fake standing in for a real Postgres — see
 *  documentation/plans/architecture/event-store-implementation-plan.md's
 *  own test-plan note. Understands only `sweepStream`'s one `DELETE ...
 *  RETURNING` shape, including the `ON DELETE CASCADE` behavior the
 *  real `_pending_aggregations` FK provides — deleting a stream row
 *  here also drops that event's own still-pending rows, exactly like
 *  the real schema. */
export class FakeDatabaseClient implements DatabaseClient {
  streamRows = new Map<string, StreamRow[]>();
  pendingRows = new Map<string, { aggregatorNodeId: number; eventHlc: string }[]>();
  queryCalls = 0;

  seedStreamRow(stream: string, hlc: string, createdAt: Date) {
    const rows = this.streamRows.get(stream) ?? [];
    rows.push({ _struo_hlc: hlc, _struo_created_at: createdAt });
    this.streamRows.set(stream, rows);
  }

  seedPending(stream: string, hlc: string, aggregatorNodeId: number) {
    const rows = this.pendingRows.get(stream) ?? [];
    rows.push({ aggregatorNodeId, eventHlc: hlc });
    this.pendingRows.set(stream, rows);
  }

  async exec(): Promise<void> {
    throw new Error("FakeDatabaseClient: exec not used by this test");
  }

  async query<Row extends Record<string, unknown>>(
    sql: string,
    params: unknown[] = [],
  ): Promise<Row[]> {
    this.queryCalls++;
    const match = sql.match(/^DELETE FROM (\S+) s WHERE/);
    if (!match) {
      throw new Error(`FakeDatabaseClient: unhandled query: ${sql}`);
    }
    const stream = unquote(match[1]!);
    const maxRemainingPending = params[0] as number;
    const cutoff = params[1] as Date | undefined;

    const rows = this.streamRows.get(stream) ?? [];
    const pending = this.pendingRows.get(stream) ?? [];

    const toDelete = rows.filter((row) => {
      const pendingCount = pending.filter((p) => p.eventHlc === row._struo_hlc).length;
      if (pendingCount > maxRemainingPending) return false;
      if (cutoff !== undefined && !(row._struo_created_at < cutoff)) return false;
      return true;
    });

    const deletedHlcs = new Set(toDelete.map((r) => r._struo_hlc));
    this.streamRows.set(
      stream,
      rows.filter((r) => !deletedHlcs.has(r._struo_hlc)),
    );
    // ON DELETE CASCADE: the deleted event's own pending rows go with it.
    this.pendingRows.set(
      stream,
      pending.filter((p) => !deletedHlcs.has(p.eventHlc)),
    );

    return toDelete.map(() => ({ deleted: 1 })) as unknown as Row[];
  }

  async execStatement<Row extends Record<string, unknown>>(): Promise<StatementResult<Row>> {
    throw new Error("FakeDatabaseClient: execStatement not used by this test");
  }

  async insertForwardedEvents(): Promise<void> {
    throw new Error("FakeDatabaseClient: insertForwardedEvents not used by this test");
  }

  async close(): Promise<void> {}
}
