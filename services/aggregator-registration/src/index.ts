// The "Aggregator Registration" component (event-stores.md
// §2.4/§2.7.5) and its aggregator-side counterpart, "Collector
// Registration" (event-aggregators.md §4.4) — implements event-stores.md
// §2.6.2's "calls Aggregator Registration to register... and retrieve
// the aggregator's schema for the stream." See
// documentation/plans/architecture/event-store-implementation-plan.md,
// Phase 10.
//
// No HTTP server framework here — `handleRegister` below is a plain
// function a real server (Bun.serve or otherwise, composed by
// services/event-store once that lands) calls into, not a route handler
// itself; standing up an actual HTTP layer is out of scope for this
// package (see the implementation plan's "Scope").

export interface AggregatorEndpoint {
  baseUrl: string;
}

export class AggregatorRegistrationError extends Error {
  readonly status: number;

  constructor(status: number, body: string) {
    super(`aggregator registration failed (HTTP ${status}): ${body}`);
    this.name = "AggregatorRegistrationError";
    this.status = status;
  }
}

/** Collector side: registers with `aggregator` for `stream` and returns
 *  its recorded migration source — the collector then runs that through
 *  its own `services/schema-migration` against its local database (see
 *  event-stores.md §2.6.2). `fetchImpl` is injectable so tests don't
 *  need a real HTTP server. */
export async function registerWithAggregator(
  aggregator: AggregatorEndpoint,
  stream: string,
  fetchImpl: typeof fetch = fetch,
): Promise<{ migration: string }> {
  const res = await fetchImpl(
    `${aggregator.baseUrl}/streams/${encodeURIComponent(stream)}/register`,
    { method: "POST" },
  );
  if (!res.ok) {
    throw new AggregatorRegistrationError(res.status, await res.text());
  }
  return (await res.json()) as { migration: string };
}

/** Aggregator side: looks up this aggregator's own recorded migration
 *  source for `stream` via `migrationForStream` (config-supplied — the
 *  same `StreamConfig.migration` shape a collector has) and returns the
 *  JSON body `registerWithAggregator` above expects. `undefined` means
 *  this aggregator doesn't know `stream` at all — a real HTTP layer
 *  turns that into a 404, not this function's concern. */
export function handleRegister(
  stream: string,
  migrationForStream: (stream: string) => string | undefined,
): { migration: string } | undefined {
  const migration = migrationForStream(stream);
  return migration === undefined ? undefined : { migration };
}
