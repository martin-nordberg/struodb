import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lang/ast.{type DataType, type Expr, type Statement}
import lang/token.{type Position, type Span, type Token, type TokenKind}

//-----------------------------------------------------------------------------
// Recursive descent, one token of lookahead for statement dispatch and
// most productions; the expression grammar needs 2-token lookahead in
// exactly one place (`parse_keyword_ops_after`, level 7). Every parse_*
// function below takes the remaining `List(Token)` (always ending in
// `Eof`, never fully consumed) and returns
// `Result(#(<thing>, List(Token)), ParseError)`.
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

pub fn parse(tokens: List(Token)) -> Result(Statement, ParseError) {
  use #(stmt, tokens1) <- result.try(case current(tokens).kind {
    token.Keyword(token.KwCreate) -> parse_create_stream(tokens)
    token.Keyword(token.KwAlter) -> parse_alter_stream(tokens)
    token.Keyword(token.KwInsert) -> parse_insert(tokens)
    _ -> Error(fail(tokens, "CREATE, ALTER, or INSERT"))
  })
  use _ <- result.try(expect_eof(tokens1))
  Ok(stmt)
}

//-----------------------------------------------------------------------------
// Token-stream plumbing
//-----------------------------------------------------------------------------

/// Always safe: `tokens` is guaranteed (by `tokenize`, and preserved by
/// every helper below) to end in `Eof`, and nothing here ever `advance`s
/// past it — every caller checks the current token's kind first, and
/// `Eof` never matches a success arm.
fn current(tokens: List(Token)) -> Token {
  let assert [tok, ..] = tokens
  tok
}

fn advance(tokens: List(Token)) -> List(Token) {
  let assert [_, ..rest] = tokens
  rest
}

fn fail(tokens: List(Token), expected: String) -> ParseError {
  case current(tokens).kind {
    token.Eof -> UnexpectedEof(expected: expected)
    _ -> UnexpectedToken(found: current(tokens), expected: expected)
  }
}

fn peek_kind(tokens: List(Token), kind: TokenKind) -> Bool {
  current(tokens).kind == kind
}

fn peek_keyword(tokens: List(Token), kw: token.Keyword) -> Bool {
  case current(tokens).kind {
    token.Keyword(k) -> k == kw
    _ -> False
  }
}

fn expect_keyword(
  tokens: List(Token),
  kw: token.Keyword,
  name: String,
) -> Result(#(Span, List(Token)), ParseError) {
  case peek_keyword(tokens, kw) {
    True -> Ok(#(current(tokens).span, advance(tokens)))
    False -> Error(fail(tokens, name))
  }
}

fn expect_punct(
  tokens: List(Token),
  kind: TokenKind,
  name: String,
) -> Result(#(Span, List(Token)), ParseError) {
  case peek_kind(tokens, kind) {
    True -> Ok(#(current(tokens).span, advance(tokens)))
    False -> Error(fail(tokens, name))
  }
}

fn expect_identifier(
  tokens: List(Token),
  expected: String,
) -> Result(#(String, Span, List(Token)), ParseError) {
  let tok = current(tokens)
  case tok.kind {
    token.Identifier(name) -> Ok(#(name, tok.span, advance(tokens)))
    token.QuotedIdentifier(name) -> Ok(#(name, tok.span, advance(tokens)))
    _ -> Error(fail(tokens, expected))
  }
}

fn expect_eof(tokens: List(Token)) -> Result(Nil, ParseError) {
  case peek_kind(tokens, token.Eof) {
    True -> Ok(Nil)
    False -> Error(fail(tokens, "end of input"))
  }
}

/// A trailing `;` (allowed, per every statement's own `';'?`) is optional
/// everywhere it appears. `fallback_end` is the end position to report
/// when there isn't one — the caller's own best "end of statement"
/// position.
fn consume_optional_semicolon(
  tokens: List(Token),
  fallback_end: Position,
) -> #(Position, List(Token)) {
  case peek_kind(tokens, token.Semicolon) {
    True -> #(current(tokens).span.end, advance(tokens))
    False -> #(fallback_end, tokens)
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
fn parse_or(tokens: List(Token)) -> Result(#(Expr, List(Token)), ParseError) {
  use #(left, tokens1) <- result.try(parse_and(tokens))
  parse_or_loop(left, tokens1)
}

fn parse_or_loop(
  left: Expr,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  case peek_keyword(tokens, token.KwOr) {
    False -> Ok(#(left, tokens))
    True -> {
      let tokens1 = advance(tokens)
      use #(right, tokens2) <- result.try(parse_and(tokens1))
      parse_or_loop(ast.BinaryOp(ast.LogicalOr, left, right), tokens2)
    }
  }
}

/// Level 11: `AND` — left, loop.
fn parse_and(tokens: List(Token)) -> Result(#(Expr, List(Token)), ParseError) {
  use #(left, tokens1) <- result.try(parse_not(tokens))
  parse_and_loop(left, tokens1)
}

fn parse_and_loop(
  left: Expr,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  case peek_keyword(tokens, token.KwAnd) {
    False -> Ok(#(left, tokens))
    True -> {
      let tokens1 = advance(tokens)
      use #(right, tokens2) <- result.try(parse_not(tokens1))
      parse_and_loop(ast.BinaryOp(ast.LogicalAnd, left, right), tokens2)
    }
  }
}

/// Level 10: prefix `NOT` — right-associative, recurses into itself for
/// the operand.
fn parse_not(tokens: List(Token)) -> Result(#(Expr, List(Token)), ParseError) {
  case peek_keyword(tokens, token.KwNot) {
    False -> parse_is(tokens)
    True -> {
      let tokens1 = advance(tokens)
      use #(operand, tokens2) <- result.try(parse_not(tokens1))
      Ok(#(ast.UnaryOp(ast.LogicalNot, operand), tokens2))
    }
  }
}

/// Level 9: `IS [NOT] NULL/TRUE/FALSE`, `IS [NOT] DISTINCT FROM` — loop
/// (not a single check; see the "IS (level 9) resolving as a loop" note
/// in the implementation plan).
fn parse_is(tokens: List(Token)) -> Result(#(Expr, List(Token)), ParseError) {
  use #(left, tokens1) <- result.try(parse_comparison(tokens))
  parse_is_loop(left, tokens1)
}

fn parse_is_loop(
  left: Expr,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  case peek_keyword(tokens, token.KwIs) {
    False -> Ok(#(left, tokens))
    True -> {
      let tokens1 = advance(tokens)
      let #(negated, tokens2) = case peek_keyword(tokens1, token.KwNot) {
        True -> #(True, advance(tokens1))
        False -> #(False, tokens1)
      }
      case current(tokens2).kind {
        token.Keyword(token.KwNull) ->
          parse_is_loop(ast.IsNull(left, negated), advance(tokens2))
        token.Keyword(token.KwTrue) ->
          parse_is_loop(ast.IsBool(left, negated, True), advance(tokens2))
        token.Keyword(token.KwFalse) ->
          parse_is_loop(ast.IsBool(left, negated, False), advance(tokens2))
        token.Keyword(token.KwDistinct) -> {
          let tokens3 = advance(tokens2)
          use #(_, tokens4) <- result.try(expect_keyword(
            tokens3,
            token.KwFrom,
            "FROM",
          ))
          // IS DISTINCT FROM's right side is `bound_expr` (level 6 or
          // tighter) — see the "Operand binding" note in the plan.
          use #(right, tokens5) <- result.try(parse_bitwise_etc(tokens4))
          parse_is_loop(ast.IsDistinctFrom(left, negated, right), tokens5)
        }
        _ -> Error(fail(tokens2, "NULL, TRUE, FALSE, or DISTINCT FROM"))
      }
    }
  }
}

/// Level 8: `=` `<` `>` `<=` `>=` `<>` `!=` — **non-associative**: checked
/// once, never looped, so `a < b < c` is a parse error at the dangling
/// second `<`.
fn parse_comparison(
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  use #(left, tokens1) <- result.try(parse_keyword_ops(tokens))
  case comparison_op(current(tokens1).kind) {
    None -> Ok(#(left, tokens1))
    Some(op) -> {
      let tokens2 = advance(tokens1)
      use #(right, tokens3) <- result.try(parse_keyword_ops(tokens2))
      Ok(#(ast.BinaryOp(op, left, right), tokens3))
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
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  use #(left, tokens1) <- result.try(parse_bitwise_etc(tokens))
  parse_keyword_ops_after(left, tokens1)
}

fn parse_keyword_ops_after(
  left: Expr,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  case classify_keyword_op(tokens) {
    None -> Ok(#(left, tokens))
    Some(#(negated, form, tokens1)) ->
      apply_keyword_op(left, negated, form, tokens1)
  }
}

/// Peeks (and, only on a real match, consumes) the operator keyword(s)
/// starting a level-7 form. Returns `None` — leaving `tokens` completely
/// untouched — for anything that isn't one, including a `NOT` not
/// followed by one of the other four: that `NOT` is left for the caller
/// (ultimately `parse_not`, level 10) to make sense of instead.
fn classify_keyword_op(
  tokens: List(Token),
) -> Option(#(Bool, KeywordOpForm, List(Token))) {
  case current(tokens).kind {
    token.Keyword(token.KwBetween) ->
      Some(#(False, BetweenForm, advance(tokens)))
    token.Keyword(token.KwIn) -> Some(#(False, InForm, advance(tokens)))
    token.Keyword(token.KwLike) -> Some(#(False, LikeForm, advance(tokens)))
    token.Keyword(token.KwIlike) -> Some(#(False, IlikeForm, advance(tokens)))
    token.Keyword(token.KwSimilar) ->
      case similar_to_form(advance(tokens)) {
        Some(tokens1) -> Some(#(False, SimilarToForm, tokens1))
        None -> None
      }
    token.Keyword(token.KwNot) -> {
      let tokens1 = advance(tokens)
      case current(tokens1).kind {
        token.Keyword(token.KwBetween) ->
          Some(#(True, BetweenForm, advance(tokens1)))
        token.Keyword(token.KwIn) -> Some(#(True, InForm, advance(tokens1)))
        token.Keyword(token.KwLike) -> Some(#(True, LikeForm, advance(tokens1)))
        token.Keyword(token.KwIlike) ->
          Some(#(True, IlikeForm, advance(tokens1)))
        token.Keyword(token.KwSimilar) ->
          case similar_to_form(advance(tokens1)) {
            Some(tokens2) -> Some(#(True, SimilarToForm, tokens2))
            None -> None
          }
        _ -> None
      }
    }
    _ -> None
  }
}

fn similar_to_form(tokens: List(Token)) -> Option(List(Token)) {
  case current(tokens).kind {
    token.Keyword(token.KwTo) -> Some(advance(tokens))
    _ -> None
  }
}

fn apply_keyword_op(
  left: Expr,
  negated: Bool,
  form: KeywordOpForm,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  case form {
    BetweenForm -> {
      // `bound_expr` (level 6 or tighter) for both bounds — see the
      // "Operand binding" note in the implementation plan.
      use #(low, tokens1) <- result.try(parse_bitwise_etc(tokens))
      use #(_, tokens2) <- result.try(expect_keyword(
        tokens1,
        token.KwAnd,
        "AND",
      ))
      use #(high, tokens3) <- result.try(parse_bitwise_etc(tokens2))
      parse_keyword_ops_after(ast.Between(left, negated, low, high), tokens3)
    }
    InForm -> {
      use #(_, tokens1) <- result.try(expect_punct(tokens, token.LeftParen, "("))
      use #(items, tokens2) <- result.try(parse_expr_list(tokens1))
      use #(_, tokens3) <- result.try(expect_punct(
        tokens2,
        token.RightParen,
        ")",
      ))
      parse_keyword_ops_after(ast.InList(left, negated, items), tokens3)
    }
    LikeForm -> {
      use #(pattern, tokens1) <- result.try(parse_bitwise_etc(tokens))
      parse_keyword_ops_after(ast.Like(left, negated, False, pattern), tokens1)
    }
    IlikeForm -> {
      use #(pattern, tokens1) <- result.try(parse_bitwise_etc(tokens))
      parse_keyword_ops_after(ast.Like(left, negated, True, pattern), tokens1)
    }
    SimilarToForm -> {
      use #(pattern, tokens1) <- result.try(parse_bitwise_etc(tokens))
      parse_keyword_ops_after(ast.SimilarTo(left, negated, pattern), tokens1)
    }
  }
}

/// `expr (',' expr)*`, each item a full unrestricted `expr` (level 12) —
/// used for `IN`'s list and function-call arguments, per the "Operand
/// binding" note: their `(...)`/`,` delimiters already make the boundary
/// unambiguous, so they don't need `bound_expr`'s restriction.
fn parse_expr_list(
  tokens: List(Token),
) -> Result(#(List(Expr), List(Token)), ParseError) {
  use #(first, tokens1) <- result.try(parse_or(tokens))
  parse_expr_list_loop([first], tokens1)
}

fn parse_expr_list_loop(
  acc: List(Expr),
  tokens: List(Token),
) -> Result(#(List(Expr), List(Token)), ParseError) {
  case peek_kind(tokens, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokens))
    True -> {
      let tokens1 = advance(tokens)
      use #(next, tokens2) <- result.try(parse_or(tokens1))
      parse_expr_list_loop([next, ..acc], tokens2)
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
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  use #(left, tokens1) <- result.try(parse_bitwise_operand(tokens))
  parse_bitwise_etc_loop(left, tokens1)
}

fn parse_bitwise_operand(
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  case current(tokens).kind {
    token.Operator(token.Tilde) -> {
      let tokens1 = advance(tokens)
      use #(operand, tokens2) <- result.try(parse_additive(tokens1))
      Ok(#(ast.UnaryOp(ast.BitNot, operand), tokens2))
    }
    _ -> parse_additive(tokens)
  }
}

fn parse_bitwise_etc_loop(
  left: Expr,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  case bitwise_op(current(tokens).kind) {
    None -> Ok(#(left, tokens))
    Some(op) -> {
      let tokens1 = advance(tokens)
      use #(right, tokens2) <- result.try(parse_additive(tokens1))
      parse_bitwise_etc_loop(ast.BinaryOp(op, left, right), tokens2)
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
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  use #(left, tokens1) <- result.try(parse_multiplicative(tokens))
  parse_additive_loop(left, tokens1)
}

fn parse_additive_loop(
  left: Expr,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  case current(tokens).kind {
    token.Operator(token.Plus) -> {
      use #(right, tokens1) <- result.try(parse_multiplicative(advance(tokens)))
      parse_additive_loop(ast.BinaryOp(ast.Add, left, right), tokens1)
    }
    token.Operator(token.Minus) -> {
      use #(right, tokens1) <- result.try(parse_multiplicative(advance(tokens)))
      parse_additive_loop(ast.BinaryOp(ast.Sub, left, right), tokens1)
    }
    _ -> Ok(#(left, tokens))
  }
}

/// Level 4: `*` `/` `%` — left, loop.
fn parse_multiplicative(
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  use #(left, tokens1) <- result.try(parse_exponent(tokens))
  parse_multiplicative_loop(left, tokens1)
}

fn parse_multiplicative_loop(
  left: Expr,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  case current(tokens).kind {
    token.Operator(token.Star) -> {
      use #(right, tokens1) <- result.try(parse_exponent(advance(tokens)))
      parse_multiplicative_loop(ast.BinaryOp(ast.Mul, left, right), tokens1)
    }
    token.Operator(token.Slash) -> {
      use #(right, tokens1) <- result.try(parse_exponent(advance(tokens)))
      parse_multiplicative_loop(ast.BinaryOp(ast.Div, left, right), tokens1)
    }
    token.Operator(token.Percent) -> {
      use #(right, tokens1) <- result.try(parse_exponent(advance(tokens)))
      parse_multiplicative_loop(ast.BinaryOp(ast.Mod, left, right), tokens1)
    }
    _ -> Ok(#(left, tokens))
  }
}

/// Level 3: `^` — left-associative, matching PostgreSQL's own quirk
/// (`2^3^2` is `(2^3)^2`, not the mathematically-conventional
/// right-associative reading).
fn parse_exponent(
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  use #(left, tokens1) <- result.try(parse_unary(tokens))
  parse_exponent_loop(left, tokens1)
}

fn parse_exponent_loop(
  left: Expr,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  case current(tokens).kind {
    token.Operator(token.Caret) -> {
      use #(right, tokens1) <- result.try(parse_unary(advance(tokens)))
      parse_exponent_loop(ast.BinaryOp(ast.Pow, left, right), tokens1)
    }
    _ -> Ok(#(left, tokens))
  }
}

/// Level 2: prefix `+` `-` — right-associative, recurses into itself for
/// the operand (so `- - 1` parses, as `Neg(Neg(1))`).
fn parse_unary(
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  case current(tokens).kind {
    token.Operator(token.Plus) -> {
      use #(operand, tokens1) <- result.try(parse_unary(advance(tokens)))
      Ok(#(ast.UnaryOp(ast.Pos, operand), tokens1))
    }
    token.Operator(token.Minus) -> {
      use #(operand, tokens1) <- result.try(parse_unary(advance(tokens)))
      Ok(#(ast.UnaryOp(ast.Neg, operand), tokens1))
    }
    _ -> parse_cast(tokens)
  }
}

/// Level 1: postfix `:: data_type` — left, loop.
fn parse_cast(tokens: List(Token)) -> Result(#(Expr, List(Token)), ParseError) {
  use #(left, tokens1) <- result.try(parse_primary(tokens))
  parse_cast_loop(left, tokens1)
}

fn parse_cast_loop(
  left: Expr,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  case current(tokens).kind {
    token.Operator(token.Cast) -> {
      use #(dt, tokens1) <- result.try(parse_data_type(advance(tokens)))
      parse_cast_loop(ast.Cast(left, dt), tokens1)
    }
    _ -> Ok(#(left, tokens))
  }
}

/// Literals, `column_ref`, `function_call`, or a parenthesized `expr`.
fn parse_primary(
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  let tok = current(tokens)
  case tok.kind {
    token.IntegerLiteral(text) -> Ok(#(ast.IntLiteral(text), advance(tokens)))
    token.NumericLiteral(text) ->
      Ok(#(ast.NumericLiteral(text), advance(tokens)))
    token.StringLiteral(value) ->
      Ok(#(ast.StringLiteral(value), advance(tokens)))
    token.Keyword(token.KwTrue) -> Ok(#(ast.BoolLiteral(True), advance(tokens)))
    token.Keyword(token.KwFalse) ->
      Ok(#(ast.BoolLiteral(False), advance(tokens)))
    token.Keyword(token.KwNull) -> Ok(#(ast.NullLiteral, advance(tokens)))
    token.LeftParen -> {
      use #(inner, tokens1) <- result.try(parse_or(advance(tokens)))
      use #(_, tokens2) <- result.try(expect_punct(
        tokens1,
        token.RightParen,
        ")",
      ))
      Ok(#(inner, tokens2))
    }
    token.Identifier(name) ->
      parse_identifier_primary(name, tok.span, advance(tokens))
    token.QuotedIdentifier(name) ->
      parse_identifier_primary(name, tok.span, advance(tokens))
    _ -> Error(fail(tokens, "an expression"))
  }
}

/// `identifier` immediately followed by `(` is a `function_call` (§8.3);
/// otherwise it's a `column_ref`, the one `Expr` variant carrying its own
/// `Span` — see the note on `ColumnRef` in ast.gleam.
fn parse_identifier_primary(
  name: String,
  span: Span,
  tokens: List(Token),
) -> Result(#(Expr, List(Token)), ParseError) {
  case peek_kind(tokens, token.LeftParen) {
    False -> Ok(#(ast.ColumnRef(name, span), tokens))
    True -> {
      use #(args, tokens1) <- result.try(parse_call_args(advance(tokens)))
      use #(_, tokens2) <- result.try(expect_punct(
        tokens1,
        token.RightParen,
        ")",
      ))
      Ok(#(ast.FunctionCall(name, args), tokens2))
    }
  }
}

fn parse_call_args(
  tokens: List(Token),
) -> Result(#(List(Expr), List(Token)), ParseError) {
  case peek_kind(tokens, token.RightParen) {
    True -> Ok(#([], tokens))
    False -> parse_expr_list(tokens)
  }
}

//-----------------------------------------------------------------------------
// data_type (spec.md §9.1)
//-----------------------------------------------------------------------------

fn parse_data_type(
  tokens: List(Token),
) -> Result(#(DataType, List(Token)), ParseError) {
  case current(tokens).kind {
    token.Keyword(token.KwBigint) -> Ok(#(ast.DtBigint, advance(tokens)))
    token.Keyword(token.KwBoolean) -> Ok(#(ast.DtBoolean, advance(tokens)))
    token.Keyword(token.KwChar) ->
      parse_optional_length(advance(tokens), ast.DtChar)
    token.Keyword(token.KwDate) -> Ok(#(ast.DtDate, advance(tokens)))
    token.Keyword(token.KwDecimal) ->
      parse_optional_precision_scale(advance(tokens), ast.DtDecimal)
    token.Keyword(token.KwDouble) -> {
      // `DOUBLE PRECISION`: two keywords, one type — bare `DOUBLE` with
      // no following `PRECISION` is a parse error, not a standalone
      // type. See the "data_type parsing" section of the plan.
      use #(_, tokens1) <- result.try(expect_keyword(
        advance(tokens),
        token.KwPrecision,
        "PRECISION",
      ))
      Ok(#(ast.DtDouble, tokens1))
    }
    token.Keyword(token.KwHlc) -> Ok(#(ast.DtHlc, advance(tokens)))
    token.Keyword(token.KwInt) -> Ok(#(ast.DtInt, advance(tokens)))
    token.Keyword(token.KwInteger) -> Ok(#(ast.DtInteger, advance(tokens)))
    token.Keyword(token.KwInterval) -> Ok(#(ast.DtInterval, advance(tokens)))
    token.Keyword(token.KwJson) -> Ok(#(ast.DtJson, advance(tokens)))
    token.Keyword(token.KwJsonb) -> Ok(#(ast.DtJsonb, advance(tokens)))
    token.Keyword(token.KwNumeric) ->
      parse_optional_precision_scale(advance(tokens), ast.DtNumeric)
    token.Keyword(token.KwReal) -> Ok(#(ast.DtReal, advance(tokens)))
    token.Keyword(token.KwSmallint) -> Ok(#(ast.DtSmallint, advance(tokens)))
    token.Keyword(token.KwText) -> Ok(#(ast.DtText, advance(tokens)))
    token.Keyword(token.KwTime) -> Ok(#(ast.DtTime, advance(tokens)))
    token.Keyword(token.KwTimestamp) -> Ok(#(ast.DtTimestamp, advance(tokens)))
    token.Keyword(token.KwTimestamptz) ->
      Ok(#(ast.DtTimestamptz, advance(tokens)))
    token.Keyword(token.KwUuid) -> Ok(#(ast.DtUuid, advance(tokens)))
    token.Keyword(token.KwVarchar) ->
      parse_optional_length(advance(tokens), ast.DtVarchar)
    _ -> Error(fail(tokens, "a data type"))
  }
}

fn parse_optional_length(
  tokens: List(Token),
  build: fn(Option(Int)) -> DataType,
) -> Result(#(DataType, List(Token)), ParseError) {
  case peek_kind(tokens, token.LeftParen) {
    False -> Ok(#(build(None), tokens))
    True -> {
      use #(n, tokens1) <- result.try(parse_int_literal_value(advance(tokens)))
      use #(_, tokens2) <- result.try(expect_punct(
        tokens1,
        token.RightParen,
        ")",
      ))
      Ok(#(build(Some(n)), tokens2))
    }
  }
}

fn parse_optional_precision_scale(
  tokens: List(Token),
  build: fn(Option(Int), Option(Int)) -> DataType,
) -> Result(#(DataType, List(Token)), ParseError) {
  case peek_kind(tokens, token.LeftParen) {
    False -> Ok(#(build(None, None), tokens))
    True -> {
      use #(p, tokens1) <- result.try(parse_int_literal_value(advance(tokens)))
      case peek_kind(tokens1, token.Comma) {
        True -> {
          use #(s, tokens2) <- result.try(
            parse_int_literal_value(advance(tokens1)),
          )
          use #(_, tokens3) <- result.try(expect_punct(
            tokens2,
            token.RightParen,
            ")",
          ))
          Ok(#(build(Some(p), Some(s)), tokens3))
        }
        False -> {
          use #(_, tokens2) <- result.try(expect_punct(
            tokens1,
            token.RightParen,
            ")",
          ))
          Ok(#(build(Some(p), None), tokens2))
        }
      }
    }
  }
}

fn parse_int_literal_value(
  tokens: List(Token),
) -> Result(#(Int, List(Token)), ParseError) {
  case current(tokens).kind {
    token.IntegerLiteral(text) ->
      case int.parse(text) {
        Ok(n) -> Ok(#(n, advance(tokens)))
        Error(Nil) -> Error(fail(tokens, "an integer"))
      }
    _ -> Error(fail(tokens, "an integer"))
  }
}

//-----------------------------------------------------------------------------
// CREATE STREAM (spec.md §9.1)
//-----------------------------------------------------------------------------

fn parse_create_stream(
  tokens: List(Token),
) -> Result(#(Statement, List(Token)), ParseError) {
  let start_span = current(tokens).span
  use #(_, tokens1) <- result.try(expect_keyword(
    tokens,
    token.KwCreate,
    "CREATE",
  ))
  use #(_, tokens2) <- result.try(expect_keyword(
    tokens1,
    token.KwStream,
    "STREAM",
  ))
  use #(name, _, tokens3) <- result.try(expect_identifier(
    tokens2,
    "a stream name",
  ))
  use #(_, tokens4) <- result.try(expect_punct(tokens3, token.LeftParen, "("))
  use #(elements, tokens5) <- result.try(parse_stream_elements(tokens4))
  use #(rparen_span, tokens6) <- result.try(expect_punct(
    tokens5,
    token.RightParen,
    ")",
  ))
  let #(end_pos, tokens7) = consume_optional_semicolon(tokens6, rparen_span.end)
  let span = token.Span(start_span.start, end_pos)
  Ok(#(ast.CreateStream(name, elements, span), tokens7))
}

fn parse_stream_elements(
  tokens: List(Token),
) -> Result(#(List(ast.StreamElement), List(Token)), ParseError) {
  use #(first, tokens1) <- result.try(parse_stream_element(tokens))
  parse_stream_elements_loop([first], tokens1)
}

fn parse_stream_elements_loop(
  acc: List(ast.StreamElement),
  tokens: List(Token),
) -> Result(#(List(ast.StreamElement), List(Token)), ParseError) {
  case peek_kind(tokens, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokens))
    True -> {
      use #(next, tokens1) <- result.try(parse_stream_element(advance(tokens)))
      parse_stream_elements_loop([next, ..acc], tokens1)
    }
  }
}

/// Dispatches on `CONSTRAINT` (→ `table_constraint`) vs. an identifier
/// (→ `column_def`) — the only two `stream_element` alternatives (§9.1).
fn parse_stream_element(
  tokens: List(Token),
) -> Result(#(ast.StreamElement, List(Token)), ParseError) {
  case current(tokens).kind {
    token.Keyword(token.KwConstraint) -> {
      use #(check, tokens1) <- result.try(parse_named_check(tokens))
      Ok(#(ast.TableConstraint(check, check.span), tokens1))
    }
    _ -> {
      use #(col, tokens1) <- result.try(parse_column_def(tokens))
      Ok(#(ast.Column(col), tokens1))
    }
  }
}

/// `CONSTRAINT constraint_name CHECK ( expr )` — shared by a column's own
/// `CONSTRAINT` clause, a standalone `table_constraint`, `ADD
/// CONSTRAINT`, and (via its `expr`) nothing else.
fn parse_named_check(
  tokens: List(Token),
) -> Result(#(ast.NamedCheck, List(Token)), ParseError) {
  let start_span = current(tokens).span
  use #(_, tokens1) <- result.try(expect_keyword(
    tokens,
    token.KwConstraint,
    "CONSTRAINT",
  ))
  use #(name, _, tokens2) <- result.try(expect_identifier(
    tokens1,
    "a constraint name",
  ))
  use #(_, tokens3) <- result.try(expect_keyword(
    tokens2,
    token.KwCheck,
    "CHECK",
  ))
  use #(_, tokens4) <- result.try(expect_punct(tokens3, token.LeftParen, "("))
  use #(expr, tokens5) <- result.try(parse_or(tokens4))
  use #(rparen_span, tokens6) <- result.try(expect_punct(
    tokens5,
    token.RightParen,
    ")",
  ))
  let span = token.Span(start_span.start, rparen_span.end)
  Ok(#(ast.NamedCheck(name, expr, span), tokens6))
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
  tokens: List(Token),
) -> Result(#(ast.ColumnDef, List(Token)), ParseError) {
  let start_span = current(tokens).span
  use #(name, _, tokens1) <- result.try(expect_identifier(
    tokens,
    "a column name",
  ))
  use #(dt, tokens2) <- result.try(parse_data_type(tokens1))
  use #(acc, tokens3) <- result.try(parse_column_clauses(
    tokens2,
    ClauseAcc(optional: False, default: None, generated: None, checks: []),
  ))
  // The span ends where the next token (`,` or `)`) begins — good enough
  // to underline "this column_def" without threading a precise end
  // position out of an arbitrary `DEFAULT`/`CHECK` expr, which carries
  // no span of its own; see the note on `Expr` spans in ast.gleam.
  let span = token.Span(start_span.start, current(tokens3).span.start)
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
  Ok(#(col, tokens3))
}

fn parse_column_clauses(
  tokens: List(Token),
  acc: ClauseAcc,
) -> Result(#(ClauseAcc, List(Token)), ParseError) {
  case current(tokens).kind {
    token.Keyword(token.KwOptional) ->
      parse_column_clauses(advance(tokens), ClauseAcc(..acc, optional: True))
    token.Keyword(token.KwDefault) -> {
      use #(expr, tokens1) <- result.try(parse_or(advance(tokens)))
      parse_column_clauses(tokens1, ClauseAcc(..acc, default: Some(expr)))
    }
    token.Keyword(token.KwGenerated) -> {
      use #(clause, tokens1) <- result.try(parse_generated_clause(tokens))
      parse_column_clauses(tokens1, ClauseAcc(..acc, generated: Some(clause)))
    }
    token.Keyword(token.KwConstraint) -> {
      use #(check, tokens1) <- result.try(parse_named_check(tokens))
      parse_column_clauses(
        tokens1,
        ClauseAcc(..acc, checks: [check, ..acc.checks]),
      )
    }
    token.Keyword(token.KwNot) -> {
      // §9.3: `NOT NULL` is never legal to write (columns are `NOT NULL`
      // by default already) — reported as `ExplicitNotNull`, not a
      // generic parse error, so the caller can render spec.md's own
      // guidance ("use OPTIONAL instead").
      let not_span = current(tokens).span
      case current(advance(tokens)).kind {
        token.Keyword(token.KwNull) -> {
          let null_span = current(advance(tokens)).span
          Error(
            ExplicitNotNull(span: token.Span(not_span.start, null_span.end)),
          )
        }
        _ -> Error(fail(tokens, "OPTIONAL, DEFAULT, GENERATED, or CONSTRAINT"))
      }
    }
    _ -> Ok(#(acc, tokens))
  }
}

fn parse_generated_clause(
  tokens: List(Token),
) -> Result(#(ast.GeneratedClause, List(Token)), ParseError) {
  use #(_, tokens1) <- result.try(expect_keyword(
    tokens,
    token.KwGenerated,
    "GENERATED",
  ))
  use #(_, tokens2) <- result.try(expect_keyword(
    tokens1,
    token.KwAlways,
    "ALWAYS",
  ))
  use #(_, tokens3) <- result.try(expect_keyword(tokens2, token.KwAs, "AS"))
  use #(_, tokens4) <- result.try(expect_punct(tokens3, token.LeftParen, "("))
  use #(expr, tokens5) <- result.try(parse_or(tokens4))
  use #(_, tokens6) <- result.try(expect_punct(tokens5, token.RightParen, ")"))
  case current(tokens6).kind {
    token.Keyword(token.KwStored) ->
      Ok(#(ast.GeneratedClause(expr, ast.Stored), advance(tokens6)))
    token.Keyword(token.KwVirtual) ->
      Ok(#(ast.GeneratedClause(expr, ast.Virtual), advance(tokens6)))
    _ -> Error(MissingGeneratedStorage(span: current(tokens6).span))
  }
}

//-----------------------------------------------------------------------------
// ALTER STREAM (spec.md §10.1)
//-----------------------------------------------------------------------------

fn parse_alter_stream(
  tokens: List(Token),
) -> Result(#(Statement, List(Token)), ParseError) {
  let start_span = current(tokens).span
  use #(_, tokens1) <- result.try(expect_keyword(tokens, token.KwAlter, "ALTER"))
  use #(_, tokens2) <- result.try(expect_keyword(
    tokens1,
    token.KwStream,
    "STREAM",
  ))
  use #(name, _, tokens3) <- result.try(expect_identifier(
    tokens2,
    "a stream name",
  ))
  use #(actions, tokens4) <- result.try(parse_alter_actions(tokens3))
  let #(end_pos, tokens5) =
    consume_optional_semicolon(tokens4, current(tokens4).span.start)
  let span = token.Span(start_span.start, end_pos)
  Ok(#(ast.AlterStream(name, actions, span), tokens5))
}

fn parse_alter_actions(
  tokens: List(Token),
) -> Result(#(List(ast.AlterAction), List(Token)), ParseError) {
  use #(first, tokens1) <- result.try(parse_alter_action(tokens))
  parse_alter_actions_loop([first], tokens1)
}

fn parse_alter_actions_loop(
  acc: List(ast.AlterAction),
  tokens: List(Token),
) -> Result(#(List(ast.AlterAction), List(Token)), ParseError) {
  case peek_kind(tokens, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokens))
    True -> {
      use #(next, tokens1) <- result.try(parse_alter_action(advance(tokens)))
      parse_alter_actions_loop([next, ..acc], tokens1)
    }
  }
}

/// `ADD`/`DROP` (each further dispatching on `COLUMN` vs. `CONSTRAINT`)
/// or `ALTER COLUMN name TYPE data_type` (§10.1). `COLUMN` is mandatory
/// throughout, unlike PostgreSQL — see spec.md §3.3.
fn parse_alter_action(
  tokens: List(Token),
) -> Result(#(ast.AlterAction, List(Token)), ParseError) {
  let start_span = current(tokens).span
  case current(tokens).kind {
    token.Keyword(token.KwAdd) ->
      case current(advance(tokens)).kind {
        token.Keyword(token.KwColumn) -> {
          use #(col, tokens1) <- result.try(
            parse_column_def(advance(advance(tokens))),
          )
          let span = token.Span(start_span.start, current(tokens1).span.start)
          Ok(#(ast.AddColumn(col, span), tokens1))
        }
        token.Keyword(token.KwConstraint) -> {
          use #(check, tokens1) <- result.try(
            parse_named_check(advance(tokens)),
          )
          Ok(#(ast.AddConstraint(check), tokens1))
        }
        _ -> Error(fail(advance(tokens), "COLUMN or CONSTRAINT"))
      }
    token.Keyword(token.KwDrop) ->
      case current(advance(tokens)).kind {
        token.Keyword(token.KwColumn) -> {
          use #(name, name_span, tokens1) <- result.try(expect_identifier(
            advance(advance(tokens)),
            "a column name",
          ))
          let span = token.Span(start_span.start, name_span.end)
          Ok(#(ast.DropColumn(name, span), tokens1))
        }
        token.Keyword(token.KwConstraint) -> {
          use #(name, name_span, tokens1) <- result.try(expect_identifier(
            advance(advance(tokens)),
            "a constraint name",
          ))
          let span = token.Span(start_span.start, name_span.end)
          Ok(#(ast.DropConstraint(name, span), tokens1))
        }
        _ -> Error(fail(advance(tokens), "COLUMN or CONSTRAINT"))
      }
    token.Keyword(token.KwAlter) -> {
      use #(_, tokens1) <- result.try(expect_keyword(
        advance(tokens),
        token.KwColumn,
        "COLUMN",
      ))
      use #(name, _, tokens2) <- result.try(expect_identifier(
        tokens1,
        "a column name",
      ))
      use #(_, tokens3) <- result.try(expect_keyword(
        tokens2,
        token.KwType,
        "TYPE",
      ))
      use #(dt, tokens4) <- result.try(parse_data_type(tokens3))
      let span = token.Span(start_span.start, current(tokens4).span.start)
      Ok(#(ast.AlterColumnType(name, dt, span), tokens4))
    }
    _ -> Error(fail(tokens, "ADD, DROP, or ALTER"))
  }
}

//-----------------------------------------------------------------------------
// INSERT (spec.md §11.1)
//-----------------------------------------------------------------------------

fn parse_insert(
  tokens: List(Token),
) -> Result(#(Statement, List(Token)), ParseError) {
  let start_span = current(tokens).span
  use #(_, tokens1) <- result.try(expect_keyword(
    tokens,
    token.KwInsert,
    "INSERT",
  ))
  use #(_, tokens2) <- result.try(expect_keyword(tokens1, token.KwInto, "INTO"))
  use #(name, _, tokens3) <- result.try(expect_identifier(
    tokens2,
    "a stream name",
  ))
  // §11.2: the column list is mandatory — no positional form.
  use #(_, tokens4) <- result.try(expect_punct(tokens3, token.LeftParen, "("))
  use #(columns, tokens5) <- result.try(parse_identifier_list(tokens4))
  use #(_, tokens6) <- result.try(expect_punct(tokens5, token.RightParen, ")"))
  use #(_, tokens7) <- result.try(expect_keyword(
    tokens6,
    token.KwValues,
    "VALUES",
  ))
  use #(rows, tokens8) <- result.try(parse_value_rows(tokens7))
  use #(on_conflict, tokens9) <- result.try(parse_optional_on_conflict(tokens8))
  use #(returning, tokens10) <- result.try(parse_optional_returning(tokens9))
  let #(end_pos, tokens11) =
    consume_optional_semicolon(tokens10, current(tokens10).span.start)
  let span = token.Span(start_span.start, end_pos)
  Ok(#(ast.Insert(name, columns, rows, on_conflict, returning, span), tokens11))
}

fn parse_identifier_list(
  tokens: List(Token),
) -> Result(#(List(String), List(Token)), ParseError) {
  use #(first, _, tokens1) <- result.try(expect_identifier(
    tokens,
    "a column name",
  ))
  parse_identifier_list_loop([first], tokens1)
}

fn parse_identifier_list_loop(
  acc: List(String),
  tokens: List(Token),
) -> Result(#(List(String), List(Token)), ParseError) {
  case peek_kind(tokens, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokens))
    True -> {
      use #(next, _, tokens1) <- result.try(expect_identifier(
        advance(tokens),
        "a column name",
      ))
      parse_identifier_list_loop([next, ..acc], tokens1)
    }
  }
}

fn parse_value_rows(
  tokens: List(Token),
) -> Result(#(List(List(ast.Value)), List(Token)), ParseError) {
  use #(first, tokens1) <- result.try(parse_value_row(tokens))
  parse_value_rows_loop([first], tokens1)
}

fn parse_value_rows_loop(
  acc: List(List(ast.Value)),
  tokens: List(Token),
) -> Result(#(List(List(ast.Value)), List(Token)), ParseError) {
  case peek_kind(tokens, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokens))
    True -> {
      use #(next, tokens1) <- result.try(parse_value_row(advance(tokens)))
      parse_value_rows_loop([next, ..acc], tokens1)
    }
  }
}

fn parse_value_row(
  tokens: List(Token),
) -> Result(#(List(ast.Value), List(Token)), ParseError) {
  use #(_, tokens1) <- result.try(expect_punct(tokens, token.LeftParen, "("))
  use #(values, tokens2) <- result.try(parse_values(tokens1))
  use #(_, tokens3) <- result.try(expect_punct(tokens2, token.RightParen, ")"))
  Ok(#(values, tokens3))
}

fn parse_values(
  tokens: List(Token),
) -> Result(#(List(ast.Value), List(Token)), ParseError) {
  use #(first, tokens1) <- result.try(parse_value(tokens))
  parse_values_loop([first], tokens1)
}

fn parse_values_loop(
  acc: List(ast.Value),
  tokens: List(Token),
) -> Result(#(List(ast.Value), List(Token)), ParseError) {
  case peek_kind(tokens, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokens))
    True -> {
      use #(next, tokens1) <- result.try(parse_value(advance(tokens)))
      parse_values_loop([next, ..acc], tokens1)
    }
  }
}

fn parse_value(
  tokens: List(Token),
) -> Result(#(ast.Value, List(Token)), ParseError) {
  case current(tokens).kind {
    token.Keyword(token.KwDefault) -> Ok(#(ast.ValueDefault, advance(tokens)))
    _ -> {
      use #(expr, tokens1) <- result.try(parse_or(tokens))
      Ok(#(ast.ValueExpr(expr), tokens1))
    }
  }
}

fn parse_optional_on_conflict(
  tokens: List(Token),
) -> Result(#(Bool, List(Token)), ParseError) {
  case peek_keyword(tokens, token.KwOn) {
    False -> Ok(#(False, tokens))
    True -> {
      use #(_, tokens1) <- result.try(expect_keyword(
        advance(tokens),
        token.KwConflict,
        "CONFLICT",
      ))
      use #(_, tokens2) <- result.try(expect_keyword(tokens1, token.KwDo, "DO"))
      use #(_, tokens3) <- result.try(expect_keyword(
        tokens2,
        token.KwNothing,
        "NOTHING",
      ))
      Ok(#(True, tokens3))
    }
  }
}

fn parse_optional_returning(
  tokens: List(Token),
) -> Result(#(Option(List(ast.ReturningItem)), List(Token)), ParseError) {
  case peek_keyword(tokens, token.KwReturning) {
    False -> Ok(#(None, tokens))
    True -> {
      use #(items, tokens1) <- result.try(
        parse_returning_items(advance(tokens)),
      )
      Ok(#(Some(items), tokens1))
    }
  }
}

fn parse_returning_items(
  tokens: List(Token),
) -> Result(#(List(ast.ReturningItem), List(Token)), ParseError) {
  use #(first, tokens1) <- result.try(parse_returning_item(tokens))
  parse_returning_items_loop([first], tokens1)
}

fn parse_returning_items_loop(
  acc: List(ast.ReturningItem),
  tokens: List(Token),
) -> Result(#(List(ast.ReturningItem), List(Token)), ParseError) {
  case peek_kind(tokens, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokens))
    True -> {
      use #(next, tokens1) <- result.try(parse_returning_item(advance(tokens)))
      parse_returning_items_loop([next, ..acc], tokens1)
    }
  }
}

fn parse_returning_item(
  tokens: List(Token),
) -> Result(#(ast.ReturningItem, List(Token)), ParseError) {
  case current(tokens).kind {
    token.Operator(token.Star) -> Ok(#(ast.ReturningStar, advance(tokens)))
    _ -> {
      use #(expr, tokens1) <- result.try(parse_or(tokens))
      case peek_keyword(tokens1, token.KwAs) {
        False -> Ok(#(ast.ReturningExpr(expr, None), tokens1))
        True -> {
          use #(alias, _, tokens2) <- result.try(expect_identifier(
            advance(tokens1),
            "an alias",
          ))
          Ok(#(ast.ReturningExpr(expr, Some(alias)), tokens2))
        }
      }
    }
  }
}
//-----------------------------------------------------------------------------
