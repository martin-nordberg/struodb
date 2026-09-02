// Composition root: builds the one `HlcClock` and `CatalogHandle` this
// process uses, then drives them from stdin — a minimal first "driving
// adapter" (see the migration plan's hexagonal-architecture framing).
// No HTTP layer yet; that (Hono or otherwise) is explicitly deferred —
// see documentation/plans/architecture/bun-typescript-migration-plan.md's
// "Explicitly deferred" section.
//
// Each line of input is one StruoQL statement (or several, `;`-
// separated, on one line): `CREATE STREAM`/`ALTER STREAM` text goes to
// `schema-bridge.applyDdl`, `INSERT` text to `streams-bridge.
// applyInsert`, picked by a leading keyword — a real client protocol is
// its own future decision, not this migration's. `~quit`/`~q` ends the
// session, echoing `reader.gleam`'s old sentinel (see the pre-migration
// shared/src/asyncio/reader.gleam, since deleted) even though nothing
// of that actor pipeline survives here.
import * as readline from "node:readline";
import { emptyCatalog, applyDdl, type CatalogHandle } from "./bridges/schema-bridge.ts";
import { applyInsert } from "./bridges/streams-bridge.ts";
import { HlcClock } from "./hlc-clock.ts";

const QUIT_SENTINELS = new Set(["~quit", "~q"]);

/** Must be exactly 5 base-62 (`0-9A-Za-z`) characters — see
 *  documentation/docs/specifications/internals/hlc-spec.md. Read from
 *  `STRUODB_NODE_ID`, falling back to a single-node development default;
 *  a real multi-node deployment's config source is not this migration's
 *  concern (see the plan's "Explicitly deferred" section). */
function nodeId(): string {
  return Bun.env.STRUODB_NODE_ID ?? "node1";
}

function looksLikeDdl(statement: string): boolean {
  const upper = statement.trimStart().slice(0, 6).toUpperCase();
  return upper.startsWith("CREATE") || upper.startsWith("ALTER");
}

export async function main(): Promise<void> {
  const clock = HlcClock.create(nodeId());
  let catalog: CatalogHandle = emptyCatalog();

  const lines = readline.createInterface({ input: process.stdin });
  for await (const line of lines) {
    const statement = line.trim();
    if (statement.length === 0) continue;
    if (QUIT_SENTINELS.has(statement)) break;

    if (looksLikeDdl(statement)) {
      const [resultJson, updatedCatalog] = applyDdl(catalog, statement);
      catalog = updatedCatalog;
      console.log(resultJson);
    } else {
      console.log(applyInsert(clock, catalog, statement));
    }
  }
}

if (import.meta.main) {
  await main();
}
