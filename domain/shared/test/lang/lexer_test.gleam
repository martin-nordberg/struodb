import gleam/list
import gleam/string
import lang/lexer.{
  InvalidDigitGroupSeparator, ReservedWord, UnknownCharacter,
  UnterminatedBlockComment, UnterminatedQuotedIdentifier, UnterminatedString,
}
import lang/token.{
  Amp, Arrow, ArrowText, Cast, Comma, Concat, ContainedBy, Contains, Dot, Eq, Ge,
  Hash, HashArrow, HashArrowText, Identifier, IntegerLiteral, Keyword, KwAnd,
  KwChar, KwCreate, Le, LeftParen, Lt, NeAngle, NeBang, NumericLiteral, Operator,
  Pipe, QuotedIdentifier, RegexMatchCi, RegexNoMatch, RegexNoMatchCi, RightParen,
  Semicolon, Shl, Shr, StringLiteral, Tilde,
}

//-----------------------------------------------------------------------------

/// Every token's `kind`, dropping the trailing `Eof` and every `Span` —
/// most tests below only care about what tokenized, not where.
fn kinds(source: String) -> List(token.TokenKind) {
  let assert Ok(tokens) = lexer.tokenize(source)
  let assert [token.Token(kind: token.Eof, span: _), ..reversed] =
    list.reverse(tokens)
  reversed
  |> list.reverse
  |> list.map(fn(t) { t.kind })
}

fn lex_error(source: String) -> lexer.LexError {
  let assert Error(err) = lexer.tokenize(source)
  err
}

//-----------------------------------------------------------------------------
// Keywords
//-----------------------------------------------------------------------------

pub fn keyword_lexes_case_insensitively_test() {
  assert kinds("CREATE") == [Keyword(KwCreate)]
  assert kinds("create") == [Keyword(KwCreate)]
  assert kinds("CrEaTe") == [Keyword(KwCreate)]
}

pub fn one_keyword_from_each_group_lexes_test() {
  // §3.1 data type, §3.2 value, §3.3 query structure, §3.4 expression.
  assert kinds("CHAR") == [Keyword(KwChar)]
  assert kinds("true") == [Keyword(token.KwTrue)]
  assert kinds("Alter") == [Keyword(token.KwAlter)]
  assert kinds("AND") == [Keyword(KwAnd)]
}

//-----------------------------------------------------------------------------
// Identifiers
//-----------------------------------------------------------------------------

pub fn unquoted_identifier_folds_to_lower_case_test() {
  assert kinds("Foo") == [Identifier("foo")]
}

pub fn quoted_identifier_preserves_case_test() {
  assert kinds("\"Foo\"") == [QuotedIdentifier("Foo")]
}

pub fn quoted_identifier_collapses_doubled_quote_test() {
  assert kinds("\"a\"\"b\"") == [QuotedIdentifier("a\"b")]
}

pub fn long_unquoted_identifier_is_not_truncated_test() {
  let long_name = string.repeat("a", 80)
  assert kinds(long_name) == [Identifier(long_name)]
}

pub fn long_quoted_identifier_is_not_truncated_test() {
  let long_name = string.repeat("A", 80)
  assert kinds("\"" <> long_name <> "\"") == [QuotedIdentifier(long_name)]
}

//-----------------------------------------------------------------------------
// PostgreSQL reserved words (spec.md §3.5)
//-----------------------------------------------------------------------------

pub fn an_unquoted_postgres_reserved_word_is_rejected_test() {
  // One from each rough source: a plain SQL reserved word (`select`), a
  // reserved word that's specifically "(can be function or type name)"
  // rather than plainly reserved (`table`), and a multi-word one
  // (`current_timestamp`).
  let assert ReservedWord(word: "select", at: _) = lex_error("select")
  let assert ReservedWord(word: "table", at: _) = lex_error("table")
  let assert ReservedWord(word: "current_timestamp", at: _) =
    lex_error("current_timestamp")
}

pub fn the_reserved_word_check_applies_case_insensitively_test() {
  // Same folding rule as keywords/identifiers (§1) — matching case
  // doesn't let a reserved word slip through.
  let assert ReservedWord(word: "select", at: _) = lex_error("SELECT")
  let assert ReservedWord(word: "select", at: _) = lex_error("Select")
}

pub fn a_struodb_keyword_that_is_also_postgres_reserved_lexes_as_the_keyword_test() {
  // `create`/`check`/`not` are both a StruoDB keyword (§3) and a
  // PostgreSQL reserved word — StruoDB's own lookup runs first, so these
  // still tokenize as `Keyword`, not `ReservedWord`; §3 already made them
  // unusable as identifiers before §3.5 existed.
  assert kinds("create") == [Keyword(KwCreate)]
  assert kinds("check") == [Keyword(token.KwCheck)]
  assert kinds("not") == [Keyword(token.KwNot)]
}

pub fn a_postgres_non_reserved_word_still_lexes_as_a_plain_identifier_test() {
  // `value` is a PostgreSQL keyword, but only "non-reserved" — not in
  // §3.5's list, and not one of StruoDB's own keywords either, so it's
  // still a perfectly ordinary identifier.
  assert kinds("value") == [Identifier("value")]
}

pub fn quoting_a_reserved_word_still_works_test() {
  // §2/§3.5: quoting is exactly the escape hatch this restriction exists
  // to require — it doesn't make reserved words unusable, only their
  // unquoted spelling.
  assert kinds("\"select\"") == [QuotedIdentifier("select")]
}

//-----------------------------------------------------------------------------
// Numeric literals
//-----------------------------------------------------------------------------

pub fn integer_literal_forms_test() {
  assert kinds("42") == [IntegerLiteral("42")]
  assert kinds("007") == [IntegerLiteral("007")]
}

pub fn numeric_literal_forms_test() {
  assert kinds("3.14") == [NumericLiteral("3.14")]
  assert kinds("3.") == [NumericLiteral("3.")]
  assert kinds(".14") == [NumericLiteral(".14")]
}

pub fn exponent_suffix_is_always_a_numeric_literal_test() {
  // §4.2: `1e10` is integer-valued but still a numeric literal, not an
  // integer literal.
  assert kinds("1e10") == [NumericLiteral("1e10")]
  assert kinds("1.5e-3") == [NumericLiteral("1.5e-3")]
  assert kinds("2E5") == [NumericLiteral("2E5")]
}

pub fn digit_group_separator_is_accepted_and_stripped_test() {
  assert kinds("1_000_000") == [IntegerLiteral("1000000")]
}

pub fn digit_group_separator_misplacement_is_rejected_test() {
  // `1_` (trailing), `1__0` (doubled), `1_.5` (trailing before the
  // point), `1._5` (leading after the point), `1e_5` (leading in the
  // exponent) — spec.md §4.2's own examples, minus `_1`; see the next
  // test for why that one isn't reachable as a numeric-literal error.
  let assert InvalidDigitGroupSeparator(at: _) = lex_error("1_")
  let assert InvalidDigitGroupSeparator(at: _) = lex_error("1__0")
  let assert InvalidDigitGroupSeparator(at: _) = lex_error("1_.5")
  let assert InvalidDigitGroupSeparator(at: _) = lex_error("1._5")
  let assert InvalidDigitGroupSeparator(at: _) = lex_error("1e_5")
}

pub fn a_leading_underscore_is_an_identifier_not_a_number_test() {
  // spec.md §4.2 lists `_1` alongside its other invalid-separator
  // examples, but a token starting with `_` is an identifier by §2's own
  // rules (§2's unquoted-identifier grammar starts with a letter or
  // `_`), so number scanning never even begins — `_1` lexes as the
  // identifier `_1`, not a rejected numeric literal. See the note on
  // "leading" separators in lexer.gleam's `validate_separator_run`.
  assert kinds("_1") == [Identifier("_1")]
}

//-----------------------------------------------------------------------------
// String literals
//-----------------------------------------------------------------------------

pub fn string_literal_collapses_doubled_quote_test() {
  assert kinds("'it''s'") == [StringLiteral("it's")]
}

pub fn string_literals_concatenate_across_a_newline_test() {
  assert kinds("'foo'\n'bar'") == [StringLiteral("foobar")]
}

pub fn string_literals_do_not_concatenate_on_the_same_line_test() {
  assert kinds("'foo' 'bar'") == [StringLiteral("foo"), StringLiteral("bar")]
}

//-----------------------------------------------------------------------------
// Comments
//-----------------------------------------------------------------------------

pub fn line_comment_is_skipped_test() {
  assert kinds("1 -- comment\n2") == [IntegerLiteral("1"), IntegerLiteral("2")]
}

pub fn nested_block_comment_is_skipped_as_one_unit_test() {
  assert kinds("1 /* outer /* inner */ still in outer */ 2")
    == [IntegerLiteral("1"), IntegerLiteral("2")]
}

//-----------------------------------------------------------------------------
// Unterminated input
//-----------------------------------------------------------------------------

pub fn unterminated_string_is_reported_test() {
  let assert UnterminatedString(at: _) = lex_error("'abc")
}

pub fn unterminated_quoted_identifier_is_reported_test() {
  let assert UnterminatedQuotedIdentifier(at: _) = lex_error("\"abc")
}

pub fn unterminated_block_comment_is_reported_test() {
  let assert UnterminatedBlockComment(at: _) = lex_error("/* abc")
}

//-----------------------------------------------------------------------------
// Maximal munch (spec.md §5)
//-----------------------------------------------------------------------------

pub fn maximal_munch_on_every_prefix_sharing_group_test() {
  assert kinds("<") == [Operator(Lt)]
  assert kinds("<=") == [Operator(Le)]
  assert kinds("<>") == [Operator(NeAngle)]
  assert kinds("<<") == [Operator(Shl)]
  assert kinds("<@") == [Operator(ContainedBy)]

  assert kinds(">") == [Operator(token.Gt)]
  assert kinds(">=") == [Operator(Ge)]
  assert kinds(">>") == [Operator(Shr)]

  assert kinds("-") == [Operator(token.Minus)]
  assert kinds("->") == [Operator(Arrow)]
  assert kinds("->>") == [Operator(ArrowText)]

  assert kinds("#") == [Operator(Hash)]
  assert kinds("#>") == [Operator(HashArrow)]
  assert kinds("#>>") == [Operator(HashArrowText)]

  assert kinds("|") == [Operator(Pipe)]
  assert kinds("||") == [Operator(Concat)]

  assert kinds("~") == [Operator(Tilde)]
  assert kinds("~*") == [Operator(RegexMatchCi)]

  assert kinds("!=") == [Operator(NeBang)]
  assert kinds("!~") == [Operator(RegexNoMatch)]
  assert kinds("!~*") == [Operator(RegexNoMatchCi)]
}

pub fn double_colon_is_one_cast_token_test() {
  assert kinds("::") == [Operator(Cast)]
}

pub fn json_and_containment_operators_test() {
  assert kinds("@>") == [Operator(Contains)]
}

pub fn bitwise_and_is_distinct_from_string_concat_test() {
  assert kinds("&") == [Operator(Amp)]
}

pub fn punctuation_tokens_test() {
  assert kinds("(),;.") == [LeftParen, RightParen, Comma, Semicolon, Dot]
}

pub fn equals_is_not_confused_with_a_longer_operator_test() {
  assert kinds("=") == [Operator(Eq)]
}

//-----------------------------------------------------------------------------
// Unknown characters
//-----------------------------------------------------------------------------

pub fn unknown_character_is_reported_test() {
  let assert UnknownCharacter(char: "$", at: _) = lex_error("$")
  let assert UnknownCharacter(char: "@", at: _) = lex_error("@")
  let assert UnknownCharacter(char: "\\", at: _) = lex_error("\\")
}

//-----------------------------------------------------------------------------
// A small end-to-end sanity check
//-----------------------------------------------------------------------------

pub fn a_whole_column_definition_tokenizes_test() {
  assert kinds("reading REAL CONSTRAINT reading_in_range CHECK (reading > 0)")
    == [
      Identifier("reading"),
      Keyword(token.KwReal),
      Keyword(token.KwConstraint),
      Identifier("reading_in_range"),
      Keyword(token.KwCheck),
      LeftParen,
      Identifier("reading"),
      Operator(token.Gt),
      IntegerLiteral("0"),
      RightParen,
    ]
}
//-----------------------------------------------------------------------------
