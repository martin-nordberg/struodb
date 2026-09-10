# Event Store — Implementation Plan

Implements `documentation/docs/specifications/architecture/event-stores.md`
(§2.2–§2.7) — the composite "event store" component shared by event
collectors and event aggregators, its two new bookkeeping tables, the
`Event Creation`/`Event Aggregation`/`Event Obsolescence` logic in §2.6,
and the software components in §2.4/§2.7. Read that spec first; this plan
covers concrete module layout, signatures, and build order, and resolves
a few points that were left ambiguous or informally sketched there (see
"Decisions carried over from discussion").

## Scope

**In scope**:
- `domain/shared`: a new `catalog.gleam` helper pair naming the two
  bookkeeping tables, and a new pure `hlc/clock.gleam` function for
  retention-cutoff encoding.
- `domain/schema`: `ddl_codegen.create_stream_to_sql` emitting the
  `_migration_history` and `_pending_aggregations` tables alongside a
  stream's own `CREATE TABLE`.
- `domain/streams`: `dml_codegen.generate` emitting the
  `_pending_aggregations` fan-out alongside a stream's `INSERT`, and the
  `dml_facade.apply_insert` signature change that requires.
- `service/src/bridges/streams-bridge.ts`: updated to match.
- A concrete JSON schema for Event Store Configuration (§2.5's `TODO`).
- New `services/*` Bun workspace packages implementing the software
  components in §2.4/§2.7: `database-repo`, `schema-migration`,
  `event-creation`, `aggregator-registration`, `event-delivery`,
  `event-obsolescence`, and the composite `event-store`.
- Root `package.json`/`mise.toml`/CI updates needed to build and test the
  above.

**Out of scope (deferred)**:
- Any real event-collector/event-aggregator deployable process — the
  `StruoQL Over HTTP` ingress (`event-collectors.md` §3.2) and
  `Collector Registration`'s server side (`event-aggregators.md` §4.4)
  that would actually host `event-store` in a running service. This plan
  builds the library, not the app that wraps it; that's a follow-up plan
  once `event-collectors.md`/`event-aggregators.md` are fleshed out past
  their current stub state.
- `domain/network`, `domain/projections` — untouched, still stubs.
- A PGLite-backed `database-repo` implementation (§2.3.1's other two
  "Yes" cells) — the interface is shaped to allow it (see Phase 6), but
  only a real-PostgreSQL-via-Bun-SQL implementation ships here.
- Node ID/cluster configuration, service discovery, TLS — `aggregator
  Registration`/`Event Delivery` talk plain HTTP to a configured base URL,
  nothing more.
- Migrating or retiring today's `service/` app — per the note added to
  `event-stores.md` §2.2, that app is throwaway scaffolding for
  TypeScript-calls-Gleam smoke testing, not something this plan builds on
  or needs to preserve.

## Decisions carried over from discussion

- **Table names live in one place.** `_struo_<stream>_migration_history`
  and `_struo_<stream>_pending_aggregations` are computed by two new
  `pub fn`s on `domain/shared/src/lang/catalog.gleam`
  (`migration_history_table_name`/`pending_aggregations_table_name`), the
  same package that already owns `hlc_column_name` etc. Both
  `ddl_codegen` (which creates the tables) and `dml_codegen` (which
  inserts into `pending_aggregations`) call these rather than
  interpolating the suffix themselves, so the two can never drift apart.
- **Per-stream aggregator lists, injected as a function — not a flat
  list.** §2.2's "INSERT transpilation needs to be passed ... a list of
  integer aggregator node IDs" doesn't account for one `source` batch
  touching several streams, each with its own aggregator set per §2.5.
  `dml_codegen.generate`/`dml_facade.apply_insert` instead take
  `aggregators_for_stream: fn(String) -> List(Int)`, mirroring the
  existing `next_hlc: fn() -> HlcParts` injection pattern exactly (same
  "only the bridge ever constructs this closure" rule).
- **Forwarded events cross the wire as structured rows, not generated
  SQL text.** §2.6.4's "the Event Delivery component calls the HTTP
  aggregation endpoint, passing the needed PostgreSQL SQL code" would
  have a collector's generated SQL executed verbatim by a peer's
  database — a real trust-boundary widening, and not actually usable
  as-is: `dml_facade.apply_insert`'s StruoQL grammar structurally
  forbids supplying the 5 system columns (dml-spec.md §5.1.4), but a
  forwarded event already has concrete, origin-assigned values for all
  5. `services/event-delivery` instead sends `{stream, rows: [{column:
  value, ...}]}` (every column including the 5 system ones, already
  resolved) and `services/database-repo` turns that into one
  parameterized bulk `INSERT ... VALUES ($1,$2,...),(...) ON CONFLICT DO
  NOTHING` on the receiving side — no SQL text crosses the wire, no
  StruoQL re-parsing happens, and a compromised/buggy collector can only
  ever cause row inserts, not arbitrary SQL. See Phase 6/10. (Worth
  folding back into `event-stores.md` §2.6.4's wording as a follow-up
  doc edit — not done as part of this plan.)
- **"A given number of aggregators" becomes a plain `threshold: number`
  config field**, 1 ≤ threshold ≤ that stream's aggregator count — see
  Phase 5. `event-stores.md` currently calls this a "quorum," which
  usually implies a majority; the config schema just calls it a
  threshold count to avoid that implication, without changing the
  semantics settled in the last review pass (delivery to `threshold`
  aggregators is sufficient for `Removed After Aggregation`/
  `Time-Limited` retention, and `ON DELETE CASCADE` is relied on to drop
  any other aggregators' still-pending rows at that point — a real,
  intentional trade-off, not a bug; see that section's own note 2).
- **Node ids are plain integers everywhere except as an HLC's own
  5-character subfield.** `EventStoreConfig.nodeId`, every
  `AggregatorConfig`/`StreamAggregatorConfig.nodeId`,
  `pending_aggregations.aggregator_node_id`, and `_struo_hlc_node_id`
  (already decoded, per ddl-spec.md §3.3.2) are all one plain,
  non-negative `Int`/`number` space — the same identity whether a node
  is acting as a collector (originating events, so its id ends up
  embedded in an HLC) or purely as an aggregator (its id only ever
  appears as a foreign lookup key, never HLC-encoded). The **only** place
  a node id is ever base-62 text is the last 5 characters of an actual
  encoded HLC value, which bounds the space: `0 <= node_id <= 62^5 - 1 =
  916_132_831`. `hlc/clock.gleam`'s own public contract (`start`/`new`
  taking a pre-formatted 5-character `String`, per hlc-spec.md §2.6) is
  **unchanged** — that parameter already *is* the literal subfield value
  every HLC this node produces will embed verbatim, so it stays a
  string at that one boundary. The translation from a config's plain
  integer to that 5-character string happens in exactly one place:
  `HlcClock.create`, which now takes a `number` and encodes it itself
  (`hlc/base62.gleam`'s already-public, general-purpose `encode`) before
  ever calling into `clock.new` — see Phase 2.
- **Retention deletes range-scan `_struo_hlc` directly.** Since
  `_struo_hlc`'s lexicographic order already equals time order
  (hlc-spec.md), a new pure `hlc/clock.threshold_for_time(physical_time_ms:
  Int) -> String` (same package, no actor/state involved) encodes a
  cutoff instant as a 15-character value with counter/node-id fields
  zeroed, so `services/event-obsolescence` can `DELETE ... WHERE
  _struo_hlc < $1` directly off the primary key — no decode step, no
  secondary index on `_struo_hlc_timestamp` needed.
- **`services/*` directories are kebab-case**, matching
  `service/src/bridges/schema-bridge.ts`'s existing convention —
  refining `event-stores.md` §2.7's literal `./services/schema_migration`
  paths (`snake_case`), which were never meant as a hard naming
  commitment (see that doc's own "Type: Shared Library" annotations,
  which settled *what* these are without settling *how they're spelled*).

## Target repository layout

```
domain/
  shared/src/lang/catalog.gleam         # + migration_history_table_name, pending_aggregations_table_name
  shared/src/hlc/clock.gleam            # + threshold_for_time
  schema/src/lang/ddl_codegen.gleam     # create_stream_to_sql emits 2 more CREATE TABLEs
  streams/src/lang/dml_codegen.gleam    # generate/insert_to_sql take aggregators_for_stream, emit CTE fan-out
  streams/src/dml_facade.gleam          # apply_insert signature grows aggregators_for_stream
services/
  database-repo/            # Bun SQL client: run generated SQL, structured bulk insert, migration-history + pending-aggregations + retention queries
  schema-migration/         # wraps ddl_facade.apply_migration + database-repo (§2.6.1)
  event-creation/           # wraps dml_facade.apply_insert + database-repo (§2.6.3)
  aggregator-registration/  # HTTP client + server for the registration handshake (§2.6.2, event-aggregators.md §4.4)
  event-delivery/           # queries + delivers + deletes pending_aggregations rows (§2.6.4)
  event-obsolescence/       # retention sweep (§2.6.5)
  event-store/              # composes the above; owns Event Store Configuration parsing + Application Initialization (§2.5, §2.6.2)
service/                    # unchanged — still the throwaway smoke-test app, not wired to services/*
package.json                # workspaces: ["service", "services/*"]
```

Each `services/*` package gets its own `package.json` (`private: true`,
`type: module`), `tsconfig.json` extending a shared root config, `src/`,
`test/` — the same shape `service/` already has, one level down. None of
them import compiled Gleam output directly except `schema-migration` and
`event-creation`, which take over that role from `service/`'s bridges for
their own two facades (see "Facades and the TypeScript boundary" in root
`CLAUDE.md` — the "only these files may import `domain/*/build/...`"
rule now applies per-package rather than only inside `service/`).

## Phase 1 — `catalog.gleam`: table-name helpers

```gleam
/// "_struo_<stream>_migration_history" — the append-only record of
/// applied CREATE/ALTER STREAM statement hashes for `stream` (see
/// `documentation/plans/lang/migration-plan.md`'s `migration_hashes`
/// field; this is where that list is meant to be persisted between
/// process restarts). Schema: `seq INTEGER PRIMARY KEY, hash CHAR(64)
/// NOT NULL`, read back `ORDER BY seq`.
pub fn migration_history_table_name(stream: String) -> String {
  "_struo_" <> stream <> "_migration_history"
}

/// "_struo_<stream>_pending_aggregations" — one row per (event,
/// aggregator) combination not yet delivered. Schema:
/// `aggregator_node_id INTEGER NOT NULL, event_hlc CHAR(15) NOT NULL
/// REFERENCES <stream>(_struo_hlc) ON DELETE CASCADE, PRIMARY KEY
/// (aggregator_node_id, event_hlc)` — that column order (not
/// `event_hlc` first) is deliberate: `services/event-delivery`'s access
/// pattern is always "pending rows for aggregator X, oldest first," and
/// the primary key's own index already serves that directly.
pub fn pending_aggregations_table_name(stream: String) -> String {
  "_struo_" <> stream <> "_pending_aggregations"
}
```

Both are pure string functions — no `Catalog` needed, since the name is a
deterministic function of the stream name alone. `ddl_semantics.gleam`'s
existing reserved-namespace check (no user-declared name may start with
`_struo_`, case-insensitively) already guarantees these can never collide
with a real column/constraint/stream name; no new check needed here.

**Test**: `domain/shared/test/lang/catalog_test.gleam` — both functions
against a plain name and one that itself needed quoting (mixed case,
reserved-word-adjacent) to confirm the suffix concatenation happens on
the *unquoted* stream name, before either codegen module quotes the
result.

## Phase 2 — `hlc/clock.gleam`/`hlc-clock.ts`: `threshold_for_time` and integer node ids

### `threshold_for_time`

```gleam
/// A synthetic HLC value for `physical_time_ms` with counter and node id
/// both zeroed — not a real clock reading, never returned by `next`/
/// `next_parts`/`merge`. Exists purely so a caller can range-compare it
/// against real `_struo_hlc` values: every real HLC recorded at or after
/// `physical_time_ms` sorts >= this value (its counter/node-id fields
/// are never negative), and every one strictly before it sorts <.
/// `services/event-obsolescence` uses this to express "delete events
/// older than T" as `WHERE _struo_hlc < threshold_for_time(t)` directly
/// on the primary key, with no decode step and no secondary index.
pub fn threshold_for_time(physical_time_ms: Int) -> String {
  let assert Ok(time_part) = base62.encode(physical_time_ms, time_width)
  time_part <> "00" <> "00000"
}
```

Pure, no `ClockState` involved — lives beside `encode_value` (which it
duplicates the shape of, deliberately not sharing code with, since
`encode_value` is keyed to a live clock's counter/node-id state and this
isn't). Exported from `HlcClock`'s TypeScript wrapper (`hlc-clock.ts`) as
a `static` method, since it needs no instance:

```ts
// @ts-expect-error — no .d.ts for compiled Gleam output.
import { threshold_for_time as clockThresholdForTime } from "../../domain/shared/build/dev/javascript/shared/hlc/clock.mjs";
// ...
static thresholdForTime(physicalTimeMs: number): string {
  return clockThresholdForTime(physicalTimeMs) as string;
}
```

**Test**: `clock_test.gleam` — `threshold_for_time(t)` is exactly 15
characters; a real `next()` value drawn at the same millisecond sorts
`>=` it; a real value from the previous millisecond sorts `<` it.

### Integer node ids at the `HlcClock` boundary

`hlc/clock.gleam`'s `start`/`new` itself is untouched — it still takes a
pre-formatted 5-character `String` (hlc-spec.md §2.6), since that
parameter already *is* the literal node-id subfield every HLC this
clock produces will embed. What changes is `HlcClock.create`
(`service/src/hlc-clock.ts`), the one place a config-supplied plain
integer becomes that string, using `hlc/base62.gleam`'s existing public
`encode` (already general-purpose, already used exactly this way inside
`clock.gleam` itself for the other two fields):

```ts
// @ts-expect-error — no .d.ts for compiled Gleam output.
import { encode as base62Encode } from "../../domain/shared/build/dev/javascript/shared/hlc/base62.mjs";

/** Largest node id that fits in the HLC's 5-character base-62 field
 *  (62^5 - 1) — see hlc-spec.md §2.2's field table. Every node id
 *  outside an actual encoded HLC value (Event Store Configuration,
 *  `aggregator_node_id`, decoded `_struo_hlc_node_id`) is a plain
 *  integer bounded by this; `base62.encode` below is what actually
 *  enforces it — this constant exists so callers like Phase 6's config
 *  validator can fail fast with a friendly message instead of an
 *  encode-time one. */
export const MAX_NODE_ID = 916_132_831; // 62^5 - 1, node_id_width = 5

export class HlcClock {
  // ...
  static create(nodeId: number, now: () => number = Date.now): HlcClock {
    const encoded = base62Encode(nodeId, 5) as Result<string, unknown>;
    if (!encoded.isOk()) {
      throw new Error(describeBase62Error(encoded[0]));
    }
    const result = clockNew(encoded[0], now) as Result<ClockState, unknown>;
    if (!result.isOk()) {
      throw new Error(describeHlcError(result[0]));
    }
    return new HlcClock(result[0]);
  }
  // ...
}
```

(`describeBase62Error` is a new small sibling of the existing
`describeHlcError`, covering `base62.Base62Error`'s
`NegativeValue`/`InsufficientWidth` variants — the two `encode` can
actually return for a 5-character width; `InvalidCharacter`/
`InvalidWidth` are unreachable here since `nodeId` is a number, not
caller-supplied text, and the width is the literal constant `5`.)

`service/src/main.ts`'s `nodeId()` — the one existing caller of
`HlcClock.create` — changes from returning a string (`Bun.env
.STRUODB_NODE_ID ?? "node1"`) to parsing an integer (`Number(Bun.env
.STRUODB_NODE_ID ?? "1")`); a one-line follow-on edit, not because
`service/` itself is in scope (it isn't — see "Scope"), but because this
signature change would otherwise leave it failing to build.

**Test** (`hlc-clock.test.ts`): `HlcClock.create(0)` and
`HlcClock.create(MAX_NODE_ID)` both succeed (the two ends of the valid
range); `HlcClock.create(MAX_NODE_ID + 1)` and `HlcClock.create(-1)`
both throw, mirroring `base62_test.gleam`'s existing
`InsufficientWidth`/`NegativeValue` coverage one level up.

## Phase 3 — `ddl_codegen.gleam`: emit the two bookkeeping tables

`create_stream_to_sql` currently renders one `CREATE TABLE`. It grows to
three statements, joined the same way `render_all` joins multiple
top-level statements:

```gleam
pub fn create_stream_to_sql(stmt: ast.DdlStatement) -> String {
  let assert ast.CreateStream(name:, ..) = stmt

  [
    main_table_sql(stmt),
    migration_history_table_sql(name),
    pending_aggregations_table_sql(name),
  ]
  |> string.join("\n\n")
}

fn main_table_sql(stmt: ast.DdlStatement) -> String {
  // exactly today's create_stream_to_sql body, unchanged
}

fn migration_history_table_sql(stream: String) -> String {
  "CREATE TABLE "
  <> expr_codegen.quote_identifier(catalog.migration_history_table_name(stream))
  <> " (\n  seq INTEGER NOT NULL PRIMARY KEY,\n  hash CHAR(64) NOT NULL\n);"
}

fn pending_aggregations_table_sql(stream: String) -> String {
  "CREATE TABLE "
  <> expr_codegen.quote_identifier(catalog.pending_aggregations_table_name(stream))
  <> " (\n"
  <> "  aggregator_node_id INTEGER NOT NULL,\n"
  <> "  event_hlc "
  <> expr_codegen.data_type_to_sql(xast.DtChar(Some(15)))
  <> " NOT NULL REFERENCES "
  <> expr_codegen.quote_identifier(stream)
  <> "(" <> expr_codegen.quote_identifier(catalog.hlc_column_name) <> ")"
  <> " ON DELETE CASCADE,\n"
  <> "  PRIMARY KEY (aggregator_node_id, event_hlc)\n);"
}
```

No change to `alter_stream_to_sql` — `ALTER STREAM` never touches either
bookkeeping table. No change to `ddl_semantics.gleam`/`catalog.gleam`'s
`StreamSchema` beyond Phase 1's two name functions — the bookkeeping
tables aren't part of a stream's *declared shape* (no column/constraint
tracking needed for them), only its transpiled output.

**Test** (`ddl_codegen_test.gleam`): a `CREATE STREAM` render now
contains all 3 `CREATE TABLE`s in order, the migration-history and
pending-aggregations tables' SQL matches the literal shape above for a
representative stream name, and a stream name needing quoting produces
correctly-quoted derived table names in all three statements.

## Phase 4 — `dml_codegen.gleam`: pending-aggregations fan-out

### Signature change

```gleam
pub fn generate(
  catalog: Catalog,
  source: String,
  next_hlc: fn() -> clock.HlcParts,
  aggregators_for_stream: fn(String) -> List(Int),
) -> Result(#(String, Catalog), CodegenError)
```

`generate_standalone` gains the same parameter, passed straight through.
`render_all`/`insert_to_sql` thread it down to each statement.

### Rendered shape

For a stream with **no** aggregators configured
(`aggregators_for_stream(stream) == []`), rendering is unchanged from
today — a flat `INSERT ... VALUES ... [ON CONFLICT DO NOTHING]
[RETURNING ...];`. This keeps the common "terminal aggregator, nobody
above it" case exactly as cheap as it is today.

For a stream **with** aggregators, the statement becomes a `WITH`
pipeline. The inner insert always does `RETURNING *` (never the
caller's own `RETURNING` list directly) so every later stage has every
column, including `_struo_hlc`, available; the caller's actual requested
output (`*`, an expression list, or nothing) is computed by the outermost
piece instead. A data-modifying CTE that nothing references (`pending`
below) still always executes in PostgreSQL — this is documented
Postgres behavior, not a trick — so it reliably fires even when there's
no user `RETURNING` to build a final `SELECT` around:

```sql
-- No RETURNING clause on the original INSERT:
WITH ins AS (
  INSERT INTO "sensor_reading" (_struo_hlc, _struo_hlc_timestamp, _struo_hlc_count, _struo_hlc_node_id, reading, units)
  VALUES ('...', to_timestamp(...), 0, 7, 42.5, 'celsius')
  ON CONFLICT DO NOTHING
  RETURNING *
)
INSERT INTO "_struo_sensor_reading_pending_aggregations" (aggregator_node_id, event_hlc)
SELECT a.aggregator_node_id, ins._struo_hlc
FROM ins CROSS JOIN unnest(ARRAY[7, 12]) AS a(aggregator_node_id);

-- With `RETURNING _struo_hlc`:
WITH ins AS (
  INSERT INTO "sensor_reading" (...) VALUES (...) ON CONFLICT DO NOTHING RETURNING *
), pending AS (
  INSERT INTO "_struo_sensor_reading_pending_aggregations" (aggregator_node_id, event_hlc)
  SELECT a.aggregator_node_id, ins._struo_hlc
  FROM ins CROSS JOIN unnest(ARRAY[7, 12]) AS a(aggregator_node_id)
)
SELECT ins._struo_hlc FROM ins;
```

This keeps the caller-visible result set at exactly one row per row
actually inserted (unaffected by however many aggregators it fans out
to), correctly drops a row skipped by `ON CONFLICT DO NOTHING` from the
fan-out too (it's simply absent from `ins`, so `CROSS JOIN` produces
nothing for it), and needs no new grammar — `dml_ast.gleam`/`dml_parser
.gleam`/`dml_semantics.gleam` are untouched; this is pure `dml_codegen`
rendering.

`unnest(ARRAY[...])` is built directly from `aggregators_for_stream(stream_name)`
(each `Int` rendered as an integer literal) at codegen time, once per
statement — not parameterized, since these come from this node's own
static configuration, never client input.

**Test plan** (`dml_codegen_test.gleam`):
- A stream with `aggregators_for_stream` returning `[]` renders exactly
  today's flat SQL — regression guard that the common path didn't grow
  overhead.
- A stream with 2 aggregator ids renders the no-`RETURNING` `WITH` shape
  above, byte-for-byte against a fixture.
- The same, with `RETURNING _struo_hlc`, renders the second shape above.
- The same, with `RETURNING *`, renders `SELECT * FROM ins` as the final
  statement.
- Multiple `VALUES` rows in one `INSERT`, with 2 aggregators, renders a
  fan-out whose `unnest` cross join is per-row (i.e. the shape scales,
  not a hand-checked SQL diff — assert row-count expectations via a
  real Postgres in the `service`-level integration test instead; see
  Phase 8).
- Two statements in one `source` targeting different streams get
  independent `aggregators_for_stream` lookups and independent fan-outs.

## Phase 5 — Facade + bridge updates

`dml_facade.apply_insert` gains the same parameter, passed straight to
`dml_codegen.generate`:

```gleam
pub fn apply_insert(
  catalog: Catalog,
  source: String,
  next_hlc: fn() -> HlcParts,
  aggregators_for_stream: fn(String) -> List(Int),
) -> String
```

`streams-bridge.ts`:

```ts
export function applyInsert(
  clock: HlcClock,
  catalog: CatalogHandle,
  source: string,
  aggregatorNodeIdsForStream: (stream: string) => number[],
): string {
  return streamsFacade.apply_insert(
    catalog,
    source,
    () => clock.nextParts(),
    aggregatorNodeIdsForStream,
  );
}
```

`services/event-creation` (Phase 8) is the one real caller that supplies
a non-trivial `aggregatorNodeIdsForStream`, built from Event Store
Configuration (Phase 6). `service/`'s own throwaway `main.ts` passes
`() => []` — no aggregators configured for its ad hoc smoke-test streams
— rather than growing config-reading logic of its own, consistent with
that app being out of scope for real use.

`ddl_facade`/`schema-bridge.ts` are unchanged — nothing about the
bookkeeping tables needs new facade surface; they ride along inside
`ddl_codegen`'s existing output.

## Phase 6 — Event Store Configuration: JSON schema

Resolves §2.5's `TODO`. Lives as TypeScript types + a runtime validator
in a new `services/event-store/src/config.ts`, since it's consumed only
by `event-store` (Phase 12) and the packages it composes take already-
parsed values (a `DatabaseClient`, plain strings/numbers), not the raw
config object.

```ts
export interface EventStoreConfig {
  databaseUrl: string;
  /** This node's own identity — plain integer, `0 <= nodeId <=
   *  HlcClock.MAX_NODE_ID` (Phase 2). Fed to `HlcClock.create` as-is;
   *  never base-62 text at this layer. */
  nodeId: number;
  streams: Record<string, StreamConfig>;
  aggregators: Record<string, AggregatorConfig>; // keyed by node id, string-typed (JSON object keys)
}

export interface StreamConfig {
  /** Full CREATE STREAM + ALTER STREAM history, in order, one string —
   *  exactly `schema-migration`'s `source` input (Phase 7). */
  migration: string;
  aggregators: StreamAggregatorConfig[];
}

export interface StreamAggregatorConfig {
  /** Same bounded integer space as `EventStoreConfig.nodeId` — this is
   *  the *other* node's identity, one it would itself pass to its own
   *  `HlcClock.create` were it acting as a collector. */
  nodeId: number;
  aggregationStrategy: AggregationStrategy;
  retentionStrategy: RetentionStrategy;
}

export type AggregationStrategy =
  | { kind: "sentImmediately" }
  | { kind: "batchBySize"; size: number }
  | { kind: "batchByTime"; intervalMs: number }
  | { kind: "sharedDatabase" };

export type RetentionStrategy =
  | { kind: "indefinite" }
  | { kind: "removedAfterAggregation"; threshold: number }
  | { kind: "timeLimited"; threshold: number; intervalMs: number };

export interface AggregatorConfig {
  baseUrl: string;
}
```

`threshold` is validated (Phase 6's `parseConfig`) to be `>= 1` and `<=`
that stream's own `aggregators.length` — the concrete form of "Decisions
carried over from discussion"'s threshold-count point. Every `nodeId`
field above (`EventStoreConfig.nodeId`, each `StreamAggregatorConfig
.nodeId`, and each key of `aggregators`) is likewise validated to be a
non-negative integer `<= HlcClock.MAX_NODE_ID` (Phase 2), and every
`StreamAggregatorConfig.nodeId` must have a matching entry in the
top-level `aggregators` map — both checked here, before `event-store`
(Phase 13) ever calls `HlcClock.create` or opens a database connection.
`sharedDatabase`
carries no extra fields (§2.3.3's "not sent" variant needs no HTTP
config at all — `event-delivery`, Phase 10, treats it as a no-op
strategy, and pending-aggregation rows for that aggregator id are never
even created, i.e. `aggregators_for_stream` for `event-creation`, Phase
8, excludes any aggregator whose strategy is `sharedDatabase`).

`parseConfig(json: unknown): EventStoreConfig` does full structural
validation (required fields, `nodeId`s are non-negative integers,
`aggregators` referenced by any `StreamAggregatorConfig.nodeId` actually
exist in the top-level `aggregators` map, threshold bounds above) and
throws a single descriptive error listing every problem found — not
fail-fast on the first one, since this runs once at startup against a
config file a human edits by hand.

**Test** (`services/event-store/test/config.test.ts`): valid config
round-trips; each validation rule above has a dedicated failing-input
test; multiple simultaneous errors are all listed in one thrown message.

## Phase 7 — `services/database-repo`

The one package that actually talks to PostgreSQL. Everything else calls
it; it depends on nothing else in `services/*`.

```ts
export interface DatabaseClient {
  /** Executes arbitrary generated DDL/DML SQL text (from ddl_codegen/
   *  dml_codegen output) with no return value expected. */
  exec(sql: string): Promise<void>;

  /** Runs `sql` and returns rows as plain objects (column name -> value)
   *  — used for RETURNING output and for reading pending-aggregation /
   *  migration-history rows back. */
  query<Row extends Record<string, unknown>>(
    sql: string,
    params?: unknown[],
  ): Promise<Row[]>;

  /** Parameterized bulk insert of already-resolved rows (every column,
   *  including the 5 system ones) into `stream`, `ON CONFLICT DO
   *  NOTHING`, fanning out into that stream's pending_aggregations table
   *  for `aggregatorNodeIds` exactly like dml_codegen's own CTE shape
   *  (Phase 4) — the TypeScript-side equivalent for events arriving
   *  already HLC-stamped from a peer, which never go through StruoQL/
   *  dml_facade at all. See "Decisions carried over from discussion." */
  insertForwardedEvents(
    stream: string,
    rows: Record<string, unknown>[],
    aggregatorNodeIds: number[],
  ): Promise<void>;

  close(): Promise<void>;
}

export function connect(databaseUrl: string): DatabaseClient; // Bun SQL-backed
```

`connect` wraps Bun's built-in `Bun.sql` (tagged-template Postgres
client) behind this interface — callers never see `Bun.sql` directly, so
a PGLite-backed `connect` variant (deferred, see "Scope") can be added
later as a second implementation of the same `DatabaseClient` interface
with no change to any caller.

`insertForwardedEvents`'s generated SQL mirrors Phase 4's shape exactly,
built here in plain TypeScript string-building (parameterized — column
values are bind parameters, `$1`/`$2`/..., never interpolated) since
there's no StruoQL to parse on this path — only already-typed JSON
values to place. Column names (from `Object.keys(rows[0])`) are
identifier-quoted the same way `expr_codegen.quote_identifier` would,
via a small local `quoteIdentifier` matching its content-based rule
(ddl-spec.md §2.2) — not re-derived from scratch; port the same
predicate rather than approximate it.

**Test** (`services/database-repo/test/`, against a real ephemeral
Postgres — e.g. a `pg-mem`/testcontainer instance, or a `docker compose`
Postgres already used the same way any future `service` integration
test would need): `exec` runs a `CREATE TABLE`; `query` reads back
`RETURNING` output; `insertForwardedEvents` populates both the stream
table and its `pending_aggregations` table correctly, including the
`ON CONFLICT DO NOTHING` skip case.

## Phase 8 — `services/schema-migration`

Implements §2.6.1 directly, wrapping `ddl_facade.apply_migration`
(already implemented — see `documentation/plans/lang/migration-plan.md`)
and `database-repo`.

```ts
export async function migrateStream(
  db: DatabaseClient,
  catalog: CatalogHandle,
  stream: string,
  source: string,
): Promise<CatalogHandle> {
  const historyTable = migrationHistoryTableName(stream); // Phase 1's Gleam helper, or a small TS port — see note below
  const previousHashes = (
    await db.query<{ hash: string }>(
      `SELECT hash FROM "${historyTable}" ORDER BY seq`,
    )
  ).map((r) => r.hash);

  const [resultJson, updatedCatalog] = applyMigration(catalog, stream, previousHashes, source);
  const result = JSON.parse(resultJson);
  if (!result.ok) throw new SchemaMigrationError(result); // kind: hash_mismatch | language_error | structural_error

  if (result.sql !== "") {
    await db.exec(result.sql); // creates the stream on first call; ALTERs on later ones
    const startSeq = previousHashes.length;
    for (const [i, hash] of result.hashes.entries()) {
      await db.exec(
        `INSERT INTO "${historyTable}" (seq, hash) VALUES ($1, $2)`,
        // (illustrative — real call goes through db.query/exec's param form)
      );
    }
  }
  return updatedCatalog;
}
```

Reads `migration_history_table_name` back out via a small TypeScript
port of Phase 1's Gleam function (identical one-liner) rather than a
Gleam call for a plain string computation — matching how `catalog.gleam`
already exposes plain `pub const` names that TypeScript could just as
well hardcode, except this one is a function of `stream`; keeping both
in sync is a one-line diff on the rare occasion the naming scheme
changes, called out explicitly in a comment referencing Phase 1's
Gleam source as the definition of record.

Note: on the very first call for a stream (`previousHashes: []`),
`historyTable` doesn't exist yet to query — `migrateStream` must special-
case "table not found" as "no previous hashes" (or check
`pg_catalog`/`information_schema` first), since `result.sql` for that
first call is exactly what creates `historyTable` in the first place
(Phase 3's `create_stream_to_sql` emits it alongside the stream's main
table). Handled via a `SELECT to_regclass($1)` existence check before
the `SELECT hash FROM ...` query, not a try/catch around a query that's
expected to usually fail.

**Test**: fresh stream (no history table yet) creates all 3 tables and
records hashes; a second call with an `ALTER STREAM` appended only runs
the new statement and appends one hash; a tampered `source` (hash
mismatch) throws without touching the database. Run against the same
ephemeral-Postgres setup as Phase 7.

## Phase 9 — `services/event-creation`

Implements §2.6.3.

```ts
export async function createEvents(
  db: DatabaseClient,
  clock: HlcClock,
  catalog: CatalogHandle,
  source: string,
  aggregatorNodeIdsForStream: (stream: string) => number[],
): Promise<void> {
  const resultJson = applyInsert(clock, catalog, source, aggregatorNodeIdsForStream);
  const result = JSON.parse(resultJson);
  if (!result.ok) throw new EventCreationError(result.error);
  await db.exec(result.sql);
}
```

`aggregatorNodeIdsForStream` here is built by `services/event-store`
(Phase 12) from `StreamConfig.aggregators`, excluding any entry whose
`aggregationStrategy.kind === "sharedDatabase"` (Phase 6's note).

**Test**: an `INSERT` against a stream with 2 aggregators populates both
the stream table and its pending-aggregations table with the right row
counts; a stream with none behaves exactly like today's plain insert; a
semantic error (unknown column, etc.) throws without touching the
database.

## Phase 10 — `services/aggregator-registration`

Implements the collector-side half of §2.6.2 ("calls Aggregator
Registration to register ... and retrieve the aggregator's schema") and
the aggregator-side server described in `event-aggregators.md` §4.4
("Collector Registration ... returns the aggregator's schema migration
script").

```ts
// Collector side
export async function registerWithAggregator(
  aggregator: AggregatorConfig,
  stream: string,
): Promise<{ migration: string }> {
  const res = await fetch(`${aggregator.baseUrl}/streams/${stream}/register`, { method: "POST" });
  if (!res.ok) throw new AggregatorRegistrationError(res.status, await res.text());
  return res.json();
}

// Aggregator side — a plain Bun.serve handler, composed into event-store's
// own server (Phase 12), not a package that listens on its own port.
export function handleRegister(catalog: CatalogHandle, stream: string): { migration: string } {
  // reads this aggregator's own recorded migration source for `stream`
  // (config-supplied, same StreamConfig.migration shape) and returns it
  // verbatim — the collector then runs it through its own
  // services/schema-migration (Phase 8) against its local database.
}
```

**Test**: `registerWithAggregator` against a local `Bun.serve` test
server returns the expected shape and surfaces a non-2xx response as a
typed error.

## Phase 11 — `services/event-delivery`

Implements §2.6.4.

```ts
export async function deliverPending(
  db: DatabaseClient,
  aggregatorNodeId: number,
  aggregator: AggregatorConfig,
  stream: string,
  batchSize: number, // 0/undefined = no limit — used by batch-by-size strategies
): Promise<number> { // returns rows delivered
  const pendingTable = pendingAggregationsTableName(stream); // Phase 1's helper, TS-ported per Phase 8's note
  const rows = await db.query<{ event_hlc: string }>(
    `SELECT * FROM "${stream}"
     WHERE _struo_hlc IN (
       SELECT event_hlc FROM "${pendingTable}" WHERE aggregator_node_id = $1
       ORDER BY event_hlc LIMIT $2
     )`,
    // params: [aggregatorNodeId, batchSize || null]
  );
  if (rows.length === 0) return 0;

  const res = await fetch(`${aggregator.baseUrl}/streams/${stream}/events`, {
    method: "POST",
    body: JSON.stringify({ rows }),
  });
  if (!res.ok) throw new EventDeliveryError(res.status, await res.text());

  await db.exec(
    `DELETE FROM "${pendingTable}" WHERE aggregator_node_id = $1 AND event_hlc = ANY($2)`,
    // params: [aggregatorNodeId, rows.map(r => r.event_hlc)]
  );
  return rows.length;
}

// Aggregator side, composed into event-store's server (Phase 12):
export async function handleIncomingEvents(
  db: DatabaseClient,
  stream: string,
  rows: Record<string, unknown>[],
  aggregatorNodeIdsForStream: (stream: string) => number[], // this aggregator's own downstream fan-out, if it forwards further
): Promise<void> {
  await db.insertForwardedEvents(stream, rows, aggregatorNodeIdsForStream(stream));
}
```

The `pending_aggregations`-then-`stream` two-step query (rather than a
single join) keeps the `ORDER BY event_hlc LIMIT` on the primary key's
own index (Phase 1's column order); the `IN (...)` against `_struo_hlc`
then does one indexed lookup per selected row on the stream table's own
primary key.

**Test**: a batch of 3 pending rows for one aggregator delivers, then
the pending rows (only that aggregator's) are gone while the stream
table's own rows remain; `batchSize` caps how many are selected per
call; a failed HTTP delivery leaves pending rows untouched (no partial
delete on failure — delete only runs after a successful response);
`handleIncomingEvents` on the aggregator side correctly creates further
pending rows if that aggregator itself forwards on.

## Phase 12 — `services/event-obsolescence`

Implements §2.6.5, using Phase 2's `HlcClock.thresholdForTime`.

```ts
export async function sweepStream(
  db: DatabaseClient,
  stream: string,
  strategy: RetentionStrategy,
): Promise<number> { // rows deleted
  switch (strategy.kind) {
    case "indefinite":
      return 0;
    case "removedAfterAggregation":
    case "timeLimited": {
      const pendingTable = pendingAggregationsTableName(stream);
      // "delivered to >= threshold aggregators" == "fewer than
      // (total configured for this stream - threshold) pending rows
      // remain" — computed by the caller (event-store, which knows the
      // stream's full aggregator count) and passed as maxRemainingPending.
      ...
      if (strategy.kind === "timeLimited") {
        const cutoff = HlcClock.thresholdForTime(Date.now() - strategy.intervalMs);
        // AND _struo_created_at < to_timestamp(...) per event-stores.md's
        // note that this strategy means _struo_created_at, not
        // _struo_hlc_timestamp — both conditions combined in one DELETE.
      }
      return deletedCount;
    }
  }
}
```

**Test**: `removedAfterAggregation` with `threshold` less than the
stream's aggregator count deletes an event once enough (not necessarily
all) pending rows are gone, and — via `ON DELETE CASCADE` — the
remaining pending rows for slower aggregators disappear with it (a
direct test of the documented trade-off, not just the happy path);
`timeLimited` additionally respects `_struo_created_at`, confirmed with
a row whose `_struo_hlc` is old but `_struo_created_at` is recent (or
vice versa) via `HlcClock`'s injectable `now`.

## Phase 13 — `services/event-store`

The composite (§2.7.7/§2.7.8). Owns config parsing (Phase 6) and
Application Initialization (§2.6.2):

```ts
export async function start(configJson: unknown): Promise<EventStore> {
  const config = parseConfig(configJson);
  const db = connect(config.databaseUrl);
  const clock = HlcClock.create(config.nodeId); // Phase 2 encodes this to the HLC's 5-character field internally
  let catalog = emptyCatalog();

  for (const [stream, streamConfig] of Object.entries(config.streams)) {
    catalog = await migrateStream(db, catalog, stream, streamConfig.migration);
    for (const agg of streamConfig.aggregators) {
      if (agg.aggregationStrategy.kind === "sharedDatabase") continue;
      const aggregatorConfig = config.aggregators[String(agg.nodeId)];
      const { migration } = await registerWithAggregator(aggregatorConfig, stream);
      catalog = await migrateStream(db, catalog, stream, migration);
    }
  }

  return new EventStore(db, clock, catalog, config);
}
```

`EventStore` also owns the two background loops:
- **Aggregation loop** — per `StreamAggregatorConfig.aggregationStrategy`:
  a `setInterval`-driven `deliverPending` call for `batchByTime`, a
  post-insert size check for `batchBySize` (checked right after
  `event-creation`'s `createEvents` call touches that stream), immediate
  `deliverPending` for `sentImmediately`.
- **Obsolescence loop** — a fixed-interval `sweepStream` call per
  stream/retention-strategy pair, per §2.6.5's "at some fixed interval."

`EventStore.createEvents(source: string)` is the one method application
code calls per incoming `INSERT`; it's the thing a future `event-
collectors.md` HTTP ingress (out of scope here) would call per request.

**Test**: `start()` against a config with one stream and no aggregators
initializes correctly with an empty pending-aggregations table; a config
naming an aggregator not present in `config.aggregators` is rejected by
Phase 6's validator before `start()` ever opens a database connection;
an end-to-end test (real ephemeral Postgres, two `EventStore` instances
in-process standing in for a collector and its aggregator) drives one
`createEvents` call through registration, delivery, and obsolescence.

## Phase 14 — Root workspace/tooling

- `package.json`: `"workspaces": ["service", "services/*"]`.
- Each `services/*/package.json` gets `build`/`test` scripts matching
  `service/`'s (`prebuild`/`pretest` running `bun run --cwd .. build:
  domain` for `schema-migration`/`event-creation`, which import compiled
  Gleam output; the others don't need it).
- `.github/workflows/test.yml`: extend the existing matrix (or add jobs)
  to build/test every `services/*` package the same way the `service`
  job already does, per root `CLAUDE.md`'s "match that before considering
  work done."
- `mise.toml`: unchanged (still Bun 1.4, Gleam 1.18 — nothing here needs
  a new tool).

## Test plan (summary)

Per-phase test plans above cover unit-level behavior. Two additional
cross-cutting suites:

- **Gleam side**: `domain/shared`, `domain/schema`, `domain/streams`'s
  existing `gleam test --runtime bun` suites all still pass unchanged
  except where a phase explicitly extends one (Phases 1–4).
- **Integration**: one real-Postgres-backed suite (Phase 13's end-to-end
  test) exercising the full chain — `CREATE STREAM` migration, `INSERT`
  with aggregator fan-out, delivery to a second in-process `EventStore`
  standing in for an aggregator, and a retention sweep — since no
  individual phase's unit tests alone confirm the pieces compose
  correctly. This is the one place a real Postgres instance (Bun SQL
  against a local/CI-provisioned database, or a container) is required;
  every earlier phase's own tests can use the same instance rather than
  standing up N separate ones.

## Step-by-step build order

1. Phase 1 (`catalog.gleam` helpers) — no dependents yet, gets its own
   tests green first.
2. Phase 2 (`threshold_for_time`) — independent of Phase 1, can happen
   in parallel.
3. Phase 3 (`ddl_codegen`) — depends on Phase 1.
4. Phase 4 (`dml_codegen`) — depends on Phase 1; independent of Phase 3.
5. Phase 5 (facades/bridges) — depends on Phase 4.
6. `bun run build:domain && bun run test:domain && bun run --cwd service
   build && bun run --cwd service test` — confirm the Gleam/bridge side
   is fully green before starting any `services/*` package, matching the
   root `CLAUDE.md`'s CI expectations.
7. Phase 6 (config schema) — no dependencies on the above, can start
   anytime; useful to have early since Phases 8–13 all reference its
   types.
8. Phase 7 (`database-repo`) — depends on nothing else in `services/*`.
9. Phases 8 and 9 (`schema-migration`, `event-creation`) — each depends
   on Phase 7 plus Phase 5's facade signatures; independent of each
   other.
10. Phase 10 (`aggregator-registration`) — depends on Phase 6.
11. Phase 11 (`event-delivery`) — depends on Phases 6, 7.
12. Phase 12 (`event-obsolescence`) — depends on Phases 2, 6, 7.
13. Phase 13 (`event-store`) — depends on everything above.
14. Phase 14 (root tooling/CI) — do this alongside Phase 7 (as soon as
    the first `services/*` package exists, so CI covers it from the
    start) rather than saving it for the end.

## Open questions

- **Should the node-id bound be enforced in the database too?**
  `pending_aggregations.aggregator_node_id` and `_struo_hlc_node_id` are
  both plain `INTEGER` (32-bit, far wider than `MAX_NODE_ID` needs), and
  today's plan enforces the `0..=916_132_831` bound only in application
  code (Phase 2's `HlcClock.create`, Phase 6's config validator) — a
  value outside that range can only ever get there via a config bug, not
  a live HLC read/write, since `HlcClock.create` fails fast at startup.
  A `CHECK (aggregator_node_id BETWEEN 0 AND 916132831)` on the
  `pending_aggregations` table (Phase 3) would catch a config bug that
  slipped past `parseConfig` somehow, at the cost of one more constant
  to keep in sync in a second language (SQL) if the field width ever
  changed. Leaning toward skipping it (the width hasn't changed since
  hlc-spec.md was written, and won't without a spec revision), but
  worth a second look during Phase 3.
- **`services/schema-migration`/`event-creation` importing compiled
  Gleam output from separate packages.** Root `CLAUDE.md`'s "only
  `service/src/bridges/*` may import `domain/*/build/...` directly" rule
  needs an explicit update once these two packages exist — noted here,
  not fixed, since it's a documentation change contingent on this plan
  actually landing.
- **Batch-by-size fan-in.** Phase 13 sketches a "check after every
  `createEvents` call" trigger for `batchBySize`, but doesn't define
  where the size threshold is actually tracked (a `SELECT count(*)` per
  insert would work but adds a query to every hot-path insert). Worth
  benchmarking against a maintained counter (in `database-repo` or
  `event-store`) before committing to one approach.
- **Delivery/obsolescence loop concurrency.** Nothing in Phases 11–12
  addresses two `EventStore` processes (or two intervals firing before
  the first finishes) racing over the same pending/retention rows. The
  `DELETE ... WHERE ... = ANY($2)` pattern is at least idempotent (a
  re-delivery of an already-deleted batch just deletes zero rows), but
  concurrent *delivery* (double-POSTing the same batch to an aggregator
  before the first call's delete commits) isn't addressed. Likely fine
  for a single-process-per-node deployment (this plan's whole scope) but
  worth a row-level lock (`SELECT ... FOR UPDATE SKIP LOCKED`) if that
  assumption ever changes.
