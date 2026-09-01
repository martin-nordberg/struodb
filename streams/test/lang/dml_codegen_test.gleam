import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import hlc/clock.{type ClockMessage}
import lang/catalog
import lang/ddl_parser
import lang/ddl_semantics
import lang/dml_ast as ast
import lang/dml_codegen
import lang/dml_semantics
import lang/expr_ast as xast
import lang/expr_codegen
import lang/expr_parser
import lang/lexer
import lang/token
import lang/token_stream

//-----------------------------------------------------------------------------
// Built directly against dml_ast, not via the parser, so these stay
// independent of parser correctness — same reasoning as
// dml_semantics_test.gleam. "..._end_to_end_test" below is the
// exception: going through the real lexer/parser/semantics is the whole
// point there. `schema/ddl_parser`/`ddl_semantics` (already a `streams`
// dev dependency — see CLAUDE.md) build a realistic `Catalog` to
// validate the worked example's `INSERT` against, the same way
// dml_semantics_test.gleam already does.
//-----------------------------------------------------------------------------

fn dummy_span() -> token.Span {
  let pos = token.Position(line: 1, column: 1, byte_offset: 0)
  token.Span(pos, pos)
}

fn col_ref(name: String) -> xast.Expr {
  xast.ColumnRef(name, dummy_span())
}

//-----------------------------------------------------------------------------
// A deterministic clock for exact-string assertions: fixed `now`, so
// every `next()`/`next_parts()` draw advances only the counter, never
// the physical time — see `hlc/clock.gleam`'s own `advance`. Two
// independently-started clocks with the same node id and `now` tick in
// lockstep, so a test can call `next_parts` on a second, "expected"
// clock the same number of times, in the same order, that
// `dml_codegen` draws from the real one, and build the expected SQL
// from those parts instead of hand-computing base-62 encodings.
//-----------------------------------------------------------------------------

fn fixed_now() -> Int {
  1_700_000_000_000
}

fn test_clock() -> Subject(ClockMessage) {
  let assert Ok(c) = clock.start("aaaaa", fixed_now)
  c
}

/// Mirrors `dml_codegen.gleam`'s own (private) system-column value
/// rendering, so expected strings below are built from the same
/// public building blocks the real codegen uses, not duplicated
/// base-62/formatting logic.
fn system_values_sql(parts: clock.HlcParts) -> String {
  expr_codegen.quote_string_literal(parts.encoded)
  <> ", to_timestamp("
  <> seconds_literal(parts.physical_time_ms)
  <> "), "
  <> int.to_string(parts.counter)
  <> ", "
  <> int.to_string(parts.node_id)
}

fn seconds_literal(ms: Int) -> String {
  int.to_string(ms / 1000)
  <> "."
  <> string.pad_start(int.to_string(ms % 1000), to: 3, with: "0")
}

//-----------------------------------------------------------------------------
// spec.md §11.7's worked example
//-----------------------------------------------------------------------------

fn insert_example() -> ast.DmlStatement {
  ast.Insert(
    stream_name: "sensor_reading",
    columns: ["reading", "units", "sensor_id"],
    rows: [
      [
        ast.ValueExpr(xast.NumericLiteral("42.5")),
        ast.ValueExpr(xast.StringLiteral("celsius")),
        ast.ValueExpr(xast.StringLiteral("sensor-001")),
      ],
    ],
    on_conflict_do_nothing: True,
    returning: Some([ast.ReturningExpr(col_ref(catalog.hlc_column_name), None)]),
    span: dummy_span(),
  )
}

/// The one row above draws exactly one `next_parts`.
fn insert_expected_sql(parts: clock.HlcParts) -> String {
  "INSERT INTO sensor_reading (_struo_hlc, _struo_hlc_timestamp, _struo_hlc_count, _struo_hlc_node_id, reading, units, sensor_id)\nVALUES\n  ("
  <> system_values_sql(parts)
  <> ", 42.5, 'celsius', 'sensor-001')\nON CONFLICT DO NOTHING\nRETURNING _struo_hlc;"
}

pub fn insert_matches_the_spec_worked_example_test() {
  let clock = test_clock()
  let parts = clock.next_parts(test_clock())
  assert dml_codegen.insert_to_sql(insert_example(), clock)
    == insert_expected_sql(parts)
}

pub fn insert_with_a_default_value_and_no_on_conflict_or_returning_test() {
  let stmt =
    ast.Insert(
      stream_name: "s",
      columns: ["a", "b"],
      rows: [[ast.ValueExpr(xast.IntLiteral("1")), ast.ValueDefault]],
      on_conflict_do_nothing: False,
      returning: None,
      span: dummy_span(),
    )
  let clock = test_clock()
  let parts = clock.next_parts(test_clock())
  assert dml_codegen.insert_to_sql(stmt, clock)
    == "INSERT INTO s (_struo_hlc, _struo_hlc_timestamp, _struo_hlc_count, _struo_hlc_node_id, a, b)\nVALUES\n  ("
    <> system_values_sql(parts)
    <> ", 1, DEFAULT);"
}

pub fn insert_with_multiple_rows_and_returning_star_test() {
  let stmt =
    ast.Insert(
      stream_name: "s",
      columns: ["a"],
      rows: [
        [ast.ValueExpr(xast.IntLiteral("1"))],
        [ast.ValueExpr(xast.IntLiteral("2"))],
      ],
      on_conflict_do_nothing: False,
      returning: Some([ast.ReturningStar]),
      span: dummy_span(),
    )
  let clock = test_clock()
  let expected_clock = test_clock()
  let parts1 = clock.next_parts(expected_clock)
  let parts2 = clock.next_parts(expected_clock)
  assert dml_codegen.insert_to_sql(stmt, clock)
    == "INSERT INTO s (_struo_hlc, _struo_hlc_timestamp, _struo_hlc_count, _struo_hlc_node_id, a)\nVALUES\n  ("
    <> system_values_sql(parts1)
    <> ", 1),\n  ("
    <> system_values_sql(parts2)
    <> ", 2)\nRETURNING *;"
}

pub fn returning_an_aliased_expr_renders_the_alias_test() {
  let stmt =
    ast.Insert(
      stream_name: "s",
      columns: ["a"],
      rows: [[ast.ValueExpr(xast.IntLiteral("1"))]],
      on_conflict_do_nothing: False,
      returning: Some([ast.ReturningExpr(col_ref("a"), Some("b"))]),
      span: dummy_span(),
    )
  let clock = test_clock()
  let parts = clock.next_parts(test_clock())
  assert dml_codegen.insert_to_sql(stmt, clock)
    == "INSERT INTO s (_struo_hlc, _struo_hlc_timestamp, _struo_hlc_count, _struo_hlc_node_id, a)\nVALUES\n  ("
    <> system_values_sql(parts)
    <> ", 1)\nRETURNING a AS b;"
}

//-----------------------------------------------------------------------------
// generate / generate_standalone, end to end
//-----------------------------------------------------------------------------

const create_stream_source = "
  CREATE STREAM sensor_reading (
    reading REAL CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 100),
    units VARCHAR(32),
    sensor_id VARCHAR(24),
    notes VARCHAR(200) OPTIONAL
  );
"

const insert_source = "
  INSERT INTO sensor_reading (reading, units, sensor_id)
  VALUES (42.5, 'celsius', 'sensor-001')
  ON CONFLICT DO NOTHING
  RETURNING _struo_hlc;
"

fn catalog_with_sensor_reading() -> catalog.Catalog {
  let assert Ok(tokens) = lexer.tokenize(create_stream_source)
  let assert Ok(stmt) = ddl_parser.parse(token_stream.new(tokens))
  let assert Ok(cat) = ddl_semantics.analyze(catalog.empty(), stmt)
  cat
}

pub fn generate_end_to_end_against_the_given_catalog_test() {
  let clock = test_clock()
  let parts = clock.next_parts(test_clock())
  let assert Ok(#(sql, catalog_after)) =
    dml_codegen.generate(catalog_with_sensor_reading(), insert_source, clock)
  assert sql == insert_expected_sql(parts) <> "\n"
  // INSERT never changes a stream's shape.
  assert catalog_after == catalog_with_sensor_reading()
}

pub fn generate_standalone_validates_against_an_empty_catalog_test() {
  // `generate_standalone` is `generate(catalog.empty(), source, clock)` —
  // since every `INSERT` needs its target stream to already exist, this
  // can only ever succeed for a source that's self-contained in a way
  // this grammar doesn't support (DML alone can't also declare a
  // stream), so the meaningful thing to prove is that it really does
  // start from an *empty* catalog: `sensor_reading` isn't found, even
  // though it's a perfectly ordinary stream name.
  let assert Error(dml_codegen.SemanticFailure(
    statement_index: 0,
    errors: [dml_semantics.UnknownStream(name: "sensor_reading", span: _)],
  )) = dml_codegen.generate_standalone(insert_source, test_clock())
}

pub fn a_semicolon_inside_a_string_literal_is_not_a_statement_boundary_test() {
  let source =
    "INSERT INTO s (a) VALUES ('x;y');
     INSERT INTO s (a) VALUES ('z');"
  let clock = test_clock()
  let expected_clock = test_clock()
  let parts1 = clock.next_parts(expected_clock)
  let parts2 = clock.next_parts(expected_clock)
  let assert Ok(#(sql, _catalog)) =
    dml_codegen.generate(catalog_with_a_stream_named_s(), source, clock)
  assert sql
    == "INSERT INTO s (_struo_hlc, _struo_hlc_timestamp, _struo_hlc_count, _struo_hlc_node_id, a)\nVALUES\n  ("
    <> system_values_sql(parts1)
    <> ", 'x;y');\n\n"
    <> "INSERT INTO s (_struo_hlc, _struo_hlc_timestamp, _struo_hlc_count, _struo_hlc_node_id, a)\nVALUES\n  ("
    <> system_values_sql(parts2)
    <> ", 'z');\n"
}

pub fn empty_input_is_a_parse_failure_not_ok_empty_test() {
  let assert Error(dml_codegen.ParseFailure(expr_parser.UnexpectedEof(
    expected: _,
  ))) = dml_codegen.generate_standalone("", test_clock())
}

//-----------------------------------------------------------------------------
// Each CodegenError variant
//-----------------------------------------------------------------------------

pub fn a_lex_error_in_a_later_statement_is_reported_test() {
  let assert Error(dml_codegen.LexFailure(lexer.UnterminatedString(at: _))) =
    dml_codegen.generate_standalone(
      "INSERT INTO s (a) VALUES (1); INSERT INTO s (a) VALUES ('",
      test_clock(),
    )
}

pub fn a_syntax_error_in_a_later_statement_is_reported_test() {
  let assert Error(dml_codegen.ParseFailure(expr_parser.UnexpectedToken(
    found: _,
    expected: _,
  ))) =
    dml_codegen.generate_standalone(
      "INSERT INTO s (a) VALUES (1); INSERT INTO s VALUES (1)",
      test_clock(),
    )
}

pub fn a_semantic_error_names_the_right_statement_and_does_not_cascade_test() {
  let source =
    "INSERT INTO s (a) VALUES (1); INSERT INTO nonexistent (a) VALUES (1);"
  let assert Error(dml_codegen.SemanticFailure(
    statement_index: 1,
    errors: [dml_semantics.UnknownStream(name: "nonexistent", span: _)],
  )) =
    dml_codegen.generate(catalog_with_a_stream_named_s(), source, test_clock())
}

fn catalog_with_a_stream_named_s() -> catalog.Catalog {
  let assert Ok(tokens) = lexer.tokenize("CREATE STREAM s (a INT);")
  let assert Ok(stmt) = ddl_parser.parse(token_stream.new(tokens))
  let assert Ok(cat) = ddl_semantics.analyze(catalog.empty(), stmt)
  cat
}
//-----------------------------------------------------------------------------
