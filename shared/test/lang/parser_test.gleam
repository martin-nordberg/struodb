import gleam/list
import gleam/option.{None, Some}
import lang/ast.{
  Add, AddColumn, AddConstraint, AlterColumnType, AlterStream, Between, BinaryOp,
  BoolLiteral, Cast, Column, ColumnDef, ColumnRef, CreateStream, DropConstraint,
  DtBigint, DtHlc, DtReal, DtTimestamptz, DtVarchar, FunctionCall,
  GeneratedClause, InList, Insert, IntLiteral, IsBool, IsDistinctFrom, IsNull,
  Like, LogicalNot, Mul, NamedCheck, Neg, NullLiteral, NumericLiteral, Pow,
  ReturningExpr, ReturningStar, SimilarTo, Stored, StringLiteral,
  TableConstraint, UnaryOp, ValueDefault, ValueExpr,
}
import lang/lexer
import lang/parser.{ExplicitNotNull, MissingGeneratedStorage, UnexpectedToken}
import lang/token_stream

//-----------------------------------------------------------------------------

fn parse(source: String) -> Result(ast.Statement, parser.ParseError) {
  let assert Ok(tokens) = lexer.tokenize(source)
  parser.parse(token_stream.new(tokens))
}

fn parse_ok(source: String) -> ast.Statement {
  let assert Ok(stmt) = parse(source)
  stmt
}

/// Parses `expr_source` by embedding it in a minimal `CREATE STREAM`'s
/// table-level `CHECK` clause and pulling the resulting `Expr` back out —
/// `expr` only ever appears inside a statement, so this is the only way
/// to exercise the expression grammar through the public `parse` API,
/// same as any other caller would.
fn parse_expr(expr_source: String) -> ast.Expr {
  let source =
    "CREATE STREAM s (a INT, CONSTRAINT c CHECK (" <> expr_source <> "))"
  let assert CreateStream(elements: [_, TableConstraint(check: check, ..)], ..) =
    parse_ok(source)
  check.expr
}

//-----------------------------------------------------------------------------
// §8.1 grammar alternatives
//
// Most of these pattern-match (`let assert ... = ...`) rather than
// compare with `==`, using `_` wherever a `ColumnRef`'s own `Span`
// appears — that span is real source position, so it can't be predicted
// by a hand-written expected value; `column_ref_carries_the_identifiers_
// own_span_test` below checks it directly instead.
//-----------------------------------------------------------------------------

pub fn integer_literal_test() {
  assert parse_expr("42") == IntLiteral("42")
}

pub fn numeric_literal_test() {
  assert parse_expr("3.14") == NumericLiteral("3.14")
}

pub fn string_literal_test() {
  assert parse_expr("'hi'") == StringLiteral("hi")
}

pub fn boolean_and_null_literals_test() {
  assert parse_expr("TRUE") == BoolLiteral(True)
  assert parse_expr("FALSE") == BoolLiteral(False)
  assert parse_expr("NULL") == NullLiteral
}

pub fn column_ref_test() {
  let assert ColumnRef(name: "reading", span: _) = parse_expr("reading")
}

pub fn column_ref_carries_the_identifiers_own_span_test() {
  let assert ColumnRef(name: "reading", span: span) = parse_expr("reading")
  // Exactly covers "reading" (7 bytes), wherever it landed in the
  // wrapping statement `parse_expr` built.
  assert span.end.byte_offset - span.start.byte_offset == 7
}

pub fn unary_op_test() {
  assert parse_expr("NOT TRUE") == UnaryOp(LogicalNot, BoolLiteral(True))
}

pub fn binary_op_test() {
  let assert BinaryOp(Add, ColumnRef("a", _), ColumnRef("b", _)) =
    parse_expr("a + b")
}

pub fn cast_test() {
  let assert Cast(ColumnRef("a", _), DtBigint) = parse_expr("a :: BIGINT")
}

pub fn between_test() {
  let assert Between(
    ColumnRef("a", _),
    False,
    IntLiteral("1"),
    IntLiteral("10"),
  ) = parse_expr("a BETWEEN 1 AND 10")
}

pub fn in_list_test() {
  let assert InList(
    ColumnRef("a", _),
    False,
    [IntLiteral("1"), IntLiteral("2"), IntLiteral("3")],
  ) = parse_expr("a IN (1, 2, 3)")
}

pub fn like_test() {
  let assert Like(ColumnRef("a", _), False, False, StringLiteral("x%")) =
    parse_expr("a LIKE 'x%'")
}

pub fn ilike_test() {
  let assert Like(ColumnRef("a", _), False, True, StringLiteral("x%")) =
    parse_expr("a ILIKE 'x%'")
}

pub fn similar_to_test() {
  let assert SimilarTo(ColumnRef("a", _), False, StringLiteral("x%")) =
    parse_expr("a SIMILAR TO 'x%'")
}

pub fn is_null_test() {
  let assert IsNull(ColumnRef("a", _), False) = parse_expr("a IS NULL")
  let assert IsNull(ColumnRef("a", _), True) = parse_expr("a IS NOT NULL")
}

pub fn is_true_false_test() {
  let assert IsBool(ColumnRef("a", _), False, True) = parse_expr("a IS TRUE")
  let assert IsBool(ColumnRef("a", _), True, False) =
    parse_expr("a IS NOT FALSE")
}

pub fn is_distinct_from_test() {
  let assert IsDistinctFrom(ColumnRef("a", _), False, ColumnRef("b", _)) =
    parse_expr("a IS DISTINCT FROM b")
}

pub fn function_call_test() {
  let assert FunctionCall("timestamptz_from_hlc", [ColumnRef("reading_hlc", _)]) =
    parse_expr("TIMESTAMPTZ_FROM_HLC(reading_hlc)")
}

pub fn function_call_with_no_args_test() {
  assert parse_expr("now()") == FunctionCall("now", [])
}

pub fn parenthesized_expr_does_not_add_an_ast_node_test() {
  // No `Paren(Expr)` wrapper — see the note on `Expr` in ast.gleam.
  let assert BinaryOp(
    Mul,
    BinaryOp(Add, ColumnRef("a", _), ColumnRef("b", _)),
    ColumnRef("c", _),
  ) = parse_expr("(a + b) * c")
}

//-----------------------------------------------------------------------------
// Precedence (spec.md §8.2)
//-----------------------------------------------------------------------------

pub fn multiplication_binds_tighter_than_addition_test() {
  assert parse_expr("1 + 2 * 3")
    == BinaryOp(
      Add,
      IntLiteral("1"),
      BinaryOp(Mul, IntLiteral("2"), IntLiteral("3")),
    )
}

pub fn prefix_tilde_binds_looser_than_addition_test() {
  // The PostgreSQL quirk: `~1 + 2` is `~(1 + 2)`, not `(~1) + 2`.
  assert parse_expr("~1 + 2")
    == UnaryOp(ast.BitNot, BinaryOp(Add, IntLiteral("1"), IntLiteral("2")))
}

pub fn prefix_minus_binds_tighter_than_addition_test() {
  // Contrasted directly against the `~` case above: unary `+`/`-` sit at
  // level 2, tighter than level 5 addition, so `-1 + 2` is `(-1) + 2`.
  assert parse_expr("-1 + 2")
    == BinaryOp(Add, UnaryOp(Neg, IntLiteral("1")), IntLiteral("2"))
}

pub fn exponentiation_is_left_associative_test() {
  // PostgreSQL-matching non-standard case: `2^3^2` is `(2^3)^2`.
  assert parse_expr("2 ^ 3 ^ 2")
    == BinaryOp(
      Pow,
      BinaryOp(Pow, IntLiteral("2"), IntLiteral("3")),
      IntLiteral("2"),
    )
}

pub fn comparison_is_non_associative_test() {
  let assert Error(UnexpectedToken(found: _, expected: _)) =
    parse("CREATE STREAM s (a INT, CONSTRAINT c CHECK (a < b < c))")
}

pub fn not_between_negates_the_between_itself_test() {
  let assert Between(
    ColumnRef("a", _),
    True,
    ColumnRef("b", _),
    ColumnRef("c", _),
  ) = parse_expr("a NOT BETWEEN b AND c")
}

pub fn outer_not_wraps_an_unnegated_between_test() {
  let assert UnaryOp(
    LogicalNot,
    Between(ColumnRef("a", _), False, ColumnRef("b", _), ColumnRef("c", _)),
  ) = parse_expr("NOT a BETWEEN b AND c")
}

//-----------------------------------------------------------------------------
// CREATE STREAM (spec.md §9)
//-----------------------------------------------------------------------------

pub fn create_stream_example_round_trips_test() {
  let source =
    "CREATE STREAM sensor_reading (
      reading_hlc HLC,
      reading_time TIMESTAMPTZ GENERATED ALWAYS AS (TIMESTAMPTZ_FROM_HLC(reading_hlc)) STORED,
      reading REAL CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 100),
      units VARCHAR(32),
      sensor_id VARCHAR(24),
      notes VARCHAR(200) OPTIONAL
    );"

  let assert CreateStream(
    name: "sensor_reading",
    elements: [
      Column(ColumnDef(
        name: "reading_hlc",
        data_type: DtHlc,
        optional: False,
        default: None,
        generated: None,
        checks: [],
        span: _,
      )),
      Column(ColumnDef(
        name: "reading_time",
        data_type: DtTimestamptz,
        optional: False,
        default: None,
        generated: Some(GeneratedClause(
          FunctionCall("timestamptz_from_hlc", [ColumnRef("reading_hlc", _)]),
          Stored,
        )),
        checks: [],
        span: _,
      )),
      Column(ColumnDef(
        name: "reading",
        data_type: DtReal,
        optional: False,
        default: None,
        generated: None,
        checks: [
          NamedCheck(
            "reading_in_range",
            BinaryOp(
              ast.LogicalAnd,
              BinaryOp(ast.CmpGt, ColumnRef("reading", _), IntLiteral("0")),
              BinaryOp(ast.CmpLe, ColumnRef("reading", _), IntLiteral("100")),
            ),
            _,
          ),
        ],
        span: _,
      )),
      Column(ColumnDef(
        name: "units",
        data_type: DtVarchar(Some(32)),
        optional: False,
        default: None,
        generated: None,
        checks: [],
        span: _,
      )),
      Column(ColumnDef(
        name: "sensor_id",
        data_type: DtVarchar(Some(24)),
        optional: False,
        default: None,
        generated: None,
        checks: [],
        span: _,
      )),
      Column(ColumnDef(
        name: "notes",
        data_type: DtVarchar(Some(200)),
        optional: True,
        default: None,
        generated: None,
        checks: [],
        span: _,
      )),
    ],
    span: _,
  ) = parse_ok(source)
}

pub fn explicit_not_null_is_a_friendly_diagnostic_test() {
  let assert Error(ExplicitNotNull(span: _)) =
    parse("CREATE STREAM s (a INT NOT NULL)")
}

pub fn missing_generated_storage_is_reported_test() {
  let assert Error(MissingGeneratedStorage(span: _)) =
    parse("CREATE STREAM s (a INT, b INT GENERATED ALWAYS AS (a + 1))")
}

pub fn double_without_precision_is_a_parse_error_test() {
  let assert Error(UnexpectedToken(found: _, expected: _)) =
    parse("CREATE STREAM s (a DOUBLE)")
}

//-----------------------------------------------------------------------------
// ALTER STREAM (spec.md §10)
//-----------------------------------------------------------------------------

pub fn alter_stream_example_round_trips_test() {
  let source =
    "ALTER STREAM sensor_reading
      ADD COLUMN calibration_id VARCHAR(24) OPTIONAL,
      ALTER COLUMN units TYPE VARCHAR(64),
      DROP CONSTRAINT reading_in_range,
      ADD CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 90);"

  let assert AlterStream(name: "sensor_reading", actions: actions, ..) =
    parse_ok(source)
  assert list.length(actions) == 4
  let assert [
    AddColumn(ColumnDef(name: "calibration_id", optional: True, ..), ..),
    AlterColumnType("units", DtVarchar(Some(64)), _),
    DropConstraint("reading_in_range", _),
    AddConstraint(NamedCheck("reading_in_range", _, _)),
  ] = actions
}

//-----------------------------------------------------------------------------
// INSERT (spec.md §11)
//-----------------------------------------------------------------------------

pub fn insert_example_round_trips_test() {
  let source =
    "INSERT INTO sensor_reading (reading_hlc, reading, units, sensor_id)
    VALUES ('01a2B3c4D5e6f70abcde', 42.5, 'celsius', 'sensor-001')
    ON CONFLICT DO NOTHING
    RETURNING reading_hlc, reading_time;"

  let assert Insert(
    stream_name: "sensor_reading",
    columns: ["reading_hlc", "reading", "units", "sensor_id"],
    rows: [
      [
        ValueExpr(StringLiteral("01a2B3c4D5e6f70abcde")),
        ValueExpr(NumericLiteral("42.5")),
        ValueExpr(StringLiteral("celsius")),
        ValueExpr(StringLiteral("sensor-001")),
      ],
    ],
    on_conflict_do_nothing: True,
    returning: Some([
      ReturningExpr(ColumnRef("reading_hlc", _), None),
      ReturningExpr(ColumnRef("reading_time", _), None),
    ]),
    ..,
  ) = parse_ok(source)
}

pub fn insert_default_value_test() {
  let assert Insert(rows: [[ValueDefault]], ..) =
    parse_ok("INSERT INTO s (a) VALUES (DEFAULT)")
}

pub fn insert_returning_star_test() {
  let assert Insert(returning: Some([ReturningStar]), ..) =
    parse_ok("INSERT INTO s (a) VALUES (1) RETURNING *")
}

pub fn insert_without_a_column_list_is_a_parse_error_test() {
  let assert Error(UnexpectedToken(found: _, expected: _)) =
    parse("INSERT INTO s VALUES (1)")
}
//-----------------------------------------------------------------------------
