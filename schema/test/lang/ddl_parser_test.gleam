import gleam/list
import gleam/option.{None, Some}
import lang/ddl_ast as ast
import lang/ddl_parser
import lang/expr_ast as xast
import lang/expr_parser
import lang/lexer
import lang/token_stream

//-----------------------------------------------------------------------------

fn parse(source: String) -> Result(ast.DdlStatement, expr_parser.ParseError) {
  let assert Ok(tokens) = lexer.tokenize(source)
  ddl_parser.parse(token_stream.new(tokens))
}

fn parse_ok(source: String) -> ast.DdlStatement {
  let assert Ok(stmt) = parse(source)
  stmt
}

/// Parses `expr_source` by embedding it in a minimal `CREATE STREAM`'s
/// table-level `CHECK` clause and pulling the resulting `Expr` back out —
/// `expr` only ever appears inside a statement, so this is the only way
/// to exercise the expression grammar through the public `parse` API,
/// same as any other caller would.
fn parse_expr(expr_source: String) -> xast.Expr {
  let source =
    "CREATE STREAM s (a INT, CONSTRAINT c CHECK (" <> expr_source <> "))"
  let assert ast.CreateStream(
    elements: [_, ast.TableConstraint(check: check, ..)],
    ..,
  ) = parse_ok(source)
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
  assert parse_expr("42") == xast.IntLiteral("42")
}

pub fn numeric_literal_test() {
  assert parse_expr("3.14") == xast.NumericLiteral("3.14")
}

pub fn string_literal_test() {
  assert parse_expr("'hi'") == xast.StringLiteral("hi")
}

pub fn boolean_and_null_literals_test() {
  assert parse_expr("TRUE") == xast.BoolLiteral(True)
  assert parse_expr("FALSE") == xast.BoolLiteral(False)
  assert parse_expr("NULL") == xast.NullLiteral
}

pub fn column_ref_test() {
  let assert xast.ColumnRef(name: "reading", span: _) = parse_expr("reading")
}

pub fn column_ref_carries_the_identifiers_own_span_test() {
  let assert xast.ColumnRef(name: "reading", span: span) = parse_expr("reading")
  // Exactly covers "reading" (7 bytes), wherever it landed in the
  // wrapping statement `parse_expr` built.
  assert span.end.byte_offset - span.start.byte_offset == 7
}

pub fn unary_op_test() {
  assert parse_expr("NOT TRUE")
    == xast.UnaryOp(xast.LogicalNot, xast.BoolLiteral(True))
}

pub fn binary_op_test() {
  let assert xast.BinaryOp(
    xast.Add,
    xast.ColumnRef("a", _),
    xast.ColumnRef("b", _),
  ) = parse_expr("a + b")
}

pub fn cast_test() {
  let assert xast.Cast(xast.ColumnRef("a", _), xast.DtBigint) =
    parse_expr("a :: BIGINT")
}

pub fn between_test() {
  let assert xast.Between(
    xast.ColumnRef("a", _),
    False,
    xast.IntLiteral("1"),
    xast.IntLiteral("10"),
  ) = parse_expr("a BETWEEN 1 AND 10")
}

pub fn in_list_test() {
  let assert xast.InList(
    xast.ColumnRef("a", _),
    False,
    [xast.IntLiteral("1"), xast.IntLiteral("2"), xast.IntLiteral("3")],
  ) = parse_expr("a IN (1, 2, 3)")
}

pub fn like_test() {
  let assert xast.Like(
    xast.ColumnRef("a", _),
    False,
    False,
    xast.StringLiteral("x%"),
  ) = parse_expr("a LIKE 'x%'")
}

pub fn ilike_test() {
  let assert xast.Like(
    xast.ColumnRef("a", _),
    False,
    True,
    xast.StringLiteral("x%"),
  ) = parse_expr("a ILIKE 'x%'")
}

pub fn similar_to_test() {
  let assert xast.SimilarTo(
    xast.ColumnRef("a", _),
    False,
    xast.StringLiteral("x%"),
  ) = parse_expr("a SIMILAR TO 'x%'")
}

pub fn is_null_test() {
  let assert xast.IsNull(xast.ColumnRef("a", _), False) =
    parse_expr("a IS NULL")
  let assert xast.IsNull(xast.ColumnRef("a", _), True) =
    parse_expr("a IS NOT NULL")
}

pub fn is_true_false_test() {
  let assert xast.IsBool(xast.ColumnRef("a", _), False, True) =
    parse_expr("a IS TRUE")
  let assert xast.IsBool(xast.ColumnRef("a", _), True, False) =
    parse_expr("a IS NOT FALSE")
}

pub fn is_distinct_from_test() {
  let assert xast.IsDistinctFrom(
    xast.ColumnRef("a", _),
    False,
    xast.ColumnRef("b", _),
  ) = parse_expr("a IS DISTINCT FROM b")
}

pub fn function_call_test() {
  let assert xast.FunctionCall(
    "timestamptz_from_hlc",
    [xast.ColumnRef("reading_hlc", _)],
  ) = parse_expr("TIMESTAMPTZ_FROM_HLC(reading_hlc)")
}

pub fn function_call_with_no_args_test() {
  assert parse_expr("now()") == xast.FunctionCall("now", [])
}

pub fn parenthesized_expr_does_not_add_an_ast_node_test() {
  // No `Paren(Expr)` wrapper — see the note on `Expr` in xast.gleam.
  let assert xast.BinaryOp(
    xast.Mul,
    xast.BinaryOp(xast.Add, xast.ColumnRef("a", _), xast.ColumnRef("b", _)),
    xast.ColumnRef("c", _),
  ) = parse_expr("(a + b) * c")
}

//-----------------------------------------------------------------------------
// Precedence (spec.md §8.2)
//-----------------------------------------------------------------------------

pub fn multiplication_binds_tighter_than_addition_test() {
  assert parse_expr("1 + 2 * 3")
    == xast.BinaryOp(
      xast.Add,
      xast.IntLiteral("1"),
      xast.BinaryOp(xast.Mul, xast.IntLiteral("2"), xast.IntLiteral("3")),
    )
}

pub fn prefix_tilde_binds_looser_than_addition_test() {
  // The PostgreSQL quirk: `~1 + 2` is `~(1 + 2)`, not `(~1) + 2`.
  assert parse_expr("~1 + 2")
    == xast.UnaryOp(
      xast.BitNot,
      xast.BinaryOp(xast.Add, xast.IntLiteral("1"), xast.IntLiteral("2")),
    )
}

pub fn prefix_minus_binds_tighter_than_addition_test() {
  // Contrasted directly against the `~` case above: unary `+`/`-` sit at
  // level 2, tighter than level 5 addition, so `-1 + 2` is `(-1) + 2`.
  assert parse_expr("-1 + 2")
    == xast.BinaryOp(
      xast.Add,
      xast.UnaryOp(xast.Neg, xast.IntLiteral("1")),
      xast.IntLiteral("2"),
    )
}

pub fn exponentiation_is_left_associative_test() {
  // PostgreSQL-matching non-standard case: `2^3^2` is `(2^3)^2`.
  assert parse_expr("2 ^ 3 ^ 2")
    == xast.BinaryOp(
      xast.Pow,
      xast.BinaryOp(xast.Pow, xast.IntLiteral("2"), xast.IntLiteral("3")),
      xast.IntLiteral("2"),
    )
}

pub fn comparison_is_non_associative_test() {
  let assert Error(expr_parser.UnexpectedToken(found: _, expected: _)) =
    parse("CREATE STREAM s (a INT, CONSTRAINT c CHECK (a < b < c))")
}

pub fn not_between_negates_the_between_itself_test() {
  let assert xast.Between(
    xast.ColumnRef("a", _),
    True,
    xast.ColumnRef("b", _),
    xast.ColumnRef("c", _),
  ) = parse_expr("a NOT BETWEEN b AND c")
}

pub fn outer_not_wraps_an_unnegated_between_test() {
  let assert xast.UnaryOp(
    xast.LogicalNot,
    xast.Between(
      xast.ColumnRef("a", _),
      False,
      xast.ColumnRef("b", _),
      xast.ColumnRef("c", _),
    ),
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

  let assert ast.CreateStream(
    name: "sensor_reading",
    elements: [
      ast.Column(ast.ColumnDef(
        name: "reading_hlc",
        data_type: xast.DtHlc,
        optional: False,
        default: None,
        generated: None,
        checks: [],
        span: _,
      )),
      ast.Column(ast.ColumnDef(
        name: "reading_time",
        data_type: xast.DtTimestamptz,
        optional: False,
        default: None,
        generated: Some(ast.GeneratedClause(
          xast.FunctionCall(
            "timestamptz_from_hlc",
            [xast.ColumnRef("reading_hlc", _)],
          ),
          ast.Stored,
        )),
        checks: [],
        span: _,
      )),
      ast.Column(ast.ColumnDef(
        name: "reading",
        data_type: xast.DtReal,
        optional: False,
        default: None,
        generated: None,
        checks: [
          ast.NamedCheck(
            "reading_in_range",
            xast.BinaryOp(
              xast.LogicalAnd,
              xast.BinaryOp(
                xast.CmpGt,
                xast.ColumnRef("reading", _),
                xast.IntLiteral("0"),
              ),
              xast.BinaryOp(
                xast.CmpLe,
                xast.ColumnRef("reading", _),
                xast.IntLiteral("100"),
              ),
            ),
            _,
          ),
        ],
        span: _,
      )),
      ast.Column(ast.ColumnDef(
        name: "units",
        data_type: xast.DtVarchar(Some(32)),
        optional: False,
        default: None,
        generated: None,
        checks: [],
        span: _,
      )),
      ast.Column(ast.ColumnDef(
        name: "sensor_id",
        data_type: xast.DtVarchar(Some(24)),
        optional: False,
        default: None,
        generated: None,
        checks: [],
        span: _,
      )),
      ast.Column(ast.ColumnDef(
        name: "notes",
        data_type: xast.DtVarchar(Some(200)),
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
  let assert Error(expr_parser.ExplicitNotNull(span: _)) =
    parse("CREATE STREAM s (a INT NOT NULL)")
}

pub fn missing_generated_storage_is_reported_test() {
  let assert Error(expr_parser.MissingGeneratedStorage(span: _)) =
    parse("CREATE STREAM s (a INT, b INT GENERATED ALWAYS AS (a + 1))")
}

pub fn double_without_precision_is_a_parse_error_test() {
  let assert Error(expr_parser.UnexpectedToken(found: _, expected: _)) =
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

  let assert ast.AlterStream(name: "sensor_reading", actions: actions, ..) =
    parse_ok(source)
  assert list.length(actions) == 4
  let assert [
    ast.AddColumn(ast.ColumnDef(name: "calibration_id", optional: True, ..), ..),
    ast.AlterColumnType("units", xast.DtVarchar(Some(64)), _),
    ast.DropConstraint("reading_in_range", _),
    ast.AddConstraint(ast.NamedCheck("reading_in_range", _, _)),
  ] = actions
}
//-----------------------------------------------------------------------------
