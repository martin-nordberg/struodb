// The "General Purpose Event Collector" composition root
// (event-collectors.md §3.3.2) — the actual deployable Bun web
// service. See
// documentation/plans/architecture/event-collector-implementation-plan.md,
// Phase 7.

import { start as startEventStore } from "event-store";
import { createApp } from "http-event-creation";
import { parseEventCollectorConfig } from "./config.ts";

export async function main(): Promise<void> {
  const configPath = Bun.argv[2];
  if (!configPath) {
    console.error("usage: event-collector-service <config-file-path>");
    process.exit(1);
  }

  const configJson = JSON.parse(await Bun.file(configPath).text());
  const config = parseEventCollectorConfig(configJson);

  const eventStore = await startEventStore(config.eventStore);
  const backgroundLoops = eventStore.startBackgroundLoops(config.sweepIntervalMs);
  const app = createApp(eventStore);
  const server = Bun.serve({ port: config.port, fetch: app.fetch });

  // event-collectors.md §3.3.2's "Shutdown (SIGTERM) gracefully shuts
  // down the event store (waiting for work in progress, stopping
  // timers, and closing the database)" — in that order: stop taking on
  // new background work, let Bun.serve's own in-flight requests drain
  // (server.stop()'s default behavior), *then* close the database, so
  // nothing still-running is left holding a closed connection.
  let shuttingDown = false;
  const shutdown = async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    backgroundLoops.stop();
    await server.stop();
    await eventStore.close();
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);

  console.log(`event-collector-service listening on :${config.port}`);
}

if (import.meta.main) {
  await main();
}
