import gleam/option.{None, Some}
import lang/expr_ast as xast
import lang/expr_parser as ep
import lang/lexer
import lang/token
import lang/token_stream as ts

//-----------------------------------------------------------------------------
// Direct tests for expr_parser.gleam's own surface — the `expect_*`
// cursor helpers and `data_type` parsing — that no downstream package
// tests directly. The precedence-layered `expr` grammar itself (the bulk
// of this module) is exercised thoroughly through both `schema`'s
// ddl_parser_test.gleam (`CREATE STREAM ... CHECK (...)`) and `streams`'
// dml_parser_test.gleam (`INSERT ... VALUES (...)`) — deliberately not
// duplicated here; this file only covers what those two don't.
//-----------------------------------------------------------------------------

fn stream_of(source: String) -> ts.TokenStream {
  let assert Ok(tokens) = lexer.tokenize(source)
  ts.new(tokens)
}

fn data_type_of(source: String) -> xast.DataType {
  let assert Ok(#(dt, tokstrm)) = ep.parse_data_type(stream_of(source))
  let assert Ok(Nil) = ep.expect_eof(tokstrm)
  dt
}

//-----------------------------------------------------------------------------
// parse_or — the expression grammar's entry point
//-----------------------------------------------------------------------------

pub fn parse_or_parses_a_bare_literal_test() {
  let assert Ok(#(xast.IntLiteral("42"), _)) = ep.parse_or(stream_of("42"))
}

pub fn parse_or_leaves_trailing_tokens_for_the_caller_test() {
  // `expr` doesn't consume its own delimiter — that's the caller's job
  // (a `,` here, `)`/`;` elsewhere) — so `parse_or` stops right after the
  // expression and hands back whatever tokens remain.
  let assert Ok(#(xast.IntLiteral("1"), tokstrm)) =
    ep.parse_or(stream_of("1, 2"))
  assert ts.peek_kind(tokstrm, token.Comma)
}

//-----------------------------------------------------------------------------
// data_type (spec.md §9.1)
//-----------------------------------------------------------------------------

pub fn bare_data_type_keywords_parse_test() {
  assert data_type_of("BIGINT") == xast.DtBigint
  assert data_type_of("BOOLEAN") == xast.DtBoolean
  assert data_type_of("DATE") == xast.DtDate
  assert data_type_of("HLC") == xast.DtHlc
  assert data_type_of("INT") == xast.DtInt
  assert data_type_of("INTEGER") == xast.DtInteger
  assert data_type_of("INTERVAL") == xast.DtInterval
  assert data_type_of("JSON") == xast.DtJson
  assert data_type_of("JSONB") == xast.DtJsonb
  assert data_type_of("REAL") == xast.DtReal
  assert data_type_of("SMALLINT") == xast.DtSmallint
  assert data_type_of("TEXT") == xast.DtText
  assert data_type_of("TIME") == xast.DtTime
  assert data_type_of("TIMESTAMP") == xast.DtTimestamp
  assert data_type_of("TIMESTAMPTZ") == xast.DtTimestamptz
  assert data_type_of("UUID") == xast.DtUuid
}

pub fn char_and_varchar_optional_length_test() {
  assert data_type_of("CHAR") == xast.DtChar(None)
  assert data_type_of("CHAR(1)") == xast.DtChar(Some(1))
  assert data_type_of("VARCHAR") == xast.DtVarchar(None)
  assert data_type_of("VARCHAR(32)") == xast.DtVarchar(Some(32))
}

pub fn decimal_and_numeric_optional_precision_scale_test() {
  assert data_type_of("DECIMAL") == xast.DtDecimal(None, None)
  assert data_type_of("DECIMAL(10)") == xast.DtDecimal(Some(10), None)
  assert data_type_of("DECIMAL(10, 2)") == xast.DtDecimal(Some(10), Some(2))
  assert data_type_of("NUMERIC") == xast.DtNumeric(None, None)
  assert data_type_of("NUMERIC(5, 0)") == xast.DtNumeric(Some(5), Some(0))
}

pub fn double_precision_is_two_keywords_for_one_type_test() {
  assert data_type_of("DOUBLE PRECISION") == xast.DtDouble
}

pub fn double_without_precision_is_a_parse_error_test() {
  let assert Error(ep.UnexpectedEof(expected: _)) =
    ep.parse_data_type(stream_of("DOUBLE"))
}

pub fn a_non_type_token_is_a_parse_error_test() {
  let assert Error(ep.UnexpectedToken(found: _, expected: _)) =
    ep.parse_data_type(stream_of("foobar"))
}

//-----------------------------------------------------------------------------
// Cursor helpers (`expect_*`, `fail`) — the primitives every statement
// parser in schema/streams is built from.
//-----------------------------------------------------------------------------

pub fn expect_keyword_matches_and_advances_test() {
  let assert Ok(#(_, tokstrm)) =
    ep.expect_keyword(stream_of("CREATE"), token.KwCreate, "CREATE")
  let assert Ok(Nil) = ep.expect_eof(tokstrm)
}

pub fn expect_keyword_fails_on_a_mismatch_test() {
  let assert Error(ep.UnexpectedToken(found: _, expected: "CREATE")) =
    ep.expect_keyword(stream_of("ALTER"), token.KwCreate, "CREATE")
}

pub fn expect_punct_matches_and_advances_test() {
  let assert Ok(#(_, tokstrm)) =
    ep.expect_punct(stream_of("("), token.LeftParen, "(")
  let assert Ok(Nil) = ep.expect_eof(tokstrm)
}

pub fn expect_punct_fails_on_a_mismatch_test() {
  let assert Error(ep.UnexpectedToken(found: _, expected: "(")) =
    ep.expect_punct(stream_of(")"), token.LeftParen, "(")
}

pub fn expect_identifier_accepts_unquoted_and_quoted_forms_test() {
  let assert Ok(#("foo", _, _)) =
    ep.expect_identifier(stream_of("foo"), "a name")
  let assert Ok(#("Foo", _, _)) =
    ep.expect_identifier(stream_of("\"Foo\""), "a name")
}

pub fn expect_identifier_fails_on_a_keyword_test() {
  let assert Error(ep.UnexpectedToken(found: _, expected: "a name")) =
    ep.expect_identifier(stream_of("CREATE"), "a name")
}

pub fn expect_eof_fails_when_tokens_remain_test() {
  let assert Error(ep.UnexpectedToken(found: _, expected: "end of input")) =
    ep.expect_eof(stream_of("a"))
}

pub fn fail_reports_unexpected_eof_at_the_end_of_input_test() {
  let assert ep.UnexpectedEof(expected: "more input") =
    ep.fail(stream_of(""), "more input")
}

pub fn fail_reports_the_found_token_otherwise_test() {
  let assert ep.UnexpectedToken(found: found, expected: "x") =
    ep.fail(stream_of("CREATE"), "x")
  assert found.kind == token.Keyword(token.KwCreate)
}
//-----------------------------------------------------------------------------
