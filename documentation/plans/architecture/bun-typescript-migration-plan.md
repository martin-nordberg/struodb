# Bun / TypeScript Migration — Architecture Plan

Converts StruoDB from Erlang/OTP-targeted Gleam applications to Gleam
compiled for the **JavaScript target**, run on **Bun**, with **TypeScript**
as the outer application layer. Domain logic stays in Gleam; it is reached
from TypeScript only through small string/JSON-in, string/JSON-out facade
functions, moving toward the hexagonal split explored in
`documentation/docs/public/x-designs/ideas/Gleam-TypeScript-Hexagonal-Architecture.pdf`
("driving adapter" and "driven adapter" in TypeScript, "pure domain core"
in Gleam).

## Scope

**In scope**: moving every package's build target to `javascript`, moving
the five Gleam packages under a new `domain/` folder, deleting `asyncio`
and its demo `main`, replacing `hlc/clock_keeper.gleam`'s actor with
TypeScript-held state, introducing a facade layer per Gleam package, and
standing up one TypeScript application (`service/`) that drives those
facades. CI, `mise.toml`, and root tooling change to match.

**Out of scope (deferred)**: an HTTP layer (Hono or otherwise), real
PostgreSQL persistence, and splitting `service/` into one process per
domain — these are the PDF's eventual destination, not this migration.
Today there is no database connectivity code anywhere in the repo (only
SQL text codegen), so there is no "driven adapter" to port yet — this plan
only builds the "driving adapter" (a TS entry point calling into Gleam)
half of the hexagon. `network`/`projections` stay stub packages; they get
the same target/layout conversion as everything else but no new facade,
since they have no real logic yet (per the root `CLAUDE.md`).

## Decisions carried over from discussion

- **TypeScript app layout**: one unified app for now — `service/` at the
  repo root (sibling to `domain/`), not one app per domain package.
  `service/` imports facades from whichever `domain/*` packages it needs.
  Splitting into per-service apps later is a matter of adding another
  workspace entry, not restructuring anything (see "Target repository
  layout" below).
- **HLC global state**: an *instantiated* singleton, not a bare module-level
  `let`. TypeScript owns an `HlcClock` class wrapping the compiled
  `hlc/clock` state; the application's composition root (`service/src/
  main.ts`) constructs the one instance the process uses and passes it to
  whatever needs it. This replaces `hlc/clock_keeper.gleam`'s actor
  one-for-one: same "one clock per process, called synchronously"
  contract, but the state now lives in a plain TS object instead of an
  Erlang process's mailbox loop. See "HLC clock" below.
- **TypeScript package management**: a root Bun workspace. One root
  `package.json` with a `workspaces` field, one `bun.lock`, shared
  `devDependencies` (TypeScript, a linter/formatter, a test runner) —
  not an independent `package.json` per app. With only `service/` to
  start, `workspaces: ["service"]` is enough; it grows by adding entries,
  never by restructuring.
- **Facade contract**: every exported facade function takes plain strings
  in (StruoQL source text, plus whatever state the call needs, as JSON)
  and returns a plain string out (JSON) — never a Gleam custom type in
  a TypeScript-visible signature. See "Facade layer" below for the one
  narrow, deliberate exception (the TypeScript **bridge** file, not the
  facade itself, is allowed to touch compiled Gleam types — see that
  section for why the exception has to exist and why it doesn't leak
  further than the bridge).

## Target repository layout

```
struodb/
  domain/
    shared/          # gleam.toml, src/, test/ — unchanged internal layout
    schema/
    streams/
    network/
    projections/
  service/
    package.json
    tsconfig.json
    src/
      main.ts                 # composition root: builds HlcClock, wires bridges
      hlc-clock.ts             # TS-held HLC state (replaces clock_keeper.gleam)
      bridges/
        schema-bridge.ts       # only file that imports domain/schema's compiled JS
        streams-bridge.ts      # only file that imports domain/streams's compiled JS
    test/
      hlc-clock.test.ts
      schema-bridge.test.ts
      streams-bridge.test.ts
  documentation/       # unchanged — already its own Bun project
  package.json         # root: Bun workspaces, shared devDependencies
  bun.lock
  mise.toml            # drops `erlang`
  .github/workflows/   # if consolidated — see "CI" below
  README.md
  CLAUDE.md
```

Every `domain/*` package keeps its own `gleam.toml`/`manifest.toml`/
`src/`/`test/` exactly as today (relative `path = "../shared"`
dependencies keep working unchanged — only the parent directory moves).
There is still no repo-wide Gleam build/test runner; `domain/*` commands
are still run from inside each package directory. `service/` is the one
new top-level thing with its own build/test/run commands.

## Phase 1 — Delete asyncio and its demo main

Delete outright (no replacement — this was `shared`'s original
actor-pipeline exercise, not load-bearing for anything real):

- `shared/src/asyncio/` (`dispatcher.gleam`, `messages.gleam`,
  `reader.gleam`, `worker.gleam`, `writer.gleam`)
- `shared/test/asyncio/` (`dispatcher_test.gleam`, `reader_test.gleam`,
  `worker_test.gleam`, `writer_test.gleam`)
- `shared/test/support.gleam` — exists solely for the `asyncio` test
  suites' `wait_until_stopped` helper (confirmed: its only importers are
  the four files above plus `clock_keeper_test.gleam`, which Phase 3 also
  deletes); nothing else references it.
- `streams/src/streams.gleam` — today's `main` is asyncio demo wiring
  (`dispatcher`/`reader`/`writer`, `birch` logging, the `in` package for
  stdin), unrelated to `streams`' actual DML logic per the root
  `CLAUDE.md`. It is replaced by `streams/src/facade.gleam` (Phase 4) —
  there is no more `main` on the Gleam side for `streams` at all, matching
  how `shared/` already has no top-level `shared.gleam`.

This is what drops `gleam_otp`, `gleam_erlang`, `gleam_deque`, `in`, and
`birch` from the dependency graph entirely (confirmed by grepping every
non-asyncio, non-`clock_keeper` source file: none of them import
`gleam/otp`, `gleam/erlang`, `gleam/deque`, `in`, or `birch`). `gleam_time`
goes with it too — its only real importer was `streams.gleam`'s
`system_now_ms`, which moves to TypeScript's `Date.now()` (Phase 3).

## Phase 2 — Move packages under `domain/`

Straight directory moves, preserving git history:

```sh
mkdir domain
git mv shared domain/shared
git mv schema domain/schema
git mv streams domain/streams
git mv network domain/network
git mv projections domain/projections
```

Nothing inside any package needs path changes: `path = "../shared"` in
`domain/schema/gleam.toml` etc. still resolves correctly since the sibling
relationship between packages is unchanged, only their shared parent
directory. Each package's own `.gitignore` (`/build`, etc.) and
`.github/workflows/test.yml` move with it unchanged in content (workflow
content changes in Phase 6, but the file's repo path is now
`domain/<pkg>/.github/workflows/test.yml`).

## Phase 3 — Convert every domain package to the JavaScript target

For each of `domain/{shared,schema,streams,network,projections}/gleam.toml`:

```toml
target = "javascript"
```

(`shared`'s `gleam.toml` already has an explicit `target = "erlang"` line
to change; the other four currently have no `target` line, defaulting to
`erlang` — add the line rather than relying on a default that will one day
change upstream.)

Prune dependencies no longer used after Phase 1's deletions:

- `domain/shared/gleam.toml`: drop `gleam_otp`, `gleam_erlang`,
  `gleam_deque`, `in`, `birch`, `gleam_time`. Left with `gleam_stdlib`
  (prod) and `gleeunit` (dev) — same shape as `schema`/`network`/
  `projections` already have today.
- `domain/streams/gleam.toml`: drop `in`, `birch`, `gleam_erlang`,
  `gleam_time`. Its `schema = { path = "../schema" }` dev dependency (used
  only by `dml_semantics_test.gleam`'s worked example, per the existing
  comment in that file) stays — it's pure Gleam-to-Gleam, unaffected by
  target.
- `domain/schema/gleam.toml`, `domain/network/gleam.toml`,
  `domain/projections/gleam.toml`: no change needed — they only ever
  depended on `gleam_stdlib` and `shared`.

Add `gleam_json` (a `path`/Hex dependency already pulled in transitively
today — confirmed present under `schema/build/packages/gleam_json/` from
an earlier `gleam deps download`) as a direct dependency of `domain/schema`
and `domain/streams`, for their facades' JSON encode/decode (Phase 4).

`gleam test`/`gleam run` need a runtime flag on the JS target:

```sh
gleam test --target javascript --runtime bun
gleam run --target javascript --runtime bun
```

(Confirmed against the installed `gleam 1.18.1` CLI: `-t/--target` accepts
`erlang`/`javascript`, and `--runtime` — `nodejs`/`deno`/`bun` — is only
meaningful once `--target javascript` is set. With `target = "javascript"`
now in every `gleam.toml`, `-t` can be dropped from the command line;
`--runtime bun` still needs to be passed explicitly on the CLI, or
recorded in `gleam.toml` if this Gleam version supports a persisted
runtime setting — check `gleam.toml`'s reference docs for the installed
1.18.x version before committing to which of the two this plan's CI/dev
scripts use.) `gleeunit` runs on both targets already, so no test-runner
change is needed beyond this flag.

Drop `erlang` from the root `mise.toml`: nothing targets `erlang` anymore,
and the `gleam` CLI itself is a standalone binary with no Erlang/OTP
runtime dependency — it never needed `erlang` installed to run the JS
target, only to install/verify a toolchain that's no longer used.

```toml
[tools]
bun = "1.4.0"
gleam = "1.18"
```

## Phase 4 — HLC clock: TypeScript-held state

`hlc/clock.gleam` (the pure `(time, counter, node_id)` state machine) is
**already** free of `gleam/erlang`/`gleam/otp` — it was split out from the
actor for exactly this kind of portability (see its own header comment).
It needs no change and compiles to the JS target as-is.

`hlc/clock_keeper.gleam` (the actor wrapper) is **deleted** — its whole
job was giving a `gleam_otp` actor a `Subject` to serialize concurrent
access to one `ClockState`; a single-threaded Bun process calling
synchronous functions doesn't need that serialization mechanism, only the
state itself, held somewhere.

New: `service/src/hlc-clock.ts`

```typescript
import * as clock from "../../domain/shared/build/dev/javascript/shared/hlc/clock.mjs";
// clock.ClockState is opaque (a Gleam-generated class); this file never
// inspects its shape, only threads instances through clock.new/next/
// next_parts/merge — the same "call straight through, hold the returned
// state" job clock_keeper.gleam's handle_message used to do per message.

export class HlcClock {
  #state: clock.ClockState;

  private constructor(state: clock.ClockState) {
    this.#state = state;
  }

  /** `nodeId` must be exactly 5 base-62 characters — see hlc-spec.md.
   *  `now` defaults to Date.now, overridable for tests. */
  static create(nodeId: string, now: () => number = Date.now): HlcClock {
    const result = clock.new_(nodeId, now); // `new` is reserved in JS output
    if (!result.isOk()) throw new Error(describeHlcError(result[0]));
    return new HlcClock(result[0]);
  }

  next(): string {
    const [state, value] = clock.next(this.#state);
    this.#state = state;
    return value;
  }

  /** Returns the decomposed HlcParts record itself — kept as the compiled
   *  Gleam type, not flattened to a plain object. This is fine: nothing
   *  outside `service/src/bridges/*` (Phase 5) ever calls nextParts()
   *  directly — application code only ever sees strings/JSON via a
   *  bridge's own typed wrapper. */
  nextParts(): clock.HlcParts {
    const [state, parts] = clock.next_parts(this.#state);
    this.#state = state;
    return parts;
  }

  merge(remote: string): string {
    const result = clock.merge(this.#state, remote);
    if (!result.isOk()) throw new Error(describeHlcError(result[0]));
    this.#state = result[0][0];
    return result[0][1];
  }
}
```

(Exact compiled-JS call shapes — constructor function naming, `Result`
representation — need to be checked against real `gleam build --target
javascript` output for this Gleam version once Phase 3 lands; the sketch
above is illustrative of the wrapping pattern, not a verified API.)

`main.ts` constructs one `HlcClock` per process (`HlcClock.create(nodeId,
Date.now)`) and passes it to whichever bridge needs it (today, only
`streams-bridge.ts`, for `INSERT`'s per-row HLC stamping) — this is the
"composition root builds it once, passes it explicitly" pattern the old
`implementation-plan.md` chose for the actor `Subject`, carried over
unchanged in spirit now that the handle is a TS object instead.

`node_id` sourcing (today a `"node1"` placeholder constant in
`streams.gleam`'s `main`) becomes a TS-side concern — e.g. read from an
environment variable in `main.ts`, with the same "must be exactly 5
base-62 characters" contract `hlc/clock.gleam`'s `new` already validates.
Not otherwise specified by this plan; a real value/config source is a
deployment concern for later.

**Test-side fallout**: `streams/test/lang/dml_codegen_test.gleam` currently
builds its `next_hlc: fn() -> clock.HlcParts` test helper by starting a
real `clock_keeper` actor (`clock_keeper.start` + `clock_keeper.next_parts`
— see `dml-codegen-hlc-injection` in project memory). With `clock_keeper`
deleted, that helper switches to calling `clock.new`/`clock.next_parts`
directly against a local, test-owned `ClockState` — simpler than before
(no actor to start/stop per test), and it was already the direction the
memory's own "How to apply going forward" note pointed at.

## Phase 5 — Facade layer (Gleam side)

New per-package facade module, `domain/<pkg>/src/facade.gleam` — the one
file each package exports to TypeScript. It is the only Gleam module a
`service/src/bridges/*.ts` file imports from that package; everything else
under `domain/<pkg>/src/lang/` stays purely internal.

Rule: every `pub fn` in `facade.gleam` takes and returns only `String`
(StruoQL source text in; JSON text out) — no `Catalog`, `DdlStatement`,
`SemanticError`, or any other `lang/` ADT ever appears in a `facade.gleam`
signature. This is what makes "Gleam ADT types fully hidden from
TypeScript" true at the boundary TypeScript code actually calls.

Sketch, `domain/schema/src/facade.gleam`:

```gleam
import gleam/json
import lang/catalog
import lang/ddl_codegen
import lang/ddl_parser
import lang/ddl_semantics

/// `catalog_json` is the stream's current shape, as previously returned
/// by this same function (or `"{}"` for a brand-new stream) — round-
/// tripped through TypeScript rather than held in a Gleam-side actor or
/// global, so the caller decides how/where it's persisted between calls.
/// Returns JSON: `{"ok": true, "sql": "...", "catalog": {...}}` on
/// success, or `{"ok": false, "errors": [...]}` on failure.
pub fn apply_ddl(catalog_json: String, source: String) -> String {
  ...
}
```

Sketch, `domain/streams/src/facade.gleam` — the one place `next_hlc: fn()
-> clock.HlcParts` (Phase 4's supplier shape, unchanged from today's
`dml_codegen.generate`) still appears in a Gleam signature:

```gleam
import hlc/clock

pub fn apply_insert(
  catalog_json: String,
  source: String,
  next_hlc: fn() -> clock.HlcParts,
) -> String {
  ...
}
```

This is the one deliberate exception to "no Gleam ADTs in a TS-visible
signature," and it doesn't actually violate the rule: `next_hlc` is a
*function value*, and the only TypeScript file allowed to construct one
that satisfies it (by calling `HlcClock.nextParts()` and handing the
result straight back into compiled Gleam) is `streams-bridge.ts` — see
Phase 6. `service/src/main.ts` and everything else in the application only
ever calls `streamsBridge.applyInsert(catalogJson, source): string`, never
`facade.apply_insert` directly. Passing the HLC values through JSON
instead (pre-drawing N values in TypeScript before the row count is even
known, since that requires parsing the statement first) was considered
and rejected as solving a problem the bridge/facade split doesn't actually
have — the callback crossing the boundary is exactly what a bridge file is
for.

A `Catalog` ⇄ JSON codec (`lang/catalog` doesn't have one today) is new
work this phase adds — `gleam_json`'s encoders/decoders, one function each
direction, living in `shared/src/lang/catalog.gleam` itself (or a sibling
`catalog_json.gleam`) so both `schema/facade.gleam` and
`streams/facade.gleam` (which also needs to decode an incoming
`catalog_json` for `dml_semantics.analyze`) share one definition of the
JSON shape rather than two independently-written ones.

## Phase 6 — TypeScript bridge + `service/` app

`service/src/bridges/schema-bridge.ts` / `streams-bridge.ts` are the only
files under `service/` that import a `domain/*/build/dev/javascript/...`
path directly — isolating the untyped boundary the PDF calls out (Gleam
doesn't emit `.d.ts`) to one file per domain package, per its own
"Automate the Type Bridge" recommendation, rather than a hand-maintained
tree of `.d.ts` files (which would need regenerating whenever a `build/`
directory — gitignored, ephemeral — is rebuilt).

```typescript
// service/src/bridges/streams-bridge.ts
// @ts-expect-error — no .d.ts for compiled Gleam output; this file is the
// one sanctioned place that's allowed to know that.
import * as streamsFacade from "../../../domain/streams/build/dev/javascript/streams/facade.mjs";
import { HlcParts } from "../../../domain/shared/build/dev/javascript/shared/hlc/clock.mjs";
import type { HlcClock } from "../hlc-clock.ts";

export function applyInsert(
  clock: HlcClock,
  catalogJson: string,
  source: string,
): string {
  return streamsFacade.apply_insert(catalogJson, source, () =>
    clock.nextParts(),
  );
}
```

`schema-bridge.ts` is the same shape, minus the HLC parameter.

`service/src/main.ts` is the composition root: builds one `HlcClock`,
reads StruoQL input from wherever this phase's caller is (still
unspecified/deferred — no HTTP layer yet; a minimal first cut can be a
CLI reading stdin, mirroring what `reader.gleam` used to do, or a small
hardcoded smoke-test call), and calls `schemaBridge.applyDdl(...)` /
`streamsBridge.applyInsert(...)`, printing/returning their JSON output.

**Build ordering**: `service/`'s bridges import from `domain/*/build/`,
which is gitignored and only exists after `gleam build --target
javascript` has run in that package. `service/package.json` needs a
`predev`/`pretest`/`prebuild` script (or root-level orchestration — see
Phase 7) that runs `gleam build --target javascript` in every
`domain/*` package it depends on before Bun touches `service/`.

## Phase 7 — Root Bun workspace and scripts

`package.json` (repo root, new):

```json
{
  "private": true,
  "workspaces": ["service"],
  "devDependencies": {
    "typescript": "^5",
    "@types/bun": "^1"
  },
  "scripts": {
    "build:domain": "for p in domain/*/; do (cd \"$p\" && gleam build --target javascript); done",
    "test:domain": "for p in domain/*/; do (cd \"$p\" && gleam test --target javascript --runtime bun); done",
    "format:domain:check": "for p in domain/*/; do (cd \"$p\" && gleam format --check src test); done"
  }
}
```

`service/package.json` depends on the root workspace for shared
`devDependencies`; its own `dev`/`build`/`test` scripts run
`bun run build:domain` (via the root, e.g. `bun run --cwd .. build:domain`)
before `bun run src/main.ts` / `bun test`.

## Phase 8 — CI

Each `domain/*/.github/workflows/test.yml` currently runs (identically):
`erlef/setup-beam` (OTP 29, Gleam 1.18.1, rebar3) → `gleam deps download`
→ `gleam test` → `gleam format --check src test`. Replace `erlef/setup-beam`
— installing an OTP/rebar3 toolchain the JS target never touches — with a
toolchain install straight from this repo's own pinned `mise.toml` (e.g.
`jdx/mise-action`, which installs everything `mise.toml` lists — now just
`gleam` and `bun`), then:

```yaml
- uses: actions/checkout@v7
- uses: jdx/mise-action@v2
- run: gleam deps download
- run: gleam test --target javascript --runtime bun
- run: gleam format --check src test
```

`service/`'s own new workflow (`service/.github/workflows/test.yml` or a
root-level one) additionally needs `domain/`'s packages built first
(`bun run build:domain` from the repo root) before `bun test` in
`service/`, since its bridges import their compiled output.

Whether to keep one workflow file per `domain/*` package (current
convention — each package's CI is fully independent) or consolidate into
one root workflow now that a `service/` build genuinely depends on
multiple `domain/*` packages being built first is worth deciding during
implementation rather than up front here; either preserves per-package
`gleam test` isolation, since `service/`'s own job can simply run
`build:domain` itself rather than depending on the other jobs' status.

## Phase 9 — Docs

- Root `CLAUDE.md`: rewrite "What this is" and "Commands" for the new
  `domain/`/`service/` split, the JS/Bun target, and the removal of
  `asyncio`; "Architecture notes" loses its `shared/asyncio` section
  entirely and gains a `service/` + facade/bridge section; the HLC section
  updates to describe `HlcClock` (TypeScript) in place of `clock_keeper`
  (actor) as `clock.gleam`'s consumer.
- `documentation/CLAUDE.md` and `documentation/docs/specifications/...`:
  update any repo-relative paths that assumed the pre-`domain/` layout
  (e.g. `shared/src/lang/...` becomes `domain/shared/src/lang/...`) —
  grep the whole `documentation/` tree for the five package names once the
  move lands, rather than trying to enumerate every hit here.
- `README.md`: currently a two-line description with no structure section
  to update — optionally add one once `domain/`/`service/` exist.

## Test plan

- **Gleam side**: existing `gleeunit` suites in every `domain/*/test/`
  keep running as-is (`gleam test --target javascript --runtime bun`) —
  none of `shared/test/hlc/base62_test.gleam` or any `lang/` test module
  touches `gleam/erlang`/`gleam/otp`, so none of them change behavior
  under the JS target. New: a `facade_test.gleam` per package exercising
  `facade.gleam`'s JSON-in/JSON-out contract directly (still a Gleam test,
  since the facade itself is Gleam) — success and error-JSON shapes for
  at least one DDL and one INSERT case.
- **TypeScript side** (new, `service/test/`, via `bun test`):
  `hlc-clock.test.ts` — construction validation (bad node ID length/
  characters rejected), monotonically increasing `next()` values under an
  injected fixed/stepped `now`, `merge()` behavior — essentially porting
  `clock_keeper_test.gleam`'s assertions to the new TS-held state, since
  that's the one piece of logic actually moving language. `schema-
  bridge.test.ts`/`streams-bridge.test.ts` — thin: confirm a bridge call
  round-trips real compiled Gleam output correctly (call with valid
  StruoQL, assert on the parsed-back JSON shape), not re-testing
  `ddl_semantics`/`dml_semantics` logic itself (that's `facade_test.gleam`
  and the existing `lang/` suites' job).
- CI (Phase 8) is what actually proves the JS-target conversion works end
  to end for every package, not just `shared`/`streams` (the two with
  interesting logic) — run it for `network`/`projections` too even though
  their `main`s stay trivial stub prints.

## Step-by-step build order

1. Phase 1: delete `asyncio`, `clock_keeper.gleam` + its test,
   `test/support.gleam`, `streams.gleam`'s demo `main`. Confirm each
   package still builds/tests under the *existing* `erlang` target before
   moving on — isolates "did the deletion break anything" from "did the
   target switch break anything."
2. Phase 2: `git mv` the five packages under `domain/`. Confirm `gleam
   build`/`gleam test` still pass from inside each `domain/<pkg>/`
   (relative `path = "../shared"` deps, still on `erlang` target).
3. Phase 3: flip `target = "javascript"` and prune dependencies, one
   package at a time, `shared` first (nothing else can build against it
   otherwise), then `schema`/`network`/`projections`/`streams` in any
   order. `gleam test --target javascript --runtime bun` after each.
4. Phase 4: delete `clock_keeper.gleam`; write `dml_codegen_test.gleam`'s
   direct `clock.new`/`clock.next_parts` replacement helper.
5. Phase 7 (root tooling) before Phase 5/6, so there's a `bun install`-able
   workspace and a `build:domain` script to develop the facades/bridges
   against as they're written.
6. Phase 5: write `domain/schema/src/facade.gleam` and
   `domain/streams/src/facade.gleam` (plus the shared `Catalog` ⇄ JSON
   codec), and each one's `facade_test.gleam`.
7. Phase 6: write `service/src/hlc-clock.ts`,
   `service/src/bridges/{schema,streams}-bridge.ts`, `service/src/main.ts`,
   and their `bun test` suites — verified against real `gleam build
   --target javascript` output, not the illustrative sketches above.
8. Phase 8: update CI workflows; confirm green on a real PR/branch, not
   just locally.
9. Phase 9: update `CLAUDE.md`s and any stale doc paths.

## Explicitly deferred (not decided by this plan)

- How/where `catalog_json` is actually persisted between calls (a file, a
  real Postgres table, an in-memory map in `main.ts` — this plan only
  fixes the *shape* crossing the boundary, not its storage).
- `node_id` sourcing/config for a real (non-single-process) deployment.
- Any HTTP layer (Hono) or real driven adapter (PostgreSQL via
  Drizzle/`pg`) — the PDF's "eventual aim," intentionally not started
  here.
- Splitting `service/` into per-domain apps — the workspace shape (Phase
  7) is chosen so this is additive later, not a decision to make now.
- Whether CI consolidates to one root workflow or stays one-per-package
  (Phase 8) — left as an implementation-time call.
