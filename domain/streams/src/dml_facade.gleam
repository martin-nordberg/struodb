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
///   `{"ok": true, "sql": "<generated INSERT text>"}`
///   `{"ok": false, "error": "<lex/parse/semantic failure description>"}`
///
/// `INSERT` never changes a stream's shape (see `dml_codegen.generate`),
/// so unlike `schema/ddl_facade.apply_ddl` this returns only the result —
/// there is no updated `Catalog` to hand back.
pub fn apply_insert(
  catalog: Catalog,
  source: String,
  next_hlc: fn() -> HlcParts,
) -> String {
  case dml_codegen.generate(catalog, source, next_hlc) {
    Ok(#(sql, _catalog_unchanged)) -> ok_json(sql)
    Error(err) -> error_json(err)
  }
}

//-----------------------------------------------------------------------------

fn ok_json(sql: String) -> String {
  json.object([#("ok", json.bool(True)), #("sql", json.string(sql))])
  |> json.to_string
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
