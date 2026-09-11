// The "StruoQL Over HTTP" component (event-collectors.md §3.2/§3.3.1) —
// a Hono app exposing event creation and admin endpoints. See
// documentation/plans/architecture/event-collector-implementation-plan.md,
// Phase 6.

import { Hono } from "hono";
import { EventCreationError } from "event-creation";
import type { InsertStatementResult, StreamStats } from "event-store";

/** The narrow slice of `EventStore`'s real API this package actually
 *  needs — a structural interface, not an import of the concrete
 *  `EventStore` class, per
 *  documentation/plans/architecture/event-collector-implementation-plan.md's
 *  "Decisions carried over from discussion". A real `EventStore`
 *  instance already satisfies this with no adapter; this package's own
 *  tests use a trivial object literal instead, with no database at
 *  all. */
export interface EventCreationBackend {
  createEvents(source: string): Promise<InsertStatementResult[]>;
  allStreamStats(): Promise<StreamStats[]>;
}

/** Event creation: `POST /api/events`, `Content-Type: text/plain`
 *  StruoQL `INSERT` text (one or more `;`-separated statements).
 *  Responds `200` with a JSON array, one entry per statement — the
 *  `RETURNING` rows if the statement had one, otherwise `{"count":
 *  N}`. A StruoQL syntax/semantic error responds `400`; anything else
 *  propagates to Hono's own default error handling (`500`).
 *
 *  Admin: `GET /api/admin` — `{"streams": [...]}`, one `StreamStats`
 *  object per configured stream. No authentication — deferred, per
 *  event-collectors.md §3.3.1. */
export function createApp(backend: EventCreationBackend): Hono {
  const app = new Hono();

  app.post("/api/events", async (c) => {
    const source = await c.req.text();
    try {
      const results = await backend.createEvents(source);
      return c.json(
        results.map((r) => (r.kind === "rows" ? r.rows : { count: r.count })),
      );
    } catch (err) {
      if (err instanceof EventCreationError) {
        return c.json({ error: err.message }, 400);
      }
      throw err;
    }
  });

  app.get("/api/admin", async (c) => {
    const streams = await backend.allStreamStats();
    return c.json({ streams });
  });

  return app;
}
