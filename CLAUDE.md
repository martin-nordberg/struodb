# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

StruoDB is a distributed event-source database. Domain logic is written in
Gleam, compiled to the **JavaScript target** and run on **Bun**; the outer
application layer (`service/`) is TypeScript. See
`documentation/plans/architecture/bun-typescript-migration-plan.md` for the
migration this repo went through to get here (Erlang/OTP target, actor
pipelines, and a per-package flat layout previously) — still the best
account of *why* the repo is shaped the way it is below, even though its
own steps are now complete.

`domain/` holds five independent Gleam packages, each with its own
`gleam.toml`/`manifest.toml` (`target = "javascript"` in every one) and no
repo-wide Gleam build/test runner — commands run from inside the package
directory you're working on:

- **`domain/shared/`** — library package with a hybrid logical clock
  (`hlc/`) and the lexical/expression layer of the StruoDB query language
  front end (`lang/` — see "The StruoDB query language front end" below).
  Every other domain package depends on it via `shared = { path =
  "../shared" }`.
- **`domain/schema/`** — handles schema-defining DDL commands. Its `lang/`
  has real `CREATE STREAM`/`ALTER STREAM` parsing, semantic analysis, and
  catalog-tracking, wired up for external callers via `src/ddl_facade.gleam`
  (see "Facades and the TypeScript boundary" below) — `schema.gleam` itself
  has no `main` any more (see "TypeScript application layer" below for
  where driving now happens).
- **`domain/streams/`** — handles stream manipulation commands. Its
  `lang/` has real `INSERT` parsing and semantic analysis, wired up via
  `src/dml_facade.gleam`. Production code depends only on `shared`;
  `schema` is a dev-only dependency, used solely by tests that build a
  `Catalog` via real DDL parsing — see "The StruoDB query language front
  end" below.
- **`domain/projections/`** — intended to handle projection behaviors.
- **`domain/network/`** — intended to maintain network configuration for
  the distributed database.

`domain/projections` and `domain/network` are currently stubs (a `main`
that prints `"Hello from <name>!"` and a placeholder test) — they exist as
the intended service boundaries but have no logic yet. `domain/schema` and
`domain/streams` have real language-front-end logic under `lang/` now (see
below), each behind its own facade. When implementing DDL, stream
manipulation, projection, or network features, expect to build them out
from this state, likely pulling shared logic from (or into)
`domain/shared/`.

`service/` is the one TypeScript application (a Bun package, part of the
root `package.json`'s Bun workspace) that drives the Gleam domain packages
— see "TypeScript application layer" below.

Toolchain is pinned in `mise.toml`: Bun 1.4, Gleam 1.18. (No Erlang —
nothing targets it any more; `gleam`'s own CLI has no Erlang/OTP runtime
dependency of its own regardless of target.)

## Commands

Gleam commands run **from inside the package directory you're working on**
(`domain/shared/`, `domain/schema/`, `domain/streams/`, `domain/network/`,
or `domain/projections/`):

```sh
gleam deps download          # fetch dependencies (first run / after editing gleam.toml)
gleam build                  # compile (javascript target, per that package's gleam.toml)
gleam test --runtime bun     # run that package's test suite (gleeunit) on Bun
gleam format src test        # format
gleam format --check src test  # check formatting only (what CI runs)
```

(No `gleam run` for any domain package any more — none has a `main` left;
driving happens from `service/`, below.)

To run a single test module or test case, use gleeunit's filtering via
`gleam test`, e.g. from `domain/shared/`:

```sh
gleam test --runtime bun -- --seed 1 base62_test
```

Root-level scripts (from the repo root; see `package.json`) wrap the above
across every `domain/*` package at once:

```sh
bun run build:domain          # gleam build in every domain/* package
bun run test:domain           # gleam test --runtime bun in every domain/* package
bun run format:domain:check   # gleam format --check src test in every domain/* package
```

`service/` (a Bun package):

```sh
bun install               # from the repo root — fetches service/'s deps too (Bun workspace)
bun run --cwd service dev    # bun run build:domain, then run src/main.ts against stdin
bun run --cwd service build  # bun run build:domain, then a type-check (tsc --noEmit)
bun run --cwd service test   # bun run build:domain, then bun test
```

CI (`.github/workflows/test.yml`, one root-level workflow) matrixes
`gleam deps download` / `gleam test --runtime bun` / `gleam format --check
src test` across every `domain/*` package, plus a `service` job building
every `domain/*` package and running `service/`'s own type-check and
`bun test` — match that before considering work done.

`build/` directories (present per `domain/*` package, gitignored) are
Gleam's compiled JS output — `service/`'s bridges import directly from
them (see below) — and dependency cache; not source, never edit files
under `domain/*/build/`.

## Architecture notes

### `domain/shared/hlc` — hybrid logical clock

Implements the algorithm in
`documentation/docs/specifications/internals/hlc-spec.md`: each clock
value is a 15-character, base-62-encoded, lexicographically-sortable
string (8 chars physical-time-ms, 2 chars logical counter, 5 chars
caller-assigned node ID) sized to fit a PostgreSQL `char(15)` with no
padding. `base62.gleam` is the pure encode/decode — its capacity lookup
table stops at width 8, not a larger "generous" ceiling: `62^9` already
exceeds JavaScript's `Number.MAX_SAFE_INTEGER`, and 8 is exactly
`clock.gleam`'s own widest field (`time_width`), the largest this codebase
ever needs. `clock.gleam` holds the per-node `(time, counter, node_id)`
state machine itself (`next()`/`next_parts()` for local events, `merge()`
on an incoming remote value per the spec's merge rule) as plain functions
over an opaque `ClockState` — no actor, no mutable state, no
`gleam/erlang`/`gleam/otp` dependency at all.

There is no Gleam-side actor wrapper any more (the pre-migration
`clock_keeper.gleam` is gone). `service/src/hlc-clock.ts`'s `HlcClock`
class is what replaced it: a plain TypeScript class holding one
`ClockState` (imported opaquely from compiled Gleam output, never
constructed or inspected — see that file's header comment) and calling
straight through to `clock.new$`/`next`/`next_parts`/`merge` on each
method call, the same "one clock per process, called synchronously" role
`clock_keeper.gleam`'s actor used to play. `service/src/main.ts`
constructs the one `HlcClock` a process uses and passes it to whichever
bridge needs it (today, `streams-bridge.ts`, for `INSERT`'s per-row HLC
stamping). The lexicographic-order-equals-value-order invariant
(fixed-width, zero-padded fields; monotonic alphabet) is load-bearing —
any change to field widths or the alphabet breaks it.

### The StruoDB query language front end (`lang/`, split across `domain/shared`/`domain/schema`/`domain/streams`)

StruoDB's query language transpiles to PostgreSQL (see
`documentation/docs/specifications/struoql/` — `lexical-spec.md` §1–§6,
`ddl-spec.md` §7–§10, `dml-spec.md` §11 — for the full grammar, split
across those three pages by section range; `overview.md` is the entry
point). Expression parsing (`expr`, `data_type`) is one
grammar shared by two statement families with different package owners,
so `lang/` exists in three places, split by what's reused vs. what's
statement-family-specific — not kept in one module:

```
domain/shared/src/lang/  token.gleam / lexer.gleam       — lexical layer
  (used by both          expr_ast.gleam / expr_parser.gleam — expr, data_type,
   schema & streams)                                        GeneratedClause, NamedCheck
                          expr_semantics.gleam            — column-reference checks
                          expr_codegen.gleam              — expr/data_type -> SQL text
                          token_stream.gleam              — token cursor
                          catalog.gleam — a stream's declared shape

domain/schema/src/lang/  ddl_ast.gleam / ddl_parser.gleam    — CREATE/ALTER STREAM
  (DDL)                  ddl_semantics.gleam
                          ddl_codegen.gleam — DdlStatement -> CREATE/ALTER TABLE SQL
domain/schema/src/       ddl_facade.gleam — JSON-in/JSON-out entry point (see below)

domain/streams/src/lang/ dml_ast.gleam / dml_parser.gleam    — INSERT
  (DML)                  dml_semantics.gleam
                          dml_codegen.gleam — DmlStatement -> INSERT INTO SQL
domain/streams/src/      dml_facade.gleam — JSON-in/JSON-out entry point (see below)
```

A DDL statement's pipeline: `source text → shared/lexer.tokenize →
schema/ddl_parser.parse (which calls into shared/expr_parser for
expressions/data types) → schema/ddl_ast.DdlStatement →
schema/ddl_semantics.analyze`, which validates the statement against a
`Catalog` and, once it's `Ok`, translates it into calls against
`shared/catalog`'s own `create_stream`/`add_column`/etc. primitives to
record the resulting shape. `INSERT` follows the same shape one package
over, through `streams/dml_parser` → `streams/dml_ast.DmlStatement` →
`streams/dml_semantics.analyze` — which validates against a `Catalog` but
never changes one, since an `INSERT` never alters a stream's shape.
`schema/ddl_facade.gleam`/`streams/dml_facade.gleam` are the outermost
layer over each pipeline — see "Facades and the TypeScript boundary"
below.

- `token.gleam` / `lexer.gleam` (shared) — lexical layer: keywords are
  case-insensitive, unquoted identifiers fold to lower case, quoted
  identifiers (`"..."`) are case-sensitive, matching PostgreSQL convention.
  An unquoted identifier matching one of PostgreSQL's own reserved
  keywords (lexical-spec.md §3.5, ~101 words) is rejected at the lexer as
  `ReservedWord` rather than accepted as an `Identifier` — this is what
  lets a future codegen stage emit unquoted identifiers by default
  (content-based quoting only) instead of always-quoting, since no
  unquoted source identifier can ever collide with a PostgreSQL reserved
  word; see `documentation/plans/lang/codegen-plan.md`'s
  identifier-quoting design decision.
- `expr_ast.gleam` / `expr_parser.gleam` (shared) — expressions,
  `data_type` (ddl-spec.md §8–§9.1), and `GeneratedClause`/`NamedCheck` (§9.1,
  §9.5 — small wrappers around an `Expr` that both `ddl_ast.gleam`, as
  parsed, and `catalog.gleam`, as stored, need the same shape for): pure
  data plus the precedence-layered recursive-descent parser for the
  expressions/data types, reused as-is by both `ddl_parser` and
  `dml_parser` (each also uses `expr_parser`'s `expect_*` cursor helpers
  and `ParseError` type for its own statement-level grammar).
  `token_stream.gleam` is the token-list cursor (peek/advance) every
  parser production in `expr_parser`/`ddl_parser`/`dml_parser` is built
  from.
- `expr_semantics.gleam` (shared) — `collect_column_refs`/
  `check_expr_column_refs`, the `Expr`-walking helpers both
  `ddl_semantics.gleam` and `dml_semantics.gleam` build their
  column-reference checks on (used to be two verbatim copies, one per
  package, until a review moved them here). `check_expr_column_refs`
  takes the error constructor as a parameter (`fn(String, Span) -> e`)
  rather than returning a fixed error type, since each package's
  `UnknownColumnReference` belongs to its own distinct `SemanticError` —
  callers just pass that variant's own constructor directly.
- `catalog.gleam` (shared) — tracks the accumulated, validated shape of a
  stream as `CREATE STREAM`/`ALTER STREAM` statements are applied to it,
  via small primitives (`create_stream`, `add_column`, `drop_column`,
  `alter_column_type`, `add_constraint`, `drop_constraint`) rather than
  one `apply_statement(catalog, stmt)` — it knows nothing about
  `ddl_ast.gleam`'s `DdlStatement`/`StreamElement`/`AlterAction` (only
  `ColumnSchema`/`NamedCheck`, both shared types), which is what lets it
  live here rather than next to `ddl_ast.gleam` in `schema/`.
  `ddl_semantics.gleam` (schema) translates a validated `DdlStatement`
  into these calls itself, one variant at a time. This is why
  `dml_semantics.gleam` (streams) can reach a `Catalog` — to validate
  `INSERT` against a stream's current shape — by depending on `shared`
  alone, with no `schema` dependency in `streams`' production code at
  all (see "What this is" above).
- `ddl_ast.gleam` / `ddl_parser.gleam` (schema) — `CreateStream`/
  `AlterStream` shape (ddl-spec.md §9–§10) and the parser that builds it.
  Read `ddl_ast.gleam`'s header comment — it explains why some shapes
  (e.g. `ColumnDef` vs `StreamElement`) are structured the way they are
  for reuse across `CREATE`/`ALTER`.
- `dml_ast.gleam` / `dml_parser.gleam` (streams) — `Insert` shape
  (dml-spec.md §11) and its parser.
- `ddl_semantics.gleam` (schema) / `dml_semantics.gleam` (streams) —
  validate a parsed statement against a `Catalog`. Each defines its own
  `SemanticError`, scoped to the variants it actually raises (no longer a
  full copy of the other's), and both call `expr_semantics.gleam` (above)
  for column-reference checks rather than keeping their own copy.

Only `CREATE STREAM`, `ALTER STREAM`, and `INSERT` are in scope so far;
querying/subscribing to a stream's events is explicitly out of scope per
the spec. `documentation/docs/specifications/struoql/design-decisions.md`'s "Open
Issues" section (renamed from the pre-VitePress spec's "Remaining open
details") tracks still-undecided points — check there before assuming a
gap in the code is a bug rather than known scope. Its "Settled Design
Decisions" section (the old spec.md §13) is a changelog recap of
already-settled points, useful for why something is the way it is
without re-deriving the reasoning from source.

### Facades and the TypeScript boundary

`domain/schema/src/ddl_facade.gleam` and `domain/streams/src/dml_facade.gleam`
are each package's *only* export to TypeScript — everything else under
`lang/` stays internal. Every function's content (StruoQL source text in;
generated SQL or an error description out) crosses as a plain
string/JSON, never a Gleam ADT. `Catalog` is the one deliberate exception,
and threads through *opaquely*: `ddl_facade.apply_ddl(catalog, source)`
returns `#(result_json, updated_catalog)`, and a caller (TypeScript, or
another Gleam module) stores `updated_catalog` and hands it back on the
next call without ever constructing or inspecting it — exactly like
`hlc/clock.ClockState` above. This was a deliberate choice over a
`Catalog ⇄ JSON` codec (see `ddl_facade.gleam`'s own header comment): a
full codec would mean hand-writing a JSON encoding for the entire
`expr_ast.Expr`/`DataType` grammar too (`ColumnSchema`'s `default`/
`generated` fields, and `NamedCheck`, embed arbitrary `Expr` trees), and
would force `streams` to decode a `schema`-produced JSON catalog shape —
duplicating knowledge that boundary is meant to keep out of `streams` in
the first place. Threading the value opaquely costs nothing, since
`schema-bridge.ts` and `streams-bridge.ts` (below) run in the same
TypeScript process.

`dml_facade.apply_insert(catalog, source, next_hlc)` is the one place a
plain Gleam function type (`next_hlc: fn() -> HlcParts`, unchanged from
`dml_codegen.generate`'s own signature) appears in a facade's public
signature — only `streams-bridge.ts` ever constructs a closure to satisfy
it, by calling a TypeScript-held `HlcClock`'s `nextParts()`; no other
TypeScript code calls `dml_facade` directly.

Both facades render every error via `string.inspect` rather than a
hand-written message per `CodegenError`/`SemanticError` variant — a
deliberate early scope cut (see `ddl_facade.gleam`'s `error_json`); a
caller needing to branch on *which* failure occurred, not just display
one, still has the real `ddl_codegen`/`dml_codegen`/`*_semantics` modules
to call directly from Gleam.

### TypeScript application layer (`service/`)

`service/` is a Bun/TypeScript application — the "driving adapter" half of
the hexagonal split explored in
`documentation/docs/public/x-designs/ideas/Gleam-TypeScript-Hexagonal-Architecture.pdf`
(no "driven adapter"/persistence layer exists yet; see the migration
plan's "Explicitly deferred" section). `src/main.ts` is the composition
root: builds one `HlcClock` (`src/hlc-clock.ts`) and one `CatalogHandle`
(`schema-bridge.emptyCatalog()`), then reads StruoQL statements from
stdin, routing `CREATE`/`ALTER` text to `schema-bridge.applyDdl` and
everything else to `streams-bridge.applyInsert`, threading the catalog
handle from each `applyDdl` call into the next.

`src/bridges/schema-bridge.ts` and `src/bridges/streams-bridge.ts` are the
*only* files allowed to import a `domain/*/build/dev/javascript/...` path
directly (Gleam emits no `.d.ts`, so these imports carry a `@ts-expect-
error` and everything they return is cast to an explicit local type) —
every other TypeScript file calls their typed wrapper functions instead.
Each corresponding domain package must be built (`gleam build`, or `bun
run build:domain` from the repo root) before `service/` can import its
compiled output — `service/package.json`'s `prebuild`/`pretest` scripts do
this automatically.

### Logging and errors

Gleam's `use`/`case` idioms are used for control flow; `let assert`
appears where a failure is meant to crash rather than be handled. There is
currently no structured-logging library in use anywhere in this repo (the
pre-migration actor pipeline's `birch` usage was deleted along with it,
per the migration plan) — a TypeScript-side caller (`service/`) logs with
plain `console.log`/`console.error` for now.

### Docs worth reading before working in a given area

Docs live in `documentation/` — a VitePress site under
`documentation/docs/` (run `bun run docs:dev` from `documentation/` to
browse it locally) plus `documentation/plans/`, historical planning docs
deliberately excluded from the built site (see its own `docs:build`
script/`.vitepress/config.ts` sidebar, which never references `plans/`).

- `documentation/plans/architecture/bun-typescript-migration-plan.md` —
  the Gleam-target/Bun/TypeScript migration this repo went through; the
  best account of why `domain/`/`service/` and the facade/bridge split
  are shaped the way they are.
- `documentation/docs/specifications/struoql/overview.md`, `lexical-spec.md`,
  `ddl-spec.md`, `dml-spec.md` — full query language grammar (lexical
  §1–§6, expressions/`CREATE`/`ALTER STREAM` §7–§10, `INSERT` §11).
- `documentation/docs/specifications/struoql/design-decisions.md` — the spec's own
  "Settled Design Decisions" (changelog recap) and "Open Issues"
  (undecided grammar points) — not a code-review-findings tracker.
- `documentation/plans/lang/implementation-plan.md`,
  `documentation/plans/lang/codegen-plan.md` — planned work for the
  language front end and PostgreSQL codegen.
- `documentation/docs/specifications/internals/hlc-spec.md` — the HLC algorithm.
  `documentation/plans/hlc/implementation-plan.md` — its planned work
  (predates the actor's removal — see the migration plan instead for the
  current TypeScript-held-state shape).
- `documentation/docs/specifications/internals/references.md` — external references
  (CloudEvents, EventQL, PostgreSQL syntax docs) informing the design.

No standalone code-review-findings tracker currently exists (the old
`docs/todo.md` served that role — "currently none" outstanding — and
was removed, not relocated, in the docs reorg).
