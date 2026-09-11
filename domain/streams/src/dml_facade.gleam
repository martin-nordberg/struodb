import gleam/json
import gleam/string
import hlc/clock.{type HlcParts}
import lang/catalog.{type Catalog}
import lang/dml_codegen

//-----------------------------------------------------------------------------
// The one module `service/src/bridges/streams-bridge.ts` imports from —
// everything else under `lang/` stays internal to this package. See
// `domain/schema/src/ddl_facade.gleam`'s header comment for the "content
// crosses as JSON, `Catalog` crosses as an opaque handle" design both
// facades share, and why.
//
// `next_hlc: fn() -> HlcParts` is the one Gleam function type appearing
// directly in this module's public signature — `dml_codegen.generate`
// already took exactly this shape (see its own doc comment) before this
// facade existed, and only `streams-bridge.ts` (never application code)
// ever constructs a closure to satisfy it, by calling a TypeScript-held
// `HlcClock`'s `nextParts()` — see `service/src/hlc-clock.ts`.
//-----------------------------------------------------------------------------

/// Validates and translates every `INSERT` statement in `source` against
/// `catalog`, drawing one fresh HLC value per row (via `next_hlc`) —
/// see `dml_codegen.generate`'s own doc comment for exactly how. Returns
/// JSON:
///   `{"ok": true, "statements": [{"sql": "<generated INSERT text>",
///     "stream_name": "<target stream>", "has_returning": true|false},
///     ...]}` — one entry per `INSERT` statement in `source`, in order.
///     See
///     documentation/plans/architecture/event-collector-implementation-plan.md,
///     Phase 1, for why a caller needs `stream_name`/`has_returning` per
///     statement (to execute and interpret each one on its own) but not
///     an aggregator count (the caller already has
///     `aggregators_for_stream` to look that up itself).
///   `{"ok": false, "error": "<lex/parse/semantic failure description>"}`
///
/// `INSERT` never changes a stream's shape (see `dml_codegen.generate`),
/// so unlike `schema/ddl_facade.apply_ddl` this returns only the result —
/// there is no updated `Catalog` to hand back.
///
/// `aggregators_for_stream: fn(String) -> List(Int)` is the other
/// function type in this module's public signature, alongside
/// `next_hlc` — same "only the bridge ever constructs this closure"
/// rule, built from Event Store Configuration on the TypeScript side
/// (see
/// documentation/plans/architecture/event-store-implementation-plan.md).
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

//-----------------------------------------------------------------------------

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

/// Renders any `dml_codegen.CodegenError` via `string.inspect` — see
/// `schema/ddl_facade.gleam`'s `error_json` for why (same scope cut, same
/// shape of error type, one package over).
fn error_json(err: dml_codegen.CodegenError) -> String {
  json.object([
    #("ok", json.bool(False)),
    #("error", json.string(string.inspect(err))),
  ])
  |> json.to_string
}
