import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lang/ast.{type DataType, type Expr, type Statement}
import lang/token.{type Span, type Token, type TokenKind}
import lang/token_stream.{type TokenStream} as ts

//-----------------------------------------------------------------------------
// Recursive descent, one token of lookahead for statement dispatch and
// most productions; the expression grammar needs 2-token lookahead in
// exactly one place (`parse_keyword_ops_after`, level 7). Every parse_*
// function below takes the remaining `TokenStream` (always ending in
// `Eof`, never fully consumed) and returns
// `Result(#(<thing>, TokenStream), ParseError)`.
//-----------------------------------------------------------------------------

pub type ParseError {
  UnexpectedToken(found: Token, expected: String)
  UnexpectedEof(expected: String)
  /// Explicit `NOT NULL` on a column (§9.3) — a friendly diagnostic in
  /// place of a generic `UnexpectedToken`; see "NOT NULL special-case" in
  /// docs/lang/implementation-plan.md.
  ExplicitNotNull(span: Span)
  /// `GENERATED ALWAYS AS (...)` with neither `STORED` nor `VIRTUAL`.
  MissingGeneratedStorage(span: Span)
}

pub fn parse(tokstrm: TokenStream) -> Result(Statement, ParseError) {
  use #(stmt, tokstrm1) <- result.try(case ts.current(tokstrm).kind {
    token.Keyword(token.KwCreate) -> parse_create_stream(tokstrm)
    token.Keyword(token.KwAlter) -> parse_alter_stream(tokstrm)
    token.Keyword(token.KwInsert) -> parse_insert(tokstrm)
    _ -> Error(fail(tokstrm, "CREATE, ALTER, or INSERT"))
  })
  use _ <- result.try(expect_eof(tokstrm1))
  Ok(stmt)
}

//-----------------------------------------------------------------------------
// Parse-error helpers, built on `ts` (lang/token_stream)'s cursor primitives
//-----------------------------------------------------------------------------

fn fail(tokstrm: TokenStream, expected: String) -> ParseError {
  case ts.current(tokstrm).kind {
    token.Eof -> UnexpectedEof(expected: expected)
    _ -> UnexpectedToken(found: ts.current(tokstrm), expected: expected)
  }
}

fn expect_keyword(
  tokstrm: TokenStream,
  kw: token.Keyword,
  name: String,
) -> Result(#(Span, TokenStream), ParseError) {
  case ts.peek_keyword(tokstrm, kw) {
    True -> Ok(#(ts.current(tokstrm).span, ts.advance(tokstrm)))
    False -> Error(fail(tokstrm, name))
  }
}

fn expect_punct(
  tokstrm: TokenStream,
  kind: TokenKind,
  name: String,
) -> Result(#(Span, TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, kind) {
    True -> Ok(#(ts.current(tokstrm).span, ts.advance(tokstrm)))
    False -> Error(fail(tokstrm, name))
  }
}

fn expect_identifier(
  tokstrm: TokenStream,
  expected: String,
) -> Result(#(String, Span, TokenStream), ParseError) {
  let tok = ts.current(tokstrm)
  case tok.kind {
    token.Identifier(name) -> Ok(#(name, tok.span, ts.advance(tokstrm)))
    token.QuotedIdentifier(name) -> Ok(#(name, tok.span, ts.advance(tokstrm)))
    _ -> Error(fail(tokstrm, expected))
  }
}

fn expect_eof(tokstrm: TokenStream) -> Result(Nil, ParseError) {
  case ts.peek_kind(tokstrm, token.Eof) {
    True -> Ok(Nil)
    False -> Error(fail(tokstrm, "end of input"))
  }
}

//-----------------------------------------------------------------------------
// Expression parsing — precedence-layered recursive descent (spec.md
// §8.2), one function per level, loosest (12, the entry point) to
// tightest (1). See the "Expression parsing" section of
// docs/lang/implementation-plan.md for the full table and the reasoning
// behind each level's associativity/lookahead.
//-----------------------------------------------------------------------------

/// Level 12: `OR` — left, loop.
fn parse_or(tokstrm: TokenStream) -> Result(#(Expr, TokenStream), ParseError) {
  use #(left, tokstrm1) <- result.try(parse_and(tokstrm))
  parse_or_loop(left, tokstrm1)
}

fn parse_or_loop(
  left: Expr,
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case ts.peek_keyword(tokstrm, token.KwOr) {
    False -> Ok(#(left, tokstrm))
    True -> {
      let tokstrm1 = ts.advance(tokstrm)
      use #(right, tokstrm2) <- result.try(parse_and(tokstrm1))
      parse_or_loop(ast.BinaryOp(ast.LogicalOr, left, right), tokstrm2)
    }
  }
}

/// Level 11: `AND` — left, loop.
fn parse_and(tokstrm: TokenStream) -> Result(#(Expr, TokenStream), ParseError) {
  use #(left, tokstrm1) <- result.try(parse_not(tokstrm))
  parse_and_loop(left, tokstrm1)
}

fn parse_and_loop(
  left: Expr,
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case ts.peek_keyword(tokstrm, token.KwAnd) {
    False -> Ok(#(left, tokstrm))
    True -> {
      let tokstrm1 = ts.advance(tokstrm)
      use #(right, tokstrm2) <- result.try(parse_not(tokstrm1))
      parse_and_loop(ast.BinaryOp(ast.LogicalAnd, left, right), tokstrm2)
    }
  }
}

/// Level 10: prefix `NOT` — right-associative, recurses into itself for
/// the operand.
fn parse_not(tokstrm: TokenStream) -> Result(#(Expr, TokenStream), ParseError) {
  case ts.peek_keyword(tokstrm, token.KwNot) {
    False -> parse_is(tokstrm)
    True -> {
      let tokstrm1 = ts.advance(tokstrm)
      use #(operand, tokstrm2) <- result.try(parse_not(tokstrm1))
      Ok(#(ast.UnaryOp(ast.LogicalNot, operand), tokstrm2))
    }
  }
}

/// Level 9: `IS [NOT] NULL/TRUE/FALSE`, `IS [NOT] DISTINCT FROM` — loop
/// (not a single check; see the "IS (level 9) resolving as a loop" note
/// in the implementation plan).
fn parse_is(tokstrm: TokenStream) -> Result(#(Expr, TokenStream), ParseError) {
  use #(left, tokstrm1) <- result.try(parse_comparison(tokstrm))
  parse_is_loop(left, tokstrm1)
}

fn parse_is_loop(
  left: Expr,
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case ts.peek_keyword(tokstrm, token.KwIs) {
    False -> Ok(#(left, tokstrm))
    True -> {
      let tokstrm1 = ts.advance(tokstrm)
      let #(negated, tokstrm2) = case ts.peek_keyword(tokstrm1, token.KwNot) {
        True -> #(True, ts.advance(tokstrm1))
        False -> #(False, tokstrm1)
      }
      case ts.current(tokstrm2).kind {
        token.Keyword(token.KwNull) ->
          parse_is_loop(ast.IsNull(left, negated), ts.advance(tokstrm2))
        token.Keyword(token.KwTrue) ->
          parse_is_loop(ast.IsBool(left, negated, True), ts.advance(tokstrm2))
        token.Keyword(token.KwFalse) ->
          parse_is_loop(ast.IsBool(left, negated, False), ts.advance(tokstrm2))
        token.Keyword(token.KwDistinct) -> {
          let tokstrm3 = ts.advance(tokstrm2)
          use #(_, tokstrm4) <- result.try(expect_keyword(
            tokstrm3,
            token.KwFrom,
            "FROM",
          ))
          // IS DISTINCT FROM's right side is `bound_expr` (level 6 or
          // tighter) — see the "Operand binding" note in the plan.
          use #(right, tokstrm5) <- result.try(parse_bitwise_etc(tokstrm4))
          parse_is_loop(ast.IsDistinctFrom(left, negated, right), tokstrm5)
        }
        _ -> Error(fail(tokstrm2, "NULL, TRUE, FALSE, or DISTINCT FROM"))
      }
    }
  }
}

/// Level 8: `=` `<` `>` `<=` `>=` `<>` `!=` — **non-associative**: checked
/// once, never looped, so `a < b < c` is a parse error at the dangling
/// second `<`.
fn parse_comparison(
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  use #(left, tokstrm1) <- result.try(parse_keyword_ops(tokstrm))
  case comparison_op(ts.current(tokstrm1).kind) {
    None -> Ok(#(left, tokstrm1))
    Some(op) -> {
      let tokstrm2 = ts.advance(tokstrm1)
      use #(right, tokstrm3) <- result.try(parse_keyword_ops(tokstrm2))
      Ok(#(ast.BinaryOp(op, left, right), tokstrm3))
    }
  }
}

fn comparison_op(kind: TokenKind) -> Option(ast.BinaryOperator) {
  case kind {
    token.Operator(token.Eq) -> Some(ast.CmpEq)
    token.Operator(token.Lt) -> Some(ast.CmpLt)
    token.Operator(token.Gt) -> Some(ast.CmpGt)
    token.Operator(token.Le) -> Some(ast.CmpLe)
    token.Operator(token.Ge) -> Some(ast.CmpGe)
    token.Operator(token.NeAngle) -> Some(ast.CmpNeAngle)
    token.Operator(token.NeBang) -> Some(ast.CmpNeBang)
    _ -> None
  }
}

/// One of the five level-7 keyword-operator forms, plus whether it was
/// negated (a leading `NOT`) — see `classify_keyword_op`.
type KeywordOpForm {
  BetweenForm
  InForm
  LikeForm
  IlikeForm
  SimilarToForm
}

/// Level 7: `[NOT] BETWEEN ... AND ...`, `[NOT] IN (...)`, `[NOT] LIKE`,
/// `[NOT] ILIKE`, `[NOT] SIMILAR TO` — loop; needs 2-token lookahead
/// (`NOT` + next) to decide whether a `NOT` here belongs to this level at
/// all. See "2-token lookahead at level 7" in the implementation plan.
fn parse_keyword_ops(
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  use #(left, tokstrm1) <- result.try(parse_bitwise_etc(tokstrm))
  parse_keyword_ops_after(left, tokstrm1)
}

fn parse_keyword_ops_after(
  left: Expr,
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case classify_keyword_op(tokstrm) {
    None -> Ok(#(left, tokstrm))
    Some(#(negated, form, tokstrm1)) ->
      apply_keyword_op(left, negated, form, tokstrm1)
  }
}

/// Peeks (and, only on a real match, consumes) the operator keyword(s)
/// starting a level-7 form. Returns `None` — leaving `tokstrm` completely
/// untouched — for anything that isn't one, including a `NOT` not
/// followed by one of the other four: that `NOT` is left for the caller
/// (ultimately `parse_not`, level 10) to make sense of instead.
fn classify_keyword_op(
  tokstrm: TokenStream,
) -> Option(#(Bool, KeywordOpForm, TokenStream)) {
  case ts.current(tokstrm).kind {
    token.Keyword(token.KwBetween) ->
      Some(#(False, BetweenForm, ts.advance(tokstrm)))
    token.Keyword(token.KwIn) -> Some(#(False, InForm, ts.advance(tokstrm)))
    token.Keyword(token.KwLike) -> Some(#(False, LikeForm, ts.advance(tokstrm)))
    token.Keyword(token.KwIlike) ->
      Some(#(False, IlikeForm, ts.advance(tokstrm)))
    token.Keyword(token.KwSimilar) ->
      case similar_to_form(ts.advance(tokstrm)) {
        Some(tokstrm1) -> Some(#(False, SimilarToForm, tokstrm1))
        None -> None
      }
    token.Keyword(token.KwNot) -> {
      let tokstrm1 = ts.advance(tokstrm)
      case ts.current(tokstrm1).kind {
        token.Keyword(token.KwBetween) ->
          Some(#(True, BetweenForm, ts.advance(tokstrm1)))
        token.Keyword(token.KwIn) -> Some(#(True, InForm, ts.advance(tokstrm1)))
        token.Keyword(token.KwLike) ->
          Some(#(True, LikeForm, ts.advance(tokstrm1)))
        token.Keyword(token.KwIlike) ->
          Some(#(True, IlikeForm, ts.advance(tokstrm1)))
        token.Keyword(token.KwSimilar) ->
          case similar_to_form(ts.advance(tokstrm1)) {
            Some(tokstrm2) -> Some(#(True, SimilarToForm, tokstrm2))
            None -> None
          }
        _ -> None
      }
    }
    _ -> None
  }
}

fn similar_to_form(tokstrm: TokenStream) -> Option(TokenStream) {
  case ts.current(tokstrm).kind {
    token.Keyword(token.KwTo) -> Some(ts.advance(tokstrm))
    _ -> None
  }
}

fn apply_keyword_op(
  left: Expr,
  negated: Bool,
  form: KeywordOpForm,
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case form {
    BetweenForm -> {
      // `bound_expr` (level 6 or tighter) for both bounds — see the
      // "Operand binding" note in the implementation plan.
      use #(low, tokstrm1) <- result.try(parse_bitwise_etc(tokstrm))
      use #(_, tokstrm2) <- result.try(expect_keyword(
        tokstrm1,
        token.KwAnd,
        "AND",
      ))
      use #(high, tokstrm3) <- result.try(parse_bitwise_etc(tokstrm2))
      parse_keyword_ops_after(ast.Between(left, negated, low, high), tokstrm3)
    }
    InForm -> {
      use #(_, tokstrm1) <- result.try(expect_punct(
        tokstrm,
        token.LeftParen,
        "(",
      ))
      use #(items, tokstrm2) <- result.try(parse_expr_list(tokstrm1))
      use #(_, tokstrm3) <- result.try(expect_punct(
        tokstrm2,
        token.RightParen,
        ")",
      ))
      parse_keyword_ops_after(ast.InList(left, negated, items), tokstrm3)
    }
    LikeForm -> {
      use #(pattern, tokstrm1) <- result.try(parse_bitwise_etc(tokstrm))
      parse_keyword_ops_after(ast.Like(left, negated, False, pattern), tokstrm1)
    }
    IlikeForm -> {
      use #(pattern, tokstrm1) <- result.try(parse_bitwise_etc(tokstrm))
      parse_keyword_ops_after(ast.Like(left, negated, True, pattern), tokstrm1)
    }
    SimilarToForm -> {
      use #(pattern, tokstrm1) <- result.try(parse_bitwise_etc(tokstrm))
      parse_keyword_ops_after(ast.SimilarTo(left, negated, pattern), tokstrm1)
    }
  }
}

/// `expr (',' expr)*`, each item a full unrestricted `expr` (level 12) —
/// used for `IN`'s list and function-call arguments, per the "Operand
/// binding" note: their `(...)`/`,` delimiters already make the boundary
/// unambiguous, so they don't need `bound_expr`'s restriction.
fn parse_expr_list(
  tokstrm: TokenStream,
) -> Result(#(List(Expr), TokenStream), ParseError) {
  use #(first, tokstrm1) <- result.try(parse_or(tokstrm))
  parse_expr_list_loop([first], tokstrm1)
}

fn parse_expr_list_loop(
  acc: List(Expr),
  tokstrm: TokenStream,
) -> Result(#(List(Expr), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokstrm))
    True -> {
      let tokstrm1 = ts.advance(tokstrm)
      use #(next, tokstrm2) <- result.try(parse_or(tokstrm1))
      parse_expr_list_loop([next, ..acc], tokstrm2)
    }
  }
}

/// Level 6: `||` `&` `|` `#` `<<` `>>` `~` `~*` `!~` `!~*` `->` `->>` `#>`
/// `#>>` `@>` `<@`, and prefix `~` — left, loop. See "Why prefix `~` at
/// level 6 ... reproduces `~1 + 2` = `~(1 + 2)`" in the implementation
/// plan for why the operand-fetch below (both for a leading `~` and for
/// the ordinary case) calls `parse_additive` (level 5), not this level
/// recursively.
fn parse_bitwise_etc(
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  use #(left, tokstrm1) <- result.try(parse_bitwise_operand(tokstrm))
  parse_bitwise_etc_loop(left, tokstrm1)
}

fn parse_bitwise_operand(
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Operator(token.Tilde) -> {
      let tokstrm1 = ts.advance(tokstrm)
      use #(operand, tokstrm2) <- result.try(parse_additive(tokstrm1))
      Ok(#(ast.UnaryOp(ast.BitNot, operand), tokstrm2))
    }
    _ -> parse_additive(tokstrm)
  }
}

fn parse_bitwise_etc_loop(
  left: Expr,
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case bitwise_op(ts.current(tokstrm).kind) {
    None -> Ok(#(left, tokstrm))
    Some(op) -> {
      let tokstrm1 = ts.advance(tokstrm)
      use #(right, tokstrm2) <- result.try(parse_additive(tokstrm1))
      parse_bitwise_etc_loop(ast.BinaryOp(op, left, right), tokstrm2)
    }
  }
}

/// Bare `~` here (in binary/loop position, i.e. *after* a `left` already
/// exists) resolves to `RegexMatchOp`, never `BitNot` — the token itself
/// doesn't distinguish the two (see the note on `Tilde` in token.gleam);
/// only `parse_bitwise_operand` above, which only ever sees a leading
/// `~`, produces `BitNot`.
fn bitwise_op(kind: TokenKind) -> Option(ast.BinaryOperator) {
  case kind {
    token.Operator(token.Concat) -> Some(ast.ConcatOp)
    token.Operator(token.Amp) -> Some(ast.BitAnd)
    token.Operator(token.Pipe) -> Some(ast.BitOr)
    token.Operator(token.Hash) -> Some(ast.BitXor)
    token.Operator(token.Shl) -> Some(ast.ShiftLeft)
    token.Operator(token.Shr) -> Some(ast.ShiftRight)
    token.Operator(token.Tilde) -> Some(ast.RegexMatchOp)
    token.Operator(token.RegexMatchCi) -> Some(ast.RegexMatchCiOp)
    token.Operator(token.RegexNoMatch) -> Some(ast.RegexNoMatchOp)
    token.Operator(token.RegexNoMatchCi) -> Some(ast.RegexNoMatchCiOp)
    token.Operator(token.Arrow) -> Some(ast.JsonGet)
    token.Operator(token.ArrowText) -> Some(ast.JsonGetText)
    token.Operator(token.HashArrow) -> Some(ast.JsonGetPath)
    token.Operator(token.HashArrowText) -> Some(ast.JsonGetPathText)
    token.Operator(token.Contains) -> Some(ast.JsonContains)
    token.Operator(token.ContainedBy) -> Some(ast.JsonContainedBy)
    _ -> None
  }
}

/// Level 5: binary `+` `-` — left, loop.
fn parse_additive(
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  use #(left, tokstrm1) <- result.try(parse_multiplicative(tokstrm))
  parse_additive_loop(left, tokstrm1)
}

fn parse_additive_loop(
  left: Expr,
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Operator(token.Plus) -> {
      use #(right, tokstrm1) <- result.try(
        parse_multiplicative(ts.advance(tokstrm)),
      )
      parse_additive_loop(ast.BinaryOp(ast.Add, left, right), tokstrm1)
    }
    token.Operator(token.Minus) -> {
      use #(right, tokstrm1) <- result.try(
        parse_multiplicative(ts.advance(tokstrm)),
      )
      parse_additive_loop(ast.BinaryOp(ast.Sub, left, right), tokstrm1)
    }
    _ -> Ok(#(left, tokstrm))
  }
}

/// Level 4: `*` `/` `%` — left, loop.
fn parse_multiplicative(
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  use #(left, tokstrm1) <- result.try(parse_exponent(tokstrm))
  parse_multiplicative_loop(left, tokstrm1)
}

fn parse_multiplicative_loop(
  left: Expr,
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Operator(token.Star) -> {
      use #(right, tokstrm1) <- result.try(parse_exponent(ts.advance(tokstrm)))
      parse_multiplicative_loop(ast.BinaryOp(ast.Mul, left, right), tokstrm1)
    }
    token.Operator(token.Slash) -> {
      use #(right, tokstrm1) <- result.try(parse_exponent(ts.advance(tokstrm)))
      parse_multiplicative_loop(ast.BinaryOp(ast.Div, left, right), tokstrm1)
    }
    token.Operator(token.Percent) -> {
      use #(right, tokstrm1) <- result.try(parse_exponent(ts.advance(tokstrm)))
      parse_multiplicative_loop(ast.BinaryOp(ast.Mod, left, right), tokstrm1)
    }
    _ -> Ok(#(left, tokstrm))
  }
}

/// Level 3: `^` — left-associative, matching PostgreSQL's own quirk
/// (`2^3^2` is `(2^3)^2`, not the mathematically-conventional
/// right-associative reading).
fn parse_exponent(
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  use #(left, tokstrm1) <- result.try(parse_unary(tokstrm))
  parse_exponent_loop(left, tokstrm1)
}

fn parse_exponent_loop(
  left: Expr,
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Operator(token.Caret) -> {
      use #(right, tokstrm1) <- result.try(parse_unary(ts.advance(tokstrm)))
      parse_exponent_loop(ast.BinaryOp(ast.Pow, left, right), tokstrm1)
    }
    _ -> Ok(#(left, tokstrm))
  }
}

/// Level 2: prefix `+` `-` — right-associative, recurses into itself for
/// the operand (so `- - 1` parses, as `Neg(Neg(1))`).
fn parse_unary(
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Operator(token.Plus) -> {
      use #(operand, tokstrm1) <- result.try(parse_unary(ts.advance(tokstrm)))
      Ok(#(ast.UnaryOp(ast.Pos, operand), tokstrm1))
    }
    token.Operator(token.Minus) -> {
      use #(operand, tokstrm1) <- result.try(parse_unary(ts.advance(tokstrm)))
      Ok(#(ast.UnaryOp(ast.Neg, operand), tokstrm1))
    }
    _ -> parse_cast(tokstrm)
  }
}

/// Level 1: postfix `:: data_type` — left, loop.
fn parse_cast(
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  use #(left, tokstrm1) <- result.try(parse_primary(tokstrm))
  parse_cast_loop(left, tokstrm1)
}

fn parse_cast_loop(
  left: Expr,
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Operator(token.Cast) -> {
      use #(dt, tokstrm1) <- result.try(parse_data_type(ts.advance(tokstrm)))
      parse_cast_loop(ast.Cast(left, dt), tokstrm1)
    }
    _ -> Ok(#(left, tokstrm))
  }
}

/// Literals, `column_ref`, `function_call`, or a parenthesized `expr`.
fn parse_primary(
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  let tok = ts.current(tokstrm)
  case tok.kind {
    token.IntegerLiteral(text) ->
      Ok(#(ast.IntLiteral(text), ts.advance(tokstrm)))
    token.NumericLiteral(text) ->
      Ok(#(ast.NumericLiteral(text), ts.advance(tokstrm)))
    token.StringLiteral(value) ->
      Ok(#(ast.StringLiteral(value), ts.advance(tokstrm)))
    token.Keyword(token.KwTrue) ->
      Ok(#(ast.BoolLiteral(True), ts.advance(tokstrm)))
    token.Keyword(token.KwFalse) ->
      Ok(#(ast.BoolLiteral(False), ts.advance(tokstrm)))
    token.Keyword(token.KwNull) -> Ok(#(ast.NullLiteral, ts.advance(tokstrm)))
    token.LeftParen -> {
      use #(inner, tokstrm1) <- result.try(parse_or(ts.advance(tokstrm)))
      use #(_, tokstrm2) <- result.try(expect_punct(
        tokstrm1,
        token.RightParen,
        ")",
      ))
      Ok(#(inner, tokstrm2))
    }
    token.Identifier(name) ->
      parse_identifier_primary(name, tok.span, ts.advance(tokstrm))
    token.QuotedIdentifier(name) ->
      parse_identifier_primary(name, tok.span, ts.advance(tokstrm))
    _ -> Error(fail(tokstrm, "an expression"))
  }
}

/// `identifier` immediately followed by `(` is a `function_call` (§8.3);
/// otherwise it's a `column_ref`, the one `Expr` variant carrying its own
/// `Span` — see the note on `ColumnRef` in ast.gleam.
fn parse_identifier_primary(
  name: String,
  span: Span,
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.LeftParen) {
    False -> Ok(#(ast.ColumnRef(name, span), tokstrm))
    True -> {
      use #(args, tokstrm1) <- result.try(parse_call_args(ts.advance(tokstrm)))
      use #(_, tokstrm2) <- result.try(expect_punct(
        tokstrm1,
        token.RightParen,
        ")",
      ))
      Ok(#(ast.FunctionCall(name, args), tokstrm2))
    }
  }
}

fn parse_call_args(
  tokstrm: TokenStream,
) -> Result(#(List(Expr), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.RightParen) {
    True -> Ok(#([], tokstrm))
    False -> parse_expr_list(tokstrm)
  }
}

//-----------------------------------------------------------------------------
// data_type (spec.md §9.1)
//-----------------------------------------------------------------------------

fn parse_data_type(
  tokstrm: TokenStream,
) -> Result(#(DataType, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Keyword(token.KwBigint) -> Ok(#(ast.DtBigint, ts.advance(tokstrm)))
    token.Keyword(token.KwBoolean) -> Ok(#(ast.DtBoolean, ts.advance(tokstrm)))
    token.Keyword(token.KwChar) ->
      parse_optional_length(ts.advance(tokstrm), ast.DtChar)
    token.Keyword(token.KwDate) -> Ok(#(ast.DtDate, ts.advance(tokstrm)))
    token.Keyword(token.KwDecimal) ->
      parse_optional_precision_scale(ts.advance(tokstrm), ast.DtDecimal)
    token.Keyword(token.KwDouble) -> {
      // `DOUBLE PRECISION`: two keywords, one type — bare `DOUBLE` with
      // no following `PRECISION` is a parse error, not a standalone
      // type. See the "data_type parsing" section of the plan.
      use #(_, tokstrm1) <- result.try(expect_keyword(
        ts.advance(tokstrm),
        token.KwPrecision,
        "PRECISION",
      ))
      Ok(#(ast.DtDouble, tokstrm1))
    }
    token.Keyword(token.KwHlc) -> Ok(#(ast.DtHlc, ts.advance(tokstrm)))
    token.Keyword(token.KwInt) -> Ok(#(ast.DtInt, ts.advance(tokstrm)))
    token.Keyword(token.KwInteger) -> Ok(#(ast.DtInteger, ts.advance(tokstrm)))
    token.Keyword(token.KwInterval) ->
      Ok(#(ast.DtInterval, ts.advance(tokstrm)))
    token.Keyword(token.KwJson) -> Ok(#(ast.DtJson, ts.advance(tokstrm)))
    token.Keyword(token.KwJsonb) -> Ok(#(ast.DtJsonb, ts.advance(tokstrm)))
    token.Keyword(token.KwNumeric) ->
      parse_optional_precision_scale(ts.advance(tokstrm), ast.DtNumeric)
    token.Keyword(token.KwReal) -> Ok(#(ast.DtReal, ts.advance(tokstrm)))
    token.Keyword(token.KwSmallint) ->
      Ok(#(ast.DtSmallint, ts.advance(tokstrm)))
    token.Keyword(token.KwText) -> Ok(#(ast.DtText, ts.advance(tokstrm)))
    token.Keyword(token.KwTime) -> Ok(#(ast.DtTime, ts.advance(tokstrm)))
    token.Keyword(token.KwTimestamp) ->
      Ok(#(ast.DtTimestamp, ts.advance(tokstrm)))
    token.Keyword(token.KwTimestamptz) ->
      Ok(#(ast.DtTimestamptz, ts.advance(tokstrm)))
    token.Keyword(token.KwUuid) -> Ok(#(ast.DtUuid, ts.advance(tokstrm)))
    token.Keyword(token.KwVarchar) ->
      parse_optional_length(ts.advance(tokstrm), ast.DtVarchar)
    _ -> Error(fail(tokstrm, "a data type"))
  }
}

fn parse_optional_length(
  tokstrm: TokenStream,
  build: fn(Option(Int)) -> DataType,
) -> Result(#(DataType, TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.LeftParen) {
    False -> Ok(#(build(None), tokstrm))
    True -> {
      use #(n, tokstrm1) <- result.try(
        parse_int_literal_value(ts.advance(tokstrm)),
      )
      use #(_, tokstrm2) <- result.try(expect_punct(
        tokstrm1,
        token.RightParen,
        ")",
      ))
      Ok(#(build(Some(n)), tokstrm2))
    }
  }
}

fn parse_optional_precision_scale(
  tokstrm: TokenStream,
  build: fn(Option(Int), Option(Int)) -> DataType,
) -> Result(#(DataType, TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.LeftParen) {
    False -> Ok(#(build(None, None), tokstrm))
    True -> {
      use #(p, tokstrm1) <- result.try(
        parse_int_literal_value(ts.advance(tokstrm)),
      )
      case ts.peek_kind(tokstrm1, token.Comma) {
        True -> {
          use #(s, tokstrm2) <- result.try(
            parse_int_literal_value(ts.advance(tokstrm1)),
          )
          use #(_, tokstrm3) <- result.try(expect_punct(
            tokstrm2,
            token.RightParen,
            ")",
          ))
          Ok(#(build(Some(p), Some(s)), tokstrm3))
        }
        False -> {
          use #(_, tokstrm2) <- result.try(expect_punct(
            tokstrm1,
            token.RightParen,
            ")",
          ))
          Ok(#(build(Some(p), None), tokstrm2))
        }
      }
    }
  }
}

fn parse_int_literal_value(
  tokstrm: TokenStream,
) -> Result(#(Int, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.IntegerLiteral(text) ->
      case int.parse(text) {
        Ok(n) -> Ok(#(n, ts.advance(tokstrm)))
        Error(Nil) -> Error(fail(tokstrm, "an integer"))
      }
    _ -> Error(fail(tokstrm, "an integer"))
  }
}

//-----------------------------------------------------------------------------
// CREATE STREAM (spec.md §9.1)
//-----------------------------------------------------------------------------

fn parse_create_stream(
  tokstrm: TokenStream,
) -> Result(#(Statement, TokenStream), ParseError) {
  let start_span = ts.current(tokstrm).span
  use #(_, tokstrm1) <- result.try(expect_keyword(
    tokstrm,
    token.KwCreate,
    "CREATE",
  ))
  use #(_, tokstrm2) <- result.try(expect_keyword(
    tokstrm1,
    token.KwStream,
    "STREAM",
  ))
  use #(name, _, tokstrm3) <- result.try(expect_identifier(
    tokstrm2,
    "a tokstrm name",
  ))
  use #(_, tokstrm4) <- result.try(expect_punct(tokstrm3, token.LeftParen, "("))
  use #(elements, tokstrm5) <- result.try(parse_stream_elements(tokstrm4))
  use #(rparen_span, tokstrm6) <- result.try(expect_punct(
    tokstrm5,
    token.RightParen,
    ")",
  ))
  let #(end_pos, tokstrm7) =
    ts.consume_optional_semicolon(tokstrm6, rparen_span.end)
  let span = token.Span(start_span.start, end_pos)
  Ok(#(ast.CreateStream(name, elements, span), tokstrm7))
}

fn parse_stream_elements(
  tokstrm: TokenStream,
) -> Result(#(List(ast.StreamElement), TokenStream), ParseError) {
  use #(first, tokstrm1) <- result.try(parse_stream_element(tokstrm))
  parse_stream_elements_loop([first], tokstrm1)
}

fn parse_stream_elements_loop(
  acc: List(ast.StreamElement),
  tokstrm: TokenStream,
) -> Result(#(List(ast.StreamElement), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokstrm))
    True -> {
      use #(next, tokstrm1) <- result.try(
        parse_stream_element(ts.advance(tokstrm)),
      )
      parse_stream_elements_loop([next, ..acc], tokstrm1)
    }
  }
}

/// Dispatches on `CONSTRAINT` (→ `table_constraint`) vs. an identifier
/// (→ `column_def`) — the only two `stream_element` alternatives (§9.1).
fn parse_stream_element(
  tokstrm: TokenStream,
) -> Result(#(ast.StreamElement, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Keyword(token.KwConstraint) -> {
      use #(check, tokstrm1) <- result.try(parse_named_check(tokstrm))
      Ok(#(ast.TableConstraint(check, check.span), tokstrm1))
    }
    _ -> {
      use #(col, tokstrm1) <- result.try(parse_column_def(tokstrm))
      Ok(#(ast.Column(col), tokstrm1))
    }
  }
}

/// `CONSTRAINT constraint_name CHECK ( expr )` — shared by a column's own
/// `CONSTRAINT` clause, a standalone `table_constraint`, `ADD
/// CONSTRAINT`, and (via its `expr`) nothing else.
fn parse_named_check(
  tokstrm: TokenStream,
) -> Result(#(ast.NamedCheck, TokenStream), ParseError) {
  let start_span = ts.current(tokstrm).span
  use #(_, tokstrm1) <- result.try(expect_keyword(
    tokstrm,
    token.KwConstraint,
    "CONSTRAINT",
  ))
  use #(name, _, tokstrm2) <- result.try(expect_identifier(
    tokstrm1,
    "a constraint name",
  ))
  use #(_, tokstrm3) <- result.try(expect_keyword(
    tokstrm2,
    token.KwCheck,
    "CHECK",
  ))
  use #(_, tokstrm4) <- result.try(expect_punct(tokstrm3, token.LeftParen, "("))
  use #(expr, tokstrm5) <- result.try(parse_or(tokstrm4))
  use #(rparen_span, tokstrm6) <- result.try(expect_punct(
    tokstrm5,
    token.RightParen,
    ")",
  ))
  let span = token.Span(start_span.start, rparen_span.end)
  Ok(#(ast.NamedCheck(name, expr, span), tokstrm6))
}

/// Clauses accumulated while scanning a `column_def`'s `column_clause*`
/// (§9.1). `checks` accumulates in reverse (prepend, then
/// `list.reverse` once done in `parse_column_def`) — the usual O(n) list-
/// building idiom rather than O(n²) appending.
type ClauseAcc {
  ClauseAcc(
    optional: Bool,
    default: Option(Expr),
    generated: Option(ast.GeneratedClause),
    checks: List(ast.NamedCheck),
  )
}

fn parse_column_def(
  tokstrm: TokenStream,
) -> Result(#(ast.ColumnDef, TokenStream), ParseError) {
  let start_span = ts.current(tokstrm).span
  use #(name, _, tokstrm1) <- result.try(expect_identifier(
    tokstrm,
    "a column name",
  ))
  use #(dt, tokstrm2) <- result.try(parse_data_type(tokstrm1))
  use #(acc, tokstrm3) <- result.try(parse_column_clauses(
    tokstrm2,
    ClauseAcc(optional: False, default: None, generated: None, checks: []),
  ))
  // The span ends where the next token (`,` or `)`) begins — good enough
  // to underline "this column_def" without threading a precise end
  // position out of an arbitrary `DEFAULT`/`CHECK` expr, which carries
  // no span of its own; see the note on `Expr` spans in ast.gleam.
  let span = token.Span(start_span.start, ts.current(tokstrm3).span.start)
  let col =
    ast.ColumnDef(
      name: name,
      data_type: dt,
      optional: acc.optional,
      default: acc.default,
      generated: acc.generated,
      checks: list.reverse(acc.checks),
      span: span,
    )
  Ok(#(col, tokstrm3))
}

fn parse_column_clauses(
  tokstrm: TokenStream,
  acc: ClauseAcc,
) -> Result(#(ClauseAcc, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Keyword(token.KwOptional) ->
      parse_column_clauses(
        ts.advance(tokstrm),
        ClauseAcc(..acc, optional: True),
      )
    token.Keyword(token.KwDefault) -> {
      use #(expr, tokstrm1) <- result.try(parse_or(ts.advance(tokstrm)))
      parse_column_clauses(tokstrm1, ClauseAcc(..acc, default: Some(expr)))
    }
    token.Keyword(token.KwGenerated) -> {
      use #(clause, tokstrm1) <- result.try(parse_generated_clause(tokstrm))
      parse_column_clauses(tokstrm1, ClauseAcc(..acc, generated: Some(clause)))
    }
    token.Keyword(token.KwConstraint) -> {
      use #(check, tokstrm1) <- result.try(parse_named_check(tokstrm))
      parse_column_clauses(
        tokstrm1,
        ClauseAcc(..acc, checks: [check, ..acc.checks]),
      )
    }
    token.Keyword(token.KwNot) -> {
      // §9.3: `NOT NULL` is never legal to write (columns are `NOT NULL`
      // by default already) — reported as `ExplicitNotNull`, not a
      // generic parse error, so the caller can render spec.md's own
      // guidance ("use OPTIONAL instead").
      let not_span = ts.current(tokstrm).span
      case ts.current(ts.advance(tokstrm)).kind {
        token.Keyword(token.KwNull) -> {
          let null_span = ts.current(ts.advance(tokstrm)).span
          Error(
            ExplicitNotNull(span: token.Span(not_span.start, null_span.end)),
          )
        }
        _ -> Error(fail(tokstrm, "OPTIONAL, DEFAULT, GENERATED, or CONSTRAINT"))
      }
    }
    _ -> Ok(#(acc, tokstrm))
  }
}

fn parse_generated_clause(
  tokstrm: TokenStream,
) -> Result(#(ast.GeneratedClause, TokenStream), ParseError) {
  use #(_, tokstrm1) <- result.try(expect_keyword(
    tokstrm,
    token.KwGenerated,
    "GENERATED",
  ))
  use #(_, tokstrm2) <- result.try(expect_keyword(
    tokstrm1,
    token.KwAlways,
    "ALWAYS",
  ))
  use #(_, tokstrm3) <- result.try(expect_keyword(tokstrm2, token.KwAs, "AS"))
  use #(_, tokstrm4) <- result.try(expect_punct(tokstrm3, token.LeftParen, "("))
  use #(expr, tokstrm5) <- result.try(parse_or(tokstrm4))
  use #(_, tokstrm6) <- result.try(expect_punct(tokstrm5, token.RightParen, ")"))
  case ts.current(tokstrm6).kind {
    token.Keyword(token.KwStored) ->
      Ok(#(ast.GeneratedClause(expr, ast.Stored), ts.advance(tokstrm6)))
    token.Keyword(token.KwVirtual) ->
      Ok(#(ast.GeneratedClause(expr, ast.Virtual), ts.advance(tokstrm6)))
    _ -> Error(MissingGeneratedStorage(span: ts.current(tokstrm6).span))
  }
}

//-----------------------------------------------------------------------------
// ALTER STREAM (spec.md §10.1)
//-----------------------------------------------------------------------------

fn parse_alter_stream(
  tokstrm: TokenStream,
) -> Result(#(Statement, TokenStream), ParseError) {
  let start_span = ts.current(tokstrm).span
  use #(_, tokstrm1) <- result.try(expect_keyword(
    tokstrm,
    token.KwAlter,
    "ALTER",
  ))
  use #(_, tokstrm2) <- result.try(expect_keyword(
    tokstrm1,
    token.KwStream,
    "STREAM",
  ))
  use #(name, _, tokstrm3) <- result.try(expect_identifier(
    tokstrm2,
    "a tokstrm name",
  ))
  use #(actions, tokstrm4) <- result.try(parse_alter_actions(tokstrm3))
  let #(end_pos, tokstrm5) =
    ts.consume_optional_semicolon(tokstrm4, ts.current(tokstrm4).span.start)
  let span = token.Span(start_span.start, end_pos)
  Ok(#(ast.AlterStream(name, actions, span), tokstrm5))
}

fn parse_alter_actions(
  tokstrm: TokenStream,
) -> Result(#(List(ast.AlterAction), TokenStream), ParseError) {
  use #(first, tokstrm1) <- result.try(parse_alter_action(tokstrm))
  parse_alter_actions_loop([first], tokstrm1)
}

fn parse_alter_actions_loop(
  acc: List(ast.AlterAction),
  tokstrm: TokenStream,
) -> Result(#(List(ast.AlterAction), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokstrm))
    True -> {
      use #(next, tokstrm1) <- result.try(
        parse_alter_action(ts.advance(tokstrm)),
      )
      parse_alter_actions_loop([next, ..acc], tokstrm1)
    }
  }
}

/// `ADD`/`DROP` (each further dispatching on `COLUMN` vs. `CONSTRAINT`)
/// or `ALTER COLUMN name TYPE data_type` (§10.1). `COLUMN` is mandatory
/// throughout, unlike PostgreSQL — see spec.md §3.3.
fn parse_alter_action(
  tokstrm: TokenStream,
) -> Result(#(ast.AlterAction, TokenStream), ParseError) {
  let start_span = ts.current(tokstrm).span
  case ts.current(tokstrm).kind {
    token.Keyword(token.KwAdd) ->
      case ts.current(ts.advance(tokstrm)).kind {
        token.Keyword(token.KwColumn) -> {
          use #(col, tokstrm1) <- result.try(
            parse_column_def(ts.advance(ts.advance(tokstrm))),
          )
          let span =
            token.Span(start_span.start, ts.current(tokstrm1).span.start)
          Ok(#(ast.AddColumn(col, span), tokstrm1))
        }
        token.Keyword(token.KwConstraint) -> {
          use #(check, tokstrm1) <- result.try(
            parse_named_check(ts.advance(tokstrm)),
          )
          Ok(#(ast.AddConstraint(check), tokstrm1))
        }
        _ -> Error(fail(ts.advance(tokstrm), "COLUMN or CONSTRAINT"))
      }
    token.Keyword(token.KwDrop) ->
      case ts.current(ts.advance(tokstrm)).kind {
        token.Keyword(token.KwColumn) -> {
          use #(name, name_span, tokstrm1) <- result.try(expect_identifier(
            ts.advance(ts.advance(tokstrm)),
            "a column name",
          ))
          let span = token.Span(start_span.start, name_span.end)
          Ok(#(ast.DropColumn(name, span), tokstrm1))
        }
        token.Keyword(token.KwConstraint) -> {
          use #(name, name_span, tokstrm1) <- result.try(expect_identifier(
            ts.advance(ts.advance(tokstrm)),
            "a constraint name",
          ))
          let span = token.Span(start_span.start, name_span.end)
          Ok(#(ast.DropConstraint(name, span), tokstrm1))
        }
        _ -> Error(fail(ts.advance(tokstrm), "COLUMN or CONSTRAINT"))
      }
    token.Keyword(token.KwAlter) -> {
      use #(_, tokstrm1) <- result.try(expect_keyword(
        ts.advance(tokstrm),
        token.KwColumn,
        "COLUMN",
      ))
      use #(name, _, tokstrm2) <- result.try(expect_identifier(
        tokstrm1,
        "a column name",
      ))
      use #(_, tokstrm3) <- result.try(expect_keyword(
        tokstrm2,
        token.KwType,
        "TYPE",
      ))
      use #(dt, tokstrm4) <- result.try(parse_data_type(tokstrm3))
      let span = token.Span(start_span.start, ts.current(tokstrm4).span.start)
      Ok(#(ast.AlterColumnType(name, dt, span), tokstrm4))
    }
    _ -> Error(fail(tokstrm, "ADD, DROP, or ALTER"))
  }
}

//-----------------------------------------------------------------------------
// INSERT (spec.md §11.1)
//-----------------------------------------------------------------------------

fn parse_insert(
  tokstrm: TokenStream,
) -> Result(#(Statement, TokenStream), ParseError) {
  let start_span = ts.current(tokstrm).span
  use #(_, tokstrm1) <- result.try(expect_keyword(
    tokstrm,
    token.KwInsert,
    "INSERT",
  ))
  use #(_, tokstrm2) <- result.try(expect_keyword(
    tokstrm1,
    token.KwInto,
    "INTO",
  ))
  use #(name, _, tokstrm3) <- result.try(expect_identifier(
    tokstrm2,
    "a tokstrm name",
  ))
  // §11.2: the column list is mandatory — no positional form.
  use #(_, tokstrm4) <- result.try(expect_punct(tokstrm3, token.LeftParen, "("))
  use #(columns, tokstrm5) <- result.try(parse_identifier_list(tokstrm4))
  use #(_, tokstrm6) <- result.try(expect_punct(tokstrm5, token.RightParen, ")"))
  use #(_, tokstrm7) <- result.try(expect_keyword(
    tokstrm6,
    token.KwValues,
    "VALUES",
  ))
  use #(rows, tokstrm8) <- result.try(parse_value_rows(tokstrm7))
  use #(on_conflict, tokstrm9) <- result.try(parse_optional_on_conflict(
    tokstrm8,
  ))
  use #(returning, tokstrm10) <- result.try(parse_optional_returning(tokstrm9))
  let #(end_pos, tokstrm11) =
    ts.consume_optional_semicolon(tokstrm10, ts.current(tokstrm10).span.start)
  let span = token.Span(start_span.start, end_pos)
  Ok(#(ast.Insert(name, columns, rows, on_conflict, returning, span), tokstrm11))
}

fn parse_identifier_list(
  tokstrm: TokenStream,
) -> Result(#(List(String), TokenStream), ParseError) {
  use #(first, _, tokstrm1) <- result.try(expect_identifier(
    tokstrm,
    "a column name",
  ))
  parse_identifier_list_loop([first], tokstrm1)
}

fn parse_identifier_list_loop(
  acc: List(String),
  tokstrm: TokenStream,
) -> Result(#(List(String), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokstrm))
    True -> {
      use #(next, _, tokstrm1) <- result.try(expect_identifier(
        ts.advance(tokstrm),
        "a column name",
      ))
      parse_identifier_list_loop([next, ..acc], tokstrm1)
    }
  }
}

fn parse_value_rows(
  tokstrm: TokenStream,
) -> Result(#(List(List(ast.Value)), TokenStream), ParseError) {
  use #(first, tokstrm1) <- result.try(parse_value_row(tokstrm))
  parse_value_rows_loop([first], tokstrm1)
}

fn parse_value_rows_loop(
  acc: List(List(ast.Value)),
  tokstrm: TokenStream,
) -> Result(#(List(List(ast.Value)), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokstrm))
    True -> {
      use #(next, tokstrm1) <- result.try(parse_value_row(ts.advance(tokstrm)))
      parse_value_rows_loop([next, ..acc], tokstrm1)
    }
  }
}

fn parse_value_row(
  tokstrm: TokenStream,
) -> Result(#(List(ast.Value), TokenStream), ParseError) {
  use #(_, tokstrm1) <- result.try(expect_punct(tokstrm, token.LeftParen, "("))
  use #(values, tokstrm2) <- result.try(parse_values(tokstrm1))
  use #(_, tokstrm3) <- result.try(expect_punct(tokstrm2, token.RightParen, ")"))
  Ok(#(values, tokstrm3))
}

fn parse_values(
  tokstrm: TokenStream,
) -> Result(#(List(ast.Value), TokenStream), ParseError) {
  use #(first, tokstrm1) <- result.try(parse_value(tokstrm))
  parse_values_loop([first], tokstrm1)
}

fn parse_values_loop(
  acc: List(ast.Value),
  tokstrm: TokenStream,
) -> Result(#(List(ast.Value), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokstrm))
    True -> {
      use #(next, tokstrm1) <- result.try(parse_value(ts.advance(tokstrm)))
      parse_values_loop([next, ..acc], tokstrm1)
    }
  }
}

fn parse_value(
  tokstrm: TokenStream,
) -> Result(#(ast.Value, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Keyword(token.KwDefault) ->
      Ok(#(ast.ValueDefault, ts.advance(tokstrm)))
    _ -> {
      use #(expr, tokstrm1) <- result.try(parse_or(tokstrm))
      Ok(#(ast.ValueExpr(expr), tokstrm1))
    }
  }
}

fn parse_optional_on_conflict(
  tokstrm: TokenStream,
) -> Result(#(Bool, TokenStream), ParseError) {
  case ts.peek_keyword(tokstrm, token.KwOn) {
    False -> Ok(#(False, tokstrm))
    True -> {
      use #(_, tokstrm1) <- result.try(expect_keyword(
        ts.advance(tokstrm),
        token.KwConflict,
        "CONFLICT",
      ))
      use #(_, tokstrm2) <- result.try(expect_keyword(
        tokstrm1,
        token.KwDo,
        "DO",
      ))
      use #(_, tokstrm3) <- result.try(expect_keyword(
        tokstrm2,
        token.KwNothing,
        "NOTHING",
      ))
      Ok(#(True, tokstrm3))
    }
  }
}

fn parse_optional_returning(
  tokstrm: TokenStream,
) -> Result(#(Option(List(ast.ReturningItem)), TokenStream), ParseError) {
  case ts.peek_keyword(tokstrm, token.KwReturning) {
    False -> Ok(#(None, tokstrm))
    True -> {
      use #(items, tokstrm1) <- result.try(
        parse_returning_items(ts.advance(tokstrm)),
      )
      Ok(#(Some(items), tokstrm1))
    }
  }
}

fn parse_returning_items(
  tokstrm: TokenStream,
) -> Result(#(List(ast.ReturningItem), TokenStream), ParseError) {
  use #(first, tokstrm1) <- result.try(parse_returning_item(tokstrm))
  parse_returning_items_loop([first], tokstrm1)
}

fn parse_returning_items_loop(
  acc: List(ast.ReturningItem),
  tokstrm: TokenStream,
) -> Result(#(List(ast.ReturningItem), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokstrm))
    True -> {
      use #(next, tokstrm1) <- result.try(
        parse_returning_item(ts.advance(tokstrm)),
      )
      parse_returning_items_loop([next, ..acc], tokstrm1)
    }
  }
}

fn parse_returning_item(
  tokstrm: TokenStream,
) -> Result(#(ast.ReturningItem, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Operator(token.Star) -> Ok(#(ast.ReturningStar, ts.advance(tokstrm)))
    _ -> {
      use #(expr, tokstrm1) <- result.try(parse_or(tokstrm))
      case ts.peek_keyword(tokstrm1, token.KwAs) {
        False -> Ok(#(ast.ReturningExpr(expr, None), tokstrm1))
        True -> {
          use #(alias, _, tokstrm2) <- result.try(expect_identifier(
            ts.advance(tokstrm1),
            "an alias",
          ))
          Ok(#(ast.ReturningExpr(expr, Some(alias)), tokstrm2))
        }
      }
    }
  }
}
//-----------------------------------------------------------------------------
