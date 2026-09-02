import lang/token.{type Position, type Token, type TokenKind}

//-----------------------------------------------------------------------------
// A cursor over a token list — the mechanical part of hand-written
// recursive descent (peek the current token, advance past it) that every
// parser production in expr_parser.gleam is built from.
//-----------------------------------------------------------------------------

pub opaque type TokenStream {
  TokenStream(tokens: List(Token))
}

/// Wraps a token list — as produced by `lexer.tokenize` — into a stream.
/// Assumes `tokens` ends in `Eof`, which `tokenize` guarantees.
pub fn new(tokens: List(Token)) -> TokenStream {
  TokenStream(tokens)
}

/// Always safe: `tokens` is guaranteed (by `tokenize`, and preserved by
/// every function below) to end in `Eof`, and nothing here ever `advance`s
/// past it — every caller checks the current token's kind first, and
/// `Eof` never matches a success arm.
pub fn current(stream: TokenStream) -> Token {
  let assert [tok, ..] = stream.tokens
  tok
}

pub fn advance(stream: TokenStream) -> TokenStream {
  let assert [_, ..rest] = stream.tokens
  TokenStream(rest)
}

pub fn peek_kind(stream: TokenStream, kind: TokenKind) -> Bool {
  current(stream).kind == kind
}

pub fn peek_keyword(stream: TokenStream, kw: token.Keyword) -> Bool {
  case current(stream).kind {
    token.Keyword(k) -> k == kw
    _ -> False
  }
}

/// A trailing `;` (allowed, per every statement's own `';'?`) is optional
/// everywhere it appears. `fallback_end` is the end position to report
/// when there isn't one — the caller's own best "end of statement"
/// position.
pub fn consume_optional_semicolon(
  stream: TokenStream,
  fallback_end: Position,
) -> #(Position, TokenStream) {
  case peek_kind(stream, token.Semicolon) {
    True -> #(current(stream).span.end, advance(stream))
    False -> #(fallback_end, stream)
  }
}
//-----------------------------------------------------------------------------
