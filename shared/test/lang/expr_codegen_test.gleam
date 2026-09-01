import gleam/option.{None, Some}
import lang/expr_ast as xast
import lang/expr_codegen
import lang/token

//-----------------------------------------------------------------------------

fn dummy_span() -> token.Span {
  let pos = token.Position(line: 1, column: 1, byte_offset: 0)
  token.Span(pos, pos)
}

fn col_ref(name: String) -> xast.Expr {
  xast.ColumnRef(name, dummy_span())
}

//-----------------------------------------------------------------------------
// Identifiers and string literals
//-----------------------------------------------------------------------------

pub fn a_safe_lowercase_identifier_is_emitted_bare_test() {
  assert expr_codegen.quote_identifier("sensor_reading") == "sensor_reading"
}

pub fn an_identifier_with_uppercase_is_quoted_test() {
  assert expr_codegen.quote_identifier("Sensor_Reading") == "\"Sensor_Reading\""
}

pub fn an_identifier_starting_with_a_digit_is_quoted_test() {
  assert expr_codegen.quote_identifier("1abc") == "\"1abc\""
}

pub fn an_identifier_with_a_space_is_quoted_test() {
  assert expr_codegen.quote_identifier("a b") == "\"a b\""
}

pub fn a_postgres_reserved_word_is_quoted_even_though_its_content_looks_safe_test() {
  // "order" contains only valid unquoted-identifier characters — this is
  // exactly the case a purely content-based check would miss; see
  // docs/lang/codegen-plan.md's "Generated identifiers..." decision.
  assert expr_codegen.quote_identifier("order") == "\"order\""
}

pub fn a_postgres_non_reserved_keyword_is_emitted_bare_test() {
  assert expr_codegen.quote_identifier("value") == "value"
}

pub fn quoting_an_identifier_doubles_an_embedded_quote_test() {
  assert expr_codegen.quote_identifier("a\"b") == "\"a\"\"b\""
}

pub fn string_literal_doubles_an_embedded_quote_test() {
  assert expr_codegen.quote_string_literal("it's") == "'it''s'"
}

//-----------------------------------------------------------------------------
// data_type (spec.md §9.1 → PostgreSQL)
//-----------------------------------------------------------------------------

pub fn bare_data_types_map_directly_test() {
  assert expr_codegen.data_type_to_sql(xast.DtBigint) == "BIGINT"
  assert expr_codegen.data_type_to_sql(xast.DtBoolean) == "BOOLEAN"
  assert expr_codegen.data_type_to_sql(xast.DtDate) == "DATE"
  assert expr_codegen.data_type_to_sql(xast.DtDouble) == "DOUBLE PRECISION"
  assert expr_codegen.data_type_to_sql(xast.DtHlc) == "CHAR(15)"
  assert expr_codegen.data_type_to_sql(xast.DtInt) == "INTEGER"
  assert expr_codegen.data_type_to_sql(xast.DtInteger) == "INTEGER"
  assert expr_codegen.data_type_to_sql(xast.DtInterval) == "INTERVAL"
  assert expr_codegen.data_type_to_sql(xast.DtJson) == "JSON"
  assert expr_codegen.data_type_to_sql(xast.DtJsonb) == "JSONB"
  assert expr_codegen.data_type_to_sql(xast.DtReal) == "REAL"
  assert expr_codegen.data_type_to_sql(xast.DtSmallint) == "SMALLINT"
  assert expr_codegen.data_type_to_sql(xast.DtText) == "TEXT"
  assert expr_codegen.data_type_to_sql(xast.DtTime) == "TIME"
  assert expr_codegen.data_type_to_sql(xast.DtTimestamp) == "TIMESTAMP"
  assert expr_codegen.data_type_to_sql(xast.DtTimestamptz) == "TIMESTAMPTZ"
  assert expr_codegen.data_type_to_sql(xast.DtUuid) == "UUID"
}

pub fn char_and_varchar_map_with_or_without_a_length_test() {
  assert expr_codegen.data_type_to_sql(xast.DtChar(None)) == "CHAR"
  assert expr_codegen.data_type_to_sql(xast.DtChar(Some(10))) == "CHAR(10)"
  assert expr_codegen.data_type_to_sql(xast.DtVarchar(None)) == "VARCHAR"
  assert expr_codegen.data_type_to_sql(xast.DtVarchar(Some(32)))
    == "VARCHAR(32)"
}

pub fn decimal_and_numeric_map_with_precision_and_or_scale_test() {
  assert expr_codegen.data_type_to_sql(xast.DtDecimal(None, None)) == "DECIMAL"
  assert expr_codegen.data_type_to_sql(xast.DtDecimal(Some(10), None))
    == "DECIMAL(10)"
  assert expr_codegen.data_type_to_sql(xast.DtDecimal(Some(10), Some(2)))
    == "DECIMAL(10, 2)"
  assert expr_codegen.data_type_to_sql(xast.DtNumeric(None, None)) == "NUMERIC"
  assert expr_codegen.data_type_to_sql(xast.DtNumeric(Some(5), Some(0)))
    == "NUMERIC(5, 0)"
}

//-----------------------------------------------------------------------------
// Expression codegen — literal forms
//-----------------------------------------------------------------------------

pub fn literal_forms_render_directly_test() {
  assert expr_codegen.expr_to_sql(xast.IntLiteral("42")) == "42"
  assert expr_codegen.expr_to_sql(xast.NumericLiteral("3.14")) == "3.14"
  assert expr_codegen.expr_to_sql(xast.BoolLiteral(True)) == "TRUE"
  assert expr_codegen.expr_to_sql(xast.BoolLiteral(False)) == "FALSE"
  assert expr_codegen.expr_to_sql(xast.NullLiteral) == "NULL"
}

pub fn string_literal_expr_is_quoted_test() {
  assert expr_codegen.expr_to_sql(xast.StringLiteral("it's")) == "'it''s'"
}

pub fn column_ref_is_quoted_only_if_needed_test() {
  assert expr_codegen.expr_to_sql(col_ref("reading")) == "reading"
  assert expr_codegen.expr_to_sql(col_ref("order")) == "\"order\""
}

//-----------------------------------------------------------------------------
// Expression codegen — operator spellings
//-----------------------------------------------------------------------------

pub fn every_binary_operator_has_its_own_spelling_test() {
  let render = fn(op) {
    expr_codegen.expr_to_sql(xast.BinaryOp(op, col_ref("a"), col_ref("b")))
  }
  assert render(xast.Add) == "a + b"
  assert render(xast.Sub) == "a - b"
  assert render(xast.Mul) == "a * b"
  assert render(xast.Div) == "a / b"
  assert render(xast.Mod) == "a % b"
  assert render(xast.Pow) == "a ^ b"
  assert render(xast.ConcatOp) == "a || b"
  assert render(xast.BitAnd) == "a & b"
  assert render(xast.BitOr) == "a | b"
  assert render(xast.BitXor) == "a # b"
  assert render(xast.ShiftLeft) == "a << b"
  assert render(xast.ShiftRight) == "a >> b"
  assert render(xast.RegexMatchOp) == "a ~ b"
  assert render(xast.RegexMatchCiOp) == "a ~* b"
  assert render(xast.RegexNoMatchOp) == "a !~ b"
  assert render(xast.RegexNoMatchCiOp) == "a !~* b"
  assert render(xast.JsonGet) == "a -> b"
  assert render(xast.JsonGetText) == "a ->> b"
  assert render(xast.JsonGetPath) == "a #> b"
  assert render(xast.JsonGetPathText) == "a #>> b"
  assert render(xast.JsonContains) == "a @> b"
  assert render(xast.JsonContainedBy) == "a <@ b"
  assert render(xast.CmpEq) == "a = b"
  assert render(xast.CmpLt) == "a < b"
  assert render(xast.CmpGt) == "a > b"
  assert render(xast.CmpLe) == "a <= b"
  assert render(xast.CmpGe) == "a >= b"
  assert render(xast.LogicalAnd) == "a AND b"
  assert render(xast.LogicalOr) == "a OR b"
}

pub fn cmp_ne_angle_and_cmp_ne_bang_keep_their_own_spelling_test() {
  // Cashing in "`<>` and `!=` stay distinct tokens/AST nodes" — see the
  // parent plan.
  assert expr_codegen.expr_to_sql(xast.BinaryOp(
      xast.CmpNeAngle,
      col_ref("a"),
      col_ref("b"),
    ))
    == "a <> b"
  assert expr_codegen.expr_to_sql(xast.BinaryOp(
      xast.CmpNeBang,
      col_ref("a"),
      col_ref("b"),
    ))
    == "a != b"
}

pub fn bitnot_and_regex_match_both_render_as_tilde_but_stay_distinct_nodes_test() {
  // Same textual spelling, different `Expr` shape (prefix vs. infix) —
  // PostgreSQL disambiguates the same way, by position.
  assert expr_codegen.expr_to_sql(xast.UnaryOp(xast.BitNot, col_ref("a")))
    == "~a"
  assert expr_codegen.expr_to_sql(xast.BinaryOp(
      xast.RegexMatchOp,
      col_ref("a"),
      col_ref("b"),
    ))
    == "a ~ b"
}

pub fn logical_not_renders_as_a_keyword_with_a_trailing_space_test() {
  assert expr_codegen.expr_to_sql(xast.UnaryOp(
      xast.LogicalNot,
      xast.BoolLiteral(True),
    ))
    == "NOT TRUE"
}

pub fn prefix_pos_and_neg_render_with_no_space_test() {
  assert expr_codegen.expr_to_sql(xast.UnaryOp(xast.Pos, xast.IntLiteral("1")))
    == "+1"
  assert expr_codegen.expr_to_sql(xast.UnaryOp(xast.Neg, xast.IntLiteral("1")))
    == "-1"
}

pub fn cast_renders_with_the_double_colon_operator_test() {
  assert expr_codegen.expr_to_sql(xast.Cast(col_ref("a"), xast.DtBigint))
    == "a::BIGINT"
}

pub fn keyword_operator_forms_render_with_their_own_negation_test() {
  assert expr_codegen.expr_to_sql(xast.Between(
      col_ref("a"),
      False,
      xast.IntLiteral("1"),
      xast.IntLiteral("10"),
    ))
    == "a BETWEEN 1 AND 10"
  assert expr_codegen.expr_to_sql(xast.Between(
      col_ref("a"),
      True,
      xast.IntLiteral("1"),
      xast.IntLiteral("10"),
    ))
    == "a NOT BETWEEN 1 AND 10"
  assert expr_codegen.expr_to_sql(
      xast.InList(col_ref("a"), False, [
        xast.IntLiteral("1"),
        xast.IntLiteral("2"),
      ]),
    )
    == "a IN (1, 2)"
  assert expr_codegen.expr_to_sql(xast.Like(
      col_ref("a"),
      False,
      False,
      xast.StringLiteral("x%"),
    ))
    == "a LIKE 'x%'"
  assert expr_codegen.expr_to_sql(xast.Like(
      col_ref("a"),
      True,
      True,
      xast.StringLiteral("x%"),
    ))
    == "a NOT ILIKE 'x%'"
  assert expr_codegen.expr_to_sql(xast.SimilarTo(
      col_ref("a"),
      False,
      xast.StringLiteral("x%"),
    ))
    == "a SIMILAR TO 'x%'"
  assert expr_codegen.expr_to_sql(xast.IsNull(col_ref("a"), True))
    == "a IS NOT NULL"
  assert expr_codegen.expr_to_sql(xast.IsBool(col_ref("a"), False, True))
    == "a IS TRUE"
  assert expr_codegen.expr_to_sql(xast.IsDistinctFrom(
      col_ref("a"),
      False,
      col_ref("b"),
    ))
    == "a IS DISTINCT FROM b"
}

pub fn function_call_renders_bare_lowercase_including_zero_arg_test() {
  assert expr_codegen.expr_to_sql(xast.FunctionCall("now", [])) == "now()"
  assert expr_codegen.expr_to_sql(
      xast.FunctionCall("timestamptz_from_hlc", [
        col_ref("reading_hlc"),
      ]),
    )
    == "timestamptz_from_hlc(reading_hlc)"
}

/// A function name reaching codegen is quoted like any other identifier
/// rather than spliced in bare — the parser accepts a `QuotedIdentifier`
/// in function-call position (§8.3's grammar doesn't restrict it to a
/// fixed built-in set), so `name` may carry content an attacker chose,
/// including SQL metacharacters. Quoting keeps it inert as a single
/// identifier token instead of letting it break out of the expression.
pub fn function_call_name_needing_quoting_is_quoted_not_spliced_raw_test() {
  assert expr_codegen.expr_to_sql(
      xast.FunctionCall("pwn); drop table s; --", []),
    )
    == "\"pwn); drop table s; --\"()"
}

//-----------------------------------------------------------------------------
// Precedence-driven reparenthesization (spec.md §8.2)
//-----------------------------------------------------------------------------

pub fn multiplication_needs_no_parens_inside_addition_test() {
  assert expr_codegen.expr_to_sql(xast.BinaryOp(
      xast.Add,
      xast.IntLiteral("1"),
      xast.BinaryOp(xast.Mul, xast.IntLiteral("2"), xast.IntLiteral("3")),
    ))
    == "1 + 2 * 3"
}

pub fn addition_needs_parens_inside_multiplication_test() {
  assert expr_codegen.expr_to_sql(xast.BinaryOp(
      xast.Mul,
      xast.BinaryOp(xast.Add, xast.IntLiteral("1"), xast.IntLiteral("2")),
      xast.IntLiteral("3"),
    ))
    == "(1 + 2) * 3"
}

pub fn prefix_tilde_reproduces_the_looser_than_addition_quirk_test() {
  // `~1 + 2` parses as `~(1 + 2)` (see expr_parser.gleam) — rendering
  // `UnaryOp(BitNot, Add(1, 2))` back as `~1 + 2`, with no parens, must
  // round-trip to that exact tree.
  assert expr_codegen.expr_to_sql(xast.UnaryOp(
      xast.BitNot,
      xast.BinaryOp(xast.Add, xast.IntLiteral("1"), xast.IntLiteral("2")),
    ))
    == "~1 + 2"
}

pub fn prefix_minus_binds_tighter_than_addition_test() {
  assert expr_codegen.expr_to_sql(xast.BinaryOp(
      xast.Add,
      xast.UnaryOp(xast.Neg, xast.IntLiteral("1")),
      xast.IntLiteral("2"),
    ))
    == "-1 + 2"
}

pub fn exponentiation_parenthesizes_its_left_operand_conservatively_test() {
  // Left-associative, so `2 ^ 3 ^ 2` (no parens) would already re-parse
  // to the same tree — but reparenthesization here is conservative, not
  // minimal (see docs/lang/codegen-plan.md), so the left operand is
  // parenthesized anyway since its own precedence isn't *strictly*
  // tighter than its parent's.
  assert expr_codegen.expr_to_sql(xast.BinaryOp(
      xast.Pow,
      xast.BinaryOp(xast.Pow, xast.IntLiteral("2"), xast.IntLiteral("3")),
      xast.IntLiteral("2"),
    ))
    == "(2 ^ 3) ^ 2"
}

pub fn and_needs_no_parens_inside_or_test() {
  assert expr_codegen.expr_to_sql(xast.BinaryOp(
      xast.LogicalOr,
      xast.BinaryOp(xast.LogicalAnd, col_ref("a"), col_ref("b")),
      col_ref("c"),
    ))
    == "a AND b OR c"
}

pub fn or_needs_parens_inside_and_test() {
  assert expr_codegen.expr_to_sql(xast.BinaryOp(
      xast.LogicalAnd,
      xast.BinaryOp(xast.LogicalOr, col_ref("a"), col_ref("b")),
      col_ref("c"),
    ))
    == "(a OR b) AND c"
}

pub fn not_wrapping_between_needs_no_parens_test() {
  assert expr_codegen.expr_to_sql(xast.UnaryOp(
      xast.LogicalNot,
      xast.Between(col_ref("a"), False, col_ref("b"), col_ref("c")),
    ))
    == "NOT a BETWEEN b AND c"
}

pub fn and_wrapped_by_parens_in_source_needs_parens_back_test() {
  // `NOT (a AND b)` — the parens are invisible in the AST (no `Paren`
  // node), so this is the concrete case reparenthesization exists for:
  // without it, this would wrongly render as `NOT a AND b`.
  assert expr_codegen.expr_to_sql(xast.UnaryOp(
      xast.LogicalNot,
      xast.BinaryOp(xast.LogicalAnd, col_ref("a"), col_ref("b")),
    ))
    == "NOT (a AND b)"
}

pub fn a_paren_free_flat_chain_still_gets_conservative_parens_test() {
  // `a + b + c`, left-associative — the concrete example from "Reparen-
  // thesization is conservative, not minimal" in codegen-plan.md.
  assert expr_codegen.expr_to_sql(xast.BinaryOp(
      xast.Add,
      xast.BinaryOp(xast.Add, col_ref("a"), col_ref("b")),
      col_ref("c"),
    ))
    == "(a + b) + c"
}
//-----------------------------------------------------------------------------
