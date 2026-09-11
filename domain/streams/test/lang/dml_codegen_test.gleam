import gleam/int
import gleam/option.{None, Some}
import gleam/string
import hlc/clock
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
import support/ref.{type Ref}

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
// independently-started clock states with the same node id and `now`
// tick in lockstep, so a test can draw from a second, "expected" state
// the same number of times, in the same order, that `dml_codegen` draws
// from the real one, and build the expected SQL from those parts instead
// of hand-computing base-62 encodings.
//
// `hlc/clock` is a pure `(time, counter, node_id)` state machine — no
// actor, no mutable state of its own (see its own header comment for
// why). Getting a `fn() -> HlcParts` supplier out of it — the shape
// `dml_codegen` actually takes — needs *some* mutable cell to advance
// across calls; a real caller closes over a TypeScript-held `HlcClock`
// instance instead (see `service/src/hlc-clock.ts`), so this test uses
// `support/ref`, a minimal FFI-backed cell, purely to get the same shape
// in pure Gleam without reintroducing an actor.
//-----------------------------------------------------------------------------

fn fixed_now() -> Int {
  1_700_000_000_000
}

fn fresh_state() -> clock.ClockState {
  let assert Ok(state) = clock.new("aaaaa", fixed_now)
  state
}

fn test_clock() -> Ref(clock.ClockState) {
  ref.new(fresh_state())
}

/// The `fn() -> HlcParts` shape `dml_codegen` actually takes, backed by
/// a `support/ref` cell: draws the next value from the cell's state each
/// call, writing the advanced state back.
fn next_hlc(from cell: Ref(clock.ClockState)) -> fn() -> clock.HlcParts {
  fn() {
    let #(new_state, parts) = clock.next_parts(ref.get(cell))
    ref.set(cell, new_state)
    parts
  }
}

/// One pure `next_parts` draw from a fresh clock state — for building the
/// "expected" parts a test asserts against, independent of the `next_hlc`
/// closure under test.
fn next_parts(
  from state: clock.ClockState,
) -> #(clock.ClockState, clock.HlcParts) {
  clock.next_parts(state)
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

/// Every existing test below (predating aggregator fan-out) uses this —
/// confirms the common "no aggregators configured" case renders exactly
/// as it always has.
fn no_aggregators() -> fn(String) -> List(Int) {
  fn(_stream) { [] }
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
  let #(_, parts) = next_parts(fresh_state())
  assert dml_codegen.insert_to_sql(
      insert_example(),
      next_hlc(clock),
      no_aggregators(),
    )
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
  let #(_, parts) = next_parts(fresh_state())
  assert dml_codegen.insert_to_sql(stmt, next_hlc(clock), no_aggregators())
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
  let #(state1, parts1) = next_parts(fresh_state())
  let #(_, parts2) = next_parts(state1)
  assert dml_codegen.insert_to_sql(stmt, next_hlc(clock), no_aggregators())
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
  let #(_, parts) = next_parts(fresh_state())
  assert dml_codegen.insert_to_sql(stmt, next_hlc(clock), no_aggregators())
    == "INSERT INTO s (_struo_hlc, _struo_hlc_timestamp, _struo_hlc_count, _struo_hlc_node_id, a)\nVALUES\n  ("
    <> system_values_sql(parts)
    <> ", 1)\nRETURNING a AS b;"
}

//-----------------------------------------------------------------------------
// Aggregator fan-out (documentation/plans/architecture/
// event-store-implementation-plan.md, Phase 4)
//-----------------------------------------------------------------------------

pub fn insert_with_aggregators_and_no_returning_fans_out_test() {
  let stmt =
    ast.Insert(
      stream_name: "s",
      columns: ["a"],
      rows: [[ast.ValueExpr(xast.IntLiteral("1"))]],
      on_conflict_do_nothing: False,
      returning: None,
      span: dummy_span(),
    )
  let clock = test_clock()
  let #(_, parts) = next_parts(fresh_state())
  assert dml_codegen.insert_to_sql(stmt, next_hlc(clock), fn(_stream) {
      [7, 12]
    })
    == "WITH ins AS (\n"
    <> "  INSERT INTO s (_struo_hlc, _struo_hlc_timestamp, _struo_hlc_count, _struo_hlc_node_id, a)\n"
    <> "  VALUES\n    ("
    <> system_values_sql(parts)
    <> ", 1)\n    RETURNING *\n"
    <> ")\n"
    <> "INSERT INTO _struo_s_pending_aggregations (aggregator_node_id, event_hlc)\n"
    <> "SELECT a.aggregator_node_id, ins._struo_hlc\n"
    <> "FROM ins CROSS JOIN unnest(ARRAY[7, 12]) AS a(aggregator_node_id);"
}

pub fn insert_with_aggregators_and_an_expr_returning_selects_from_ins_test() {
  let stmt =
    ast.Insert(
      stream_name: "s",
      columns: ["a"],
      rows: [[ast.ValueExpr(xast.IntLiteral("1"))]],
      on_conflict_do_nothing: False,
      returning: Some([
        ast.ReturningExpr(col_ref(catalog.hlc_column_name), None),
      ]),
      span: dummy_span(),
    )
  let clock = test_clock()
  let #(_, parts) = next_parts(fresh_state())
  assert dml_codegen.insert_to_sql(stmt, next_hlc(clock), fn(_stream) {
      [7, 12]
    })
    == "WITH ins AS (\n"
    <> "  INSERT INTO s (_struo_hlc, _struo_hlc_timestamp, _struo_hlc_count, _struo_hlc_node_id, a)\n"
    <> "  VALUES\n    ("
    <> system_values_sql(parts)
    <> ", 1)\n    RETURNING *\n"
    <> "),\npending AS (\n"
    <> "  INSERT INTO _struo_s_pending_aggregations (aggregator_node_id, event_hlc)\n"
    <> "  SELECT a.aggregator_node_id, ins._struo_hlc\n"
    <> "  FROM ins CROSS JOIN unnest(ARRAY[7, 12]) AS a(aggregator_node_id)\n"
    <> ")\n"
    <> "SELECT _struo_hlc FROM ins;"
}

pub fn insert_with_aggregators_and_returning_star_selects_star_from_ins_test() {
  let stmt =
    ast.Insert(
      stream_name: "s",
      columns: ["a"],
      rows: [[ast.ValueExpr(xast.IntLiteral("1"))]],
      on_conflict_do_nothing: False,
      returning: Some([ast.ReturningStar]),
      span: dummy_span(),
    )
  let clock = test_clock()
  let #(_, parts) = next_parts(fresh_state())
  assert dml_codegen.insert_to_sql(stmt, next_hlc(clock), fn(_stream) { [3] })
    == "WITH ins AS (\n"
    <> "  INSERT INTO s (_struo_hlc, _struo_hlc_timestamp, _struo_hlc_count, _struo_hlc_node_id, a)\n"
    <> "  VALUES\n    ("
    <> system_values_sql(parts)
    <> ", 1)\n    RETURNING *\n"
    <> "),\npending AS (\n"
    <> "  INSERT INTO _struo_s_pending_aggregations (aggregator_node_id, event_hlc)\n"
    <> "  SELECT a.aggregator_node_id, ins._struo_hlc\n"
    <> "  FROM ins CROSS JOIN unnest(ARRAY[3]) AS a(aggregator_node_id)\n"
    <> ")\n"
    <> "SELECT * FROM ins;"
}

/// A row skipped by `ON CONFLICT DO NOTHING` is simply absent from
/// `ins`, so the fan-out correctly emits nothing for it too — codegen
/// doesn't need (or have) any special case for this, since it's just
/// ordinary SQL evaluation once the statement reaches PostgreSQL. This
/// test only confirms `ON CONFLICT DO NOTHING` still renders in the
/// wrapped `ins` CTE; the actual zero-rows-fan-out behavior needs a real
/// Postgres to observe, per the implementation plan's own test-plan note.
pub fn insert_with_aggregators_still_renders_on_conflict_do_nothing_test() {
  let stmt =
    ast.Insert(
      stream_name: "s",
      columns: ["a"],
      rows: [[ast.ValueExpr(xast.IntLiteral("1"))]],
      on_conflict_do_nothing: True,
      returning: None,
      span: dummy_span(),
    )
  let clock = test_clock()
  let sql =
    dml_codegen.insert_to_sql(stmt, next_hlc(clock), fn(_stream) { [7] })
  assert string.contains(sql, "ON CONFLICT DO NOTHING\n    RETURNING *")
}

/// Multiple `VALUES` rows still render exactly one fan-out `INSERT`
/// (one `CROSS JOIN unnest(...)`, not one per row) — the per-row
/// multiplication is ordinary SQL evaluation once this reaches
/// PostgreSQL, not something codegen needs to duplicate textually. Full
/// row-count verification needs a real Postgres — see the
/// implementation plan's own test-plan note.
pub fn insert_with_multiple_rows_and_aggregators_fans_out_once_test() {
  let stmt =
    ast.Insert(
      stream_name: "s",
      columns: ["a"],
      rows: [
        [ast.ValueExpr(xast.IntLiteral("1"))],
        [ast.ValueExpr(xast.IntLiteral("2"))],
      ],
      on_conflict_do_nothing: False,
      returning: None,
      span: dummy_span(),
    )
  let clock = test_clock()
  let sql =
    dml_codegen.insert_to_sql(stmt, next_hlc(clock), fn(_stream) { [7, 12] })
  let assert [_, _] = string.split(sql, "CROSS JOIN unnest(ARRAY[7, 12])")
  assert string.contains(sql, "    (1),\n    (")
    || string.contains(sql, ", 1),\n    (")
}

/// Two statements in one `source`, targeting different streams, each get
/// their own `aggregators_for_stream` lookup and independent fan-out.
pub fn two_statements_get_independent_aggregator_lookups_test() {
  let source = "INSERT INTO s (a) VALUES (1); INSERT INTO t (a) VALUES (2);"
  let assert Ok(#(results, _catalog)) =
    dml_codegen.generate(
      catalog_with_streams_s_and_t(),
      source,
      next_hlc(test_clock()),
      fn(stream) {
        case stream {
          "s" -> [7]
          _ -> []
        }
      },
    )

  let assert [s_result, t_result] = results
  assert s_result.stream_name == "s"
  assert string.contains(s_result.sql, "_struo_s_pending_aggregations")
  assert t_result.stream_name == "t"
  // "t"'s statement, with no aggregators, still renders as a plain
  // INSERT (no WITH wrapper).
  assert !string.contains(t_result.sql, "_struo_t_pending_aggregations")
  assert string.starts_with(t_result.sql, "INSERT INTO t")
}

fn catalog_with_streams_s_and_t() -> catalog.Catalog {
  let assert Ok(tokens) =
    lexer.tokenize("CREATE STREAM s (a INT); CREATE STREAM t (a INT);")
  let assert Ok(stmts) = ddl_parser.parse_many(token_stream.new(tokens))
  let assert [create_s, create_t] = stmts
  let assert Ok(cat) = ddl_semantics.analyze(catalog.empty(), create_s)
  let assert Ok(cat) = ddl_semantics.analyze(cat, create_t)
  cat
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
  let #(_, parts) = next_parts(fresh_state())
  let assert Ok(#(results, catalog_after)) =
    dml_codegen.generate(
      catalog_with_sensor_reading(),
      insert_source,
      next_hlc(clock),
      no_aggregators(),
    )
  let assert [result] = results
  assert result.sql == insert_expected_sql(parts)
  assert result.stream_name == "sensor_reading"
  assert result.has_returning == True
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
  )) =
    dml_codegen.generate_standalone(
      insert_source,
      next_hlc(test_clock()),
      no_aggregators(),
    )
}

pub fn a_semicolon_inside_a_string_literal_is_not_a_statement_boundary_test() {
  let source =
    "INSERT INTO s (a) VALUES ('x;y');
     INSERT INTO s (a) VALUES ('z');"
  let clock = test_clock()
  let #(state1, parts1) = next_parts(fresh_state())
  let #(_, parts2) = next_parts(state1)
  let assert Ok(#(results, _catalog)) =
    dml_codegen.generate(
      catalog_with_a_stream_named_s(),
      source,
      next_hlc(clock),
      no_aggregators(),
    )
  let assert [result1, result2] = results
  assert result1.sql
    == "INSERT INTO s (_struo_hlc, _struo_hlc_timestamp, _struo_hlc_count, _struo_hlc_node_id, a)\nVALUES\n  ("
    <> system_values_sql(parts1)
    <> ", 'x;y');"
  assert result2.sql
    == "INSERT INTO s (_struo_hlc, _struo_hlc_timestamp, _struo_hlc_count, _struo_hlc_node_id, a)\nVALUES\n  ("
    <> system_values_sql(parts2)
    <> ", 'z');"
}

pub fn empty_input_is_a_parse_failure_not_ok_empty_test() {
  let assert Error(dml_codegen.ParseFailure(expr_parser.UnexpectedEof(
    expected: _,
  ))) =
    dml_codegen.generate_standalone(
      "",
      next_hlc(test_clock()),
      no_aggregators(),
    )
}

//-----------------------------------------------------------------------------
// Each CodegenError variant
//-----------------------------------------------------------------------------

pub fn a_lex_error_in_a_later_statement_is_reported_test() {
  let assert Error(dml_codegen.LexFailure(lexer.UnterminatedString(at: _))) =
    dml_codegen.generate_standalone(
      "INSERT INTO s (a) VALUES (1); INSERT INTO s (a) VALUES ('",
      next_hlc(test_clock()),
      no_aggregators(),
    )
}

pub fn a_syntax_error_in_a_later_statement_is_reported_test() {
  let assert Error(dml_codegen.ParseFailure(expr_parser.UnexpectedToken(
    found: _,
    expected: _,
  ))) =
    dml_codegen.generate_standalone(
      "INSERT INTO s (a) VALUES (1); INSERT INTO s VALUES (1)",
      next_hlc(test_clock()),
      no_aggregators(),
    )
}

pub fn a_semantic_error_names_the_right_statement_and_does_not_cascade_test() {
  let source =
    "INSERT INTO s (a) VALUES (1); INSERT INTO nonexistent (a) VALUES (1);"
  let assert Error(dml_codegen.SemanticFailure(
    statement_index: 1,
    errors: [dml_semantics.UnknownStream(name: "nonexistent", span: _)],
  )) =
    dml_codegen.generate(
      catalog_with_a_stream_named_s(),
      source,
      next_hlc(test_clock()),
      no_aggregators(),
    )
}

fn catalog_with_a_stream_named_s() -> catalog.Catalog {
  let assert Ok(tokens) = lexer.tokenize("CREATE STREAM s (a INT);")
  let assert Ok(stmt) = ddl_parser.parse(token_stream.new(tokens))
  let assert Ok(cat) = ddl_semantics.analyze(catalog.empty(), stmt)
  cat
}
//-----------------------------------------------------------------------------
