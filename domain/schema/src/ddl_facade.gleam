import gleam/json
import gleam/string
import lang/catalog.{type Catalog}
import lang/ddl_codegen

//-----------------------------------------------------------------------------
// The one module `service/src/bridges/schema-bridge.ts` imports from —
// everything else under `lang/` stays internal to this package. See
// documentation/plans/architecture/bun-typescript-migration-plan.md's
// "Facade layer" for the design this follows, and the note below for one
// way this module's actual shape differs from that plan.
//
// `source` (StruoQL text) and every function's *content* result cross the
// Gleam/TypeScript boundary as plain strings/JSON, never a Gleam ADT —
// that's the "hidden from TypeScript" promise. `Catalog` is the one
// deliberate exception, and it isn't really an exception to that promise:
// it crosses as an *opaque* value TypeScript only ever stores and hands
// back unchanged, never constructs or inspects (exactly like
// `hlc/clock.ClockState` — see `service/src/hlc-clock.ts`), so nothing
// TypeScript-visible ever needs to know `Catalog` has fields, let alone
// pattern-match on them.
//
// The migration plan's original sketch instead had `catalog_json: String`
// crossing the boundary, encoded/decoded via a new `Catalog ⇄ JSON` codec.
// Building that turned out to mean hand-writing a JSON encoding for the
// *entire* `lang/expr_ast.Expr`/`DataType` grammar too (`ColumnSchema`'s
// `default`/`generated` fields, and `NamedCheck`, all embed arbitrary
// `Expr` trees) — a large, separate undertaking, and not one this
// migration's facade layer needs to force: threading `Catalog` opaquely
// costs nothing (no serialization at all, since `schema-bridge.ts` and
// `streams-bridge.ts` run in the same TypeScript process) and — unlike a
// hand-rolled codec `streams`' facade would also need, to decode a
// `catalog_json` `schema` produced — keeps `streams`' production code
// depending on `shared` alone, never `schema`, exactly as documented in
// the root CLAUDE.md.
//-----------------------------------------------------------------------------

/// A fresh, empty catalog — the starting point before any `CREATE
/// STREAM` has been applied. A caller bootstrapping a new stream set
/// calls this once and threads the `Catalog` each `apply_ddl` call
/// returns into the next.
pub fn empty_catalog() -> Catalog {
  catalog.empty()
}

/// Validates and translates every `CREATE STREAM`/`ALTER STREAM`
/// statement in `source` against `catalog` (in order, threaded across
/// them exactly as `ddl_codegen.generate` already does), returning
/// `#(result_json, updated_catalog)`. `updated_catalog` is `catalog`
/// itself, unchanged, whenever `result_json` reports failure.
///
/// `result_json` is one of:
///   `{"ok": true, "sql": "<generated CREATE/ALTER TABLE text>"}`
///   `{"ok": false, "error": "<lex/parse/semantic failure description>"}`
pub fn apply_ddl(catalog: Catalog, source: String) -> #(String, Catalog) {
  case ddl_codegen.generate(catalog, source) {
    Ok(#(sql, updated_catalog)) -> #(ok_json(sql), updated_catalog)
    Error(err) -> #(error_json(err), catalog)
  }
}

//-----------------------------------------------------------------------------

fn ok_json(sql: String) -> String {
  json.object([#("ok", json.bool(True)), #("sql", json.string(sql))])
  |> json.to_string
}

/// Renders any `ddl_codegen.CodegenError` via `string.inspect` rather
/// than a hand-written message per variant (there are 3 top-level
/// variants, one of which wraps a whole `List(ddl_semantics.
/// SemanticError)`, itself several variants deep) — a reasonable scope
/// cut for this early facade; a caller that needs to branch on *which*
/// failure occurred, rather than just display one, still has the real
/// `ddl_codegen.generate`/`CodegenError` to call directly from Gleam
/// code (e.g. a future test or another Gleam-side caller), just not
/// through this string/JSON boundary.
fn error_json(err: ddl_codegen.CodegenError) -> String {
  json.object([
    #("ok", json.bool(False)),
    #("error", json.string(string.inspect(err))),
  ])
  |> json.to_string
}
