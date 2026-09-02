# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

StruoDB is a distributed event-source database, written in Gleam (targeting
Erlang/OTP). It's a monorepo of five independent Gleam packages, each with
its own `gleam.toml`, `manifest.toml`, and CI workflow:

- **`shared/`** — library package with an async I/O actor pipeline
  (`asyncio/`), a hybrid logical clock (`hlc/`), and the lexical/
  expression layer of the StruoDB query language front end (`lang/` — see
  "The StruoDB query language front end" below). Every other package
  depends on it via `shared = { path = "../shared" }`.
- **`schema/`** — application intended to handle schema-defining DDL
  commands. Its `lang/` now has real `CREATE STREAM`/`ALTER STREAM`
  parsing, semantic analysis, and catalog-tracking; the app's own `main`
  is still the stub print below, not yet wired to any of it.
- **`streams/`** — application intended to handle stream manipulation
  commands. Its `lang/` now has real `INSERT` parsing and semantic
  analysis; `streams/src/streams.gleam`'s current `main` is unrelated
  actor-pipeline demo code, not stream-manipulation logic wired to any of
  it yet. Production code depends only on `shared`; `schema` is a
  dev-only dependency, used solely by one test that builds a `Catalog` via
  real DDL parsing — see "The StruoDB query language front end" below.
- **`projections/`** — application intended to handle projection
  behaviors.
- **`network/`** — application intended to maintain network configuration
  for the distributed database.

`projections` and `network` are currently stubs (a `main` that prints
`"Hello from <name>!"` and a placeholder test) — they exist as the
intended service boundaries but have no logic yet. `schema` and `streams`
have real language-front-end logic under `lang/` now (see below), but
still no logic wired to their actual DDL/stream-manipulation purpose.
When implementing DDL, stream manipulation, projection, or network
features, expect to build them out from this state, likely pulling shared
logic from (or into) `shared/`.

Toolchain is pinned in `mise.toml`: Erlang 29, Gleam 1.18.

## Commands

All commands are run **from inside the package directory you're working
on** (`shared/`, `schema/`, `streams/`, `projections/`, or `network/`) —
there is no repo-wide build/test runner.

```sh
gleam deps download   # fetch dependencies (first run / after editing gleam.toml)
gleam build            # compile
gleam test             # run that package's test suite (gleeunit)
gleam format src test  # format
gleam format --check src test   # check formatting only (what CI runs)
gleam run              # run the package's main (apps only, not `shared`)
```

To run a single test module or test case, use gleeunit's filtering via
`gleam test`, e.g. from `shared/`:

```sh
gleam test -- --seed 1 dispatcher_test
```

(gleeunit runs every `..._test.gleam` file's exported `..._test()`
functions; there's no per-file flag beyond what `gleam test --` forwards to
the underlying `eunit` filter.)

CI (`.github/workflows/test.yml`, identical in every package) runs
`gleam deps download`, `gleam test`, then `gleam format --check src test` —
match that before considering work done.

`build/` directories (present per-package) are Gleam's compiled/dependency
output and are not source — never edit files under `*/build/`.

## Architecture notes

### `shared/asyncio` — actor pipeline for line-oriented job processing

A `reader` reads lines of input and forwards each as a job (`AddJob`) to a
`dispatcher` actor. The dispatcher owns a pool of `worker` actors bounded by
`max_worker_count`, keeping up to `max_idle_worker_count` idle workers
alive and stopping the rest; jobs queue (`Deque`) when all workers are
busy. A worker calls the caller-supplied `handle_input: fn(String) ->
String` and sends the result to a shared `writer` actor for output. Message
types for all four roles live centrally in `asyncio/messages.gleam`
(`DispatcherMessage`, `WorkerMessage`, `WriterMessage`); actors talk to each
other only through these, never through shared state.

The dispatcher stops gracefully rather than dropping in-flight work or
leaking its worker pool: `StopDispatcher` moves it through
`Ready -> Draining -> Stopping -> Stopped` (see the `DispatcherStatus` doc
comment in `dispatcher.gleam`) — draining lets already-queued jobs finish
while rejecting new `AddJob`s, then every worker is told to stop once it's
next idle, and only once every worker has been told to stop does the
dispatcher call `actor.stop()` itself. `dispatcher.stop(subject)` (mirroring
`writer.stop`) sends `StopDispatcher` and blocks until the actor has
actually exited — unlike `writer.stop`, with no fixed timeout, since
draining a backlog has no bound. It's the caller that started the
dispatcher's job to call it (see `streams.gleam`'s `main`, which does so
after `reader.read_loop` returns and before stopping the writer) —
`reader.gleam` itself still only fire-and-forgets `StopDispatcher` on the
quit sentinel and does not wait. The quit sentinel is `~quit` or its
abbreviation `~q`, matched after trimming trailing line-ending whitespace
so it's recognized whether or not the input's last line has a trailing
newline (`reader.gleam`'s `is_quit_sentinel`).

### `shared/hlc` — hybrid logical clock

Implements the algorithm in `docs/hlc/spec.md`: each clock value is a
15-character, base-62-encoded, lexicographically-sortable string
(8 chars physical-time-ms, 2 chars logical counter, 5 chars caller-assigned
node ID) sized to fit a PostgreSQL `char(15)` with no padding. `base62.gleam`
is the pure encode/decode; `clock_state.gleam` holds the per-node
`(time, counter, node_id)` state machine itself (`next()`/`next_parts()`
for local events, `merge()` on an incoming remote value per the spec's
merge rule) as plain functions over an opaque `ClockState` — no actor, no
`gleam/erlang`/`gleam/otp` dependency at all. `clock.gleam` is a thin
actor wrapper around it: it owns one `ClockState` as its own actor state
and, on every `ClockMessage`, calls straight through to
`clock_state.next`/`next_parts`/`merge` for the next state and reply
value. The split exists so a caller that only needs `HlcParts`/the state
machine (e.g. `streams/lang/dml_codegen.gleam`) can depend on
`clock_state.gleam` alone, without pulling in `gleam_otp`/`gleam_erlang`
— packages with no JavaScript-target support at all, which matters if
StruoDB ever needs a non-BEAM target. The
lexicographic-order-equals-value-order invariant (fixed-width, zero-padded
fields; monotonic alphabet) is load-bearing — any change to field widths or
the alphabet breaks it.

### The StruoDB query language front end (`lang/`, split across `shared`/`schema`/`streams`)

StruoDB's query language transpiles to PostgreSQL (see `docs/lang/spec.md`
for the full grammar). Expression parsing (`expr`, `data_type`) is one
grammar shared by two statement families with different package owners,
so `lang/` exists in three places, split by what's reused vs. what's
statement-family-specific — not kept in one module:

```
shared/src/lang/     token.gleam / lexer.gleam       — lexical layer
  (used by both       expr_ast.gleam / expr_parser.gleam — expr, data_type,
   schema & streams)                                    GeneratedClause, NamedCheck
                       expr_semantics.gleam            — column-reference checks
                       expr_codegen.gleam              — expr/data_type -> SQL text
                       token_stream.gleam              — token cursor
                       catalog.gleam — a stream's declared shape

schema/src/lang/     ddl_ast.gleam / ddl_parser.gleam    — CREATE/ALTER STREAM
  (DDL)               ddl_semantics.gleam
                       ddl_codegen.gleam — DdlStatement -> CREATE/ALTER TABLE SQL

streams/src/lang/    dml_ast.gleam / dml_parser.gleam    — INSERT
  (DML)               dml_semantics.gleam
                       dml_codegen.gleam — DmlStatement -> INSERT INTO SQL
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

- `token.gleam` / `lexer.gleam` (shared) — lexical layer: keywords are
  case-insensitive, unquoted identifiers fold to lower case, quoted
  identifiers (`"..."`) are case-sensitive, matching PostgreSQL convention.
  An unquoted identifier matching one of PostgreSQL's own reserved
  keywords (spec.md §3.5, ~101 words) is rejected at the lexer as
  `ReservedWord` rather than accepted as an `Identifier` — this is what
  lets a future codegen stage emit unquoted identifiers by default
  (content-based quoting only) instead of always-quoting, since no
  unquoted source identifier can ever collide with a PostgreSQL reserved
  word; see `docs/lang/codegen-plan.md`'s identifier-quoting design
  decision.
- `expr_ast.gleam` / `expr_parser.gleam` (shared) — expressions,
  `data_type` (spec.md §8–§9.1), and `GeneratedClause`/`NamedCheck` (§9.1,
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
  `AlterStream` shape (spec.md §9–§10) and the parser that builds it. Read
  `ddl_ast.gleam`'s header comment — it explains why some shapes (e.g.
  `ColumnDef` vs `StreamElement`) are structured the way they are for
  reuse across `CREATE`/`ALTER`.
- `dml_ast.gleam` / `dml_parser.gleam` (streams) — `Insert` shape (spec.md
  §11) and its parser.
- `ddl_semantics.gleam` (schema) / `dml_semantics.gleam` (streams) —
  validate a parsed statement against a `Catalog`. Each defines its own
  `SemanticError`, scoped to the variants it actually raises (no longer a
  full copy of the other's), and both call `expr_semantics.gleam` (above)
  for column-reference checks rather than keeping their own copy.

Only `CREATE STREAM`, `ALTER STREAM`, and `INSERT` are in scope so far;
querying/subscribing to a stream's events is explicitly out of scope per
the spec. `docs/lang/spec.md` §13 and its "Remaining open details" section
track settled-but-unimplemented and still-undecided points — check there
before assuming a gap in the code is a bug rather than known scope.

### Logging and errors

Actors use `birch` for structured logging (see `dispatcher.gleam` for the
convention: `log.debug_m("message", [#("key", value), ...])`). Gleam's
`use`/`case` idioms are used for control flow; `let assert` appears where a
failure is meant to crash the actor/test rather than be handled.

### Docs worth reading before working in a given area

- `docs/lang/spec.md` — full query language grammar (lexical + statements).
- `docs/lang/implementation-plan.md`, `docs/lang/codegen-plan.md` — planned
  work for the language front end and PostgreSQL codegen.
- `docs/hlc/spec.md`, `docs/hlc/implementation-plan.md` — HLC algorithm and
  planned work.
- `docs/todo.md` — outstanding code-review findings (currently none).
- `docs/references.md` — external references (CloudEvents, EventQL,
  PostgreSQL syntax docs) informing the design.
