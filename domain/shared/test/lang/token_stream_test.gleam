import lang/lexer
import lang/token
import lang/token_stream

//-----------------------------------------------------------------------------
// A cursor over a token list — built from real `lexer.tokenize` output
// (never hand-assembled `Token`s), matching how every parser production
// this module actually backs already consumes it.
//-----------------------------------------------------------------------------

fn stream_of(source: String) -> token_stream.TokenStream {
  let assert Ok(tokens) = lexer.tokenize(source)
  token_stream.new(tokens)
}

fn dummy_position() -> token.Position {
  token.Position(line: 1, column: 1, byte_offset: 0)
}

//-----------------------------------------------------------------------------
// current / advance
//-----------------------------------------------------------------------------

pub fn current_is_the_first_token_test() {
  let assert token.Token(kind: token.Keyword(token.KwCreate), span: _) =
    token_stream.current(stream_of("CREATE STREAM"))
}

pub fn advance_moves_to_the_next_token_test() {
  let stream = stream_of("CREATE STREAM") |> token_stream.advance
  let assert token.Token(kind: token.Keyword(token.KwStream), span: _) =
    token_stream.current(stream)
}

pub fn advance_is_a_pure_step_leaving_the_original_stream_untouched_test() {
  // `advance` returns a new stream rather than mutating in place — the
  // original cursor still reports its own current token afterward.
  let stream0 = stream_of("CREATE STREAM")
  let stream1 = token_stream.advance(stream0)
  let assert token.Token(kind: token.Keyword(token.KwCreate), span: _) =
    token_stream.current(stream0)
  let assert token.Token(kind: token.Keyword(token.KwStream), span: _) =
    token_stream.current(stream1)
}

pub fn advancing_to_the_end_lands_on_eof_test() {
  let stream = stream_of("a") |> token_stream.advance
  let assert token.Token(kind: token.Eof, span: _) =
    token_stream.current(stream)
}

//-----------------------------------------------------------------------------
// peek_kind / peek_keyword
//-----------------------------------------------------------------------------

pub fn peek_kind_true_when_the_current_token_matches_test() {
  assert token_stream.peek_kind(stream_of("("), token.LeftParen)
}

pub fn peek_kind_false_when_it_does_not_match_test() {
  assert !token_stream.peek_kind(stream_of("("), token.RightParen)
}

pub fn peek_keyword_true_for_the_matching_keyword_test() {
  assert token_stream.peek_keyword(stream_of("ALTER"), token.KwAlter)
}

pub fn peek_keyword_false_for_a_different_keyword_test() {
  assert !token_stream.peek_keyword(stream_of("ALTER"), token.KwCreate)
}

pub fn peek_keyword_false_for_a_non_keyword_token_test() {
  // `foo` is an `Identifier`, not a `Keyword(_)` at all — `peek_keyword`
  // must not confuse "wrong keyword" with "not a keyword token."
  assert !token_stream.peek_keyword(stream_of("foo"), token.KwCreate)
}

//-----------------------------------------------------------------------------
// consume_optional_semicolon
//-----------------------------------------------------------------------------

pub fn consume_optional_semicolon_present_advances_past_it_test() {
  let stream = stream_of("a;") |> token_stream.advance
  let semicolon_end = token_stream.current(stream).span.end
  let #(end_pos, stream1) =
    token_stream.consume_optional_semicolon(stream, dummy_position())
  assert end_pos == semicolon_end
  let assert token.Token(kind: token.Eof, span: _) =
    token_stream.current(stream1)
}

pub fn consume_optional_semicolon_absent_leaves_the_stream_untouched_test() {
  let stream = stream_of("a") |> token_stream.advance
  let fallback = dummy_position()
  let #(end_pos, stream1) =
    token_stream.consume_optional_semicolon(stream, fallback)
  assert end_pos == fallback
  let assert token.Token(kind: token.Eof, span: _) =
    token_stream.current(stream1)
}
//-----------------------------------------------------------------------------
