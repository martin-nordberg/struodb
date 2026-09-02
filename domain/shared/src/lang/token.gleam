//-----------------------------------------------------------------------------
// Pure data: lexical tokens for StruoDB source text (spec.md Part I). No
// logic beyond the structural equality Gleam gives records/unions for free
// — see lexer.gleam for the scanner that produces these.
//-----------------------------------------------------------------------------

/// A position in source text, both as line/column (for human-readable error
/// messages) and byte offset (for slicing/highlighting source). 1-indexed,
/// matching how editors and most compiler diagnostics number lines/columns.
pub type Position {
  Position(line: Int, column: Int, byte_offset: Int)
}

/// The half-open-by-convention (but here inclusive-inclusive, since every
/// caller wants "start of first grapheme" through "end of last grapheme")
/// range a token or AST node occupies in source text.
pub type Span {
  Span(start: Position, end: Position)
}

pub type Token {
  Token(kind: TokenKind, span: Span)
}

pub type TokenKind {
  Keyword(Keyword)
  /// Unquoted identifier: already folded to lower case (§1); full text,
  /// never truncated — see "On not truncating in the lexer" in
  /// lexer.gleam.
  Identifier(name: String)
  /// Quoted identifier (`"..."`): case preserved exactly; `""` collapsed
  /// to one literal `"`; full text, never truncated.
  QuotedIdentifier(name: String)
  /// Digit-group separators (`_`, §4.2) already stripped from `text`.
  IntegerLiteral(text: String)
  /// Ditto; has a `.` and/or an exponent — see §4.2 on why `1e10` lands
  /// here rather than in `IntegerLiteral` despite being integer-valued.
  NumericLiteral(text: String)
  /// `''` already collapsed to one literal `'`; adjacent
  /// newline-separated literals already concatenated into one token
  /// (§4.3) — every later stage sees exactly one `StringLiteral`.
  StringLiteral(value: String)
  Operator(Operator)
  LeftParen
  RightParen
  Comma
  Semicolon
  Dot
  Eof
}

/// One variant per keyword in spec.md §3 — deliberately not
/// `Keyword(String)`, so the parser can exhaustively pattern-match keyword
/// tokens and get a compile error from Gleam itself if a keyword is ever
/// missed, rather than a runtime string-comparison bug.
pub type Keyword {
  // §3.1 Data type keywords
  KwBigint
  KwBoolean
  KwChar
  KwDate
  KwDecimal
  KwDouble
  KwInt
  KwInteger
  KwInterval
  KwJson
  KwJsonb
  KwNumeric
  KwPrecision
  KwReal
  KwSmallint
  KwText
  KwTime
  KwTimestamp
  KwTimestamptz
  KwUuid
  KwVarchar
  // §3.2 Value keywords
  KwFalse
  KwNull
  KwTrue
  // §3.3 Query structure keywords
  KwAdd
  KwAlter
  KwAlways
  KwAs
  KwCheck
  KwColumn
  KwConflict
  KwConstraint
  KwCreate
  KwDefault
  KwDo
  KwDrop
  KwGenerated
  KwInsert
  KwInto
  KwNothing
  KwOn
  KwOptional
  KwReturning
  KwStored
  KwStream
  KwType
  KwValues
  KwVirtual
  // §3.4 Expression keywords
  KwAnd
  KwBetween
  KwDistinct
  KwFrom
  KwIlike
  KwIn
  KwIs
  KwLike
  KwNot
  KwOr
  KwSimilar
  KwTo
}

/// One variant per operator in spec.md §5.1–§5.7 (punctuation in §5.8 gets
/// its own `TokenKind` variants above instead, since `(` `)` `,` `;` `.`
/// are never part of an operand-combining expression).
pub type Operator {
  Plus
  Minus
  Star
  Slash
  Percent
  Caret
  Eq
  Gt
  Lt
  Le
  Ge
  /// `<>` — kept distinct from `NeBang`; see the note in lexer.gleam and
  /// `BinaryOperator`'s `CmpNeAngle` in expr_ast.gleam.
  NeAngle
  /// `!=`
  NeBang
  /// `||`
  Concat
  Amp
  Pipe
  Hash
  /// Bare `~` — both bitwise-NOT (prefix, §5.4) and regex-match (infix,
  /// §5.5) tokenize to this one variant; the lexer has no type
  /// information to disambiguate them, and PostgreSQL doesn't either at
  /// the lexical level (see the note in lexer.gleam). The **parser**
  /// resolves which meaning applies from position (prefix vs. infix),
  /// producing `UnaryOperator.BitNot` or `BinaryOperator.RegexMatchOp`
  /// (expr_ast.gleam) accordingly — so this token type has no separate
  /// `RegexMatch` variant to keep in sync with `Tilde`.
  Tilde
  Shl
  Shr
  /// `~*`
  RegexMatchCi
  /// `!~`
  RegexNoMatch
  /// `!~*`
  RegexNoMatchCi
  /// `->`
  Arrow
  /// `->>`
  ArrowText
  /// `#>`
  HashArrow
  /// `#>>`
  HashArrowText
  /// `@>`
  Contains
  /// `<@`
  ContainedBy
  /// `::`
  Cast
}
//-----------------------------------------------------------------------------
