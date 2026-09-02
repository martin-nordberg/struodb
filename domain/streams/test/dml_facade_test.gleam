import dml_facade
import gleam/string
import hlc/clock
import lang/catalog
import lang/ddl_parser
import lang/ddl_semantics
import lang/lexer
import lang/token_stream
import support/ref

//-----------------------------------------------------------------------------
// Exercises `dml_facade`'s actual JSON-in/JSON-out contract directly —
// not re-testing `dml_semantics`/`dml_codegen` themselves (those already
// have their own suites), just confirming this module wires them
// together and renders the two JSON shapes it promises. Builds its
// `Catalog` via schema's own `ddl_parser`/`ddl_semantics`, the same
// worked-example pattern `dml_codegen_test.gleam` already uses (see its
// header comment) — `schema` is a `streams` *dev* dependency for exactly
// this; `dml_facade.gleam` itself never imports it (see that module's
// header comment for why that boundary matters).
//-----------------------------------------------------------------------------

fn catalog_with_a_stream_named_s() -> catalog.Catalog {
  let assert Ok(tokens) = lexer.tokenize("CREATE STREAM s (a INT);")
  let assert Ok(stmt) = ddl_parser.parse(token_stream.new(tokens))
  let assert Ok(cat) = ddl_semantics.analyze(catalog.empty(), stmt)
  cat
}

fn a_next_hlc() -> fn() -> clock.HlcParts {
  let assert Ok(state) = clock.new("aaaaa", fn() { 1_700_000_000_000 })
  let cell = ref.new(state)
  fn() {
    let #(new_state, parts) = clock.next_parts(ref.get(cell))
    ref.set(cell, new_state)
    parts
  }
}

pub fn apply_insert_on_a_valid_statement_returns_ok_json_test() {
  let result =
    dml_facade.apply_insert(
      catalog_with_a_stream_named_s(),
      "INSERT INTO s (a) VALUES (1);",
      a_next_hlc(),
    )

  let assert True = string.contains(result, "\"ok\":true")
  let assert True = string.contains(result, "INSERT INTO s")
}

pub fn apply_insert_against_an_unknown_stream_returns_error_json_test() {
  let result =
    dml_facade.apply_insert(
      catalog.empty(),
      "INSERT INTO nonexistent (a) VALUES (1);",
      a_next_hlc(),
    )

  let assert True = string.contains(result, "\"ok\":false")
  let assert True = string.contains(result, "\"error\":")
}
