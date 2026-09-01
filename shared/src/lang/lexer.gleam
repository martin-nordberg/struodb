import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import lang/token.{type Keyword, type Position, type Token, type TokenKind}

//-----------------------------------------------------------------------------

/// Reasons `tokenize` could not turn `source` into a `List(Token)`.
/// Lexing stops at the first error — see the "Design decisions" section
/// of docs/lang/implementation-plan.md for why lexing (unlike semantic
/// analysis) doesn't try to accumulate more than one.
pub type LexError {
  UnterminatedString(at: Position)
  UnterminatedBlockComment(at: Position)
  UnterminatedQuotedIdentifier(at: Position)
  /// A `_` digit-group separator (§4.2) led, trailed, doubled up, or sat
  /// next to the decimal point or exponent marker within one numeric
  /// literal. `at` is the literal's own start position, not the
  /// offending `_` itself — precise enough for a human to find it in a
  /// short literal, and simpler than threading a second position through
  /// every digit-run helper below.
  InvalidDigitGroupSeparator(at: Position)
  /// An unquoted identifier matched one of PostgreSQL's own reserved
  /// words (§3.5) — `word` is already folded to lower case. Quoting it
  /// (`"..."`, §2) is unaffected and always works; this only rejects the
  /// unquoted spelling, the same restriction PostgreSQL itself applies.
  /// See §3.5 for why StruoDB enforces this rather than leaving it to
  /// the transpiler.
  ReservedWord(word: String, at: Position)
  UnknownCharacter(char: String, at: Position)
}

//-----------------------------------------------------------------------------

/// Scans `source` into a flat list of tokens ending in `Eof`, or the first
/// `LexError` encountered. A hand-written scanner over
/// `string.to_graphemes`, matching the grapheme-list-consuming style
/// `base62.decode_loop` already uses in this codebase.
pub fn tokenize(source: String) -> Result(List(Token), LexError) {
  let start = token.Position(line: 1, column: 1, byte_offset: 0)
  scan(string.to_graphemes(source), start, [])
}

//-----------------------------------------------------------------------------
// Top-level loop
//-----------------------------------------------------------------------------

/// `chars` always holds the graphemes not yet consumed; `pos` is always
/// the position of `chars`'s first element (or, once `chars` is empty,
/// the position one past the last character of `source` — where `Eof`
/// belongs). Every helper below preserves that invariant.
fn scan(
  chars: List(String),
  pos: Position,
  acc: List(Token),
) -> Result(List(Token), LexError) {
  use #(chars2, pos2) <- result.try(skip_ignorable(chars, pos))
  case chars2 {
    [] ->
      Ok(list.reverse([token.Token(token.Eof, token.Span(pos2, pos2)), ..acc]))
    _ -> {
      use #(tok, chars3, pos3) <- result.try(scan_token(chars2, pos2))
      scan(chars3, pos3, [tok, ..acc])
    }
  }
}

/// One iteration's dispatch (plan step 2–6): string literal, quoted
/// identifier, unquoted identifier/keyword, number, or
/// operator/punctuation (which itself reports `UnknownCharacter` for
/// anything matching none of the above). Only ever called with non-empty
/// `chars` — `scan` already peels off the `Eof` case first.
fn scan_token(
  chars: List(String),
  pos: Position,
) -> Result(#(Token, List(String), Position), LexError) {
  case chars {
    [] -> panic as "scan_token called with empty input"
    ["'", ..rest] -> scan_string(rest, advance(pos, "'"), pos, "")
    ["\"", ..rest] -> scan_quoted_identifier(rest, advance(pos, "\""), pos, "")
    [first, ..] ->
      case is_ident_start(first) {
        True -> scan_identifier(chars, pos)
        False ->
          case is_digit(first) {
            True -> scan_number(chars, pos)
            False -> {
              let starts_fractional =
                first == "."
                && case chars {
                  [_, second, ..] -> is_digit(second)
                  _ -> False
                }
              case starts_fractional {
                True -> scan_number(chars, pos)
                False -> scan_operator(chars, pos)
              }
            }
          }
      }
  }
}

//-----------------------------------------------------------------------------
// Whitespace and comments (spec.md §6)
//-----------------------------------------------------------------------------

fn skip_ignorable(
  chars: List(String),
  pos: Position,
) -> Result(#(List(String), Position), LexError) {
  case chars {
    [" ", ..rest] -> skip_ignorable(rest, advance(pos, " "))
    ["\t", ..rest] -> skip_ignorable(rest, advance(pos, "\t"))
    ["\n", ..rest] -> skip_ignorable(rest, advance(pos, "\n"))
    ["\r", ..rest] -> skip_ignorable(rest, advance(pos, "\r"))
    ["-", "-", ..rest] -> {
      let #(rest2, pos2) = skip_to_eol(rest, advance(advance(pos, "-"), "-"))
      skip_ignorable(rest2, pos2)
    }
    ["/", "*", ..rest] -> {
      use #(rest2, pos2) <- result.try(skip_block_comment(
        rest,
        advance(advance(pos, "/"), "*"),
        1,
        pos,
      ))
      skip_ignorable(rest2, pos2)
    }
    _ -> Ok(#(chars, pos))
  }
}

fn skip_to_eol(
  chars: List(String),
  pos: Position,
) -> #(List(String), Position) {
  case chars {
    [] -> #(chars, pos)
    ["\n", ..] -> #(chars, pos)
    [c, ..rest] -> skip_to_eol(rest, advance(pos, c))
  }
}

/// `depth` is the current `/*` nesting level (starts at 1, the caller's
/// own opening `/*`); `start` is that opening `/*`'s position, kept
/// around only to name in `UnterminatedBlockComment` if EOF is hit
/// before `depth` returns to 0. Nesting matches PostgreSQL — see §6.
fn skip_block_comment(
  chars: List(String),
  pos: Position,
  depth: Int,
  start: Position,
) -> Result(#(List(String), Position), LexError) {
  case chars {
    [] -> Error(UnterminatedBlockComment(at: start))
    ["*", "/", ..rest] -> {
      let pos2 = advance(advance(pos, "*"), "/")
      case depth - 1 {
        0 -> Ok(#(rest, pos2))
        remaining -> skip_block_comment(rest, pos2, remaining, start)
      }
    }
    ["/", "*", ..rest] ->
      skip_block_comment(
        rest,
        advance(advance(pos, "/"), "*"),
        depth + 1,
        start,
      )
    [c, ..rest] -> skip_block_comment(rest, advance(pos, c), depth, start)
  }
}

//-----------------------------------------------------------------------------
// String literals (spec.md §4.3)
//-----------------------------------------------------------------------------

/// `start` is the opening `'`'s position (for `UnterminatedString`, and
/// the token's own `Span`); `acc` is the value decoded so far (`''`
/// already collapsed to one `'`).
fn scan_string(
  chars: List(String),
  pos: Position,
  start: Position,
  acc: String,
) -> Result(#(Token, List(String), Position), LexError) {
  case chars {
    [] -> Error(UnterminatedString(at: start))
    ["'", "'", ..rest] ->
      scan_string(rest, advance(advance(pos, "'"), "'"), start, acc <> "'")
    ["'", ..rest] ->
      case peek_continuation(rest, advance(pos, "'")) {
        // §4.3: a newline-separated `'...' '...'` pair is one literal —
        // resolved once here, so no later stage ever sees two adjacent
        // string-literal tokens needing concatenation of their own.
        Some(#(rest2, pos2)) -> scan_string(rest2, pos2, start, acc)
        None -> {
          let end_pos = advance(pos, "'")
          Ok(#(
            token.Token(token.StringLiteral(acc), token.Span(start, end_pos)),
            rest,
            end_pos,
          ))
        }
      }
    [c, ..rest] -> scan_string(rest, advance(pos, c), start, acc <> c)
  }
}

/// After a string literal's closing `'`: skips whitespace, and if that
/// whitespace contains a newline and is followed immediately by another
/// `'`, consumes through that opening `'` too and reports where the next
/// segment's content starts. Otherwise reports `None`, leaving `chars`/
/// `pos` for the caller to use as-is (same-line whitespace between two
/// string literals does **not** concatenate them — they stay two
/// separate tokens, a parse error at the statement level).
fn peek_continuation(
  chars: List(String),
  pos: Position,
) -> Option(#(List(String), Position)) {
  skip_ws_tracking_newline(chars, pos, False)
}

fn skip_ws_tracking_newline(
  chars: List(String),
  pos: Position,
  saw_newline: Bool,
) -> Option(#(List(String), Position)) {
  case chars {
    [" ", ..rest] ->
      skip_ws_tracking_newline(rest, advance(pos, " "), saw_newline)
    ["\t", ..rest] ->
      skip_ws_tracking_newline(rest, advance(pos, "\t"), saw_newline)
    ["\r", ..rest] ->
      skip_ws_tracking_newline(rest, advance(pos, "\r"), saw_newline)
    ["\n", ..rest] -> skip_ws_tracking_newline(rest, advance(pos, "\n"), True)
    ["'", ..rest] ->
      case saw_newline {
        True -> Some(#(rest, advance(pos, "'")))
        False -> None
      }
    _ -> None
  }
}

//-----------------------------------------------------------------------------
// Quoted identifiers (spec.md §2)
//-----------------------------------------------------------------------------

fn scan_quoted_identifier(
  chars: List(String),
  pos: Position,
  start: Position,
  acc: String,
) -> Result(#(Token, List(String), Position), LexError) {
  case chars {
    [] -> Error(UnterminatedQuotedIdentifier(at: start))
    ["\"", "\"", ..rest] ->
      scan_quoted_identifier(
        rest,
        advance(advance(pos, "\""), "\""),
        start,
        acc <> "\"",
      )
    ["\"", ..rest] -> {
      let end_pos = advance(pos, "\"")
      Ok(#(
        token.Token(token.QuotedIdentifier(acc), token.Span(start, end_pos)),
        rest,
        end_pos,
      ))
    }
    [c, ..rest] ->
      scan_quoted_identifier(rest, advance(pos, c), start, acc <> c)
  }
}

//-----------------------------------------------------------------------------
// Unquoted identifiers and keywords (spec.md §2, §3)
//-----------------------------------------------------------------------------

/// `chars`'s first grapheme is already known (by `scan_token`) to satisfy
/// `is_ident_start`.
fn scan_identifier(
  chars: List(String),
  pos: Position,
) -> Result(#(Token, List(String), Position), LexError) {
  let #(raw, rest, end_pos) = consume_while(chars, pos, is_ident_continue)
  // §1: unquoted identifiers fold to lower case — no truncation here, see
  // "On not truncating in the lexer" in docs/lang/implementation-plan.md;
  // the full text is kept all the way through tokens and the AST.
  let folded = string.lowercase(raw)
  case lookup_keyword(folded) {
    Some(kw) ->
      Ok(#(
        token.Token(token.Keyword(kw), token.Span(pos, end_pos)),
        rest,
        end_pos,
      ))
    // Not one of StruoDB's own keywords — still rejected unquoted if it's
    // one of PostgreSQL's own reserved words (§3.5); a StruoDB keyword
    // that also happens to be PostgreSQL-reserved (e.g. `create`, `not`)
    // is already handled above and never reaches this check.
    None ->
      case is_postgres_reserved_word(folded) {
        True -> Error(ReservedWord(word: folded, at: pos))
        False ->
          Ok(#(
            token.Token(token.Identifier(folded), token.Span(pos, end_pos)),
            rest,
            end_pos,
          ))
      }
  }
}

/// `text` is already folded to lower case by the caller — keywords are
/// case-insensitive (§1). A `case` over string literals, not a `Dict`
/// built per call, matching the "avoid an ad hoc `Dict` built per call"
/// reasoning `base62.gleam` documents for its own capacity table.
fn lookup_keyword(text: String) -> Option(Keyword) {
  case text {
    // §3.1 Data type keywords
    "bigint" -> Some(token.KwBigint)
    "boolean" -> Some(token.KwBoolean)
    "char" -> Some(token.KwChar)
    "date" -> Some(token.KwDate)
    "decimal" -> Some(token.KwDecimal)
    "double" -> Some(token.KwDouble)
    "int" -> Some(token.KwInt)
    "integer" -> Some(token.KwInteger)
    "interval" -> Some(token.KwInterval)
    "json" -> Some(token.KwJson)
    "jsonb" -> Some(token.KwJsonb)
    "numeric" -> Some(token.KwNumeric)
    "precision" -> Some(token.KwPrecision)
    "real" -> Some(token.KwReal)
    "smallint" -> Some(token.KwSmallint)
    "text" -> Some(token.KwText)
    "time" -> Some(token.KwTime)
    "timestamp" -> Some(token.KwTimestamp)
    "timestamptz" -> Some(token.KwTimestamptz)
    "uuid" -> Some(token.KwUuid)
    "varchar" -> Some(token.KwVarchar)
    // §3.2 Value keywords
    "false" -> Some(token.KwFalse)
    "null" -> Some(token.KwNull)
    "true" -> Some(token.KwTrue)
    // §3.3 Query structure keywords
    "add" -> Some(token.KwAdd)
    "alter" -> Some(token.KwAlter)
    "always" -> Some(token.KwAlways)
    "as" -> Some(token.KwAs)
    "check" -> Some(token.KwCheck)
    "column" -> Some(token.KwColumn)
    "conflict" -> Some(token.KwConflict)
    "constraint" -> Some(token.KwConstraint)
    "create" -> Some(token.KwCreate)
    "default" -> Some(token.KwDefault)
    "do" -> Some(token.KwDo)
    "drop" -> Some(token.KwDrop)
    "generated" -> Some(token.KwGenerated)
    "insert" -> Some(token.KwInsert)
    "into" -> Some(token.KwInto)
    "nothing" -> Some(token.KwNothing)
    "on" -> Some(token.KwOn)
    "optional" -> Some(token.KwOptional)
    "returning" -> Some(token.KwReturning)
    "stored" -> Some(token.KwStored)
    "stream" -> Some(token.KwStream)
    "type" -> Some(token.KwType)
    "values" -> Some(token.KwValues)
    "virtual" -> Some(token.KwVirtual)
    // §3.4 Expression keywords
    "and" -> Some(token.KwAnd)
    "between" -> Some(token.KwBetween)
    "distinct" -> Some(token.KwDistinct)
    "from" -> Some(token.KwFrom)
    "ilike" -> Some(token.KwIlike)
    "in" -> Some(token.KwIn)
    "is" -> Some(token.KwIs)
    "like" -> Some(token.KwLike)
    "not" -> Some(token.KwNot)
    "or" -> Some(token.KwOr)
    "similar" -> Some(token.KwSimilar)
    "to" -> Some(token.KwTo)
    _ -> None
  }
}

/// `text` is expected already folded to lower case by the caller. True
/// for exactly the words spec.md §3.5 lists: PostgreSQL's own "reserved"
/// and "reserved (can be function or type name)" keywords
/// (https://www.postgresql.org/docs/current/sql-keywords-appendix.html,
/// "PostgreSQL" column, as of PostgreSQL 18) — see §3.5 for why StruoDB
/// rejects these unquoted rather than leaving the problem to the
/// transpiler. Same `case`-over-literals style as `lookup_keyword` above,
/// for the same reason.
///
/// Exported (unlike `lookup_keyword`, StruoDB's own keyword table) so
/// `expr_codegen.gleam` can reuse this exact table for its own
/// quoting decision — see `docs/lang/codegen-plan.md`'s
/// identifier-quoting design decision for why codegen needs it too, not
/// just the lexer.
pub fn is_postgres_reserved_word(text: String) -> Bool {
  case text {
    "all"
    | "analyse"
    | "analyze"
    | "and"
    | "any"
    | "array"
    | "as"
    | "asc"
    | "asymmetric"
    | "authorization"
    | "binary"
    | "both"
    | "case"
    | "cast"
    | "check"
    | "collate"
    | "collation"
    | "column"
    | "concurrently"
    | "constraint"
    | "create"
    | "cross"
    | "current_catalog"
    | "current_date"
    | "current_role"
    | "current_schema"
    | "current_time"
    | "current_timestamp"
    | "current_user"
    | "default"
    | "deferrable"
    | "desc"
    | "distinct"
    | "do"
    | "else"
    | "end"
    | "except"
    | "false"
    | "fetch"
    | "for"
    | "foreign"
    | "freeze"
    | "from"
    | "full"
    | "grant"
    | "group"
    | "having"
    | "ilike"
    | "in"
    | "initially"
    | "inner"
    | "intersect"
    | "into"
    | "is"
    | "isnull"
    | "join"
    | "lateral"
    | "leading"
    | "left"
    | "like"
    | "limit"
    | "localtime"
    | "localtimestamp"
    | "natural"
    | "not"
    | "notnull"
    | "null"
    | "offset"
    | "on"
    | "only"
    | "or"
    | "order"
    | "outer"
    | "overlaps"
    | "placing"
    | "primary"
    | "references"
    | "returning"
    | "right"
    | "select"
    | "session_user"
    | "similar"
    | "some"
    | "symmetric"
    | "system_user"
    | "table"
    | "tablesample"
    | "then"
    | "to"
    | "trailing"
    | "true"
    | "union"
    | "unique"
    | "user"
    | "using"
    | "variadic"
    | "verbose"
    | "when"
    | "where"
    | "window"
    | "with" -> True
    _ -> False
  }
}

//-----------------------------------------------------------------------------
// Numeric literals (spec.md §4.2)
//-----------------------------------------------------------------------------

/// `chars`'s first grapheme is already known (by `scan_token`) to be
/// either a digit, or a `.` immediately followed by a digit.
fn scan_number(
  chars: List(String),
  pos: Position,
) -> Result(#(Token, List(String), Position), LexError) {
  let #(int_raw, chars1, pos1) =
    consume_while(chars, pos, is_digit_or_underscore)
  use _ <- result.try(case validate_separator_run(int_raw) {
    True -> Ok(Nil)
    False -> Error(InvalidDigitGroupSeparator(at: pos))
  })

  let #(has_dot, chars2, pos2) = case chars1 {
    [".", ..rest] -> #(True, rest, advance(pos1, "."))
    _ -> #(False, chars1, pos1)
  }

  use #(frac_raw, chars3, pos3) <- result.try(case has_dot {
    False -> Ok(#("", chars2, pos2))
    True -> {
      let #(raw, rest, p) = consume_while(chars2, pos2, is_digit_or_underscore)
      case validate_separator_run(raw) {
        True -> Ok(#(raw, rest, p))
        False -> Error(InvalidDigitGroupSeparator(at: pos))
      }
    }
  })

  use maybe_exponent <- result.try(try_scan_exponent(chars3, pos3, pos))
  let #(exponent_text, chars4, pos4) = case maybe_exponent {
    Some(#(text, rest, p)) -> #(text, rest, p)
    None -> #("", chars3, pos3)
  }

  let dot_text = case has_dot {
    True -> "."
    False -> ""
  }
  // Digit-group separators stripped, but the literal's shape ("3.",
  // ".14", "1e10") kept exactly as written, per the "Numeric literals
  // keep their source text" design decision in
  // docs/lang/implementation-plan.md.
  let text =
    strip_underscores(int_raw)
    <> dot_text
    <> strip_underscores(frac_raw)
    <> strip_underscores(exponent_text)
  let is_numeric = has_dot || exponent_text != ""
  let kind = case is_numeric {
    True -> token.NumericLiteral(text)
    False -> token.IntegerLiteral(text)
  }
  Ok(#(token.Token(kind, token.Span(pos, pos4)), chars4, pos4))
}

/// Tries to consume a `[eE][+-]?digits` exponent suffix starting at
/// `chars`/`pos`. Returns `Ok(None)`, consuming nothing, if there's no
/// `e`/`E` here or it isn't followed by at least one digit-or-`_`
/// character (e.g. a bare trailing `e`, which is then free to be
/// rescanned as its own identifier token) — but once a digit or `_`
/// *does* follow, this commits to exponent parsing and validates
/// separator placement the same way the integer/fractional parts do,
/// matching spec.md's `1e_5` being invalid rather than "not an
/// exponent." `literal_start` is only for `InvalidDigitGroupSeparator`.
fn try_scan_exponent(
  chars: List(String),
  pos: Position,
  literal_start: Position,
) -> Result(Option(#(String, List(String), Position)), LexError) {
  case chars {
    [e, ..after_e] if e == "e" || e == "E" -> {
      let #(sign, after_sign, pos_after_sign) = case after_e {
        [s, ..rest] if s == "+" || s == "-" -> #(
          s,
          rest,
          advance(advance(pos, e), s),
        )
        _ -> #("", after_e, advance(pos, e))
      }
      case after_sign {
        [d, ..] ->
          case is_digit_or_underscore(d) {
            False -> Ok(None)
            True -> {
              let #(digits_raw, rest2, end_pos) =
                consume_while(
                  after_sign,
                  pos_after_sign,
                  is_digit_or_underscore,
                )
              case validate_separator_run(digits_raw) {
                True -> Ok(Some(#(e <> sign <> digits_raw, rest2, end_pos)))
                False -> Error(InvalidDigitGroupSeparator(at: literal_start))
              }
            }
          }
        [] -> Ok(None)
      }
    }
    _ -> Ok(None)
  }
}

/// A digit-run (already extracted by `consume_while`, so every character
/// in `raw` is a digit or `_`) is valid unless a `_` leads, trails, or
/// doubles up — the three ways spec.md §4.2 forbids independent of what
/// comes immediately before/after the run itself (the "next to the
/// decimal point or exponent marker" cases fall out for free: a run
/// bordering `.`/`e` that starts or ends with `_` is exactly a leading or
/// trailing `_` from the run's own point of view — see the call sites in
/// `scan_number`/`try_scan_exponent`, one per run).
fn validate_separator_run(raw: String) -> Bool {
  case raw {
    "" -> True
    _ ->
      !string.starts_with(raw, "_")
      && !string.ends_with(raw, "_")
      && !string.contains(raw, "__")
  }
}

fn strip_underscores(text: String) -> String {
  string.replace(in: text, each: "_", with: "")
}

//-----------------------------------------------------------------------------
// Operators and punctuation (spec.md §5)
//-----------------------------------------------------------------------------

/// Maximal munch (§5): a table ordered longest-match-first, tried top to
/// bottom — the simplest correct implementation at this operator count,
/// per the "Algorithm" section of docs/lang/implementation-plan.md (a
/// trie was considered and rejected as unnecessary). `chars`'s first
/// grapheme is already known (by `scan_token`) to be none of `'`, `"`, a
/// digit, an identifier-start character, or a `.` starting a fractional
/// number.
fn scan_operator(
  chars: List(String),
  pos: Position,
) -> Result(#(Token, List(String), Position), LexError) {
  case chars {
    ["-", ">", ">", ..rest] ->
      emit(token.Operator(token.ArrowText), chars, pos, 3, rest)
    ["#", ">", ">", ..rest] ->
      emit(token.Operator(token.HashArrowText), chars, pos, 3, rest)
    ["!", "~", "*", ..rest] ->
      emit(token.Operator(token.RegexNoMatchCi), chars, pos, 3, rest)
    ["<", "=", ..rest] -> emit(token.Operator(token.Le), chars, pos, 2, rest)
    [">", "=", ..rest] -> emit(token.Operator(token.Ge), chars, pos, 2, rest)
    ["<", ">", ..rest] ->
      emit(token.Operator(token.NeAngle), chars, pos, 2, rest)
    ["!", "=", ..rest] ->
      emit(token.Operator(token.NeBang), chars, pos, 2, rest)
    ["|", "|", ..rest] ->
      emit(token.Operator(token.Concat), chars, pos, 2, rest)
    ["<", "<", ..rest] -> emit(token.Operator(token.Shl), chars, pos, 2, rest)
    [">", ">", ..rest] -> emit(token.Operator(token.Shr), chars, pos, 2, rest)
    ["~", "*", ..rest] ->
      emit(token.Operator(token.RegexMatchCi), chars, pos, 2, rest)
    ["!", "~", ..rest] ->
      emit(token.Operator(token.RegexNoMatch), chars, pos, 2, rest)
    ["-", ">", ..rest] -> emit(token.Operator(token.Arrow), chars, pos, 2, rest)
    ["#", ">", ..rest] ->
      emit(token.Operator(token.HashArrow), chars, pos, 2, rest)
    ["@", ">", ..rest] ->
      emit(token.Operator(token.Contains), chars, pos, 2, rest)
    ["<", "@", ..rest] ->
      emit(token.Operator(token.ContainedBy), chars, pos, 2, rest)
    [":", ":", ..rest] -> emit(token.Operator(token.Cast), chars, pos, 2, rest)
    ["+", ..rest] -> emit(token.Operator(token.Plus), chars, pos, 1, rest)
    ["-", ..rest] -> emit(token.Operator(token.Minus), chars, pos, 1, rest)
    ["*", ..rest] -> emit(token.Operator(token.Star), chars, pos, 1, rest)
    ["/", ..rest] -> emit(token.Operator(token.Slash), chars, pos, 1, rest)
    ["%", ..rest] -> emit(token.Operator(token.Percent), chars, pos, 1, rest)
    ["^", ..rest] -> emit(token.Operator(token.Caret), chars, pos, 1, rest)
    ["=", ..rest] -> emit(token.Operator(token.Eq), chars, pos, 1, rest)
    [">", ..rest] -> emit(token.Operator(token.Gt), chars, pos, 1, rest)
    ["<", ..rest] -> emit(token.Operator(token.Lt), chars, pos, 1, rest)
    ["&", ..rest] -> emit(token.Operator(token.Amp), chars, pos, 1, rest)
    ["|", ..rest] -> emit(token.Operator(token.Pipe), chars, pos, 1, rest)
    ["#", ..rest] -> emit(token.Operator(token.Hash), chars, pos, 1, rest)
    ["~", ..rest] -> emit(token.Operator(token.Tilde), chars, pos, 1, rest)
    ["(", ..rest] -> emit(token.LeftParen, chars, pos, 1, rest)
    [")", ..rest] -> emit(token.RightParen, chars, pos, 1, rest)
    [",", ..rest] -> emit(token.Comma, chars, pos, 1, rest)
    [";", ..rest] -> emit(token.Semicolon, chars, pos, 1, rest)
    [".", ..rest] -> emit(token.Dot, chars, pos, 1, rest)
    [c, ..] -> Error(UnknownCharacter(char: c, at: pos))
    [] -> panic as "scan_operator called with empty input"
  }
}

/// Builds the `n`-grapheme token `kind` starting at `start_pos`; `chars`
/// is the full remaining input (used only to compute the consumed
/// graphemes' end position) and `rest` is `chars` with those `n`
/// graphemes already dropped, as bound by the caller's own pattern match.
fn emit(
  kind: TokenKind,
  chars: List(String),
  start_pos: Position,
  n: Int,
  rest: List(String),
) -> Result(#(Token, List(String), Position), LexError) {
  let end_pos = list.fold(list.take(chars, n), start_pos, advance)
  Ok(#(token.Token(kind, token.Span(start_pos, end_pos)), rest, end_pos))
}

//-----------------------------------------------------------------------------
// Shared character-class and position helpers
//-----------------------------------------------------------------------------

fn is_ident_start(c: String) -> Bool {
  is_letter(c) || c == "_"
}

fn is_ident_continue(c: String) -> Bool {
  is_letter(c) || is_digit(c) || c == "_"
}

fn is_digit_or_underscore(c: String) -> Bool {
  is_digit(c) || c == "_"
}

fn is_letter(c: String) -> Bool {
  is_between(c, "a", "z") || is_between(c, "A", "Z")
}

fn is_digit(c: String) -> Bool {
  is_between(c, "0", "9")
}

/// `c`, `lo`, and `hi` are each expected to be a single grapheme; grapheme
/// ordering via `string.compare` matches ASCII order for the plain
/// letters/digits this is ever called with.
fn is_between(c: String, lo: String, hi: String) -> Bool {
  case string.compare(c, lo), string.compare(c, hi) {
    order.Lt, _ -> False
    _, order.Gt -> False
    _, _ -> True
  }
}

/// Advances `pos` by one grapheme `char`, tracking line/column resets on
/// `\n` and byte offset via `char`'s own UTF-8 size (so a multi-byte
/// grapheme, e.g. inside a quoted identifier or string literal, still
/// advances the byte offset correctly).
fn advance(pos: Position, char: String) -> Position {
  case char {
    "\n" ->
      token.Position(
        line: pos.line + 1,
        column: 1,
        byte_offset: pos.byte_offset + string.byte_size(char),
      )
    _ ->
      token.Position(
        line: pos.line,
        column: pos.column + 1,
        byte_offset: pos.byte_offset + string.byte_size(char),
      )
  }
}

/// Consumes the maximal run of leading graphemes satisfying `pred`,
/// returning that run's text, the remaining characters, and the position
/// just past the run. Shared by identifier scanning and every digit-run
/// in `scan_number`/`try_scan_exponent`.
fn consume_while(
  chars: List(String),
  pos: Position,
  pred: fn(String) -> Bool,
) -> #(String, List(String), Position) {
  consume_while_loop(chars, pos, pred, "")
}

fn consume_while_loop(
  chars: List(String),
  pos: Position,
  pred: fn(String) -> Bool,
  acc: String,
) -> #(String, List(String), Position) {
  case chars {
    [c, ..rest] ->
      case pred(c) {
        True -> consume_while_loop(rest, advance(pos, c), pred, acc <> c)
        False -> #(acc, chars, pos)
      }
    [] -> #(acc, chars, pos)
  }
}
//-----------------------------------------------------------------------------
