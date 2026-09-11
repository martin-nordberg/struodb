import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// A real process-level smoke test — spawns the actual composition root
// (main.ts) against a real config file and a real (in-memory PGLite)
// database, exercises it over real HTTP, and sends a real SIGTERM.
// Previously flagged as an accepted gap in
// documentation/plans/architecture/event-collector-implementation-plan.md's
// "Open questions" ("no environment to run a real deployable in") — now
// closeable precisely because PGLite needs no external server.

async function waitForReady(port: number, deadlineMs: number): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < deadlineMs) {
    try {
      const res = await fetch(`http://localhost:${port}/api/admin`);
      if (res.ok) return;
    } catch {
      // not listening yet
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`event-collector-service did not become ready on :${port} in time`);
}

describe("event-collector-service (smoke)", () => {
  test(
    "starts, serves event creation and admin over real HTTP, and shuts down cleanly on SIGTERM",
    async () => {
      const dir = mkdtempSync(join(tmpdir(), "event-collector-service-"));
      const configPath = join(dir, "config.json");
      const port = 34_567;

      writeFileSync(
        configPath,
        JSON.stringify({
          eventStore: {
            databaseUrl: "pglite://",
            nodeId: 1,
            streams: {
              sensor_reading: {
                migration: "CREATE STREAM sensor_reading (reading REAL);",
                aggregators: [],
              },
            },
            aggregators: {},
          },
          port,
          sweepIntervalMs: 3_600_000,
        }),
      );

      const proc = Bun.spawn(["bun", "run", "src/main.ts", configPath], {
        cwd: join(import.meta.dir, ".."),
        stdout: "pipe",
        stderr: "pipe",
      });

      try {
        await waitForReady(port, 10_000);

        const insertRes = await fetch(`http://localhost:${port}/api/events`, {
          method: "POST",
          body: "INSERT INTO sensor_reading (reading) VALUES (1.0);",
        });
        expect(insertRes.status).toBe(200);
        expect(await insertRes.json()).toEqual([{ count: 1 }]);

        const adminRes = await fetch(`http://localhost:${port}/api/admin`);
        expect(adminRes.status).toBe(200);
        const admin = (await adminRes.json()) as {
          streams: {
            name: string;
            migrationStepCount: number;
            eventCount: number;
            aggregatorNodeIds: number[];
            pendingByAggregator: Record<number, number>;
          }[];
        };
        expect(admin.streams).toEqual([
          {
            name: "sensor_reading",
            migrationStepCount: 1,
            eventCount: 1,
            aggregatorNodeIds: [],
            pendingByAggregator: {},
          },
        ]);

        proc.kill("SIGTERM");
        const exitCode = await proc.exited;
        expect(exitCode).toBe(0);
      } finally {
        if (proc.exitCode === null) proc.kill("SIGKILL");
        rmSync(dir, { recursive: true, force: true });
      }
    },
    15_000,
  );
});
