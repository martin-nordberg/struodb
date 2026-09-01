# StruoDB Query Language — Implementation Plan

Implements [`spec.md`](./spec.md). Read that first; this document covers
module layout, concrete signatures, and the steps to build the lexer,
parser, and semantic-analysis stages. Open questions raised along the way
are cross-referenced inline and collected in one list at the end, the same
way spec.md accumulates its own "Remaining open details."

**Note on package layout**: this plan was written, and the "Module
layout"/per-module sections below still read, as if `lang/` were one
`src/lang/` under a single package. It isn't, as built: expression parsing
plus `GeneratedClause`/`NamedCheck`/`Catalog` (`token`/`lexer`/`expr_ast`/
`expr_parser`/`token_stream`/`catalog`) live in `shared/`, reused by
`ddl_ast`/`ddl_parser`/`ddl_semantics` in `schema/` (CREATE/ALTER STREAM)
and by `dml_ast`/`dml_parser`/`dml_semantics` in `streams/` (INSERT) —
see CLAUDE.md's "The StruoDB query language front end" for the current
physical layout and why the split happened where it did. The design
decisions and per-check reasoning below are all still accurate; only file
paths and the single `Statement`/`SemanticError` types (now
`DdlStatement`+`DmlStatement`, and two independently-defined
`SemanticError`s) have changed, called out inline below.

## Scope

- **In scope**: tokenizing StruoDB source text (Part I of spec.md);
  parsing it into an AST (expressions/function calls, `CREATE STREAM`,
  `ALTER STREAM`, `INSERT` — Part II §8–§11); and semantic analysis —
  every rule spec.md states as "not expressed by the grammar, enforced as
  a semantic check."
- **Out of scope**: transpiling a validated AST to PostgreSQL SQL text
  (codegen). The semantic stage's job ends at "this statement is valid,
  and here is the catalog it produces" — turning that into `CREATE TABLE`/
  `ALTER TABLE`/`INSERT INTO` text is a separate plan once this one lands.
  Also out of scope: anything under spec.md §12 (querying/subscribing),
  since no grammar exists for it yet.

## Design decisions carried over from discussion

- **Pure functions throughout, no actors.** Unlike `util/hlc/clock` or
  `util/asyncio/*`, none of lexing, parsing, or semantic analysis is
  concurrent or stateful across calls in a way that needs an OTP actor —
  each stage is a plain `input -> Result(output, errors)` transform. This
  also makes every stage trivially testable without `test/support`-style
  actor-lifecycle helpers.
- **A statement is analyzed against an explicit, caller-supplied
  `Catalog`.** `ALTER STREAM` and `INSERT` are only meaningful relative to
  a stream's *current* declared shape (its columns, their types/
  nullability, its constraints) — §10 and §11's rules (widening-only type
  changes, drop-only-if-`OPTIONAL`, resolving an omitted column's value,
  rejecting a reserved `_STRUO_`-prefixed name, etc.) all require knowing
  what a
  `CREATE STREAM` (and any prior `ALTER STREAM`s) already established.
  Rather than have the semantic module reach out to a live database or
  own any persistence itself, it takes a `Catalog` value in and returns an
  updated `Catalog` out — pure, matching the explicit-passing style already
  used for `Subject`s in `util/hlc/clock`/`util/asyncio/*`. *How* a caller
  assembles the starting `Catalog` before the first statement in a given
  run (replay every historical `CREATE STREAM`/`ALTER STREAM` from a
  migrations directory each time, or load/persist a serialized snapshot)
  is intentionally left to whatever CLI/application layer eventually
  drives this — see open questions.
- **Semantic analysis accumulates diagnostics; lexing and parsing stop at
  the first error.** A lexer/parser is a classic recursive-descent
  scanner where one malformed token or misplaced keyword usually makes
  the rest of the input unreliable to keep interpreting, so both stop and
  report one error. Most semantic checks on a single statement are
  independent of each other, though (e.g. a reserved `_STRUO_`-prefixed
  name and "`CHECK` references an unknown column" don't block each
  other) — reporting all
  of them in one pass is strictly more useful to a caller than fixing one
  error at a time through repeated runs, and costs little: every check
  below is a read-only walk of the already-built AST plus `Catalog`.
- **Position tracking on tokens, top-level AST nodes, and `ColumnRef` —
  not on every `Expr` subnode.** Every `Token` carries a `Span`
  (§token.gleam) so lex/parse errors can point at the right place. AST
  nodes for statements, columns, and constraints carry a `Span` too,
  since semantic errors need to name "which column" or "which
  constraint." Of `Expr`'s fourteen variants, only `ColumnRef` carries
  one, deliberately: it's the only kind of subexpression this plan's
  semantic checks ever need to blame individually (an unknown or
  disallowed column reference, §9.4/§10/§11), and the parser already has
  the identifier `Token` in hand at the point it builds a `ColumnRef`, so
  capturing its span costs nothing extra. Spanning the other thirteen
  variants too was considered and rejected as disproportionate — see
  "Expression-level spans: a narrower alternative" under `expr_parser.gleam`.
- **Numeric literals keep their source text, not a parsed value.**
  `IntegerLiteral`/`NumericLiteral` tokens and AST nodes store the
  literal's text (digit-group separators stripped, per §4.2) rather than
  an `Int`/`Float`. A `DECIMAL(30,10)` literal can exceed `Float`
  precision, and since transpilation (out of scope here, but worth
  designing for) just re-emits the literal for PostgreSQL to parse itself,
  there is no need to round-trip through a Gleam numeric type at all —
  doing so could only lose precision, never add value.
- **Keyword tokens are per-keyword variants, not `Keyword(String)`.**
  Matches how `ClockMessage`'s constructors are specific
  (`Next`/`Merge`/`StopClock`) rather than stringly-typed — lets the
  parser exhaustively pattern-match keyword tokens and get a compile
  error from Gleam itself if a keyword is missed, rather than a runtime
  string-comparison bug.
- **`<>` and `!=` stay distinct tokens/AST nodes, never folded into one
  `Ne`.** Both mean not-equals (§5.2) and are treated identically by
  parsing (same precedence, same non-associativity) and semantic analysis
  — the distinction is preserved solely so a future formatter/
  pretty-printer can round-trip which spelling the user actually wrote,
  without needing per-`Expr` `Span`s (previous bullet) just to recover
  that one fact.
- **The lexer never truncates identifiers, even though spec.md §2 says
  an over-long one is "silently truncated to 63 bytes."** That rule
  describes what PostgreSQL does to the identifier once the transpiled
  SQL runs — PostgreSQL's own truncation is encoding-aware and
  authoritative, so StruoDB re-implementing it would only risk getting a
  multi-byte edge case wrong for no benefit. The lexer keeps the full
  text; only `ddl_semantics.gleam`'s duplicate-name check applies an
  approximate truncation (`postgres_name`), purely to give an earlier,
  friendlier diagnostic than a PostgreSQL error at execution time — see
  "On not truncating in the lexer" under `lexer.gleam` below.

## Module layout

As planned (single package) vs. as built (split by package — see the note
above):

```
# As planned:                        # As built:
src/lang/                            shared/src/lang/
  token.gleam                          token.gleam       # unchanged
  lexer.gleam                          lexer.gleam       # unchanged
  ast.gleam                            expr_ast.gleam    # Expr/DataType/operators half of ast.gleam,
                                                           # plus GeneratedClause/NamedCheck — see
                                                           # their own note in the ast.gleam section
  parser.gleam                         expr_parser.gleam # expr/data_type half of parser.gleam
                                        token_stream.gleam # extracted from parser.gleam's own
                                                           # peek/advance plumbing (§parser.gleam
                                                           # below never called this out as its own
                                                           # module — a later cleanup pulled it out)
  catalog.gleam                        catalog.gleam     # briefly lived in schema/, moved back —
                                                           # see its own section below
                                        expr_semantics.gleam # collect_column_refs/check_expr_column_refs —
                                                           # briefly two copies, one per
                                                           # *_semantics.gleam below; see their section
  semantic.gleam (CREATE/ALTER half) schema/src/lang/
                                        ddl_ast.gleam      # Statement/StreamElement/etc. half of ast.gleam,
                                                           # renamed DdlStatement
                                        ddl_parser.gleam  # CREATE/ALTER STREAM half of parser.gleam
                                        ddl_semantics.gleam # CREATE/ALTER half of semantic.gleam
  semantic.gleam (INSERT half)       streams/src/lang/
                                        dml_ast.gleam      # Insert/Value/ReturningItem half of ast.gleam,
                                                           # renamed DmlStatement
                                        dml_parser.gleam  # INSERT half of parser.gleam
                                        dml_semantics.gleam # INSERT half of semantic.gleam — its own
                                                           # scoped SemanticError

test/lang/                           shared/test/lang/
  token_test.gleam                     token_test.gleam   # still unbuilt, see below
  lexer_test.gleam                     lexer_test.gleam
  ast_test.gleam                       (none — no free-standing helper constructors to test)
  parser_test.gleam                    expr_parser_test.gleam # expect_*/data_type only — see below
                                        token_stream_test.gleam
                                        expr_semantics_test.gleam
  catalog_test.gleam                   catalog_test.gleam # briefly lived in schema/test/lang/, moved back
                                      schema/test/lang/
  semantic_test.gleam (CREATE/ALTER)   ddl_semantics_test.gleam
                                        ddl_parser_test.gleam
                                      streams/test/lang/
  semantic_test.gleam (INSERT)         dml_semantics_test.gleam
                                        dml_parser_test.gleam
```

Each error type still lives in the module that raises it (`LexError` in
`lexer.gleam`; `ParseError` in `expr_parser.gleam`, reused by
`ddl_parser.gleam`/`dml_parser.gleam` rather than redefined;
`SemanticError` independently in both `ddl_semantics.gleam` and
`dml_semantics.gleam`) — matching `HlcError`/`Base62Error` living in
`clock.gleam`/`base62.gleam` rather than a shared `errors.gleam`. No
facade module (no `src/lang.gleam` in any of the three packages): callers
`import lang/lexer`, `import lang/ddl_parser`, etc. directly, matching how
`util/hlc/*` and `util/asyncio/*` are imported today.

**`catalog.gleam`'s two moves**: it started (like everything else here)
in a single `src/lang/`, migrated to `schema/src/lang/` once the package
split landed (next to the `ddl_ast.gleam` types its `apply_statement`
operated on directly), and then moved back to `shared/src/lang/` once a
review decoupled it from `ddl_ast` entirely — see its own section below
and "Open questions" for why the schema-only stop wasn't the end state.

---

## `shared/src/lang/token.gleam`

Pure data, no logic beyond maybe an `Eq`-friendly shape (Gleam gives that
for free on records/unions).

```gleam
/// A position in source text, both as line/column (for human-readable
/// error messages) and byte offset (for slicing/highlighting source).
/// 1-indexed, matching how editors and most compiler diagnostics number
/// lines/columns.
pub type Position {
  Position(line: Int, column: Int, byte_offset: Int)
}

pub type Span {
  Span(start: Position, end: Position)
}

pub type Token {
  Token(kind: TokenKind, span: Span)
}

pub type TokenKind {
  Keyword(Keyword)
  Identifier(name: String)          // unquoted, already folded to lower case; full text, untruncated
  QuotedIdentifier(name: String)    // case preserved, "" collapsed to "; full text, untruncated
  IntegerLiteral(text: String)      // digit-group separators stripped (§4.2)
  NumericLiteral(text: String)      // ditto
  StringLiteral(value: String)      // '' collapsed to ', adjacent literals concatenated (§4.3)
  Operator(Operator)
  LeftParen
  RightParen
  Comma
  Semicolon
  Dot
  Eof
}

/// One variant per keyword in spec.md §3 — deliberately not
/// `Keyword(String)`; see "Design decisions" above.
pub type Keyword {
  KwBigint
  KwBoolean
  KwChar
  // ... one per §3.1 data type keyword ...
  KwFalse
  KwNull
  KwTrue
  KwAdd
  KwAlter
  // ... one per §3.3 query-structure keyword ...
  KwAnd
  KwBetween
  // ... one per §3.4 expression keyword ...
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
  NeAngle     // `<>` — kept distinct from `NeBang` — see note in lexer section
  NeBang      // `!=`
  Concat      // `||`
  Amp
  Pipe
  Hash
  Tilde
  Shl
  Shr
  RegexMatch       // `~`  (only in binary position — see lexer note)
  RegexMatchCi     // `~*`
  RegexNoMatch     // `!~`
  RegexNoMatchCi   // `!~*`
  Arrow           // `->`
  ArrowText       // `->>`
  HashArrow       // `#>`
  HashArrowText   // `#>>`
  Contains        // `@>`
  ContainedBy     // `<@`
  Cast            // `::`
}
```

**Note on `Tilde`/`RegexMatch` overlap**: §5.4 says prefix `~` (bitwise
NOT) and infix `~` (regex match) are "disambiguated by arity/operand type
... rather than by separate tokens" in PostgreSQL. This plan instead gives
the *lexer* one token (`Tilde`) for bare `~` and lets the **parser**
decide prefix-vs-infix from position (exactly how it already must
disambiguate unary vs. binary `+`/`-`), rather than trying to
disambiguate by type at lex time (the lexer has no type information at
all). `~*`/`!~`/`!~*` are unambiguously multi-character regex operators
and get their own token kinds directly.

**Note on `<>` vs `!=`**: both mean not-equals (§5.2) and PostgreSQL
treats them as the same operator *semantically*, but this plan keeps them
as distinct tokens (`NeAngle`/`NeBang`) all the way through to the AST
(`CmpNeAngle`/`CmpNeBang` in `BinaryOperator`, below) rather than folding
them into one `Ne`. Every other stage — parsing (both sit at the same
§8.2 precedence level, non-associative comparison) and semantic analysis
— treats the two identically; the distinction exists solely so a future
formatter/pretty-printer can preserve which spelling the user actually
wrote, without needing a `Span`-based workaround to recover it later.

---

## `shared/src/lang/lexer.gleam`

```gleam
pub type LexError {
  UnterminatedString(at: Position)
  UnterminatedBlockComment(at: Position)
  UnterminatedQuotedIdentifier(at: Position)
  InvalidDigitGroupSeparator(at: Position)  // leading/trailing/doubled `_`, or adjacent to `.`/exponent — §4.2
  ReservedWord(word: String, at: Position)  // unquoted, matches one of PostgreSQL's own reserved words — §3.5
  UnknownCharacter(char: String, at: Position)
}

pub fn tokenize(source: String) -> Result(List(Token), LexError)
```

### Algorithm

A hand-written scanner over `string.to_graphemes(source)` (matching the
grapheme-list-consuming style `base62.decode_loop` already uses in this
codebase), threading a small `ScanState` (remaining graphemes, current
`Position`) through a recursive loop that emits one `Token` per
iteration and appends `Eof` at the end.

Per iteration, in this order:

1. **Skip whitespace** (space, tab, newline — advancing `line`/`column`
   correctly on `\n`) and **comments** (§6): `-- ...` to end of line;
   `/* ... */` tracked with a nesting counter (increment on each `/*`,
   decrement on each `*/`, keep consuming until it reaches 0) so
   `/* outer /* inner */ still in outer */` is one comment, per spec.
2. **String literal** (starts with `'`, §4.3): consume until an
   unescaped closing `'`, treating `''` as an escaped literal quote
   (consume both, emit one `'` into the value) rather than
   open-then-immediately-close. Unterminated input (EOF before a closing
   `'`) is `UnterminatedString`. After closing, look ahead past
   whitespace: if that whitespace contains a newline and the next
   non-whitespace character is another `'`, treat this as a
   continuation — consume the next string literal the same way and
   concatenate its value onto this one, repeating until no such
   continuation follows (§4.3's "two string literals ... are
   concatenated" rule, resolved once here so every later stage sees one
   `StringLiteral` token, never two adjacent ones needing their own
   concatenation logic).
3. **Quoted identifier** (starts with `"`, §2): same doubling rule as
   string literals (`""` → one literal `"`), but no cross-line
   concatenation (§4.3's continuation rule is stated for string literals
   only). `UnterminatedQuotedIdentifier` on EOF. Case is preserved
   exactly, and the full decoded text is kept as-is — **no truncation at
   this stage**; see "On not truncating in the lexer" below.
4. **Unquoted identifier or keyword** (starts with a letter or `_`,
   §2): consume letters/digits/`_`, fold to lower case, then look the
   folded text up in a keyword table (a `case` over string literals, or
   a `Dict(String, Keyword)` built once from a literal list — same
   "avoid an ad hoc `Dict` built per call" reasoning `base62.gleam`
   already documents for its capacity table, so prefer the `case`/literal
   list form here too). A hit emits `Keyword(...)`. A miss falls through
   to a second lookup, against a separate table of PostgreSQL's own
   reserved words (§3.5, same `case`-over-literals style) — a hit there
   is `ReservedWord`, not an `Identifier`; only a miss against *both*
   tables emits `Identifier(name: ...)` holding the full folded text,
   untruncated. See "PostgreSQL reserved words" below for why this
   second table exists.
5. **Number** (starts with a digit, or `.` followed by a digit, §4.2):
   consume the integer part (digits and `_` separators), optionally a
   `.` and fractional digits, optionally an exponent (`[eE][+-]?digits`).
   Validate digit-group separator placement while scanning (a `_` is
   only legal strictly between two digits — never adjacent to the start,
   end, `.`, or `e`/`E`) rather than as a second pass; strip `_`
   characters from the collected text before building the token.
   Classify as `IntegerLiteral` (digits only, no `.`/exponent) or
   `NumericLiteral` (has a `.` and/or exponent) per §4.2's rule that
   `1e10` is a numeric literal despite being integer-valued.
6. **Operator/punctuation** (§5): maximal-munch match against the
   longest applicable prefix first — e.g. try 3-character `->>`/`#>>`/
   `!~*` before 2-character `->`/`#>`/`!~`/`<=` etc. before 1-character.
   A table ordered longest-first, tried top to bottom, is the simplest
   correct implementation; a trie is unnecessary at this operator count.
7. Anything else is `UnknownCharacter`.

### On not truncating in the lexer

spec.md §2's 63-byte truncation rule describes what happens once an
over-long identifier reaches PostgreSQL — it doesn't require StruoDB to
perform that truncation itself. Since the transpiler's output is
PostgreSQL SQL text (identifiers included) and PostgreSQL already
truncates at 63 bytes using its own correct, encoding-aware,
mid-codepoint-safe logic (`pg_mbcliplen`) when that SQL runs, re-doing
the same truncation in the lexer would only risk getting the mid-codepoint
edge case *wrong* relative to what PostgreSQL itself does — for no
correctness benefit, since PostgreSQL's truncation is authoritative
regardless of what StruoDB passes it. So the lexer keeps the full
identifier text, untruncated, all the way through tokens and the AST; the
one place truncation-awareness still matters is the semantic layer's
column/constraint-name uniqueness check, which needs to catch two
identifiers that collide only *after* truncation — see
`ddl_semantics.gleam`'s "Postgres-name" helper below. That check doesn't need
to reproduce `pg_mbcliplen` exactly either: it exists purely to give an
earlier, friendlier diagnostic than PostgreSQL's own error at execution
time, so an approximate (codepoint-boundary, not necessarily
byte-boundary-identical) truncation is good enough — a mismatch on a
genuinely rare edge case just means PostgreSQL reports it instead of
StruoDB, not that the transpiled program is wrong.

### PostgreSQL reserved words

Added after the rest of this plan was already built, directly motivated
by `codegen-plan.md`'s "Generated identifiers are always double-quoted"
design decision: that decision defaulted to always-quoting specifically
because a content-based quoting check (quote only if the string looks
like it needed quoting — uppercase, special characters, a leading digit)
can't by itself tell that a perfectly normal-looking string like `order`
is a PostgreSQL reserved word and still needs quoting. Codegen still
needs that reserved-word check — rejecting it at the lexer doesn't make
codegen's own check optional, since a StruoDB source can still
*deliberately* quote a reserved word as an identifier (`"order"`), which
reaches codegen indistinguishable from an ordinary name. What rejecting
it at the lexer actually fixes is *where the reserved-word list itself
comes from*: instead of codegen needing its own separately-sourced copy,
this table (below) is now the single, canonical, already-implemented
list — codegen reuses it (or an equivalent moved somewhere both can
reach) directly. See `codegen-plan.md`'s own "Design decisions" and
"Issues" for where this was previously flagged as unresolved, and for
the corrected framing.

The word list itself (§3.5) is PostgreSQL's own **reserved** and
**reserved (can be function or type name)** keyword categories — sourced
from
[sql-keywords-appendix](https://www.postgresql.org/docs/current/sql-keywords-appendix.html)'s
"PostgreSQL" column, as of PostgreSQL 18, 101 words — deliberately
excluding PostgreSQL's own "non-reserved" keywords (e.g. `value`,
`type`), which PostgreSQL itself allows unquoted in identifier position.
Checked only *after* StruoDB's own keyword table already misses (step 4
above), so a word that's both a StruoDB keyword and PostgreSQL-reserved
(`create`, `not`, `check`, ...) is unaffected — it was already rejected
as an identifier by §3, for an unrelated reason, before this table is
ever consulted. Quoting (§2) is the escape hatch either way; this
restriction only ever affects the *unquoted* spelling.

This word list is a point-in-time snapshot, not derived at build or run
time from a live PostgreSQL installation (`pg_get_keywords()`, which
`codegen-plan.md`'s "Issues" section raised as one option) — simpler,
and sufficient here: StruoDB targets a specific PostgreSQL major version
range in practice, and a version-to-version change to this list would be
a rare, deliberate update to both this table and spec.md §3.5 together,
not something worth generating dynamically.

---

## `shared/src/lang/expr_ast.gleam`, `schema/src/lang/ddl_ast.gleam`, `streams/src/lang/dml_ast.gleam`

As planned, one `ast.gleam` held every type below. As built, it split
along the same line as everything else in this doc's "package layout"
note: `DataType`/`Expr`/`UnaryOperator`/`BinaryOperator` — reused by both
statement families — live in `shared/src/lang/expr_ast.gleam`; the
`CREATE`/`ALTER STREAM`-only shapes live in `schema/src/lang/ddl_ast.gleam`
(and `Statement` is now `DdlStatement`, holding only `CreateStream`/
`AlterStream` — no `Insert` case); the `INSERT`-only shapes live in
`streams/src/lang/dml_ast.gleam` (as `DmlStatement`, holding only
`Insert`). `ddl_ast.gleam` imports `expr_ast.gleam` (`as xast`, by
convention) for `DataType`/`Expr`; so does `dml_ast.gleam`.

`GeneratedClause`/`GeneratedStorage`/`NamedCheck` — originally planned as
part of `ast.gleam`'s `CREATE`/`ALTER STREAM` shapes below — also ended
up in `expr_ast.gleam` rather than `ddl_ast.gleam`, even though nothing
in `streams/`'s `INSERT` grammar uses them: `catalog.gleam`'s
`StreamSchema`/`ColumnSchema` (below) need the same shape to *store* a
generated-column clause or a named `CHECK`, and `catalog.gleam` lives in
`shared/` (see its own section) — so these three types had to live
somewhere reachable from both `shared/` and `schema/`, and `expr_ast.
gleam` (small wrappers around one `Expr`, already imported everywhere)
was the natural fit over inventing a fourth module.

```gleam
// shared/src/lang/expr_ast.gleam
pub type DataType {
  DtBigint
  DtBoolean
  DtChar(length: Option(Int))
  DtDate
  DtDecimal(precision: Option(Int), scale: Option(Int))
  DtDouble          // `DOUBLE PRECISION`, two keywords, one type — see parser section
  DtInt
  DtInteger
  DtInterval
  DtJson
  DtJsonb
  DtNumeric(precision: Option(Int), scale: Option(Int))
  DtReal
  DtSmallint
  DtText
  DtTime
  DtTimestamp
  DtTimestamptz
  DtUuid
  DtVarchar(length: Option(Int))
}

pub type Expr {
  IntLiteral(text: String)
  NumericLiteral(text: String)
  StringLiteral(value: String)
  BoolLiteral(Bool)
  NullLiteral
  ColumnRef(name: String, span: Span)
  UnaryOp(op: UnaryOperator, operand: Expr)
  BinaryOp(op: BinaryOperator, left: Expr, right: Expr)
  Cast(expr: Expr, data_type: DataType)
  Between(expr: Expr, negated: Bool, low: Expr, high: Expr)
  InList(expr: Expr, negated: Bool, items: List(Expr))
  Like(expr: Expr, negated: Bool, case_insensitive: Bool, pattern: Expr)
  SimilarTo(expr: Expr, negated: Bool, pattern: Expr)
  IsNull(expr: Expr, negated: Bool)
  IsBool(expr: Expr, negated: Bool, value: Bool)
  IsDistinctFrom(left: Expr, negated: Bool, right: Expr)
  FunctionCall(name: String, args: List(Expr))
}
```

`ColumnRef` is the one `Expr` variant that carries a `Span`, deliberately
— see "Expression-level spans: a narrower alternative" under
`expr_parser.gleam` below for why the other thirteen variants don't. (No
other `Expr` node needs one: nothing in this plan's semantic checks blames
a literal, an operator, or a function call by itself — only ever "this
column doesn't exist" or "this column can't be referenced here," both of
which are about a `ColumnRef`.)

```gleam
// shared/src/lang/expr_ast.gleam, continued
pub type UnaryOperator {
  Pos          // unary `+`
  Neg          // unary `-`
  BitNot       // `~`
  LogicalNot   // `NOT`
}

pub type BinaryOperator {
  Add
  Sub
  Mul
  Div
  Mod
  Pow
  ConcatOp
  BitAnd
  BitOr
  BitXor
  ShiftLeft
  ShiftRight
  RegexMatchOp
  RegexMatchCiOp
  RegexNoMatchOp
  RegexNoMatchCiOp
  JsonGet
  JsonGetText
  JsonGetPath
  JsonGetPathText
  JsonContains
  JsonContainedBy
  CmpEq
  CmpLt
  CmpGt
  CmpLe
  CmpGe
  CmpNeAngle   // `<>` — kept distinct from `CmpNeBang`, not merged; see token.gleam note
  CmpNeBang    // `!=`
  LogicalAnd
  LogicalOr
}
```

`Expr` deliberately has no `Paren(Expr)` wrapper — parenthesization only
ever affects *how* the parser groups operators, never anything the AST
needs to remember afterward, so `(a + b) * c` and a hypothetically
differently-parenthesized-but-equivalent input both just produce
`BinaryOp(Mul, BinaryOp(Add, a, b), c)`.

```gleam
// shared/src/lang/expr_ast.gleam, continued — see the note above on why
// these three live here rather than in ddl_ast.gleam
pub type GeneratedClause {
  GeneratedClause(expr: Expr, storage: GeneratedStorage)
}

pub type GeneratedStorage {
  Stored
  Virtual
}

pub type NamedCheck {
  NamedCheck(constraint_name: String, expr: Expr, span: Span)
}
```

```gleam
// schema/src/lang/ddl_ast.gleam — imports expr_ast as xast
pub type DdlStatement {
  CreateStream(name: String, elements: List(StreamElement), span: Span)
  AlterStream(name: String, actions: List(AlterAction), span: Span)
}

pub type StreamElement {
  Column(ColumnDef)                          // renamed from a bare `ColumnDef` variant
  TableConstraint(check: xast.NamedCheck, span: Span)
}

pub type ColumnDef {
  ColumnDef(
    name: String,
    data_type: xast.DataType,
    optional: Bool,
    default: Option(xast.Expr),
    generated: Option(xast.GeneratedClause),
    checks: List(xast.NamedCheck),
    span: Span,
  )
}

pub type AlterAction {
  AddColumn(ColumnDef, span: Span)
  DropColumn(column_name: String, span: Span)
  AlterColumnType(column_name: String, data_type: xast.DataType, span: Span)
  AddConstraint(xast.NamedCheck)
  DropConstraint(constraint_name: String, span: Span)
}
```

(As built, `ColumnDef` is its own standalone type rather than a
`StreamElement` variant directly, so `AlterAction.AddColumn` can hold one
without holding an entire `StreamElement` — see `ddl_ast.gleam`'s own
header comment for the full reasoning. This plan's original phrasing
["Read its header comment — it explains why `ColumnDef` vs `StreamElement`
are structured the way they are"] anticipated exactly this.)

```gleam
// streams/src/lang/dml_ast.gleam — imports expr_ast as xast
pub type DmlStatement {
  Insert(
    stream_name: String,
    columns: List(String),
    rows: List(List(Value)),
    on_conflict_do_nothing: Bool,
    returning: Option(List(ReturningItem)),
    span: Span,
  )
}

pub type Value {
  ValueExpr(xast.Expr)
  ValueDefault  // bare `DEFAULT` keyword, §11.3
}

pub type ReturningItem {
  ReturningStar
  ReturningExpr(expr: xast.Expr, alias: Option(String))
}
```

---

## `shared/src/lang/expr_parser.gleam`

```gleam
// shared/src/lang/expr_parser.gleam
pub type ParseError {
  UnexpectedToken(found: Token, expected: String)
  UnexpectedEof(expected: String)
  ExplicitNotNull(span: Span)     // friendly diagnostic — see below
  MissingGeneratedStorage(span: Span)  // GENERATED ALWAYS AS (...) with neither STORED nor VIRTUAL
}
```

As planned, one `parse(tokens) -> Result(Statement, ParseError)` dispatched
on `CREATE`/`ALTER`/`INSERT`. As built, `ParseError` and the whole
expression/`data_type` grammar below live once, in `expr_parser.gleam`,
but `pub fn parse` itself doesn't — each statement family owns its own:
`ddl_parser.parse(tokstrm) -> Result(DdlStatement, ParseError)` (dispatch
on `CREATE`/`ALTER`) in `schema/`, `dml_parser.parse(tokstrm) ->
Result(DmlStatement, ParseError)` (dispatch on `INSERT`) in `streams/` —
each `import`s `expr_parser.{type ParseError, ...}` (`as ep`, by
convention) both for the error type and to call into the precedence-layered
functions below for every expression/`data_type` they parse. Every
`parse_*` function actually takes/returns a `token_stream.TokenStream`
(`shared/src/lang/token_stream.gleam`'s cursor type — `peek_kind`/
`peek_keyword`/`current`/`advance`), not a raw `List(Token)`, wrapped once
via `token_stream.new` at the top of whichever `parse` a caller calls.

Recursive descent, one token of lookahead for statement dispatch
(`CREATE` / `ALTER` / `INSERT`, wherever each package's own `parse` does
it) and most productions; the expression grammar needs 2-token lookahead
in exactly one place (see level 7 below).

### Expression parsing — precedence-layered recursive descent

Rather than a generic Pratt/binding-power table, one function per
precedence level from spec.md §8.2, from loosest (level 12, the entry
point) to tightest (level 1, called innermost). Each level's function
calls the next-tighter level to obtain its operand(s), then loops
(or, where the spec says non-associative, checks *once*) for its own
operators:

| Level | Function              | Operators                                                                 | Assoc / arity notes |
|-------|------------------------|----------------------------------------------------------------------------|----------------------|
| 12    | `parse_or`             | `OR`                                                                        | left, loop |
| 11    | `parse_and`            | `AND`                                                                       | left, loop |
| 10    | `parse_not`            | prefix `NOT`                                                                | right — recurse into `parse_not` for the operand |
| 9     | `parse_is`             | `IS [NOT] NULL/TRUE/FALSE`, `IS [NOT] DISTINCT FROM`                        | loop (see note) |
| 8     | `parse_comparison`     | `=` `<` `>` `<=` `>=` `<>`/`!=`                                             | **non-associative** — check once, do not loop |
| 7     | `parse_keyword_ops`    | `[NOT] BETWEEN ... AND ...`, `[NOT] IN (...)`, `[NOT] LIKE`, `[NOT] ILIKE`, `[NOT] SIMILAR TO` | loop; needs 2-token lookahead (`NOT` + next) — see below |
| 6     | `parse_bitwise_etc`    | `\|\|` `&` `\|` `#` `<<` `>>` `~` `~*` `!~` `!~*` `->` `->>` `#>` `#>>` `@>` `<@`, **and prefix `~`** | left, loop; prefix `~` recognized here — see note |
| 5     | `parse_additive`       | binary `+` `-`                                                             | left, loop |
| 4     | `parse_multiplicative` | `*` `/` `%`                                                                 | left, loop |
| 3     | `parse_exponent`       | `^`                                                                         | left, loop (PostgreSQL quirk: `2^3^2` is `(2^3)^2`, not right-assoc) |
| 2     | `parse_unary`          | prefix `+` `-`                                                              | right — recurse into `parse_unary` for the operand |
| 1     | `parse_cast`           | postfix `:: data_type`                                                     | left, loop |
| —     | `parse_primary`        | literals, `column_ref`, `function_call`, `'(' expr ')'`                     | — |

**Why prefix `~` at level 6 (not level 2, where unary `+`/`-` live)
reproduces `~1 + 2` = `~(1 + 2)` with no special-casing beyond table
placement**: each level's operand-fetch step calls the *next tighter*
level, and that call already fully consumes every chain at its own and
all tighter precedences before returning. So `parse_unary` (level 2)
fetching its operand via `parse_cast`/`parse_primary` (level 1) only
ever gets the single literal/primary immediately after the sign — `+2`
never gets pulled in, since `+` binds at level 5, looser than level 1.
But `parse_bitwise_etc` (level 6), on seeing a leading `~`, fetches its
operand via `parse_additive` (level 5) — and *that* call, being a normal
level-5 parse, already consumes the entire `1 + 2` chain (descending
through levels 4→1 for each operand, then looping on `+`) before
returning it as one combined node. The prefix operator's operand
therefore comes out already including everything through its own
level's tightness, purely as a side effect of how each layer is written
— exactly reproducing the table in §8.2 with no extra logic.

**Non-associative comparison (level 8)**: `parse_comparison` calls
`parse_keyword_ops` once for `left`; if the next token is a comparison
operator, consumes it, calls `parse_keyword_ops` once more for `right`,
and returns `BinaryOp(cmp, left, right)` **without** looping to check for
a second comparison operator — `a < b < c` is therefore a parse error at
whatever token follows (in this case a dangling `<`), the same as
PostgreSQL.

**2-token lookahead at level 7**: after fetching `left` via
`parse_bitwise_etc`, `parse_keyword_ops` must decide whether a `NOT`
token here belongs to it (`expr NOT BETWEEN ...`) or is a stray token
belonging to something else entirely (never valid at this position,
since `NOT` as prefix-logical-not is only recognized at level 10, already
above this call in the recursion). The rule: peek one token; if it's
`BETWEEN`/`IN`/`LIKE`/`ILIKE`/`SIMILAR`, consume it directly (unnegated
form). If it's `NOT`, peek a second token; only consume both if that
second token is one of the same five — otherwise leave `NOT` unconsumed
and return `left` as-is, letting the caller (ultimately `parse_not` at
level 10, or a statement-level "expected `)`/`,`/end of clause" check)
report whatever error is appropriate for a dangling `NOT` in that
context.

**`IS` (level 9) resolving as a loop, not a single check**: unlike level
8, nothing in §8.2 marks `IS [NOT] ...` non-associative, and the grammar
in §8.1 defines it as one of the alternatives *expr* itself can be, which
permits `(a IS NOT NULL) IS NOT NULL` to reparse. Implemented as a loop
(zero or more) for that reason, though this reading is itself flagged as
an open question below.

**Operand binding for `BETWEEN`/`LIKE`/`ILIKE`/`SIMILAR TO`/
`IS [NOT] DISTINCT FROM`**: §8.1 defines these using `bound_expr`, a
restriction of `expr` to precedence level 6 or tighter, specifically so
the right operand doesn't absorb an operator looser than level 7 (e.g.
`a LIKE b OR c` parses as `(a LIKE b) OR c`, not `a LIKE (b OR c)`).
`parse_keyword_ops` (level 7) implements `bound_expr` by calling
`parse_bitwise_etc` (level 6) directly for `BETWEEN`'s low/high,
`LIKE`/`ILIKE`'s pattern, and `SIMILAR TO`'s pattern; `parse_is`
(level 9) does the same for `IS DISTINCT FROM`'s right side. `IN`'s list
items and function-call arguments, by contrast, sit inside explicit
`(...)`/`,` delimiters, so each item is parsed as a full `parse_or`
(level 12, i.e. unrestricted `expr`) with no ambiguity risk — matching
§8.1's grammar, which leaves `IN`'s list items as plain `expr`.

### Expression-level spans: a narrower alternative

`Expr` (§expr_ast.gleam) carries no `Span` on any variant except
`ColumnRef`. The alternative — a `span` field on all fourteen variants —
was considered and rejected as disproportionate: no semantic check in this
plan ever needs to blame a literal, an operator, or a function call by
itself, only ever a specific column reference (`DefaultReferencesColumn`,
`UnknownColumnReference` — see `ddl_semantics.gleam`/`dml_semantics.gleam`
below). Giving every
variant a span would mean threading a `Span` through all twelve of the
precedence-layered parser functions above (each would need to remember
its left operand's start position and merge it with the end position
after parsing its own operator/right operand) for a benefit — precise
underlines on error nodes no check actually produces — that doesn't
exist yet. `ColumnRef` alone costs nothing comparable: `parse_primary`
already holds the identifier `Token` (and therefore its `Span`) at the
exact moment it builds a `ColumnRef` from it, so capturing the span is
just passing along data already in hand, not new bookkeeping. If a
future check ever needs to blame a bare literal or a function call by
name, the same treatment (a `span` field on that one variant only) can
be added later without disturbing the other variants or their existing
parser/test code.

### Statement parsers (`schema/src/lang/ddl_parser.gleam`, `streams/src/lang/dml_parser.gleam`)

`parse_create_stream`/`parse_alter_stream` live in `ddl_parser.gleam`;
`parse_insert` lives in `dml_parser.gleam` — each package's `pub fn parse`
dispatches only within its own statement family (see the note under
`expr_parser.gleam` above).

- `parse_create_stream`: `CREATE STREAM` name, `(`, one-or-more
  `stream_element` separated by `,`, `)`, optional `;`. Each
  `stream_element` starts with `CONSTRAINT` (→ `table_constraint`) or an
  identifier (→ `column_def`); `column_def` then loops consuming zero or
  more `column_clause`s (`OPTIONAL` / `DEFAULT expr` /
  `GENERATED ALWAYS AS (expr) (STORED|VIRTUAL)` / `CONSTRAINT name CHECK
  (expr)`) until a `,` or `)` — §9.1 leaves clause repetition/order
  unconstrained (already an open question in spec.md itself; this parser
  accepts any order and any repetition, folding duplicates last-write-wins
  at the AST level, and semantic analysis decides what to reject — see
  semantic section).
- **`NOT NULL` special-case**: while scanning `column_clause`s, if the
  parser sees `NOT` immediately followed by `NULL` in clause position, it
  does not fall through to a generic "unexpected token" error — it
  consumes both and returns `ExplicitNotNull(span)` specifically, so the
  caller can render spec.md §9.3's exact guidance ("columns are `NOT
  NULL` by default; use `OPTIONAL` to make this column nullable") instead
  of a generic syntax error. This is a deliberate parser-level nicety,
  not required by the grammar — flagged as an open question (is this
  worth the special-case, or is a generic parse error acceptable?).
- `parse_alter_stream`: `ALTER STREAM` name, one-or-more `alter_action`
  separated by `,`, optional `;`. Each `alter_action` dispatches on
  `ADD`/`DROP`/`ALTER` (`ADD` then further dispatches on `COLUMN` vs.
  `CONSTRAINT`; `ALTER` requires `COLUMN name TYPE data_type`).
- `parse_insert`: `INSERT INTO` name, mandatory `(` column list `)`,
  `VALUES`, one-or-more `value_row` separated by `,`, optional
  `ON CONFLICT DO NOTHING`, optional `RETURNING` item list, optional `;`.
  A `value` is either `DEFAULT` (→ `ValueDefault`) or a full expression.

### `data_type` parsing

spec.md §9.1 gives a formal `data_type ::= ...` production directly —
straightforward to parse from:

- Bare keyword, no parameters: `BIGINT`, `BOOLEAN`, `DATE`, `INT`,
  `INTEGER`, `INTERVAL`, `JSON`, `JSONB`, `REAL`, `SMALLINT`, `TEXT`,
  `TIME`, `TIMESTAMP`, `TIMESTAMPTZ`, `UUID`.
- `CHAR` / `VARCHAR`: keyword, then an *optional* `(n)`, `n >= 1` — bare
  `CHAR` defaults to length 1, bare `VARCHAR` to unlimited, per §9.1.
- `DECIMAL` / `NUMERIC`: keyword, then an *optional* `(p)` or `(p, s)`,
  `p >= 1` and `0 <= s <= p` — bare form unconstrained, per §9.1.
- `DOUBLE PRECISION`: **two consecutive keyword tokens**, `DOUBLE` then a
  mandatory `PRECISION` — spec.md §3.1 lists `DOUBLE` and `PRECISION` as
  separate keywords for exactly this reason, and §9.1's grammar and
  §10.4's prose both refer to the type as "`DOUBLE PRECISION`" directly.
  The parser must special-case this (bare `DOUBLE` with no following
  `PRECISION` is a parse error, not a valid standalone type), rather than
  treating every data-type keyword as independently able to start and end
  a `data_type`.

---

## `shared/src/lang/catalog.gleam`

As planned, and as first built once the package split landed, this
module's one `apply_statement(catalog, stmt: DdlStatement) -> Catalog`
operated directly on `ddl_ast`'s `DdlStatement`/`StreamElement`/
`AlterAction` types — which put `catalog.gleam` in `schema/`, next to
`ddl_ast.gleam`, and forced `streams/` to depend on the whole `schema`
package (its DDL parser and semantics included) just to read/write a
`Catalog` for `INSERT` validation. A later review decoupled it: instead
of one function taking a whole `DdlStatement`, this module now exposes
one small primitive per kind of change, each taking only the shared types
(`ColumnSchema`, `NamedCheck` — the latter from `expr_ast.gleam`) it
actually needs, with no `ddl_ast` import at all. That's what lets it live
in `shared/` — reachable from `streams/` at no extra dependency cost,
since every package already depends on `shared`.

```gleam
pub type Catalog {
  Catalog(streams: Dict(String, StreamSchema))
}

pub type StreamSchema {
  StreamSchema(
    name: String,
    columns: Dict(String, ColumnSchema),
    constraints: Dict(String, NamedCheck),
  )
}

pub type ColumnSchema {
  ColumnSchema(
    name: String,
    data_type: DataType,
    optional: Bool,
    default: Option(Expr),
    generated: Option(GeneratedClause),
    system: Bool,   // one of the 4 automatic system columns below, never
                     // a `ddl_ast`-derived (user) column
  )
}

pub fn empty() -> Catalog

/// The 4 automatic system columns (`_struo_hlc`/`_struo_hlc_timestamp`/
/// `_struo_hlc_count`/`_struo_hlc_node_id`, spec.md §9.2) every stream
/// gets, `system: True`, defined once here.
pub fn system_columns() -> List(ColumnSchema)

/// Callers (`ddl_semantics.gleam`) are expected to have already validated
/// the `CreateStream` producing these arguments and to call this only
/// once that has come back `Ok` — none of these six functions re-check
/// anything (that names don't collide, that `stream` exists for the five
/// below). Always joins `system_columns()` onto `columns`, so no caller
/// needs to remember to add them.
pub fn create_stream(
  catalog: Catalog,
  name: String,
  columns: List(ColumnSchema),
  constraints: List(NamedCheck),
) -> Catalog

pub fn add_column(catalog: Catalog, stream: String, column: ColumnSchema) -> Catalog
pub fn drop_column(catalog: Catalog, stream: String, column_name: String) -> Catalog
pub fn alter_column_type(
  catalog: Catalog,
  stream: String,
  column_name: String,
  data_type: DataType,
) -> Catalog
pub fn add_constraint(catalog: Catalog, stream: String, check: NamedCheck) -> Catalog
pub fn drop_constraint(catalog: Catalog, stream: String, constraint_name: String) -> Catalog
```

Kept as a separate module from `ddl_semantics.gleam` (rather than folding
`Catalog` into that module directly) because "what a stream currently
looks like" is a reusable concept a later codegen stage will also need
(to know a column's current type when emitting `ALTER TABLE ... TYPE`,
for instance) — it shouldn't only exist as a side effect of validation.
`ddl_semantics.gleam` is where the translation from a validated
`DdlStatement` into these six calls now happens (a private
`apply_statement`/`apply_create_stream`/`apply_alter_action` there,
reusing the same `column_defs`/`table_constraints` helpers
`check_create_stream` already builds for validation) — see its own
section below.

---

## `shared/src/lang/expr_semantics.gleam`

Not in the original plan as a module of its own — as first built (once
the package split landed), `ddl_semantics.gleam` and `dml_semantics.
gleam` below each kept their own verbatim copy of these two functions,
since each needed `List(SemanticError)` back and the two packages'
`SemanticError` types are distinct. A review noticed the recursive half
(`collect_column_refs`) doesn't touch `SemanticError` at all, and the
thin wrapper around it (`check_expr_column_refs`) only needs the *error
constructor*, not a fixed error type — so both moved here, generic over
that one parameter:

```gleam
/// Every `ColumnRef` reachable inside `expr`, with its own span — the
/// only kind of subexpression either caller's checks ever need to blame
/// individually; see the note on `Expr` in expr_ast.gleam.
pub fn collect_column_refs(expr: Expr) -> List(#(String, Span))

/// Every `ColumnRef` inside `expr` not found in `valid_names`, each
/// reported via `unknown_column_reference` — a caller-supplied
/// constructor rather than a fixed error type, so this stays usable by
/// both `ddl_semantics.gleam`'s and `dml_semantics.gleam`'s own
/// `SemanticError`.
pub fn check_expr_column_refs(
  expr: Expr,
  valid_names: List(String),
  unknown_column_reference: fn(String, Span) -> e,
) -> List(e)
```

A caller passes its own `UnknownColumnReference` variant's constructor
directly — `check_expr_column_refs(expr, valid_names,
UnknownColumnReference)` — since a two-argument record constructor is
already exactly `fn(String, Span) -> SemanticError` in that package.
Nothing else in either `*_semantics.gleam` module moved here:
`postgres_name`/`find_duplicates` (below) exist only in
`ddl_semantics.gleam`, since only its checks have a name-uniqueness rule
to apply them to.

---

## `schema/src/lang/ddl_semantics.gleam`, `streams/src/lang/dml_semantics.gleam`

As planned, one `semantic.gleam` held one `SemanticError` type covering
`CreateStream`/`AlterStream`/`Insert` together and one `analyze`. As
built, each statement family owns its own module, its own `SemanticError`,
and its own `analyze`. `dml_semantics.gleam`'s `SemanticError` started
out (once the package split landed) as a full copy of `ddl_semantics.
gleam`'s, all sixteen `CREATE`/`ALTER`-only variants included though none
of them were ever constructed by `dml_semantics`' `check_insert` — a
review pruned that copy down to just the eight variants below.
`collect_column_refs`/`check_expr_column_refs`, the `Expr`-walking
helpers both modules' checks are built on, went through the same
history: copy-pasted verbatim into both at first, then moved into
`shared/src/lang/expr_semantics.gleam` once a review noticed neither
copy actually needed to be there — see that module's own section below.

```gleam
// schema/src/lang/ddl_semantics.gleam
pub type SemanticError {
  ReservedIdentifier(name: String, span: Span)                  // §2, §9.2
  SystemColumnNotModifiable(column: String, span: Span)         // §10.3/§10.4
  DefaultReferencesColumn(column: String, referenced: String, span: Span)  // §9.4
  UnknownColumnReference(referenced: String, span: Span)
  // Both `span` fields above are the offending `ColumnRef`'s own span,
  // not the enclosing `DEFAULT`/`CHECK`/`GENERATED` clause's — see
  // "Expression-level spans: a narrower alternative" under
  // `expr_parser.gleam`.
  DuplicateColumnName(stream: String, name: String, span: Span)
  DuplicateConstraintName(stream: String, name: String, span: Span)
  UnknownStream(name: String, span: Span)
  AddColumnNeedsOptionalOrDefault(column: String, span: Span)   // §10.2
  DropNonOptionalColumn(column: String, span: Span)             // §10.3
  DropUnknownColumn(column: String, span: Span)
  NarrowingTypeChange(column: String, from: DataType, to: DataType, span: Span)  // §10.4
  UnsupportedTypeChange(column: String, from: DataType, to: DataType, span: Span) // cross-family
  DropUnknownConstraint(name: String, span: Span)
  InvalidDataTypeParameter(column: String, span: Span, reason: String)  // §9.1 param bounds
}
```

```gleam
// streams/src/lang/dml_semantics.gleam — holds only what check_insert
// actually raises (see note above).
pub type SemanticError {
  UnknownStream(name: String, span: Span)
  UnknownColumnReference(referenced: String, span: Span)
  InsertColumnListEmpty(span: Span)
  InsertUnknownColumn(column: String, span: Span)
  InsertGeneratedColumnInList(column: String, span: Span)       // §11.4
  InsertSystemColumnInList(column: String, span: Span)          // §11.4
  InsertMissingRequiredColumn(column: String, span: Span)       // §11.2/§11.3, NOT NULL with no default
  InsertColumnCountMismatch(expected: Int, got: Int, row_index: Int, span: Span)
}
```

Each module has its own matching `analyze`:

```gleam
// ddl_semantics.gleam
/// Validates `stmt` against `catalog` (its current declared shape, for
/// `AlterStream`), returning every violation found — not just the
/// first — or, if there are none, the `Catalog` updated with this
/// statement's effect.
pub fn analyze(
  cat: Catalog,
  stmt: DdlStatement,
) -> Result(Catalog, List(SemanticError))

// dml_semantics.gleam
/// Same shape, but `Insert` never changes a stream's shape, so a
/// successful `analyze` always returns `catalog` unchanged.
pub fn analyze(
  cat: Catalog,
  stmt: DmlStatement,
) -> Result(Catalog, List(SemanticError))
```

`postgres_name`, by contrast, exists only in `ddl_semantics.gleam` — its
column/constraint-name uniqueness checks are the only ones that need it
(`dml_semantics.gleam`'s `check_insert` has no name-uniqueness rule of its
own to apply it to):

```gleam
// schema/src/lang/ddl_semantics.gleam
/// Approximates PostgreSQL's own 63-byte `NAMEDATALEN` truncation
/// (§2), purely so column/constraint-name uniqueness checks below can
/// catch a collision the way PostgreSQL will ultimately see it — two
/// identifiers differing only after byte 63 collide there even if they
/// don't collide as written. This exists only to give an earlier,
/// friendlier diagnostic than PostgreSQL's own error at execution time
/// (see "On not truncating in the lexer" in the lexer section); it is
/// **not** required to match PostgreSQL's `pg_mbcliplen` byte-for-byte
/// — backing off to the last full-codepoint boundary at or before byte
/// 63 is good enough, since the transpiled SQL's correctness never
/// depends on this function, only on PostgreSQL's own truncation of the
/// full, untruncated identifier StruoDB actually passes through.
fn postgres_name(identifier: String) -> String
```

### `CREATE STREAM` checks

1. Build a column symbol table from all `ColumnDef`s first (name → decl),
   comparing names via `postgres_name` rather than raw string equality
   so two names that only collide after truncation still raise
   `DuplicateColumnName` — needed before any of the expression-reference
   checks below can run.
2. The stream name and every column/constraint name: reject any starting
   with `_STRUO_` (case-insensitive) as `ReservedIdentifier` — reserved
   for the 4 automatic system columns and future system use — §2, §9.2.
   (`HLC` is not a data type; `CREATE STREAM` never declares these
   columns at all — `catalog.create_stream` adds them unconditionally.)
3. Every column's `DEFAULT expr`, if present: walk the expr, collect
   every `ColumnRef(name, span)` found; any hit is
   `DefaultReferencesColumn(column: .., referenced: name, span: span)` —
   `span` is the `ColumnRef`'s own, so the error underlines the specific
   reference, not the whole `DEFAULT` clause (a `DEFAULT` expression
   cannot reference *any* column, sibling or otherwise, so finding any
   `ColumnRef` at all is the violation) — §9.4.
4. Every column's `GENERATED ALWAYS AS (expr)`, every `CHECK (expr)`
   (column-level or table-level): walk the expr, collect every
   `ColumnRef(name, span)`, and check each `name` against the symbol
   table from step 1 — a name not found is
   `UnknownColumnReference(referenced: name, span: span)`, again
   underlining the specific reference via its own `span`.
5. Constraint names (`CONSTRAINT constraint_name`, column-level or
   table-level) unique within the stream, again compared via
   `postgres_name` — `DuplicateConstraintName`, per §9.5. (Step 1's
   `DuplicateColumnName` check is the column-name half of the same
   requirement, per §9.1.)
6. `data_type` parameter sanity (`VARCHAR(n)`/`CHAR(n)`: `n >= 1`;
   `DECIMAL(p, s)`/`NUMERIC(p, s)`: `p >= 1`, `0 <= s <= p`) — per §9.1's
   `data_type` grammar.

If all checks pass: `ddl_semantics.gleam`'s own `apply_statement`
translates the `CreateStream` into one `catalog.create_stream(...)` call
(see the `catalog.gleam` section above), producing a new `StreamSchema`
and returning `Ok(new_catalog)`.

### `ALTER STREAM` checks

0. The target stream must already exist in `catalog` — `UnknownStream`
   otherwise (and no further per-action checks run, since there is no
   schema to check them against).
1. Per `AddColumn(column_def)`: same `ReservedIdentifier`/
   `DuplicateColumnName`/`UnknownColumnReference`/parameter-sanity checks
   as `CREATE STREAM` (run against the *union* of existing columns and
   this new one, so a `CHECK` on the new column may reference an existing
   sibling). Must have `optional == True`, or a `default`, or a
   `generated` clause — `AddColumnNeedsOptionalOrDefault` otherwise —
   §10.2.
2. Per `DropColumn(name)`: must exist (`DropUnknownColumn`); one of the 4
   automatic system columns (`ColumnSchema.system == True`) is
   `SystemColumnNotModifiable`, checked ahead of and instead of the
   `optional == True` check below (`DropNonOptionalColumn`) — §10.3.
3. Per `AlterColumnType(name, new_type)`: must exist
   (reuse `DropUnknownColumn`'s shape or a dedicated variant — open
   question, naming only); a system column is `SystemColumnNotModifiable`,
   same as `DropColumn` above; otherwise look up the existing
   `ColumnSchema`'s `data_type` and classify the change:
   - Same type family, parameters only growing (`VARCHAR`/`CHAR` length
     up; `DECIMAL`/`NUMERIC` scale held or grown without shrinking
     `precision - scale`) → allowed.
   - Listed widening chain (`SMALLINT`→`INT`/`INTEGER`→`BIGINT`;
     `REAL`→`DOUBLE PRECISION`) → allowed, including a multi-step jump
     that skips an intermediate type (`SMALLINT` straight to `BIGINT`),
     per §10.4.
   - Anything else (parameters shrinking, or a different type family
     entirely) → `NarrowingTypeChange` or `UnsupportedTypeChange`
     respectively — §10.4 (both presumed-disallowed cases spec.md's own
     "Remaining open details" already flags as unconfirmed).
4. Per `AddConstraint(named_check)`: `DuplicateConstraintName` if the
   name collides with an existing constraint; `UnknownColumnReference`
   for any `ColumnRef` in its `expr` not found among the stream's
   columns. **Not implemented**: verifying the new constraint is
   semantically compatible with existing rows (that requires a live
   database — out of scope for a pure syntax/catalog-level pass).
5. Per `DropConstraint(name)`: must exist — `DropUnknownConstraint`
   otherwise.
6. **Not implemented**: verifying a replacement `CHECK` is *stronger*
   than what it replaced (§10.5) when a `DropConstraint`+`AddConstraint`
   pair under the same name appears together. spec.md itself defers
   *how* this is checked to an open decision ranging from "unenforced
   documented convention" to "pattern-matched check restricted to simple
   numeric comparisons" — this plan takes no position and implements
   neither, pending that decision. If a restricted-pattern approach is
   chosen, it belongs here as an additional check once the DROP+ADD pair
   is recognized (same constraint name, both actions in the same
   statement or not — another open point already in spec.md).

If all per-action checks across the whole statement pass:
`ddl_semantics.gleam`'s `apply_statement` translates each `AlterAction`
into the matching `catalog.add_column`/`drop_column`/`alter_column_type`/
`add_constraint`/`drop_constraint` call, folded over the action list in
order, and `Ok(new_catalog)`.

### `INSERT` checks

0. The target stream must exist — `UnknownStream`.
1. Column list non-empty — `InsertColumnListEmpty` (the grammar already
   requires at least one via `column_name (',' column_name)*`, so this
   is mostly a defensive check / can't actually trigger from a
   successfully-parsed statement — kept for completeness, flagged as
   possibly-dead code once confirmed).
2. Every name in the column list must exist on the target stream —
   `InsertUnknownColumn` — and must **not** be one of the 4 automatic
   system columns (`ColumnSchema.system == True`) — `InsertSystemColumnInList`
   — nor a `GENERATED` column — `InsertGeneratedColumnInList` — §11.4.
3. Every column *not* in the list, excluding system columns and
   `GENERATED` columns (neither may ever appear in the list at all, per
   check 2 — their absence is never an error): resolvable via its own
   `default`, or `optional == True` (→ implicit `NULL`) — otherwise
   `InsertMissingRequiredColumn` — §11.2/§11.3.
4. Every `value_row` supplies exactly as many values as the column list
   has entries — `InsertColumnCountMismatch(expected, got, row_index)`
   for any row that doesn't.
5. For each `value` that is `ValueExpr(expr)` (not the bare `DEFAULT`
   placeholder): walk `expr`, and every `ColumnRef` found is checked
   against the target stream's columns — `UnknownColumnReference`. (An
   `INSERT` expression referencing a column at all is unusual — there is
   no other-row context to read from — but nothing in spec.md's grammar
   forbids writing one, e.g. `VALUES (..., sensor_id, ...)` referencing a
   column that isn't actually in scope; catching it here rather than
   silently transpiling something meaningless downstream.)
7. **Not implemented**: any type-compatibility check between a supplied
   `expr`/literal and its target column's `data_type` (e.g. inserting a
   string literal into an `INT` column). PostgreSQL performs this itself
   once the transpiled `INSERT` actually runs, so it isn't strictly
   required for correctness, only for earlier/friendlier errors — noted
   as a possible future enhancement, not a spec.md requirement, so not
   added as an open question.

`Insert` never changes a stream's shape, so `apply_statement` is a no-op
pass-through returning `catalog` unchanged on success.

---

## Test plan

Each module gets its own `test/lang/*_test.gleam`, following the
one-behavior-per-test-function style already used in
`test/util/hlc/base62_test.gleam`. As built, these live under
`shared/test/lang/`, `schema/test/lang/`, or `streams/test/lang/`
matching wherever the module itself lives (see "Module layout" above).

### `shared/test/lang/token_test.gleam`

- Only tests any shared helper logic `token.gleam` ends up with (e.g. a
  `Span` merge/combine helper, if one is added) — otherwise this module
  is pure data and most of its coverage naturally comes from
  `lexer_test.gleam`. Not yet built (no such helper exists), same as
  planned.

### `shared/test/lang/token_stream_test.gleam`

Not in the original plan — added once `token_stream.gleam` was pulled out
of `parser.gleam`'s own plumbing (see "Module layout"). Covers `current`/
`advance` (including landing on `Eof` at the end of input), `peek_kind`/
`peek_keyword` (both the match and no-match cases, plus a non-keyword
token correctly reporting `False` from `peek_keyword` rather than crashing
or matching by accident), and `consume_optional_semicolon` (both the
present-and-consumed and absent-and-fallback-position branches).

### `shared/test/lang/expr_parser_test.gleam`

Not in the original plan as a single `parser_test.gleam` split out this
way, but needed once `expr_parser.gleam` became a module of its own with
no test file in the package it lives in — without it, `shared`'s own
`gleam test` couldn't catch a regression in expression/`data_type`
parsing, only `schema`'s and `streams`' could (via `ddl_parser_test.gleam`/
`dml_parser_test.gleam` below, which exercise the same grammar but only
indirectly, through each package's own statement wrapper). Deliberately
narrow, covering only what those two don't duplicate:

- `parse_or` as a direct entry point (a bare literal; that it leaves
  trailing tokens for the caller rather than requiring EOF itself).
- `data_type` (§9.1): every bare keyword; `CHAR`/`VARCHAR`'s optional
  `(n)`; `DECIMAL`/`NUMERIC`'s optional `(p)`/`(p, s)`; `DOUBLE
  PRECISION`'s two-keyword form and its `DOUBLE`-without-`PRECISION`
  error; a non-type token's error.
- The `expect_keyword`/`expect_punct`/`expect_identifier`/`expect_eof`/
  `fail` cursor helpers directly — match and mismatch for each, since
  every statement parser in `schema`/`streams` is built on these and
  none of their own tests exercise the helpers' own contract in isolation.

The full precedence table, the `~1 + 2`/`-1 + 2` contrast, non-associative
comparison, and the `BETWEEN`/`NOT BETWEEN` cases stay exercised only
through `ddl_parser_test.gleam` and `dml_parser_test.gleam` below (each
wraps the same `expr` grammar differently — a `CREATE STREAM ... CHECK
(...)` vs. an `INSERT ... VALUES (...)` — so between the two, both
statement families' actual entry points into `expr_parser` get covered,
at the cost of the same expression-level assertions appearing twice).

### `shared/test/lang/expr_semantics_test.gleam`

Same reasoning as `expr_parser_test.gleam` above: `expr_semantics.gleam`
is logic living in `shared/`, so `shared`'s own `gleam test` needs to be
able to catch a regression in it directly, not only via whichever of
`ddl_semantics_test.gleam`/`dml_semantics_test.gleam` happens to exercise
the broken case. Exercised against a throwaway local error type, not
either package's real `SemanticError`, specifically to prove
`check_expr_column_refs` is genuinely generic and not accidentally
coupled to one:

- `collect_column_refs`: a bare literal has none; a bare `ColumnRef` is
  itself; every `ColumnRef` nested anywhere across several unrelated
  `Expr` constructors (unary, binary, cast, function call) is found, not
  just the ones a narrower test would happen to cover; a repeated
  reference is reported once per occurrence, not deduplicated.
- `check_expr_column_refs`: every reference valid → no errors; an
  unknown reference → reported via the caller's own constructor; several
  references, only some unknown → only those are reported; no references
  at all → never flagged.

### `shared/test/lang/lexer_test.gleam`

- One keyword from each of §3.1–§3.4 tokenizes to its `Keyword` variant,
  case-insensitively (`CREATE`, `create`, `CrEaTe` all → `KwCreate`).
- Unquoted identifier folds to lower case; quoted identifier preserves
  case; `""` inside a quoted identifier decodes to one `"`.
- An identifier longer than 63 bytes tokenizes with its **full** text
  intact (both unquoted and quoted forms) — the lexer does not truncate;
  see "On not truncating in the lexer" above. (The 63-byte collision case
  is instead covered in `ddl_semantics_test.gleam`, via `postgres_name`.)
- Integer literal (`42`, `007`), numeric literal in all three forms
  (`3.14`, `3.`, `.14`), exponent suffix on both forms (`1e10` classified
  as `NumericLiteral` despite being integer-valued, per §4.2), and
  digit-group separators (`1_000_000` accepted; `_1`/`1_`/`1__0`/`1_.5`/
  `1._5`/`1e_5` each rejected with `InvalidDigitGroupSeparator`).
- String literal with an embedded doubled quote (`'it''s'` → `it's`);
  two string literals separated by newline-containing whitespace
  concatenate into one token; two separated only by same-line whitespace
  do **not** concatenate (still two separate tokens — a parse error at
  the statement level, not a lexer concern).
- Nested block comment (`/* outer /* inner */ still in outer */`) is
  skipped as a single unit; an unterminated block/string/quoted
  identifier each produce their respective `Unterminated...` error.
- Maximal munch: `<=` tokenizes as one `Le`, not `Lt` followed by `Eq`;
  similarly for every prefix-sharing group spec.md's §5 intro calls out
  (`<`/`<=`/`<>`/`<<`/`<@`, `>`/`>=`/`>>`, `-`/`->`/`->>`, `#`/`#>`/`#>>`,
  `|`/`||`, `~`/`~*`, `!=`/`!~`/`!~*`).
- `UnknownCharacter` on an input character outside every recognized
  form (e.g. `$`, `@` on its own, a stray backslash).
- An unquoted PostgreSQL reserved word (§3.5) is rejected as
  `ReservedWord`, case-insensitively, for one plainly-reserved example
  (`select`), one "(can be function or type name)" example (`table`),
  and one multi-word example (`current_timestamp`); a StruoDB keyword
  that's also PostgreSQL-reserved (`create`, `check`, `not`) still
  tokenizes as `Keyword`, not `ReservedWord`, proving StruoDB's own
  keyword table is checked first; a PostgreSQL keyword that's only
  *non*-reserved (`value`) still tokenizes as a plain `Identifier`;
  quoting a reserved word (`"select"`) still works.

### `shared/test/lang/catalog_test.gleam`

Built directly against `catalog.gleam`'s own primitives (`ColumnSchema`/
`NamedCheck` values constructed by hand), not via `ddl_ast`/
`ddl_semantics` — `catalog.gleam` knows nothing about those, by design;
see its own section above.

- `create_stream` produces a `StreamSchema` with the right columns
  (the 4 automatic `system_columns()` included, each `system: True`)
  and `constraints`.
- `add_column`/`drop_column`/`alter_column_type`/`add_constraint`/
  `drop_constraint` each updates the right part of an existing
  `StreamSchema` and leaves the rest unchanged.
- Chaining several of the above (e.g. `drop_column` then
  `drop_constraint`) applies both in sequence.
- `dml_semantics.gleam`'s own `apply_statement` — a no-op pass-through
  for `Insert`, which never changes a stream's shape — is instead tested
  implicitly by `dml_semantics_test.gleam`'s own `analyze` tests, since
  `catalog.gleam` only ever sees `Insert` indirectly, through whatever a
  prior `CreateStream`/`AlterStream` already recorded.

### `schema/test/lang/ddl_parser_test.gleam`, `streams/test/lang/dml_parser_test.gleam`

Both files exercise the *same* `expr_parser.gleam` grammar (see the note
under `expr_parser_test.gleam` above) through their own package's actual
`parse` entry point — `ddl_parser_test.gleam` wraps `expr_source` in
`CREATE STREAM s (a INT, CONSTRAINT c CHECK (<expr_source>))`,
`dml_parser_test.gleam` in `INSERT INTO s (a) VALUES (<expr_source>)` —
so the bullets below (all but the last two) appear, essentially verbatim,
in both files:

- Each grammar alternative in §8.1 parses to the expected `Expr` shape
  for one representative input.
- A `ColumnRef` parsed from source carries the identifier token's own
  `Span` (start/end matching just that identifier, not the surrounding
  expression) — the one place `Expr` tracks position at all.
- Precedence: for one input per adjacent pair of levels in the §8.2
  table, confirm the tighter operator binds first (e.g. `1 + 2 * 3` →
  `Add(1, Mul(2,3))`, not `Mul(Add(1,2), 3)`).
- The `~1 + 2` = `~(1 + 2)` quirk specifically, plus a contrasting
  `-1 + 2` = `(-1) + 2` case right next to it, so a future change that
  accidentally aligns their behavior fails a test immediately.
- `2 ^ 3 ^ 2` = `(2^3)^2` (left-associative exponentiation, the
  PostgreSQL-matching non-standard case).
- `a < b < c` is a parse error (non-associative comparison, §8.2) —
  tested through each file's own statement wrapper, not a bare `CREATE
  STREAM` fed to `dml_parser.parse` (which would fail immediately on
  statement dispatch instead, for the wrong reason).
- `a NOT BETWEEN b AND c` parses as negated `Between`; `NOT a BETWEEN b
  AND c` parses as `LogicalNot(Between(a, ...))` — the two-token-lookahead
  case and the outer-`NOT` case land on different AST shapes as intended.
- *(`ddl_parser_test.gleam` only)* `CREATE STREAM` round-trips spec.md
  §9.7's example into the expected `DdlStatement`/`StreamElement` shapes,
  including the `GENERATED ALWAYS AS (...) STORED` clause and the named
  `CHECK`; `NOT NULL` written on a column produces `ExplicitNotNull`, not
  a generic `UnexpectedToken`; `GENERATED ALWAYS AS (expr)` with neither
  `STORED` nor `VIRTUAL` produces `MissingGeneratedStorage`; `ALTER
  STREAM` round-trips spec.md §10.7's example (four actions in one
  statement, comma-separated); `DOUBLE` not followed by `PRECISION` in a
  `data_type` position is a parse error, not silently accepted as a
  standalone type.
- *(`dml_parser_test.gleam` only)* `INSERT` round-trips spec.md §11.7's
  example, including `ON CONFLICT DO NOTHING` and `RETURNING`; the bare
  `DEFAULT` keyword parses as `ValueDefault`; `RETURNING *` parses as
  `ReturningStar`; column list omitted entirely (`INSERT INTO t VALUES
  (...)`) is a parse error (§11.2's mandatory-column-list rule) —
  confirms the grammar-level rejection, distinct from the (likely dead,
  per the note above) semantic-level `InsertColumnListEmpty` check.

### `schema/test/lang/ddl_semantics_test.gleam`, `streams/test/lang/dml_semantics_test.gleam`

One test per `SemanticError` variant each module actually raises (see the
two separate `SemanticError` types above), each with a minimal
`CreateStream`/`AlterStream` (schema) or `Insert` (streams) AST (built
directly, not via the parser, to keep these tests independent of parser
correctness) that should trigger exactly that error — plus, in
`ddl_semantics_test.gleam`:

- A `CreateStream` with two independent violations (e.g. a reserved
  `_STRUO_`-prefixed column name *and* an unknown column reference in a
  `CHECK`) reports **both** in one `Error(list)`, confirming diagnostics
  accumulate rather than stopping at the first.
- `postgres_name`: two columns with identical names round-trip to a
  collision as expected; two columns whose names are identical only in
  their first 63 bytes (differing after that) still raise
  `DuplicateColumnName`; two columns whose names differ well within the
  first 63 bytes do not. (Only in `ddl_semantics_test.gleam` — the sole
  module with a `postgres_name` to test; not duplicated in
  `dml_semantics_test.gleam`, which has nothing of its own that calls it.)
- spec.md §9.7's example `CREATE STREAM` analyzes clean (`Ok`), and the
  resulting catalog's `sensor_reading` schema has exactly the five
  columns and one constraint the example declares. Building on that
  catalog: spec.md §10.7's `ALTER STREAM` example analyzes clean too.
- An `ALTER STREAM` widening `VARCHAR(64)` → `VARCHAR(32)` (shrinking)
  is `NarrowingTypeChange`; `INT` → `DECIMAL` (cross-family) is
  `UnsupportedTypeChange`.
- `UnknownColumnReference`'s `span` matches the offending `ColumnRef`'s
  own span, not the enclosing `CHECK`/`GENERATED` clause's — built with
  the reference nested inside a larger expression (e.g. `a AND
  unknown_col > 0`) so a test asserting on the *whole clause's* span
  would fail, confirming the check actually reads the `ColumnRef`'s span
  rather than falling back to the column's.

`dml_semantics_test.gleam` adds:

- An `INSERT` naming a system column in its column list is
  `InsertSystemColumnInList`, even when every other listed column
  resolves fine.
- Continuing past spec.md §10.7's `ALTER STREAM` example (built via
  `schema/ddl_parser` + `schema/ddl_semantics`, imported for exactly this
  purpose — see "Open questions" on what that dependency costs): spec.md
  §11.7's `INSERT` example analyzes clean against the resulting catalog,
  all the way through `dml_semantics.analyze`.

---

## Step-by-step build order

This was the original, single-package build order — historical at this
point, since the package split (see "Module layout") happened after all
six steps below were already built and passing:

1. `src/lang/token.gleam` — types only, no logic.
2. `src/lang/lexer.gleam` + `test/lang/lexer_test.gleam` — get this fully
   correct first, same reasoning as `base62.gleam` in the HLC plan:
   everything downstream depends on it.
3. `src/lang/ast.gleam` — types only.
4. `src/lang/parser.gleam` + `test/lang/parser_test.gleam` — expression
   grammar and precedence first (most subtle part), then the three
   statement grammars.
5. `src/lang/catalog.gleam` + `test/lang/catalog_test.gleam`.
6. `src/lang/semantic.gleam` + `test/lang/semantic_test.gleam` — last,
   since it depends on all four prior modules.
7. `gleam test`, then a manual smoke check via `gleam run` (or a small
   throwaway script) feeding spec.md's three worked examples (§9.7,
   §10.7, §11.7) end-to-end: `tokenize` → `parse` → `analyze`, confirming
   all three come back `Ok`.

**What followed, not originally planned**: `ast.gleam` split into
`expr_ast.gleam` (shared) + `ddl_ast.gleam` (schema) + `dml_ast.gleam`
(streams); `parser.gleam` into `expr_parser.gleam` (shared) +
`ddl_parser.gleam` (schema) + `dml_parser.gleam` (streams), pulling
`token_stream.gleam`'s cursor out along the way; `catalog.gleam` moved
from `shared/` to `schema/`, then back to `shared/` once a review
decoupled it from `ddl_ast` (see its own section above); `semantic.gleam`
split into `ddl_semantics.gleam` (schema) + `dml_semantics.gleam`
(streams — depending only on `shared` in production code once
`catalog.gleam` moved back; `schema` is now a `dev_dependencies`-only
dependency, for one test that builds a `Catalog` via real DDL parsing),
with their shared `collect_column_refs`/`check_expr_column_refs` moved
out into `expr_semantics.gleam` (shared) once a review noticed both
copies could be one generic function (see its own section above). See
"Module layout" above for the resulting layout.

---

## Open questions

Carried over from spec.md's own "Remaining open details" (not repeated
here — see that list directly) plus what this planning pass surfaced:

- ~~`data_type` has no formal grammar in spec.md~~ — **resolved**:
  spec.md §9.1 now gives a formal `data_type ::= ...` production,
  confirming every assumption this plan made: `CHAR`/`VARCHAR` take an
  optional `(n)` (bare `CHAR` defaults to length 1, bare `VARCHAR` to
  unlimited); `DECIMAL`/`NUMERIC` take an optional `(p)`/`(p, s)` (bare
  form unconstrained); `DOUBLE` must always be followed by `PRECISION`;
  every other data-type keyword is bare. §9.1 also now states the
  parameter bounds (`n >= 1`; `p >= 1`, `0 <= s <= p`) this plan's
  semantic-analysis section previously had to assume from PostgreSQL on
  its own — see "`data_type` parameter sanity" under the `CREATE STREAM`
  checks above, which can now cite §9.1 directly instead of "assumed
  from PostgreSQL's own constraints."
- **Catalog sourcing across runs is entirely undecided.** This plan's
  `analyze` functions take an explicit `Catalog` in and return one out
  (via `catalog.gleam`'s own primitives, once validation passes — see its
  section above), but *how* a caller assembles the very first
  `Catalog` for a given run — replay every historical `CREATE STREAM`/
  `ALTER STREAM` from a migrations directory each invocation, load a
  persisted/serialized snapshot, introspect a live PostgreSQL database's
  actual schema — is outside this plan's scope and undecided. This
  matters for the eventual CLI/application layer, not for the modules
  planned here, but is worth resolving before that layer is designed.
- ~~Expression-level `Span`s~~ — **resolved, narrower than originally
  framed**: rather than a `span` on all fourteen `Expr` variants (real
  parser boilerplate — every precedence-layered function would need to
  track and merge spans — for a benefit no current check uses), only
  `ColumnRef` carries one. That's the only `Expr` shape this plan's
  semantic checks (`DefaultReferencesColumn`, `UnknownColumnReference`)
  ever blame individually, and the parser already holds the identifier
  `Token` when it builds a `ColumnRef`, so capturing the span is free.
  See "Expression-level spans: a narrower alternative" under
  `expr_parser.gleam`.
- ~~Mid-codepoint byte truncation~~ — **resolved, and dissolved rather
  than answered**: the lexer no longer truncates identifiers at all (see
  "On not truncating in the lexer"), since the transpiled SQL's
  correctness never depended on StruoDB replicating PostgreSQL's
  `pg_mbcliplen` — PostgreSQL truncates the full identifier itself,
  correctly, when the SQL runs. The only place approximate truncation
  still appears is `ddl_semantics.gleam`'s `postgres_name` helper, used solely
  for an early duplicate-name diagnostic; getting its boundary choice
  slightly different from PostgreSQL's own in a rare multi-byte edge case
  only costs a missed early warning, not correctness, so no further
  confirmation against spec.md is needed here.
- ~~Right-operand binding for `BETWEEN`/`IN`/`LIKE`/`ILIKE`/
  `SIMILAR TO`/`IS DISTINCT FROM`~~ — **resolved**: spec.md §8.1 now
  defines a `bound_expr` nonterminal (precedence level 6 or tighter) and
  uses it for `BETWEEN`'s bounds, `LIKE`/`ILIKE`/`SIMILAR TO`'s pattern,
  and `IS DISTINCT FROM`'s right side, confirming this plan's approach;
  `IN`'s list items stay as unrestricted `expr`, also as this plan
  assumed.
- **Does `IS [NOT] ...` (level 9) loop or apply once?** This plan allows
  `(a IS NOT NULL) IS NOT NULL` to reparse (a loop), since §8.1's grammar
  technically permits it by making the IS-forms just another `expr`
  alternative — but this may not be intentional or useful; PostgreSQL's
  actual grammar may restrict it. Low priority (an unusual thing to write
  either way) but noted.
- ~~Multi-step widening jumps in `ALTER COLUMN ... TYPE`~~ — **resolved**:
  spec.md §10.4 now states directly that a widening change may skip an
  intermediate type (`SMALLINT → BIGINT` directly is allowed), confirming
  this plan's default.
- ~~Column-name and constraint-name uniqueness within a stream~~ —
  **resolved**: spec.md §9.1 and §9.5 now state both requirements
  explicitly, confirming this plan's assumption.
- **The `NOT NULL` friendly-diagnostic special-case** in the parser
  (`ExplicitNotNull` instead of a generic parse error) is a judgment call
  about error-message quality, not a spec.md requirement — flagged in
  case a generic parse error is preferred for simplicity.
- **How "stronger" is verified when replacing a `CHECK` constraint**
  (§10.5) is unimplemented here entirely, pending spec.md's own
  unresolved decision on the verification mechanism (see spec.md's
  "Remaining open details" for the options under consideration).
- ~~`ddl_semantics.gleam`/`dml_semantics.gleam`'s duplicated
  `collect_column_refs`/`check_expr_column_refs`~~ — **resolved**:
  (`SemanticError` itself was the same story until an earlier review
  pruned `dml_semantics`'s copy down to only the eight variants
  `check_insert` actually raises.) Both functions moved to
  `shared/src/lang/expr_semantics.gleam` — `collect_column_refs` as-is
  (it never touched `SemanticError`), `check_expr_column_refs` made
  generic over the error type via a caller-supplied constructor parameter
  (`fn(String, Span) -> e`), since each package's `UnknownColumnReference`
  is a variant of its own distinct `SemanticError`. Each caller passes
  its own variant's constructor directly:
  `check_expr_column_refs(expr, valid_names, UnknownColumnReference)`.
  See `expr_semantics.gleam`'s own section above.
- ~~`streams` depends on the whole `schema` package just to reach
  `catalog.gleam`~~ — **resolved**: `catalog.gleam`'s `apply_statement`
  used to operate directly on `ddl_ast`'s `DdlStatement`/`StreamElement`/
  `AlterAction` (schema-only types), which is why `catalog.gleam` lived
  in `schema/` rather than `shared/` — but `dml_semantics.gleam`'s
  `INSERT` checks need the same `Catalog` to read a stream's current
  shape, so `streams/gleam.toml` ended up depending on all of `schema`
  (its DDL parser and semantics included) for that one module, contrary
  to CLAUDE.md's stated architecture ("every other package depends on it
  via `shared`"). A review decoupled `catalog.gleam` from `ddl_ast`: it
  now exposes six small primitives (`create_stream`, `add_column`, ...)
  taking only shared types, with `ddl_semantics.gleam` itself translating
  a validated `DdlStatement` into those calls (one variant at a time,
  reusing the column/constraint-gathering helpers `check_create_stream`
  already builds for validation) rather than handing the whole statement
  to `catalog.gleam`. That let `catalog.gleam` move back to `shared/`,
  and `streams`' production code now depends on `shared` alone —
  `streams/gleam.toml`'s `schema` entry is a `[dev_dependencies]`-only
  dependency now, kept solely because one test
  (`dml_semantics_test.gleam`'s worked-example test) chooses to build its
  `Catalog` fixture via real DDL parsing rather than by hand.
