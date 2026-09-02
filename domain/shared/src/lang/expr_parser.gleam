import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lang/expr_ast.{type DataType, type Expr}
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

//-----------------------------------------------------------------------------
// Parse-error helpers, built on `ts` (lang/token_stream)'s cursor primitives
//-----------------------------------------------------------------------------

pub fn fail(tokstrm: TokenStream, expected: String) -> ParseError {
  case ts.current(tokstrm).kind {
    token.Eof -> UnexpectedEof(expected: expected)
    _ -> UnexpectedToken(found: ts.current(tokstrm), expected: expected)
  }
}

pub fn expect_keyword(
  tokstrm: TokenStream,
  kw: token.Keyword,
  name: String,
) -> Result(#(Span, TokenStream), ParseError) {
  case ts.peek_keyword(tokstrm, kw) {
    True -> Ok(#(ts.current(tokstrm).span, ts.advance(tokstrm)))
    False -> Error(fail(tokstrm, name))
  }
}

pub fn expect_punct(
  tokstrm: TokenStream,
  kind: TokenKind,
  name: String,
) -> Result(#(Span, TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, kind) {
    True -> Ok(#(ts.current(tokstrm).span, ts.advance(tokstrm)))
    False -> Error(fail(tokstrm, name))
  }
}

pub fn expect_identifier(
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

pub fn expect_eof(tokstrm: TokenStream) -> Result(Nil, ParseError) {
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
pub fn parse_or(
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
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
      parse_or_loop(
        expr_ast.BinaryOp(expr_ast.LogicalOr, left, right),
        tokstrm2,
      )
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
      parse_and_loop(
        expr_ast.BinaryOp(expr_ast.LogicalAnd, left, right),
        tokstrm2,
      )
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
      Ok(#(expr_ast.UnaryOp(expr_ast.LogicalNot, operand), tokstrm2))
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
          parse_is_loop(expr_ast.IsNull(left, negated), ts.advance(tokstrm2))
        token.Keyword(token.KwTrue) ->
          parse_is_loop(
            expr_ast.IsBool(left, negated, True),
            ts.advance(tokstrm2),
          )
        token.Keyword(token.KwFalse) ->
          parse_is_loop(
            expr_ast.IsBool(left, negated, False),
            ts.advance(tokstrm2),
          )
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
          parse_is_loop(expr_ast.IsDistinctFrom(left, negated, right), tokstrm5)
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
      Ok(#(expr_ast.BinaryOp(op, left, right), tokstrm3))
    }
  }
}

fn comparison_op(kind: TokenKind) -> Option(expr_ast.BinaryOperator) {
  case kind {
    token.Operator(token.Eq) -> Some(expr_ast.CmpEq)
    token.Operator(token.Lt) -> Some(expr_ast.CmpLt)
    token.Operator(token.Gt) -> Some(expr_ast.CmpGt)
    token.Operator(token.Le) -> Some(expr_ast.CmpLe)
    token.Operator(token.Ge) -> Some(expr_ast.CmpGe)
    token.Operator(token.NeAngle) -> Some(expr_ast.CmpNeAngle)
    token.Operator(token.NeBang) -> Some(expr_ast.CmpNeBang)
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
      parse_keyword_ops_after(
        expr_ast.Between(left, negated, low, high),
        tokstrm3,
      )
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
      parse_keyword_ops_after(expr_ast.InList(left, negated, items), tokstrm3)
    }
    LikeForm -> {
      use #(pattern, tokstrm1) <- result.try(parse_bitwise_etc(tokstrm))
      parse_keyword_ops_after(
        expr_ast.Like(left, negated, False, pattern),
        tokstrm1,
      )
    }
    IlikeForm -> {
      use #(pattern, tokstrm1) <- result.try(parse_bitwise_etc(tokstrm))
      parse_keyword_ops_after(
        expr_ast.Like(left, negated, True, pattern),
        tokstrm1,
      )
    }
    SimilarToForm -> {
      use #(pattern, tokstrm1) <- result.try(parse_bitwise_etc(tokstrm))
      parse_keyword_ops_after(
        expr_ast.SimilarTo(left, negated, pattern),
        tokstrm1,
      )
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
      Ok(#(expr_ast.UnaryOp(expr_ast.BitNot, operand), tokstrm2))
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
      parse_bitwise_etc_loop(expr_ast.BinaryOp(op, left, right), tokstrm2)
    }
  }
}

/// Bare `~` here (in binary/loop position, i.e. *after* a `left` already
/// exists) resolves to `RegexMatchOp`, never `BitNot` — the token itself
/// doesn't distinguish the two (see the note on `Tilde` in token.gleam);
/// only `parse_bitwise_operand` above, which only ever sees a leading
/// `~`, produces `BitNot`.
fn bitwise_op(kind: TokenKind) -> Option(expr_ast.BinaryOperator) {
  case kind {
    token.Operator(token.Concat) -> Some(expr_ast.ConcatOp)
    token.Operator(token.Amp) -> Some(expr_ast.BitAnd)
    token.Operator(token.Pipe) -> Some(expr_ast.BitOr)
    token.Operator(token.Hash) -> Some(expr_ast.BitXor)
    token.Operator(token.Shl) -> Some(expr_ast.ShiftLeft)
    token.Operator(token.Shr) -> Some(expr_ast.ShiftRight)
    token.Operator(token.Tilde) -> Some(expr_ast.RegexMatchOp)
    token.Operator(token.RegexMatchCi) -> Some(expr_ast.RegexMatchCiOp)
    token.Operator(token.RegexNoMatch) -> Some(expr_ast.RegexNoMatchOp)
    token.Operator(token.RegexNoMatchCi) -> Some(expr_ast.RegexNoMatchCiOp)
    token.Operator(token.Arrow) -> Some(expr_ast.JsonGet)
    token.Operator(token.ArrowText) -> Some(expr_ast.JsonGetText)
    token.Operator(token.HashArrow) -> Some(expr_ast.JsonGetPath)
    token.Operator(token.HashArrowText) -> Some(expr_ast.JsonGetPathText)
    token.Operator(token.Contains) -> Some(expr_ast.JsonContains)
    token.Operator(token.ContainedBy) -> Some(expr_ast.JsonContainedBy)
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
      parse_additive_loop(
        expr_ast.BinaryOp(expr_ast.Add, left, right),
        tokstrm1,
      )
    }
    token.Operator(token.Minus) -> {
      use #(right, tokstrm1) <- result.try(
        parse_multiplicative(ts.advance(tokstrm)),
      )
      parse_additive_loop(
        expr_ast.BinaryOp(expr_ast.Sub, left, right),
        tokstrm1,
      )
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
      parse_multiplicative_loop(
        expr_ast.BinaryOp(expr_ast.Mul, left, right),
        tokstrm1,
      )
    }
    token.Operator(token.Slash) -> {
      use #(right, tokstrm1) <- result.try(parse_exponent(ts.advance(tokstrm)))
      parse_multiplicative_loop(
        expr_ast.BinaryOp(expr_ast.Div, left, right),
        tokstrm1,
      )
    }
    token.Operator(token.Percent) -> {
      use #(right, tokstrm1) <- result.try(parse_exponent(ts.advance(tokstrm)))
      parse_multiplicative_loop(
        expr_ast.BinaryOp(expr_ast.Mod, left, right),
        tokstrm1,
      )
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
      parse_exponent_loop(
        expr_ast.BinaryOp(expr_ast.Pow, left, right),
        tokstrm1,
      )
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
      Ok(#(expr_ast.UnaryOp(expr_ast.Pos, operand), tokstrm1))
    }
    token.Operator(token.Minus) -> {
      use #(operand, tokstrm1) <- result.try(parse_unary(ts.advance(tokstrm)))
      Ok(#(expr_ast.UnaryOp(expr_ast.Neg, operand), tokstrm1))
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
      parse_cast_loop(expr_ast.Cast(left, dt), tokstrm1)
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
      Ok(#(expr_ast.IntLiteral(text), ts.advance(tokstrm)))
    token.NumericLiteral(text) ->
      Ok(#(expr_ast.NumericLiteral(text), ts.advance(tokstrm)))
    token.StringLiteral(value) ->
      Ok(#(expr_ast.StringLiteral(value), ts.advance(tokstrm)))
    token.Keyword(token.KwTrue) ->
      Ok(#(expr_ast.BoolLiteral(True), ts.advance(tokstrm)))
    token.Keyword(token.KwFalse) ->
      Ok(#(expr_ast.BoolLiteral(False), ts.advance(tokstrm)))
    token.Keyword(token.KwNull) ->
      Ok(#(expr_ast.NullLiteral, ts.advance(tokstrm)))
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
/// `Span` — see the note on `ColumnRef` in expr_ast.gleam.
fn parse_identifier_primary(
  name: String,
  span: Span,
  tokstrm: TokenStream,
) -> Result(#(Expr, TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.LeftParen) {
    False -> Ok(#(expr_ast.ColumnRef(name, span), tokstrm))
    True -> {
      use #(args, tokstrm1) <- result.try(parse_call_args(ts.advance(tokstrm)))
      use #(_, tokstrm2) <- result.try(expect_punct(
        tokstrm1,
        token.RightParen,
        ")",
      ))
      Ok(#(expr_ast.FunctionCall(name, args), tokstrm2))
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

pub fn parse_data_type(
  tokstrm: TokenStream,
) -> Result(#(DataType, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Keyword(token.KwBigint) ->
      Ok(#(expr_ast.DtBigint, ts.advance(tokstrm)))
    token.Keyword(token.KwBoolean) ->
      Ok(#(expr_ast.DtBoolean, ts.advance(tokstrm)))
    token.Keyword(token.KwChar) ->
      parse_optional_length(ts.advance(tokstrm), expr_ast.DtChar)
    token.Keyword(token.KwDate) -> Ok(#(expr_ast.DtDate, ts.advance(tokstrm)))
    token.Keyword(token.KwDecimal) ->
      parse_optional_precision_scale(ts.advance(tokstrm), expr_ast.DtDecimal)
    token.Keyword(token.KwDouble) -> {
      // `DOUBLE PRECISION`: two keywords, one type — bare `DOUBLE` with
      // no following `PRECISION` is a parse error, not a standalone
      // type. See the "data_type parsing" section of the plan.
      use #(_, tokstrm1) <- result.try(expect_keyword(
        ts.advance(tokstrm),
        token.KwPrecision,
        "PRECISION",
      ))
      Ok(#(expr_ast.DtDouble, tokstrm1))
    }
    token.Keyword(token.KwInt) -> Ok(#(expr_ast.DtInt, ts.advance(tokstrm)))
    token.Keyword(token.KwInteger) ->
      Ok(#(expr_ast.DtInteger, ts.advance(tokstrm)))
    token.Keyword(token.KwInterval) ->
      Ok(#(expr_ast.DtInterval, ts.advance(tokstrm)))
    token.Keyword(token.KwJson) -> Ok(#(expr_ast.DtJson, ts.advance(tokstrm)))
    token.Keyword(token.KwJsonb) -> Ok(#(expr_ast.DtJsonb, ts.advance(tokstrm)))
    token.Keyword(token.KwNumeric) ->
      parse_optional_precision_scale(ts.advance(tokstrm), expr_ast.DtNumeric)
    token.Keyword(token.KwReal) -> Ok(#(expr_ast.DtReal, ts.advance(tokstrm)))
    token.Keyword(token.KwSmallint) ->
      Ok(#(expr_ast.DtSmallint, ts.advance(tokstrm)))
    token.Keyword(token.KwText) -> Ok(#(expr_ast.DtText, ts.advance(tokstrm)))
    token.Keyword(token.KwTime) -> Ok(#(expr_ast.DtTime, ts.advance(tokstrm)))
    token.Keyword(token.KwTimestamp) ->
      Ok(#(expr_ast.DtTimestamp, ts.advance(tokstrm)))
    token.Keyword(token.KwTimestamptz) ->
      Ok(#(expr_ast.DtTimestamptz, ts.advance(tokstrm)))
    token.Keyword(token.KwUuid) -> Ok(#(expr_ast.DtUuid, ts.advance(tokstrm)))
    token.Keyword(token.KwVarchar) ->
      parse_optional_length(ts.advance(tokstrm), expr_ast.DtVarchar)
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
