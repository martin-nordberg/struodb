# Event Collector — Implementation Plan

Implements `documentation/docs/specifications/architecture/event-collectors.md`
§3.2–§3.3 — the two software components of a standalone, general-purpose
event collector: `http-event-creation` (StruoQL-over-HTTP) and
`event-collector-service` (the deployable Bun web service itself), plus
the "Supporting Changes" §3.1 already calls out in already-shipped code
(`event-store`, `event-creation`, `database-repo`). Read that spec first;
this plan also builds directly on
`documentation/plans/architecture/event-store-implementation-plan.md`
("implemented" per its own status line) and doesn't re-derive its design
decisions.

**Initial scope, per discussion**: a standalone general-purpose event
collector as a Bun web service, backed by PGLite for its PostgreSQL data
initially, designed so a later swap to real PostgreSQL touches
configuration only — never this component's own code or dependencies.

**Status: implemented**, per "Step-by-step build order" below — every
phase's Gleam/TypeScript code and test suite is in place, `gleam test
--runtime bun`/`gleam format --check` are green for `domain/streams`,
and `tsc --noEmit`/`bun test` are green for every `services/*` package
this plan touches plus `service/`. See "Implementation notes" near the
end for where reality landed relative to this plan's own "Open
questions" — several of them turned out to be directly answerable once
PGLite was actually installed and exercised, rather than staying open.

## Scope

**In scope**:
- `domain/streams`: `dml_codegen.generate`/`dml_facade.apply_insert`
  report one result per `INSERT` statement instead of one joined SQL
  string, so a batch of several statements (or a single statement
  spanning several streams) can each get their own accurate response.
- `services/database-repo`: a new `execStatement` method (single
  statement in, `{rows, affectedRows}` out) on `DatabaseClient`; a
  PGLite-backed second implementation behind the same interface,
  selected by `connect(databaseUrl)` dispatching on URL scheme; three
  small stats-query helpers backing the admin endpoint.
- `services/event-creation`: `createEvents` returns one result per
  statement (rows, for a `RETURNING` statement; an accurate insert
  count otherwise — see "Decisions carried over from discussion" for
  why that count needs correcting when aggregators are configured).
- `services/event-store`: `EventStore.createEvents`'s return type
  follows suit; new `streamStats`/`allStreamStats` methods back the
  admin endpoint.
- New `services/http-event-creation`: a Hono app (event creation +
  admin endpoints, per event-collectors.md §3.3.1), decoupled from
  `EventStore`'s concrete class via a narrow structural interface.
- New `services/event-collector-service`: the actual deployable — CLI
  config-file argument, composition root, graceful SIGTERM shutdown.
- Root workspace/CI updates for the two new packages.

**Out of scope (deferred)**:
- Authentication for the admin endpoint — event-collectors.md §3.3.1
  itself defers this explicitly.
- The aggregator side of anything (its own `POST /streams/:stream
  /register`/`/events` HTTP server) — that's `event-aggregators.md`'s
  own future implementation plan; this collector only ever calls
  *out* to an aggregator (`aggregator-registration`/`event-delivery`,
  both already built), never receives inbound aggregator traffic.
- `domain/network`, `domain/projections` — untouched.
- Standalone PostgreSQL / PostgreSQL-in-container as the actual
  connection this collector uses — `BunSqlClient` (already built)
  already speaks real Postgres; nothing here needs to *change* for that
  swap to work, which is the whole point (see "Decisions" below), but
  this plan's own testing only exercises the PGLite path plus the
  already-existing fakes for what it doesn't touch.
- Rate limiting, request size limits, CORS — premature for a first
  standalone-service pass; worth a look once this has a real deployment
  target.

## Decisions carried over from discussion

- **PGLite is a second `DatabaseClient` implementation inside
  `database-repo`, never a dependency of anything above it.**
  `event-collector-service` depends on `event-store` (hence
  transitively `database-repo`), full stop — it has no idea PGLite
  exists. `database-repo.connect(databaseUrl)` dispatches purely on the
  URL's scheme (`pglite://` vs. anything else, today just
  `postgres://`/`postgresql://` via `Bun.SQL`). Swapping to real
  PostgreSQL later is changing one config value, not any package's
  dependency list or code.
- **PGLite's storage is file-backed by default for this use case.**
  `pglite://<filesystem-path>` maps to `new PGlite(<path>)`; the bare
  scheme with nothing after it (`pglite://`) maps to PGLite's in-memory
  mode, used only for tests. A "standalone" service that's meant to
  retain events across restarts should always be configured with a real
  path in production — this plan doesn't enforce that (a config
  validator can't know whether in-memory was a deliberate test choice
  or a production mistake), but it's worth flagging in the collector's
  own README/deployment notes once those exist.
- **`execStatement` is new, added alongside `query`/`exec` — neither of
  those two change.** `schema-migration`, `event-delivery`, and
  `event-obsolescence` (all already shipped, tested, and unrelated to
  this plan's own goal) call `query`/`exec` today and don't need
  per-statement metadata; leaving them alone means their existing tests
  and fakes need only a trivial new stub method, not a rewrite. Only
  `event-creation`'s new per-statement path uses `execStatement`.
- **The aggregator-count-inflation problem (raised discussing
  event-collectors.md) is solved by correcting the count in
  TypeScript, not by changing what SQL gets executed.** When a stream
  has aggregators configured and its `INSERT` has no `RETURNING`
  clause, `dml_codegen`'s generated SQL (already built, unchanged by
  this plan) ends with the `_pending_aggregations` fan-out `INSERT` as
  its own top-level statement — its own affected-row-count is
  `(rows actually inserted) × (aggregator count)`, deterministically
  (`CROSS JOIN unnest(ARRAY[...])` always produces exactly one row per
  aggregator id per input row; a row skipped by `ON CONFLICT DO
  NOTHING` never reaches the fan-out to begin with). Dividing by the
  aggregator count for that specific statement's stream recovers the
  exact insert count — see "Phase 3" below. This needs `dml_facade` to
  report, per statement, which stream it targeted and whether it had a
  `RETURNING` clause (both already known to `dml_ast.Insert`); it does
  **not** need to report the aggregator count itself — the TypeScript
  caller already holds `aggregatorNodeIdsForStream` and can look that
  count up directly, one less thing for the Gleam/JSON boundary to
  carry.
- **Existing `dml_codegen_test.gleam` coverage survives via
  `generate_standalone` staying a compatibility wrapper.** `generate`'s
  return type changes (a joined `String` → `List(InsertStatementResult)`),
  but `generate_standalone` re-joins the per-statement SQL the same way
  `render_all` used to (`string.join(...,  "\n\n")` plus a trailing
  `"\n"`), so every existing exact-string test built against
  `generate_standalone` keeps passing unchanged. Only the handful of
  tests calling `generate` directly need a small mechanical update.
- **PGLite unlocks real integration tests, not just fakes.** Every
  previous implementation phase used a hand-rolled in-memory fake
  `DatabaseClient` because no Postgres instance was available in that
  environment. PGLite runs embedded, in-process, with no external
  server — `new PGlite()` (in-memory) is a real, fully-functional
  Postgres for test purposes. Once Phase 2 lands, `event-creation`'s,
  `http-event-creation`'s, and `event-collector-service`'s own tests in
  this plan use a real in-memory PGLite instance instead of a fake —
  the fakes already written for `schema-migration`/`event-delivery`/
  `event-obsolescence` are untouched (those packages aren't modified
  here) but are worth revisiting for the same upgrade in a later pass.
- **`http-event-creation` depends on `event-store` for types only,
  via a narrow structural interface**, not the concrete `EventStore`
  class — `EventCreationBackend` below declares just the two methods
  the HTTP layer calls. `EventStore` already satisfies it structurally,
  so `event-collector-service` passes a real instance with no adapter,
  while `http-event-creation`'s own tests use a trivial object literal
  instead of constructing a real `EventStore` (database, clock, and
  all).
- **Collector-specific config (`port`, the obsolescence-sweep interval)
  lives in `event-collector-service`'s own config type, wrapping
  `EventStoreConfig` rather than extending it.** `EventStoreConfig`
  (already built) is meant to be reusable by an aggregator process too
  eventually, which has no HTTP port of its own — keeping those fields
  out of it avoids contaminating a type another role will also need.
- **`services/*` package/path naming matches event-collectors.md's own
  `Name:`/`Path:` fields exactly**: `http-event-creation`,
  `event-collector-service` — no further renaming.

## Target repository layout

```
domain/streams/src/lang/dml_codegen.gleam   # generate/render_all return List(InsertStatementResult); generate_standalone re-joins for compatibility
domain/streams/src/dml_facade.gleam         # apply_insert JSON: {"ok": true, "statements": [...]}
service/src/bridges/streams-bridge.ts       # applyInsert's return type follows the new JSON shape
services/
  database-repo/src/index.ts        # + execStatement, + PGliteClient, connect() scheme dispatch
  database-repo/src/pglite-client.ts        # new
  database-repo/src/admin-stats.ts          # new: streamEventCount, pendingCountsByAggregator, migrationStepCount
  event-creation/src/index.ts               # createEvents returns InsertStatementResult[]; applies the aggregator-count correction
  event-store/src/index.ts                  # createEvents follows suit; + streamStats/allStreamStats
  http-event-creation/                      # new
    src/index.ts                            # createApp(backend): Hono
    test/index.test.ts
  event-collector-service/                  # new
    src/config.ts                           # EventCollectorConfig, parseEventCollectorConfig
    src/main.ts                             # composition root
    test/config.test.ts
package.json                                # workspaces already cover services/*; no change needed
```

## Phase 1 — `dml_codegen.gleam`/`dml_facade.gleam`: per-statement results

### `dml_codegen.gleam`

```gleam
/// One rendered `INSERT` statement's SQL, alongside the two pieces of
/// metadata a caller needs to correctly interpret executing it on its
/// own — see
/// documentation/plans/architecture/event-collector-implementation-plan.md's
/// "Decisions carried over from discussion" for why `has_returning` is
/// here but an aggregator count is deliberately not.
pub type InsertStatementResult {
  InsertStatementResult(sql: String, stream_name: String, has_returning: Bool)
}

pub fn generate(
  catalog: Catalog,
  source: String,
  next_hlc: fn() -> clock.HlcParts,
  aggregators_for_stream: fn(String) -> List(Int),
) -> Result(#(List(InsertStatementResult), Catalog), CodegenError) {
  use tokens <- result.try(
    lexer.tokenize(source) |> result.map_error(LexFailure),
  )
  use statements <- result.try(
    dml_parser.parse_many(token_stream.new(tokens))
    |> result.map_error(ParseFailure),
  )
  use final_catalog <- result.try(validate_all(catalog, statements, 0))
  Ok(#(render_all(statements, next_hlc, aggregators_for_stream), final_catalog))
}

/// Re-joins `generate`'s per-statement results into one SQL blob, the
/// same way `render_all` always has (`"\n\n"`-joined, one trailing
/// `"\n"`) — kept so every existing exact-string test built against
/// this function needs no change at all.
pub fn generate_standalone(
  source: String,
  next_hlc: fn() -> clock.HlcParts,
  aggregators_for_stream: fn(String) -> List(Int),
) -> Result(String, CodegenError) {
  use #(results, _catalog) <- result.try(generate(
    catalog.empty(),
    source,
    next_hlc,
    aggregators_for_stream,
  ))
  let joined =
    results |> list.map(fn(r) { r.sql }) |> string.join("\n\n")
  Ok(joined <> "\n")
}

fn render_all(
  statements: List(ast.DmlStatement),
  next_hlc: fn() -> clock.HlcParts,
  aggregators_for_stream: fn(String) -> List(Int),
) -> List(InsertStatementResult) {
  list.map(statements, fn(stmt) {
    let ast.Insert(stream_name:, returning:, ..) = stmt
    InsertStatementResult(
      sql: insert_to_sql(stmt, next_hlc, aggregators_for_stream),
      stream_name: stream_name,
      has_returning: option.is_some(returning),
    )
  })
}
```

`insert_to_sql` itself is untouched — `render_all` above is the only
caller-visible change; every other private helper in this module is
unaffected.

**Test plan** (`dml_codegen_test.gleam`):
- Every existing test calling `generate_standalone` needs no change —
  confirm by running the suite before touching anything else.
- The handful calling `generate` directly (`generate_threads_the_catalog
  _and_validates_alter_against_it_test`, `generate_end_to_end_against
  _the_given_catalog_test`, `a_semicolon_inside_a_string_literal_is_not
  _a_statement_boundary_test`, the `CodegenError`-variant tests) get a
  small mechanical update: assert against `result.sql`/`.stream_name`/
  `.has_returning` on each list element, or re-join via
  `list.map(fn(r) { r.sql }) |> string.join("\n\n")` where the test only
  cared about the combined SQL text.
- New: a 2-statement `source` (targeting two different streams, one
  with `RETURNING` and one without) produces a 2-element list with the
  right `stream_name`/`has_returning` on each, in source order.
- New: a stream with aggregators and no `RETURNING` still reports
  `has_returning: False` — this module never needs to know about the
  aggregator-count correction at all, only whether `RETURNING` was
  present.

### `dml_facade.gleam`

```gleam
/// Returns JSON:
///   `{"ok": true, "statements": [{"sql": "...", "stream_name": "...",
///     "has_returning": true|false}, ...]}` — one entry per `INSERT`
///     statement in `source`, in order.
///   `{"ok": false, "error": "<lex/parse/semantic failure description>"}`
pub fn apply_insert(
  catalog: Catalog,
  source: String,
  next_hlc: fn() -> HlcParts,
  aggregators_for_stream: fn(String) -> List(Int),
) -> String {
  case dml_codegen.generate(catalog, source, next_hlc, aggregators_for_stream) {
    Ok(#(results, _catalog_unchanged)) -> ok_json(results)
    Error(err) -> error_json(err)
  }
}

fn ok_json(results: List(dml_codegen.InsertStatementResult)) -> String {
  json.object([
    #("ok", json.bool(True)),
    #("statements", json.array(results, statement_result_json)),
  ])
  |> json.to_string
}

fn statement_result_json(r: dml_codegen.InsertStatementResult) -> json.Json {
  json.object([
    #("sql", json.string(r.sql)),
    #("stream_name", json.string(r.stream_name)),
    #("has_returning", json.bool(r.has_returning)),
  ])
}
```

`error_json` is unchanged.

**Test plan** (`dml_facade_test.gleam`): update the existing
`"ok":true`/`"INSERT INTO s"` substring checks to instead assert against
the new `"statements":[...]` array shape (e.g. `string.contains(result,
"\"stream_name\":\"s\"")`); add one test confirming a 2-statement source
produces a 2-element `"statements"` array.

### `service/src/bridges/streams-bridge.ts`

No signature change — `applyInsert` still returns the raw JSON string
from the facade (it always has; callers `JSON.parse` it themselves). Its
doc comment gets a one-line update pointing at the new shape, and
`service/test/streams-bridge.test.ts`'s `"INSERT INTO s"` substring
check becomes a `"stream_name":"s"` one instead, matching Phase 1's
facade-level test update above.

## Phase 2 — `database-repo`: `execStatement` + PGLite

### `execStatement`

```ts
export interface StatementResult<Row extends Record<string, unknown> = Record<string, unknown>> {
  rows: Row[];
  /** Rows affected by a non-`SELECT` statement — Bun's `SQL` client
   *  attaches this to the array it resolves with (confirmed against
   *  the installed Bun 1.4 runtime: `SQLResultArray` carries both
   *  `count` and `affectedRows`); PGLite's own `query()` result object
   *  exposes `affectedRows` directly. For a statement *with*
   *  `RETURNING`, this equals `rows.length`. */
  affectedRows: number;
}

export interface DatabaseClient {
  exec(sql: string): Promise<void>;
  query<Row extends Record<string, unknown>>(sql: string, params?: unknown[]): Promise<Row[]>;
  /** Runs exactly one SQL statement (no trailing `;`-separated batch —
   *  that's what `exec` is still for) and returns both its rows and its
   *  affected-row-count. The one method `event-creation`'s new
   *  per-statement path uses; every other existing caller keeps using
   *  `query`/`exec` unchanged. */
  execStatement<Row extends Record<string, unknown>>(
    sql: string,
    params?: unknown[],
  ): Promise<StatementResult<Row>>;
  insertForwardedEvents(stream: string, rows: Record<string, unknown>[], aggregatorNodeIds: number[]): Promise<void>;
  close(): Promise<void>;
}
```

`BunSqlClient.execStatement`:

```ts
async execStatement<Row extends Record<string, unknown>>(
  sql: string,
  params: unknown[] = [],
): Promise<StatementResult<Row>> {
  const result = (await this.#sql.unsafe<Row[]>(sql, params)) as Row[] & {
    affectedRows?: number;
    count?: number;
  };
  return { rows: result, affectedRows: result.affectedRows ?? result.count ?? result.length };
}
```

(The `?? result.count ?? result.length` fallback chain is defensive —
verify during implementation which field Bun 1.4's `SQL.unsafe` actually
populates for a plain `INSERT`/`INSERT...RETURNING`/multi-row `INSERT`,
and drop the unused fallbacks once confirmed rather than leaving dead
branches.)

### `PGliteClient` (`src/pglite-client.ts`, new)

```ts
import { PGlite } from "@electric-sql/pglite";
import { buildForwardedInsertSql } from "./forwarded-insert.ts";
import type { DatabaseClient, StatementResult } from "./index.ts";

/** `dataDir` is everything after `pglite://` in the connection URL —
 *  empty means PGLite's own in-memory mode (tests only; see "Decisions
 *  carried over from discussion" on why production should always pass
 *  a real path). PGLite embeds real PostgreSQL (via WASM) with no
 *  external server process, so this implementation talks to it through
 *  PGLite's own `query`/`exec` API — structurally similar to
 *  `Bun.SQL`'s but not the same calls. */
export class PGliteClient implements DatabaseClient {
  #db: PGlite;

  constructor(dataDir: string) {
    this.#db = new PGlite(dataDir === "" ? undefined : dataDir);
  }

  async exec(sql: string): Promise<void> {
    await this.#db.exec(sql); // PGLite's own multi-statement runner
  }

  async query<Row extends Record<string, unknown>>(
    sql: string,
    params: unknown[] = [],
  ): Promise<Row[]> {
    const result = await this.#db.query<Row>(sql, params);
    return result.rows;
  }

  async execStatement<Row extends Record<string, unknown>>(
    sql: string,
    params: unknown[] = [],
  ): Promise<StatementResult<Row>> {
    const result = await this.#db.query<Row>(sql, params);
    return { rows: result.rows, affectedRows: result.affectedRows };
  }

  async insertForwardedEvents(
    stream: string,
    rows: Record<string, unknown>[],
    aggregatorNodeIds: number[],
  ): Promise<void> {
    const { sql, params } = buildForwardedInsertSql(stream, rows, aggregatorNodeIds);
    await this.#db.query(sql, params);
  }

  async close(): Promise<void> {
    await this.#db.close();
  }
}
```

### `connect()` dispatch

```ts
const PGLITE_SCHEME = "pglite://";

export function connect(databaseUrl: string): DatabaseClient {
  if (databaseUrl.startsWith(PGLITE_SCHEME)) {
    return new PGliteClient(databaseUrl.slice(PGLITE_SCHEME.length));
  }
  return new BunSqlClient(databaseUrl);
}
```

`package.json` gains `@electric-sql/pglite` as a real (non-dev)
dependency — confirm the current stable version at implementation time
and pin it exactly, per this repo's existing convention elsewhere
(`gleam.toml`'s loose-but-bounded ranges) translated to `package.json`'s
own equivalent (an exact or caret-pinned version, whichever this repo's
other `package.json`s already do — check `service/package.json` and
match).

**Test plan** (`services/database-repo/test/`):
- `execStatement` against `BunSqlClient`: covered by the existing
  "no real Postgres available" constraint — leave as a documented gap
  (see Phase 1's own note) unless a real Postgres becomes available.
- `PGliteClient`, against a real in-memory instance (`new
  PGliteClient("")`, i.e. `connect("pglite://")`): `exec` runs a
  multi-statement `CREATE TABLE ...; CREATE TABLE ...;` blob (confirm
  PGLite's `exec` really does run each statement, not just the first —
  its own docs describe this but verify against the pinned version);
  `query` reads rows back; `execStatement` on a plain `INSERT` (no
  `RETURNING`) reports the right `affectedRows` with an empty `rows`;
  `execStatement` on `INSERT ... RETURNING *` reports both correctly;
  `insertForwardedEvents` populates both the stream table and its
  `_pending_aggregations` table, `ON CONFLICT DO NOTHING` included;
  `close()` doesn't throw.
- `connect("pglite://")` and `connect("pglite:///tmp/...")` both
  return a working, independent `PGliteClient`; `connect("postgres://
  ...")` still returns a `BunSqlClient` (type-level check only, no
  live connection attempted).

## Phase 3 — `database-repo`: admin-stats helpers

New file, `src/admin-stats.ts` — plain functions, not part of the
`DatabaseClient` interface itself (these are read-only reporting
queries against tables the interface's other methods already assume
exist, not a data-access primitive every implementation must define):

```ts
import { quoteIdentifier } from "./identifier.ts";
import { migrationHistoryTableName, pendingAggregationsTableName } from "./table-names.ts";
import type { DatabaseClient } from "./index.ts";

export async function streamEventCount(db: DatabaseClient, stream: string): Promise<number> {
  const rows = await db.query<{ count: string }>(
    `SELECT count(*) FROM ${quoteIdentifier(stream)}`,
  );
  return Number(rows[0]?.count ?? 0);
}

export async function migrationStepCount(db: DatabaseClient, stream: string): Promise<number> {
  const rows = await db.query<{ count: string }>(
    `SELECT count(*) FROM ${quoteIdentifier(migrationHistoryTableName(stream))}`,
  );
  return Number(rows[0]?.count ?? 0);
}

/** Keyed by aggregator node id — an aggregator with zero pending rows
 *  right now simply has no key, not a zero entry (the query only
 *  returns aggregators that actually have pending rows); a caller
 *  wanting every *configured* aggregator represented (even at 0) fills
 *  in the gaps itself from its own config, same as
 *  `EventStore.streamStats` (Phase 5) does. */
export async function pendingCountsByAggregator(
  db: DatabaseClient,
  stream: string,
): Promise<Record<number, number>> {
  const rows = await db.query<{ aggregator_node_id: number; count: string }>(
    `SELECT aggregator_node_id, count(*) FROM ${quoteIdentifier(pendingAggregationsTableName(stream))} GROUP BY aggregator_node_id`,
  );
  const result: Record<number, number> = {};
  for (const row of rows) result[row.aggregator_node_id] = Number(row.count);
  return result;
}
```

`count(*)`'s Postgres `bigint` result comes back as a numeric string
over the wire (both `Bun.SQL` and PGLite) to avoid silent precision loss
above `Number.MAX_SAFE_INTEGER` — the `Number(...)` conversions above
are a deliberate, accepted simplification (an event count realistically
never approaches that range); revisit if that assumption ever stops
holding.

**Test plan**: against a real in-memory `PGliteClient` (per Phase 2),
seed a stream with a few rows and a couple of pending-aggregation rows
across two aggregators, confirm all three functions report the right
numbers, including `migrationStepCount` after one `CREATE STREAM` +
one `ALTER STREAM`.

## Phase 4 — `event-creation`: per-statement results + the count correction

```ts
export type InsertStatementResult =
  | { kind: "rows"; rows: Record<string, unknown>[] }
  | { kind: "count"; count: number };

interface FacadeStatementResult {
  sql: string;
  stream_name: string;
  has_returning: boolean;
}

export async function createEvents(
  db: DatabaseClient,
  clock: HlcClock,
  catalog: CatalogHandle,
  source: string,
  aggregatorNodeIdsForStream: (stream: string) => number[],
): Promise<InsertStatementResult[]> {
  const resultJson = streamsFacade.apply_insert(
    catalog,
    source,
    () => clock.nextParts(),
    (stream: string) => List.fromArray(aggregatorNodeIdsForStream(stream)),
  );
  const result = JSON.parse(resultJson);
  if (!result.ok) {
    throw new EventCreationError(result.error);
  }

  const results: InsertStatementResult[] = [];
  for (const stmt of result.statements as FacadeStatementResult[]) {
    const { rows, affectedRows } = await db.execStatement(stmt.sql);
    if (stmt.has_returning) {
      results.push({ kind: "rows", rows });
    } else {
      // See the implementation plan's "Decisions carried over from
      // discussion": the fan-out INSERT's own affected-row-count is
      // inflated by exactly this stream's configured aggregator count
      // when there's no RETURNING to read the true count from instead.
      const aggregatorCount = aggregatorNodeIdsForStream(stmt.stream_name).length;
      const count = aggregatorCount > 0 ? affectedRows / aggregatorCount : affectedRows;
      results.push({ kind: "count", count });
    }
  }
  return results;
}
```

**Test plan** (against a real in-memory PGLite `DatabaseClient`, per
Phase 2 — this package's tests already build a real `Catalog` via the
compiled `schema` facade, so the whole path is now exercisable
end-to-end with no fakes at all):
- A stream with no aggregators, no `RETURNING`: one `{kind: "count",
  count: 1}` per row inserted — unaffected by this phase's own change
  (`aggregatorCount` is `0`, correction is a no-op).
- A stream with 2 aggregators, no `RETURNING`, 3 rows in one `INSERT`:
  `{kind: "count", count: 3}` — not `6`. This is *the* regression test
  for the correction; assert it against a real PGLite-backed pending
  table, not just the arithmetic in isolation, since the real risk is
  `execStatement`'s `affectedRows` not meaning what this code assumes.
- A stream with 2 aggregators and `RETURNING _struo_hlc`: `{kind:
  "rows", rows: [...]}` with exactly 3 rows (unaffected by aggregator
  count, confirming the `RETURNING` branch never needed correcting).
- Two statements in one `source`, targeting different streams with
  different aggregator counts: two independent, individually-correct
  results, in order.
- A semantic error still throws `EventCreationError` before any
  `execStatement` call.

## Phase 5 — `event-store`: `createEvents` return type + admin stats

```ts
import {
  migrationStepCount,
  pendingCountsByAggregator,
  streamEventCount,
} from "database-repo";
import { createEvents, type CatalogHandle, type InsertStatementResult } from "event-creation";

export type { InsertStatementResult } from "event-creation";

export interface StreamStats {
  name: string;
  migrationStepCount: number;
  eventCount: number;
  aggregatorNodeIds: number[];
  /** Every *configured* aggregator gets a key, `0` if it has nothing
   *  pending right now — unlike `pendingCountsByAggregator`'s own raw
   *  return value (Phase 3), which only mentions aggregators that
   *  currently have at least one pending row. */
  pendingByAggregator: Record<number, number>;
}
```

```ts
export class EventStore {
  // ... existing fields unchanged ...

  async createEvents(source: string): Promise<InsertStatementResult[]> {
    return createEvents(this.#db, this.#clock, this.#catalog, source, (stream) =>
      aggregatorNodeIdsForStream(this.#config, stream),
    );
  }

  async streamStats(stream: string): Promise<StreamStats> {
    const streamConfig = this.#config.streams[stream];
    if (!streamConfig) {
      throw new Error(`streamStats: unknown stream "${stream}"`);
    }
    const [steps, events, pending] = await Promise.all([
      migrationStepCount(this.#db, stream),
      streamEventCount(this.#db, stream),
      pendingCountsByAggregator(this.#db, stream),
    ]);
    const aggregatorNodeIds = streamConfig.aggregators.map((a) => a.nodeId);
    const pendingByAggregator: Record<number, number> = {};
    for (const nodeId of aggregatorNodeIds) {
      pendingByAggregator[nodeId] = pending[nodeId] ?? 0;
    }
    return {
      name: stream,
      migrationStepCount: steps,
      eventCount: events,
      aggregatorNodeIds,
      pendingByAggregator,
    };
  }

  async allStreamStats(): Promise<StreamStats[]> {
    return Promise.all(
      Object.keys(this.#config.streams).map((stream) => this.streamStats(stream)),
    );
  }

  // ... deliverPendingFor / sweepAll / startBackgroundLoops / close unchanged ...
}
```

(`migrationStepCount` the imported function and the `StreamStats` field
of the same name coexist fine — same non-issue as the already-shipped
`createEvents` method/import pair one file over.)

**Test plan**: extend the existing `services/event-store/test/`
fake-`DatabaseClient` suite with `streamStats`/`allStreamStats` cases
(a stream with one aggregator that hasn't received anything yet reports
`{7: 0}`, not an absent key); confirm `store.createEvents(...)`'s
return value now surfaces through the existing "initializes correctly"
test rather than being discarded.

## Phase 6 — `services/http-event-creation` (new package)

```json
{
  "name": "http-event-creation",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "exports": { ".": "./src/index.ts" },
  "dependencies": {
    "event-creation": "workspace:*",
    "event-store": "workspace:*",
    "hono": "^4"
  },
  "scripts": {
    "build": "tsc --noEmit",
    "test": "bun test"
  }
}
```

No `prebuild`/Gleam dependency — this package never imports compiled
Gleam output itself, only types re-exported from `event-store`/
`event-creation`.

```ts
// src/index.ts
import { Hono } from "hono";
import { EventCreationError } from "event-creation";
import type { InsertStatementResult, StreamStats } from "event-store";

/** The narrow slice of `EventStore`'s real API this package actually
 *  needs — see "Decisions carried over from discussion" on why this is
 *  a structural interface, not an import of the concrete class. A real
 *  `EventStore` instance already satisfies this with no adapter. */
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
```

**Test plan** (`test/index.test.ts`, a trivial in-memory
`EventCreationBackend` — no `EventStore`, no database, at all):
- `POST /api/events` with a fake `createEvents` returning `[{kind:
  "count", count: 3}]` responds `200` with `[{"count": 3}]`.
- The same with a `{kind: "rows", rows: [...]}` entry responds with
  that array verbatim as the JSON array element.
- A fake `createEvents` that throws `EventCreationError` responds `400`
  with `{"error": "..."}`.
- A fake `createEvents` that throws a plain `Error` responds `500`
  (Hono's default).
- `GET /api/admin` with a fake `allStreamStats` returning a couple of
  `StreamStats` objects responds `200` with `{"streams": [...]}`
  matching them exactly.

## Phase 7 — `services/event-collector-service` (new package)

```json
{
  "name": "event-collector-service",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "dependencies": {
    "event-store": "workspace:*",
    "http-event-creation": "workspace:*"
  },
  "scripts": {
    "prebuild": "bun run --cwd ../.. build:domain",
    "build": "bun run prebuild && tsc --noEmit",
    "pretest": "bun run prebuild",
    "test": "bun test",
    "start": "bun run prebuild && bun run src/main.ts"
  }
}
```

### `src/config.ts`

```ts
import { ConfigError, parseConfig as parseEventStoreConfig, type EventStoreConfig } from "event-store";

export interface EventCollectorConfig {
  eventStore: EventStoreConfig;
  port: number;
  /** event-stores.md §2.6.5's "fixed interval," in milliseconds —
   *  passed straight to `EventStore.startBackgroundLoops`. */
  sweepIntervalMs: number;
}

const DEFAULT_SWEEP_INTERVAL_MS = 60_000;

export function parseEventCollectorConfig(json: unknown): EventCollectorConfig {
  if (typeof json !== "object" || json === null || Array.isArray(json)) {
    throw new ConfigError(["config must be a JSON object"]);
  }
  const obj = json as Record<string, unknown>;
  const issues: string[] = [];

  let eventStore: EventStoreConfig | undefined;
  try {
    eventStore = parseEventStoreConfig(obj.eventStore);
  } catch (err) {
    if (!(err instanceof ConfigError)) throw err;
    issues.push(...err.issues.map((i) => `eventStore.${i}`));
  }

  const port = obj.port;
  if (typeof port !== "number" || !Number.isInteger(port) || port <= 0) {
    issues.push(`port: must be a positive integer (got ${JSON.stringify(port)})`);
  }

  const sweepIntervalMs = obj.sweepIntervalMs ?? DEFAULT_SWEEP_INTERVAL_MS;
  if (typeof sweepIntervalMs !== "number" || !Number.isInteger(sweepIntervalMs) || sweepIntervalMs <= 0) {
    issues.push(
      `sweepIntervalMs: must be a positive integer if given (got ${JSON.stringify(obj.sweepIntervalMs)})`,
    );
  }

  if (issues.length > 0) {
    throw new ConfigError(issues);
  }
  return { eventStore: eventStore!, port: port as number, sweepIntervalMs: sweepIntervalMs as number };
}
```

### `src/main.ts`

```ts
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
```

**Test plan**:
- `config.test.ts`: valid config round-trips; a missing/invalid `port`
  is reported; an invalid nested `eventStore` field surfaces its issues
  prefixed with `eventStore.`; `sweepIntervalMs` defaults when absent
  and is validated when present.
- `main.ts` itself is intentionally thin (composition only) and isn't
  unit-tested directly — every piece it wires together
  (`parseEventCollectorConfig`, `event-store.start`,
  `http-event-creation.createApp`, `EventStore.startBackgroundLoops`)
  already has its own coverage. A real smoke test (actually spawning
  the process against a `pglite://` config, hitting it with `fetch`,
  sending `SIGTERM`, confirming clean exit) is worth adding once this
  is actually deployed somewhere — not blocking for this plan.

## Phase 8 — Root workspace/tooling

- `package.json`: no change needed — `"services/*"` already covers new
  packages (per the event-store implementation plan's own Phase 14).
- `.github/workflows/test.yml`: add `http-event-creation` and
  `event-collector-service` to the existing `services` matrix job's
  `package` list (alphabetical, matching the existing entries).
- `bun install` at the repo root once both packages' `package.json`s
  exist, to link the new workspace members before their own
  `build`/`test` scripts run for the first time.

## Test plan (summary)

- **Gleam side**: `domain/streams`'s existing `gleam test --runtime bun`
  suite stays green except for Phase 1's own listed updates.
- **TypeScript side**: Phases 2–5 (database-repo through event-store)
  get real coverage against an in-memory PGLite instance for the first
  time in this codebase — no more fakes for anything this plan touches.
  Phases 6–7 (the two new packages) use plain object-literal fakes for
  their own narrow interfaces (`EventCreationBackend`), needing no
  database at all.
- **Not covered by any test in this plan**: `BunSqlClient.execStatement`
  against a real PostgreSQL server (still no live one available in this
  environment — same caveat the event-store plan already carries), and
  a full process-level smoke test of `event-collector-service` itself
  (spawn, HTTP round-trip, SIGTERM, exit).

## Step-by-step build order

1. Phase 1 (Gleam: `dml_codegen`/`dml_facade`) — get `domain/streams`
   fully green (including the updated `streams-bridge.ts` doc comment
   and test) before touching any TypeScript package.
2. Phase 2 (`database-repo`: `execStatement` + PGLite) — `bun add
   @electric-sql/pglite`, implement, get its own tests green against a
   real in-memory instance. This unblocks every later phase's testing
   strategy, so do it early even though nothing downstream strictly
   needs it before Phase 4.
3. Phase 3 (`database-repo`: admin-stats helpers) — independent of
   Phase 4/5, can happen in either order relative to them.
4. Phase 4 (`event-creation`) — depends on Phases 1 and 2.
5. Phase 5 (`event-store`) — depends on Phases 3 and 4.
6. Phase 6 (`http-event-creation`) — depends on Phase 5's exported
   types only; its own tests need none of the above actually working.
7. Phase 7 (`event-collector-service`) — depends on Phases 5 and 6.
8. Phase 8 (root/CI) — do alongside Phase 6, as soon as the first new
   package directory exists, per the event-store plan's own precedent
   of not saving tooling updates for the very end.
9. Full check: `bun run build:domain && bun run test:domain && bun run
   format:domain:check`, then `bun run build:services && bun run
   test:services`, then `bun run --cwd service build && bun run --cwd
   service test` — matching root `CLAUDE.md`'s CI expectations.

## Implementation notes (how this actually landed)

Written after building the plan above end to end — per
`documentation/plans/lang/migration-plan.md`'s own "Implementation
notes" precedent.

- **PGLite's actual API (version 0.5.8, installed and exercised for
  real) matches this plan's design exactly, no surprises.** Its
  `Results<T>` type is `{ rows, affectedRows?, command?, rowCount?,
  fields, blob? }` — confirmed by reading the package's own shipped
  `.d.ts`, not assumed — so `PGliteClient.execStatement`'s `{ rows:
  result.rows, affectedRows: result.affectedRows ?? result.rows.length
  }` needed no adjustment. `database-repo`'s own test suite
  (`test/pglite-client.test.ts`, `test/admin-stats.test.ts`) runs
  against real in-memory `PGlite` instances, not fakes, and this
  closes what this plan's own "Open questions" originally flagged as
  unverified PGLite `exec()`/`query()` behavior.
- **The aggregator-count division correction is verified against a
  real Postgres engine, not just arithmetic.**
  `event-creation/test/index.test.ts`'s "2 aggregators, no RETURNING, 3
  rows" test asserts both the corrected count (`3`) *and* the real
  row count actually sitting in `_pending_aggregations` afterward
  (`6`) — the exact discrepancy the correction exists to paper over,
  observed directly rather than inferred.
- **A real process-level smoke test was added after all**
  (`event-collector-service/test/smoke.test.ts`) — this plan's own
  "Open questions" originally expected this to stay unverified for the
  same "no environment to run a real deployable in" reason
  `event-store-implementation-plan.md` cited for its own equivalent
  gap. PGLite changed that calculus: the test spawns the actual
  `main.ts` against a real config file and a real (in-memory) database,
  hits `/api/events` and `/api/admin` over real HTTP, sends a real
  `SIGTERM`, and asserts a clean exit — no live Postgres or aggregator
  needed for any of it.
- **`event-creation` and `event-store`'s hand-rolled
  `fake-database-client.ts` files were deleted, not just left
  alongside new PGLite-based tests** — once every test in both
  packages could run against a real embedded database, the fakes had
  no remaining callers; keeping unreachable test fixtures around
  contradicts this codebase's own established discipline (see
  `documentation/plans/lang/migration-plan.md`'s `EmptyMigration`
  precedent, cited again here since it applies just as directly).
  `schema-migration`/`event-delivery`/`event-obsolescence`'s own fakes
  are untouched — those packages weren't modified by this plan, so
  their existing test strategy stays as-is; upgrading them to real
  PGLite too is a reasonable future pass, not done here.

## Open questions

- **Heterogeneous response array shape.** event-collectors.md's own
  wording ("a JSON array of the RETURNING result rows" vs. "a count")
  literally implies each array entry is either an array or a bare
  count — Phase 6 implements a `{"count": N}` object instead of a bare
  number for the non-`RETURNING` case, so every entry in the response
  array is at least uniformly *an object or array of objects*, never a
  bare number mixed in among arrays. Worth confirming this reading is
  acceptable, or whether the doc actually wants a bare number.
- **`Bun.SQL`'s exact `affectedRows`/`count` field name and behavior
  for `INSERT`/`INSERT ... RETURNING`/multi-row `INSERT`** is still
  asserted only from static analysis of the installed Bun 1.4 binary
  (`grep`-level confirmation that `SQLResultArray` carries both `count`
  and `affectedRows`, not part of its public `.d.ts`), not from running
  a real query against a real Postgres — there is still none available
  in this environment (unlike the PGLite side, this one couldn't be
  resolved the same way). Confirm against a real connection before
  trusting `BunSqlClient.execStatement` in production; Phase 2's
  fallback chain (`affectedRows ?? count ?? length`) is a hedge, not a
  verified answer, for this backend specifically.
