import gleam/option.{None, Some}
import lang/dml_ast.{
  Insert, ReturningExpr, ReturningStar, ValueDefault, ValueExpr,
} as ast
import lang/dml_parser
import lang/expr_ast.{
  Add, Between, BinaryOp, BoolLiteral, Cast, ColumnRef, DtBigint, FunctionCall,
  InList, IntLiteral, IsBool, IsDistinctFrom, IsNull, Like, LogicalNot, Mul, Neg,
  NullLiteral, NumericLiteral, Pow, SimilarTo, StringLiteral, UnaryOp,
} as xast
import lang/expr_parser as ep
import lang/lexer
import lang/token_stream

//-----------------------------------------------------------------------------

fn parse(source: String) -> Result(ast.DmlStatement, ep.ParseError) {
  let assert Ok(tokens) = lexer.tokenize(source)
  dml_parser.parse(token_stream.new(tokens))
}

fn parse_ok(source: String) -> ast.DmlStatement {
  let assert Ok(stmt) = parse(source)
  stmt
}

/// Parses `expr_source` by embedding it in a minimal `INSERT`'s `VALUES`
/// row and pulling the resulting `Expr` back out — `expr` only ever
/// appears inside a statement, so this is the only way to exercise the
/// expression grammar through the public `parse` API, same as any other
/// caller would.
fn parse_expr(expr_source: String) -> xast.Expr {
  let source = "INSERT INTO s (a) VALUES (" <> expr_source <> ")"
  let assert Insert(_, _, [[ValueExpr(expr)]], _, _, _) = parse_ok(source)
  expr
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
  // No `Paren(Expr)` wrapper — see the note on `Expr` in expr_ast.gleam.
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
    == UnaryOp(xast.BitNot, BinaryOp(Add, IntLiteral("1"), IntLiteral("2")))
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
  let assert Error(ep.UnexpectedToken(found: _, expected: _)) =
    parse("INSERT INTO s (a) VALUES (a < b < c)")
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

pub fn insert_returning_an_aliased_expr_test() {
  let assert Insert(
    returning: Some([ReturningExpr(ColumnRef("a", _), alias)]),
    ..,
  ) = parse_ok("INSERT INTO s (a) VALUES (1) RETURNING a AS b")
  assert alias == Some("b")
}

pub fn insert_with_multiple_value_rows_parses_each_in_order_test() {
  let assert Insert(
    rows: [
      [ValueExpr(IntLiteral("1"))],
      [ValueExpr(IntLiteral("2"))],
      [ValueExpr(IntLiteral("3"))],
    ],
    ..,
  ) = parse_ok("INSERT INTO s (a) VALUES (1), (2), (3)")
}

pub fn insert_without_a_column_list_is_a_parse_error_test() {
  let assert Error(ep.UnexpectedToken(found: _, expected: _)) =
    parse("INSERT INTO s VALUES (1)")
}

//-----------------------------------------------------------------------------
// parse_many
//-----------------------------------------------------------------------------

fn parse_many(source: String) -> Result(List(ast.DmlStatement), ep.ParseError) {
  let assert Ok(tokens) = lexer.tokenize(source)
  dml_parser.parse_many(token_stream.new(tokens))
}

pub fn parse_many_parses_each_statement_in_order_test() {
  let assert Ok([
    Insert(stream_name: "s", rows: [[ValueExpr(IntLiteral("1"))]], ..),
    Insert(stream_name: "s", rows: [[ValueExpr(IntLiteral("2"))]], ..),
  ]) = parse_many("INSERT INTO s (a) VALUES (1); INSERT INTO s (a) VALUES (2);")
}

pub fn parse_many_does_not_require_a_separating_semicolon_test() {
  // Each statement's own trailing `;` is optional (§11.1) — nothing in
  // `parse_many` itself demands one between statements either.
  let assert Ok([Insert(stream_name: "s", ..), Insert(stream_name: "s", ..)]) =
    parse_many("INSERT INTO s (a) VALUES (1) INSERT INTO s (a) VALUES (2)")
}

pub fn parse_many_handles_a_semicolon_inside_a_string_literal_test() {
  // The concrete regression test for "never split raw text on `;`"
  // (docs/lang/codegen-plan.md) — a literal `;` inside a string literal
  // value must not be mistaken for a statement boundary.
  let assert Ok([Insert(..), Insert(..)]) =
    parse_many(
      "INSERT INTO s (a) VALUES ('x;y');
       INSERT INTO s (a) VALUES (2);",
    )
}

pub fn parse_many_rejects_empty_input_test() {
  let assert Error(ep.UnexpectedEof(expected: _)) = parse_many("")
}
//-----------------------------------------------------------------------------
