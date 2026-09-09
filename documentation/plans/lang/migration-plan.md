# Schema Migration Implementation Plan

Implements `documentation/docs/designs/ideas/schema-migration.md` — a new
entry point alongside `ddl_facade.apply_ddl` that replays a *stream's
entire* `CREATE STREAM`/`ALTER STREAM` history in one call and returns
only the PostgreSQL for the steps not already recorded as applied, per an
externally-tracked list of SHA-256 hashes. This is the core logic behind
the "StruoQL Schema Migration" component in
`documentation/docs/specifications/architecture/event-collectors.md`
§2.2 ("Reads the migration commands for a schema. Ensures that the event
collector's database is up-to-date with the schema and that the
migration is append-only.") — that doc's "CREATE SCHEMA"/"ALTER SCHEMA"
wording, and the idea doc's own, are informal; there is no new grammar
here, only `CREATE STREAM`/`ALTER STREAM` as `ddl-spec.md` already
defines them.

Read `implementation-plan.md` and `codegen-plan.md` first — this plan
builds directly on `ddl_ast`/`ddl_parser`/`ddl_semantics`/`ddl_codegen`/
`catalog` as they exist today (all "implemented" per those plans) and
doesn't re-derive their design decisions.

**Status: implemented**, per "Step-by-step build order" below —
`catalog.gleam`'s `migration_hashes`/`set_migration_hashes`, the
`gleam_crypto` dependency, `ddl_hash.gleam`, `ddl_codegen.gleam`'s
`validate_statement` extraction, `ddl_migration.gleam`,
`ddl_facade.apply_migration`, and `schema-bridge.ts`'s `applyMigration`
are all in place with passing test suites (`gleam test --runtime bun` in
`domain/shared` and `domain/schema`, `bun test` in `service/`), a clean
`gleam format --check` across every `domain/*` package, and a clean
`tsc --noEmit` in `service/`. One correction made during implementation:
the planned `EmptyMigration` error variant turned out to be dead code —
`ddl_parser.parse_many` already refuses zero statements on its own
(`UnexpectedEof`) before `ddl_migration.gleam` would ever see an empty
statement list, so an empty `source` surfaces as an ordinary
`LanguageError` instead; the variant was removed rather than kept
unreachable. The two "Open questions" below remain open — worth a look
before this is relied on by a real caller.

## Scope

- **In scope**: a new `ddl_facade.apply_migration` entry point (stream
  name, a catalog that must not yet contain that stream, a list of
  previously-applied hash codes, and StruoQL source containing that
  stream's full `CREATE STREAM` + zero or more `ALTER STREAM` history) →
  the fully-migrated `Catalog` (with the stream's complete hash list
  recorded) plus PostgreSQL for only the not-yet-applied suffix, or an
  error. A stream's declared shape (`catalog.gleam`'s `StreamSchema`)
  gains a `migration_hashes: List(String)` field. Hashing is per
  `CREATE`/`ALTER STREAM` *statement*, not per `AlterAction` within one —
  matching `ddl_semantics.apply_statement`'s existing "one statement, one
  atomic catalog update" granularity.
- **Out of scope**: anything that actually talks to a real PostgreSQL
  database (reading or writing a `schema_migrations`-style history
  table) — that's the "PostgreSQL Database I/O" component in
  `event-collectors.md`, still just an architecture-diagram box today,
  same as `codegen-plan.md`'s own scope cut. Wiring `apply_migration`
  into `service/src/main.ts`'s stdin-driven loop is also out of scope:
  that loop calls `applyDdl` once per typed statement, which isn't the
  shape this entry point wants (a stream name + its externally-tracked
  hash history + its *entire* source, all at once) — a real caller for
  it doesn't exist until the database I/O component does. Only the
  `schema-bridge.ts` wrapper function itself is in scope, per "Facades
  and the TypeScript boundary" in the root `CLAUDE.md`.

## Feedback on the idea doc (resolved below, recorded here for context)

- The doc's "Outputs" list doesn't mention returning the newly-computed
  hash codes themselves, only the revised catalog and the new SQL. But
  `Catalog` crosses to TypeScript opaquely (never inspected — see
  `ddl_facade.gleam`'s header comment); without the hash list coming back
  some other way, a caller has no way to learn what to record as
  "now applied" in its own external history table. Resolved below by
  adding a `hashes` array to the success JSON, holding just the newly
  computed ones (one per newly-emitted statement, in source order).
- `catalog.create_stream`'s signature is left unchanged (new streams
  still start with `migration_hashes: []`); a separate `set_migration_hashes`
  primitive is added rather than threading hashes through
  `create_stream`/the `ALTER STREAM` primitives, so `apply_ddl`'s
  existing behavior and tests are untouched.
- The doc doesn't spell out several structural misuse cases beyond "hash
  mismatch." Treated as new hard errors, listed under "Structural
  validation" below: starting catalog already has the named stream,
  first statement isn't `CREATE STREAM`, a later statement is an
  unexpected second `CREATE STREAM` or names a different stream, and a
  `previous_hashes` list longer than the number of statements given.
- The pinned `gleam_stdlib` (1.0.5, per `manifest.toml`) has no
  `bit_array.base16_encode` — that was added in a later stdlib version.
  `ddl_hash.gleam` hand-rolls hex encoding of the raw SHA-256 digest
  (see below) rather than bumping `gleam_stdlib`'s version requirement,
  which is unrelated to this feature.

## Design decisions

- **Hash basis: a canonical, span-free JSON serialization of the
  `DdlStatement`, independent of `ddl_codegen`'s SQL rendering** — not
  the generated SQL text itself. Reusing `expr_codegen.expr_to_sql`/
  `data_type_to_sql` (or the per-statement `create_stream_to_sql`/
  `alter_stream_to_sql`) would also be whitespace-invariant, but it ties
  hash stability to codegen's *formatting* choices forever: a later
  change to how `ddl_codegen` prints, say, a `DEFAULT` expression would
  silently change every already-recorded hash in a live external
  database, breaking append-only detection for existing deployments.
  A serialization that exists solely to be hashed, and that `ddl_codegen`
  never touches, doesn't have that failure mode — `ddl_codegen` stays
  free to change its SQL formatting at will.
- **Built with `gleam/json`, not hand-rolled string concatenation.**
  `domain/schema` already depends on `gleam_json` (`ddl_facade.gleam`
  uses it today). Tagging every node with an explicit field (`"stmt":
  "create_stream"`, `"kind": "column"`, `"action": "drop_column"`, ...)
  and letting `json.to_string` handle string escaping/structure makes the
  encoding unambiguous (two different ASTs can't collide onto the same
  string) for free — a hand-rolled tagged-string format would need its
  own escaping scheme to get the same guarantee. `json.object`'s field
  order is exactly the order given in code, so output is deterministic
  across calls without needing to sort keys.
- **Every `Span` is dropped**, everywhere it appears in `ddl_ast`/
  `expr_ast` — the entire point is whitespace/position invariance. Only
  semantic content (names, operators, literals' values, structure)
  is encoded.
- **Re-validate every statement on every call, historical ones
  included** — don't add an "apply without checking" path to
  `ddl_semantics`. `apply_migration` is a batch, cold-path operation
  (replaying a stream's full history, likely at service startup or on a
  schedule), not a hot one, so re-running `ddl_semantics.analyze` across
  the whole history each time costs nothing that matters and needs no
  new, weaker entry point into `ddl_semantics` whose only caller trusts
  its input. It also means a hash-verified-unchanged historical
  statement that somehow *fails* validation today (e.g. a future
  `ddl_semantics` bug fix that's now stricter) is reported as an error
  rather than silently applied.
- **`migration_hashes` is a plain setter (`set_migration_hashes`), not an
  incremental appender**, on `catalog.gleam`. `apply_migration` already
  has the complete final list in hand (`previous_hashes` ++ the new
  statements' hashes, computed in source order) by the time it touches
  the catalog for the last time — setting it once avoids any risk of a
  fold-based appender getting the order or count wrong across the
  replayed-vs-new split.
- **Structural checks run once, up front, over the parsed statement
  list** — not accumulated alongside `ddl_semantics.SemanticError` the
  way `check_create_stream`/`check_alter_stream`'s *own* checks
  accumulate. These are caller-misuse conditions ("you didn't pass this
  stream's actual history"), not user-authorable language mistakes, so
  fail-fast on the first one found is enough; there's no reason a caller
  needs every structural problem enumerated at once the way a StruoQL
  author benefits from seeing every column error in one `CREATE STREAM`
  at once.
- **`ddl_codegen.gleam` gains one new `pub fn`, no other change to its
  behavior.** Its private `validate_all` loop's per-statement body
  (`ddl_semantics.analyze` wrapped into `SemanticFailure`) is exactly
  what `ddl_migration.gleam`'s own loop needs too, so it's pulled out as
  `pub fn validate_statement(catalog, stmt, index) -> Result(Catalog, CodegenError)`
  and both `validate_all` (unchanged behavior) and the new module call
  it, rather than `ddl_migration.gleam` growing its own copy or
  depending on `ddl_semantics` directly and re-deriving `SemanticFailure`
  wrapping.

## Module layout

```
domain/shared/src/lang/catalog.gleam        — + migration_hashes field, + set_migration_hashes
domain/schema/src/lang/ddl_hash.gleam        — NEW: canonical JSON + SHA-256 hex hash of one DdlStatement
domain/schema/src/lang/ddl_migration.gleam   — NEW: apply_migration's real logic, MigrationError
domain/schema/src/lang/ddl_codegen.gleam     — + pub fn validate_statement (extracted from validate_all)
domain/schema/src/ddl_facade.gleam           — + apply_migration, + JSON "kind"/"hashes" shape
service/src/bridges/schema-bridge.ts         — + applyMigration wrapper
domain/schema/gleam.toml                     — + gleam_crypto dependency
```

## `catalog.gleam` changes

```gleam
pub type StreamSchema {
  StreamSchema(
    name: String,
    columns: Dict(String, ColumnSchema),
    constraints: Dict(String, NamedCheck),
    /// SHA-256 hex hashes (`ddl_hash.gleam`, schema/) of every
    /// `CREATE`/`ALTER STREAM` statement applied to this stream so far,
    /// in application order — `create_stream` starts this at `[]`;
    /// `apply_migration` (schema/) is the only thing that ever sets it
    /// to something else, via `set_migration_hashes` below. Untouched by
    /// `add_column`/`drop_column`/etc., same as `name`/`constraints`
    /// aren't touched by unrelated primitives.
    migration_hashes: List(String),
  )
}
```

`create_stream`'s own constructor call gains `migration_hashes: []`; its
public signature is unchanged. New primitive, alongside `add_column`/
`drop_column`/etc., built on the same `update_schema` helper:

```gleam
pub fn set_migration_hashes(
  catalog: Catalog,
  stream: String,
  hashes: List(String),
) -> Catalog {
  update_schema(catalog, stream, fn(schema) {
    StreamSchema(..schema, migration_hashes: hashes)
  })
}
```

## `ddl_hash.gleam` (new, `domain/schema/src/lang/`)

```gleam
import gleam/bit_array
import gleam/crypto
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import lang/ddl_ast as ast
import lang/expr_ast as xast

/// SHA-256 of a canonical, span-free JSON encoding of `stmt` — see
/// "Design decisions" in migration-plan.md for why JSON, and why not
/// `ddl_codegen`'s rendered SQL. Lower-case hex, 64 characters.
pub fn hash_statement(stmt: ast.DdlStatement) -> String {
  canonical_statement(stmt)
  |> json.to_string
  |> bit_array.from_string
  |> crypto.hash(crypto.Sha256, _)
  |> hex_encode
}

fn canonical_statement(stmt: ast.DdlStatement) -> Json { ... }
fn canonical_stream_element(el: ast.StreamElement) -> Json { ... }
fn canonical_column_def(col: ast.ColumnDef) -> Json { ... }
fn canonical_alter_action(action: ast.AlterAction) -> Json { ... }
fn canonical_named_check(check: xast.NamedCheck) -> Json { ... }
fn canonical_generated_clause(g: Option(xast.GeneratedClause)) -> Json { ... }
fn canonical_expr(expr: xast.Expr) -> Json { ... }
fn canonical_data_type(dt: xast.DataType) -> Json { ... }

fn hex_encode(digest: BitArray) -> String { ... }
```

- One `canonical_*` function per AST type, each an exhaustive `case`
  over every constructor (mirrors `expr_codegen.gleam`'s own shape — same
  exhaustiveness discipline, deliberately independent output). Every
  object tags its node kind explicitly (`json.object([#("stmt",
  json.string("create_stream")), #("name", json.string(name)), #("elements",
  json.array(...))])`) so structurally different nodes can never encode
  to the same JSON text. No field is ever a bare positional value with
  an implicit meaning.
- `canonical_expr`'s `ColumnRef(name, span)` and `NamedCheck`'s `span`
  are the only two `Span`-carrying shapes in the whole grammar (per
  `expr_ast.gleam`'s own note on `ColumnRef`) — both simply omit their
  `span` field from the JSON, same as every other node omits `Span`
  wherever `ddl_ast`/`expr_ast` carries one.
- `hex_encode` walks the digest via Gleam's native bit-array pattern
  matching (`case bits { <<byte, rest:bytes>> -> ... }`), converting each
  byte with `int.to_base_string(byte, 16)` and left-padding to 2
  characters — the pinned `gleam_stdlib` (1.0.5) has no
  `bit_array.base16_encode` (added in a later version; see "Feedback on
  the idea doc" above).
- **Test plan** (`domain/schema/test/lang/ddl_hash_test.gleam`):
  - Same source with different whitespace/formatting parses to an
    `ast.DdlStatement` that hashes identically.
  - Two different valid statements hash differently.
  - A `DropColumn`/`AlterColumnType` pair naming the same column (same
    field values, different constructor) hash differently — regression
    guard on the "every node tags its own kind" property.
  - A `CREATE STREAM`'s hash is stable across unrelated catalog state
    (pure function of the statement alone, no `Catalog` parameter).

## `ddl_codegen.gleam`: one extracted `pub fn`

```gleam
/// The per-statement body `validate_all`'s fold already ran — pulled out
/// so `ddl_migration.gleam` can reuse the exact same
/// `ddl_semantics.analyze`-and-wrap-into-`SemanticFailure` step without
/// its own copy or a direct `ddl_semantics` dependency. `index` is
/// passed through, not recomputed, so `ddl_migration.gleam`'s own loop
/// (which skips rendering — not validating — some statements) still
/// reports the same 0-based "statements successfully parsed before this
/// one" index `apply_ddl`'s errors already promise.
pub fn validate_statement(
  catalog: Catalog,
  stmt: ast.DdlStatement,
  index: Int,
) -> Result(Catalog, CodegenError) {
  case ddl_semantics.analyze(catalog, stmt) {
    Ok(next_catalog) -> Ok(next_catalog)
    Error(errors) -> Error(SemanticFailure(index, errors))
  }
}
```

`validate_all` becomes a one-line-per-step wrapper around this; no
behavior change, no test change needed for `ddl_codegen_test.gleam`.

## `ddl_migration.gleam` (new, `domain/schema/src/lang/`)

```gleam
pub type MigrationError {
  /// Wraps a lex/parse/semantic failure exactly as `ddl_codegen.generate`
  /// would report it — same `CodegenError` type, no duplicate variants.
  /// Also what a `source` with no statements at all surfaces as:
  /// `ddl_parser.parse_many` already refuses "zero statements" on its
  /// own (`UnexpectedEof`), so there's no separate `EmptyMigration` case
  /// to add on top — turned out to be dead code once actually wired up,
  /// removed during implementation.
  LanguageError(ddl_codegen.CodegenError)
  /// `catalog` already had `stream` — violates the "starting catalog
  /// must not include the named stream" precondition.
  StreamAlreadyExists(stream: String)
  /// The first statement wasn't `CREATE STREAM`.
  FirstStatementMustBeCreateStream(span: Span)
  /// A statement after the first was `CREATE STREAM` again.
  UnexpectedCreateStream(span: Span)
  /// A statement named a stream other than the one passed in.
  StatementTargetsWrongStream(expected: String, actual: String, span: Span)
  /// `previous_hashes` named more statements than `source` contains.
  TooManyPreviousHashes(previous_count: Int, statement_count: Int)
  /// `previous_hashes[statement_index]` didn't match that statement's
  /// actual hash — source modified from a prior migration.
  HashMismatch(statement_index: Int, expected: String, actual: String, span: Span)
}

/// See `ddl_facade.apply_migration`'s own doc comment for the full
/// contract; this is its unwrapped Gleam-level equivalent.
pub fn apply_migration(
  catalog: Catalog,
  stream: String,
  previous_hashes: List(String),
  source: String,
) -> Result(#(String, List(String), Catalog), MigrationError)
```

Body, roughly:

1. `catalog.streams |> dict.has_key(stream)` → `StreamAlreadyExists` if
   `True`.
2. Lex + `ddl_parser.parse_many` (wrapping failures in `LanguageError`,
   exactly as `ddl_codegen.generate` does) → `statements`; empty
   `source` already fails here (`ParseFailure(UnexpectedEof(..))`), so
   `statements` is never `[]` past this point.
3. `list.length(previous_hashes) > list.length(statements)` →
   `TooManyPreviousHashes`.
4. Walk `statements` once, index-by-index: statement 0 must be
   `ast.CreateStream(name: stream, ..)` (wrong statement kind →
   `FirstStatementMustBeCreateStream`; right kind, wrong `name` →
   `StatementTargetsWrongStream`); every later one must be
   `ast.AlterStream(name: stream, ..)` (wrong kind →
   `UnexpectedCreateStream`; right kind, wrong `name` →
   `StatementTargetsWrongStream`).
5. Fold over `statements` with index, threading `Catalog`, an
   accumulated `new_sql: List(String)`, and `new_hashes: List(String)`:
   - Compute `hash = ddl_hash.hash_statement(stmt)`.
   - If `index < list.length(previous_hashes)`: compare `hash` against
     `previous_hashes[index]`; mismatch → `HashMismatch`. Match →
     `ddl_codegen.validate_statement(catalog, stmt, index)` to fold the
     catalog forward, emit nothing to `new_sql`/`new_hashes` (already
     applied).
   - Else (`index >= list.length(previous_hashes)`, i.e. genuinely new):
     `ddl_codegen.validate_statement` the same way, then render via
     `ddl_codegen.create_stream_to_sql`/`alter_stream_to_sql` (both
     already `pub`) and append to `new_sql`, append `hash` to
     `new_hashes`.
6. On success: `catalog.set_migration_hashes(final_catalog, stream,
   list.append(previous_hashes, new_hashes))`, then return
   `#(string.join(new_sql, "\n\n") <> "\n", new_hashes, tagged_catalog)`
   — empty string when `new_sql` is `[]` (the "already fully migrated,
   nothing new to run" case), matching `render_all`'s own trailing-`\n`
   convention when there's anything to join.

## `ddl_facade.gleam` additions

```gleam
/// Stream-scoped counterpart to `apply_ddl`: given `stream`'s *entire*
/// `CREATE STREAM` + `ALTER STREAM` history in one `source` string, plus
/// the hash codes an external migration-history store already has
/// recorded as applied for it (`previous_hashes`, in application order),
/// returns `#(result_json, updated_catalog)`. `catalog` must not already
/// contain `stream` — see the module doc comment on why `apply_migration`
/// always replays a stream's full history rather than threading forward
/// incrementally the way `apply_ddl` does.
///
/// `result_json` is one of:
///   `{"ok": true, "kind": "ok", "sql": "<new-statements-only SQL, "" if none>",
///     "hashes": ["<new hash>", ...]}`
///     — `hashes` is only the newly-computed ones, in source order: what
///     a caller should append to its own external history after
///     successfully running `sql`.
///   `{"ok": false, "kind": "hash_mismatch", "statement_index": <int>,
///     "error": "<string.inspect detail>"}`
///     — a caller likely treats this as an alarm-worthy condition (a
///     previously-applied migration's source was edited), distinct from
///     an ordinary language mistake.
///   `{"ok": false, "kind": "language_error", "error": "<string.inspect
///     of the underlying ddl_codegen.CodegenError>"}`
///   `{"ok": false, "kind": "structural_error", "error": "<string.inspect
///     of the MigrationError variant>"}`
///     — caller misuse: wrong/missing stream in `source`, catalog
///     already had the stream, too many `previous_hashes`, empty source.
pub fn apply_migration(
  catalog: Catalog,
  stream: String,
  previous_hashes: List(String),
  source: String,
) -> #(String, Catalog)
```

Implementation dispatches on `ddl_migration.apply_migration`'s
`Result`, matching on the `MigrationError` variant to pick `"kind"`
(`HashMismatch` → `"hash_mismatch"`; `LanguageError` → `"language_error"`;
everything else → `"structural_error"`) the same way `ddl_facade.gleam`
already renders every error body via `string.inspect` rather than a
hand-written message per variant (see its existing `error_json` doc
comment) — the `"kind"` tag is the only new *structured* information a
caller gets; the `"error"` string stays a display-only detail dump, same
scope cut as `apply_ddl`.

## `schema-bridge.ts` addition

```ts
export function applyMigration(
  catalog: CatalogHandle,
  stream: string,
  previousHashes: string[],
  source: string,
): [string, CatalogHandle] {
  return schemaFacade.apply_migration(catalog, stream, previousHashes, source);
}
```

Same `@ts-expect-error`-annotated direct import as `applyDdl`; no new
file, no new export surface beyond this one function.

## `gleam.toml` change

`domain/schema/gleam.toml`'s `[dependencies]` gains:

```toml
gleam_crypto = ">= 1.0.0 and < 2.0.0"
```

(matching the existing loose-bound style of `gleam_stdlib`/`gleam_json`
above it; latest resolvable today is 1.6.0, confirmed to support both
Erlang and JavaScript targets). `domain/shared` and `domain/streams` gain
no new dependency — hashing is schema-only, same as `ddl_ast`/
`ddl_semantics`/`ddl_codegen` already are.

## Test plan

- `domain/shared/test/lang/catalog_test.gleam`: `create_stream` leaves
  `migration_hashes` at `[]`; `set_migration_hashes` replaces it;
  `add_column`/`drop_column`/`alter_column_type`/`add_constraint`/
  `drop_constraint` leave an existing stream's `migration_hashes`
  untouched.
- `domain/schema/test/lang/ddl_hash_test.gleam`: see "Test plan" under
  `ddl_hash.gleam` above.
- `domain/schema/test/lang/ddl_migration_test.gleam`:
  - Fresh migration (`previous_hashes: []`), 1 `CREATE` + 2 `ALTER`
    statements → `sql` contains all 3 statements' SQL, `hashes` has 3
    entries, resulting catalog's `migration_hashes` has 3 entries in
    order.
  - Same source, `previous_hashes` = the first statement's hash only →
    `sql`/`hashes` cover only the 2 `ALTER`s; final catalog's
    `migration_hashes` still has all 3, in order.
  - `previous_hashes` covering all statements → `sql == ""`,
    `hashes == []`, catalog still fully populated.
  - `previous_hashes[0]` doesn't match the first statement's real hash →
    `HashMismatch(statement_index: 0, ..)`.
  - `catalog` already contains `stream` → `StreamAlreadyExists`.
  - First statement is `ALTER STREAM` → `FirstStatementMustBeCreateStream`.
  - A later statement is `CREATE STREAM` again → `UnexpectedCreateStream`.
  - A statement names a different stream than the `stream` parameter →
    `StatementTargetsWrongStream`.
  - `previous_hashes` longer than the statement count →
    `TooManyPreviousHashes`.
  - Empty `source` and an ordinary lex/parse/semantic failure both
    surface as `LanguageError`, same detail `ddl_codegen.generate` would
    have produced for identical input.
- `domain/schema/test/ddl_facade_test.gleam`: JSON-shape assertions for
  each outcome above (`"kind"`, `"hashes"`, `"statement_index"` presence/
  absence), mirroring the existing `apply_ddl` tests' `string.contains`
  style.
- `service/test/schema-bridge.test.ts`: one round-trip test (fresh
  migration → `ok`/`sql`/`hashes`), one resume-with-existing-hashes test,
  one `hash_mismatch` test — mirroring `schema-bridge.test.ts`'s existing
  "thin, confirms the real compiled-Gleam round trip" scope note.

## Step-by-step build order

1. `catalog.gleam`: add `migration_hashes` field + `set_migration_hashes`;
   update `catalog_test.gleam`.
2. `domain/schema/gleam.toml`: add `gleam_crypto`; `gleam deps download`.
3. `ddl_hash.gleam` + its test suite, standalone (depends only on
   `ddl_ast`/`expr_ast`, nothing from this plan's other new pieces).
4. `ddl_codegen.gleam`: extract `validate_statement`; confirm
   `ddl_codegen_test.gleam` still passes unchanged.
5. `ddl_migration.gleam` + its test suite.
6. `ddl_facade.gleam`: `apply_migration` + JSON shape; extend
   `ddl_facade_test.gleam`.
7. `schema-bridge.ts`: `applyMigration`; extend `schema-bridge.test.ts`.
8. Full check across both: `bun run build:domain`, `bun run
   test:domain`, `bun run format:domain:check`, then `bun run --cwd
   service build`/`test` — matching what CI (`.github/workflows/test.yml`)
   runs, per the root `CLAUDE.md`.

## Open questions

- Whether `hashes` in the success JSON should instead be the *full*
  list (`previous_hashes` ++ new) rather than just the new ones —
  new-only was chosen as directly "what to append," but a caller that
  wants to replace its stored list wholesale would prefer the full one.
  Easy to revisit during review; doesn't change anything else in this
  plan's shape.
- Whether `StreamAlreadyExists` should instead be tolerated by treating
  `catalog`'s existing entry for `stream` as the true starting point
  (ignoring `previous_hashes` and diffing against the catalog's own
  `migration_hashes` instead) rather than hard-erroring — the idea doc's
  own precondition ("must not include the named stream") reads as
  intentional, so this plan treats it as a hard error, but the
  alternative would let a caller incrementally extend a stream already
  live in the same in-process `Catalog` without a full replay. Worth
  confirming isn't the actually-intended usage before this ships.
- No change proposed to `documentation/docs/specifications/struoql/`
  (nothing here is a grammar change) or to
  `documentation/docs/designs/ideas/schema-migration.md` itself — once
  implemented, consider whether to fold a settled summary into
  `design-decisions.md`'s "Settled Design Decisions," per that doc's own
  role (see root `CLAUDE.md`'s note on it), or leave the idea doc as
  historical context. Not resolved here; a documentation follow-up, not
  a code one.
