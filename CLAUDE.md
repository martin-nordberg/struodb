# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

StruoDB is a distributed event-source database, written in Gleam (targeting
Erlang/OTP). It's a monorepo of five independent Gleam packages, each with
its own `gleam.toml`, `manifest.toml`, and CI workflow:

- **`shared/`** — library package with essentially all real logic so far:
  an async I/O actor pipeline (`asyncio/`), a hybrid logical clock
  (`hlc/`), and the StruoDB query language front end (`lang/`). Every
  other package depends on it via `shared = { path = "../shared" }`.
- **`schema/`** — application intended to handle schema-defining DDL
  commands.
- **`streams/`** — application intended to handle stream manipulation
  commands.
- **`projections/`** — application intended to handle projection
  behaviors.
- **`network/`** — application intended to maintain network configuration
  for the distributed database.

`schema`, `streams`, `projections`, and `network` are currently stubs
(a `main` that prints `"Hello from <name>!"` and a placeholder test) — they
exist as the intended service boundaries but have no logic yet. When
implementing DDL, stream manipulation, projection, or network features,
expect to build them out from this stub state, likely pulling shared logic
from (or into) `shared/`.

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
other only through these, never through shared state. See `docs/todo.md`
for known correctness gaps in the shutdown path (dispatcher exit racing
in-flight work, worker-leak on `StopDispatcher`, fragile quit-sentinel
matching in `reader`) before touching that code.

### `shared/hlc` — hybrid logical clock

Implements the algorithm in `docs/hlc/spec.md`: each clock value is a
15-character, base-62-encoded, lexicographically-sortable string
(8 chars physical-time-ms, 2 chars logical counter, 5 chars caller-assigned
node ID) sized to fit a PostgreSQL `char(15)` with no padding. `base62.gleam`
is the pure encode/decode; `clock.gleam` holds the per-node
`(time, counter, node_id)` state machine (`next()` for local events,
`receive()` on incoming messages per the spec's merge rule). The
lexicographic-order-equals-value-order invariant (fixed-width, zero-padded
fields; monotonic alphabet) is load-bearing — any change to field widths or
the alphabet breaks it.

### `shared/lang` — StruoDB query language front end

StruoDB's query language transpiles to PostgreSQL (see `docs/lang/spec.md`
for the full grammar). The pipeline is:

```
source text → lexer (token.gleam types) → parser → ast.gleam Statement
                                                        │
                                                        ▼
                                              semantic.gleam (validates)
                                                        │
                                                        ▼
                                          catalog.gleam (tracks a stream's
                                          declared shape as statements apply)
```

- `token.gleam` / `lexer.gleam` — lexical layer: keywords are
  case-insensitive, unquoted identifiers fold to lower case, quoted
  identifiers (`"..."`) are case-sensitive, matching PostgreSQL convention.
- `ast.gleam` — pure data shapes only (`CreateStream`, `AlterStream`,
  `Insert`, expressions, types); no logic. Read its header comment — it
  explains why some shapes (e.g. `ColumnDef` vs `StreamElement`) are
  structured the way they are for reuse across statement kinds.
- `parser.gleam` — builds `ast.gleam` values from tokens.
- `semantic.gleam` — validates a parsed `Statement` (currently the largest
  module besides the parser).
- `catalog.gleam` — tracks the accumulated, validated shape of a stream as
  `CREATE STREAM`/`ALTER STREAM` statements are applied to it.

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
- `docs/todo.md` — outstanding code-review findings (currently all in
  `shared/src/asyncio/`).
- `docs/references.md` — external references (CloudEvents, EventQL,
  PostgreSQL syntax docs) informing the design.
