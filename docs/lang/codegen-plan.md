# StruoDB Query Language — Codegen Implementation Plan

Implements the "Out of scope" item `docs/lang/implementation-plan.md` left
for later: turning a validated `Statement`/`Catalog` into PostgreSQL SQL
text. Read `spec.md` and `implementation-plan.md` first — this plan builds
directly on `token`/`lexer`/`ast`/`parser`/`catalog`/`semantic` as they
exist today and doesn't re-derive their design decisions.

**Note on package layout**: this plan is still unbuilt, and was written
before `lang/` split across `shared`/`schema`/`streams` (see
`implementation-plan.md`'s own "Note on package layout" and CLAUDE.md's
"The StruoDB query language front end"). It still refers throughout to a
single `ast`/`parser`/`catalog`/`semantic` and one `src/lang/codegen.gleam`
— read those as shorthand for "the expr/DDL/DML modules, wherever they now
live" rather than literal paths; "Module layout" below proposes how
`codegen.gleam` itself should probably split along the same line before
anyone starts implementing it, and "Issues" adds the one new question the
split raises that this plan doesn't resolve: whether one `generate` call
is still expected to mix `CREATE STREAM`/`ALTER STREAM` and `INSERT` in
the same input, now that validating each needs a different package's
parser/semantics.

## Scope

- **In scope**: given a string containing one or more `;`-separated
  StruoDB statements (`CREATE STREAM`/`ALTER STREAM`/`INSERT`), validate
  all of them in order against a threaded `Catalog` and return the
  equivalent PostgreSQL, formatted — a single function from `String` to
  `Result(String, CodegenError)` (plus a `Catalog`-threading variant for
  multi-batch callers; see below). This is pure text generation.
- **Out of scope**: actually connecting to or running anything against a
  database; managing migration files; deciding *how* `TIMESTAMPTZ_FROM_HLC`
  (or any future built-in) is itself implemented in the target database —
  codegen emits a call to it and assumes it already exists there (see
  "Issues" below). Also out of scope, unchanged from the parent plan:
  anything under spec.md §12 (querying/subscribing).

## Design decisions

- **Tokenize the whole multi-statement input once; never split raw source
  text on `;` before lexing.** A naive `string.split(source, ";")` is
  unsafe: a string literal or quoted identifier can itself contain a
  literal `;` (`CHECK (notes != 'a;b')` is legal StruoDB), and splitting
  on raw text would cut it in half. The lexer already treats such a `;`
  as ordinary content, not a delimiter, because it scans character by
  character with full knowledge of string/quoted-identifier boundaries —
  so the only safe place to find statement boundaries is in the *token*
  stream, after lexing, where a top-level `Semicolon` token is
  unambiguous. This also means every `Span` stays meaningful against the
  original full input; a "lex each statement's raw text separately"
  design would have to recompute a byte offset per chunk.
- **Codegen's emission step needs no `Catalog`.** Only *validating* a
  statement (`ALTER STREAM`/`INSERT` against what a stream currently
  looks like) needs one — every `Statement` the parser produces is
  already fully self-contained for the purpose of *emitting* SQL (an
  `AlterAction` carries its own new type/column name; an `Insert` carries
  its own column list and values; PostgreSQL applies its own column
  defaults for anything genuinely omitted, exactly mirroring what
  `semantic.gleam` already validated). So the pipeline is: lex once,
  parse into a `List(Statement)`, thread a `Catalog` through
  `semantic.analyze` purely to *validate* (discarding nothing from the
  original statements), then translate each already-validated
  `Statement` to SQL independently, with no further `Catalog` lookups.
- **`ddl_parser.gleam`/`dml_parser.gleam` each gain their own `pub fn
  parse_many`; `ddl_semantics.gleam`/`dml_semantics.gleam` gain nothing
  new.** Multi-statement parsing needs access to "parse one statement,
  then report the leftover tokens" — currently private inside each
  package's own `parse` (which immediately asserts EOF after one
  statement) — so that has to become new public API in both. Folding
  `analyze` over a `List(DdlStatement)`/`List(DmlStatement)` with a
  threaded `Catalog`, by contrast, is a three-line recursive fold any
  caller can write itself; adding an `analyze_many` to either
  `*_semantics.gleam` would grow its public surface for no real reuse
  benefit, so that fold lives privately in `ddl_codegen.gleam`/
  `dml_codegen.gleam` instead.
- **Validation stops at the first statement that fails, not just the
  first check within it.** Within one statement, `semantic.analyze`
  already accumulates every independent violation (unchanged). Across
  statements, though, statement *N+1* is typically validated against the
  `Catalog` effect statement *N* would have had — if statement *N*
  itself failed, that effect never happened, so continuing to validate
  *N+1* against the pre-*N* catalog would produce misleading cascading
  errors (e.g. "unknown stream" on every later statement referencing a
  stream whose `CREATE STREAM` just failed). So codegen's driver reports
  exactly one statement's worth of `SemanticError`s per failed run, along
  with which statement (0-indexed) it was.
- **Generated identifiers are quoted only when needed — not
  unconditionally — via a content check plus a reserved-word check.**
  `ddl_ast.gleam`'s/`dml_ast.gleam`'s name fields (`CreateStream.name`/
  `AlterStream.name`, `Insert.stream_name`, `ColumnDef.name`,
  `NamedCheck.constraint_name`, etc.) are plain `String` with no memory
  of whether the source spelled them as a bare `Identifier` (already
  lower-cased by the lexer, §1) or a case-preserving `QuotedIdentifier`
  — that distinction is genuinely gone by the time an AST exists, and
  codegen has to re-derive "does this need quotes in the output" from
  the string alone, regardless of which form produced it. Two checks,
  both needed: (a) *content* — quote if the string contains uppercase/
  non-`[a-z0-9_]` characters, or starts with a digit, since an unquoted
  identifier can never contain those; (b) *reserved word* — quote if the
  string is one of PostgreSQL's own reserved words (spec.md §3.5), since
  PostgreSQL requires quoting those regardless of content. Neither check
  alone is sufficient: a name could fail only (a) (`Sensor_Reading`), only
  (b) (`order` — valid identifier characters throughout, but still
  reserved), or neither (`sensor_reading`, emitted bare). This plan
  originally defaulted to always-quoting instead of implementing check
  (b), for lack of anywhere to source PostgreSQL's reserved-word list
  from. **That's resolved now, not by removing the need for check (b),
  but by there being a ready, canonical, already-correct list to reuse
  for it**: spec.md §3.5 / `lexer.gleam`'s `is_postgres_reserved_word`,
  the same table the lexer itself now enforces (see
  `implementation-plan.md`'s "PostgreSQL reserved words") — codegen calls
  the same function (or an equivalent moved somewhere both `lexer.gleam`
  and codegen can reach) rather than hand-maintaining its own copy. The
  lexer enforcing this at parse time doesn't let codegen skip check (b):
  a StruoDB source can still *deliberately* quote a reserved word as an
  identifier (`"order"`), and that identifier reaches the AST as the
  plain string `order`, indistinguishable at that point from a
  never-quoted one — but it does mean the *only* way `order` ever reaches
  codegen unquoted-looking is if it was deliberately quoted in the
  source, never by accident, which is what actually mattered about this
  design decision from the start. Function-call names are unaffected by
  any of this either way: emitted bare, lower-case, unquoted, since today
  they're only ever one of a small, project-controlled set of built-ins
  (§8.3), not arbitrary user-chosen identifiers.
- **The `HLC` column transpiles to `CHAR(15)`, inlined `PRIMARY KEY`, no
  explicit `NOT NULL`** (redundant once `PRIMARY KEY` is present).
  `docs/hlc/spec.md` states the encoding is fixed-width, 15 characters,
  "chosen specifically so the value fits a PostgreSQL `char(15)` column
  with no padding" — this is that decision cashed in, not a new one.
- **StruoDB's precedence table doubles as the pretty-printer's
  reparenthesization table.** `expr_ast.gleam`'s `Expr` has no `Paren`
  node (parenthesization is only ever a parsing-time concern) and most
  variants carry no `Span`, so regenerating correct PostgreSQL text means
  re-deriving *when* a child expression needs parentheses added back —
  purely from each operator's own precedence level. Since spec.md §8.2
  is defined to match PostgreSQL's own operator precedence table exactly
  (that was the point), the same twelve levels `expr_parser.gleam`
  already encodes (shared/, so `expr_codegen.gleam` can sit right next to
  it) are the correct levels for this, with no separate table to design
  or keep in sync.
- **Reparenthesization is conservative, not minimal.** Rather than the
  usual "only the right operand of a left-associative operator at the
  same precedence needs parens" refinement, every child is parenthesized
  whenever its own top-level precedence is not *strictly tighter* than
  its parent's — on both sides, unconditionally. This occasionally emits
  a technically-unneeded paren (`("a" + "b") + "c"` for a already-flat
  `a + b + c`), but the rule is one line and trivially correct, versus a
  meaningfully larger one that has to reason about associativity and
  operand position per operator. "Nicely formatted" doesn't require
  *minimally* parenthesized — flagged as a possible later refinement in
  "Issues" below, not a blocker.
- **`GENERATED ALWAYS AS (...) VIRTUAL` transpiles the same as `...
  STORED`.** For a pure function of sibling columns in the same row (the
  only kind this grammar allows — see §9.4), `STORED` and `VIRTUAL` are
  observationally identical in every query result; they only differ in
  *when* the value is computed and whether it occupies disk space. This
  matters because PostgreSQL's own generated-column support has
  historically been `STORED`-only — whether the version this project
  targets accepts `VIRTUAL` directly is unconfirmed (see "Issues"), so
  collapsing both StruoDB forms to `STORED` in the emitted SQL is the
  safe, always-correct choice regardless of target-version support,
  rather than a shortcut taken for convenience.

## Module layout

As originally planned, one `src/lang/codegen.gleam` under a single
package. Given the split `lang/` actually has now (see the note above),
codegen should follow the same line — reusable expression/data-type
rendering in `shared`, statement-family-specific rendering and drivers in
`schema`/`streams` — rather than being written as one new file that would
have to import both `schema` and `streams` (a dependency direction
nothing else in this codebase takes) just to see both `DdlStatement` and
`DmlStatement`:

```
shared/src/lang/
  expr_codegen.gleam    # expr_to_sql, data_type_to_sql, quote_identifier,
                         # quote_string_literal, reparenthesization — pure,
                         # reused by both packages below

schema/src/lang/
  ddl_codegen.gleam     # create_stream_to_sql, alter_stream_to_sql,
                         # generate/generate_standalone, CodegenError —
                         # DdlStatement only

streams/src/lang/
  dml_codegen.gleam     # insert_to_sql, generate/generate_standalone,
                         # CodegenError — DmlStatement only
```

Each of `ddl_codegen.gleam`/`dml_codegen.gleam` builds output with
`gleam/string_tree` (append-heavy construction, `string_tree.to_string`
once at the end) rather than repeated `String` concatenation, matching how
`gleam/string`'s own `replace` is implemented under the hood.

```gleam
// schema/src/lang/ddl_codegen.gleam
pub type CodegenError {
  LexFailure(lexer.LexError)
  ParseFailure(ep.ParseError)
  /// `statement_index` is 0-based, counting only statements that were
  /// successfully parsed before this one failed to validate.
  SemanticFailure(statement_index: Int, errors: List(ddl_semantics.SemanticError))
}

/// Validates every statement in `source` against `catalog` (threaded
/// across them in order, exactly as calling `ddl_semantics.analyze`
/// repeatedly would), and — only if every one of them passes — returns
/// the equivalent formatted PostgreSQL for all of them concatenated, plus
/// the resulting `Catalog`. Returning the catalog lets a caller processing
/// several files/batches in sequence chain calls, passing each result's
/// catalog into the next.
pub fn generate(
  catalog: Catalog,
  source: String,
) -> Result(#(String, Catalog), CodegenError)

/// Convenience wrapper for the common single-shot case: no prior
/// migration history to seed the catalog with.
pub fn generate_standalone(source: String) -> Result(String, CodegenError)
```

`streams/src/lang/dml_codegen.gleam` mirrors this shape exactly, against
`DmlStatement`/`dml_semantics.SemanticError`/`ep.ParseError`, one package
over. Whether a caller needing *both* (a migration/deploy tool driving
`schema` and `streams` together) belongs in one of these two packages, a
new orchestration layer, or stays entirely out of scope for `lang/`
itself is the open question in "Issues" below — neither `generate` as
sketched here attempts to accept mixed `CREATE STREAM`/`INSERT` input.

### `ddl_parser.gleam`/`dml_parser.gleam` additions

```gleam
/// Parses one or more `;`-separated statements from `tokens`, in order,
/// all of the same statement family (`ddl_parser.parse_many` accepts only
/// CREATE/ALTER STREAM; `dml_parser.parse_many` only INSERT). Errors
/// (`UnexpectedEof`, reusing the existing `expr_parser.ParseError`
/// variant) if `tokens` is just `Eof` — "one or more" is not satisfied by
/// zero.
pub fn parse_many(tokstrm: TokenStream) -> Result(List(DdlStatement), ParseError)
// and, in dml_parser.gleam:
pub fn parse_many(tokstrm: TokenStream) -> Result(List(DmlStatement), ParseError)
```

Each implemented by extracting the dispatch-and-return-leftover-tokens
half of that package's own today's `parse` (everything before its own
`expect_eof` call) into a private
`parse_one_statement(tokstrm) -> Result(#(DdlStatement, TokenStream), ParseError)`
(or `DmlStatement` in `dml_parser.gleam`), which both `parse` (unchanged
behavior: one statement, then require EOF) and the new `parse_many` (loop:
parse one, check for `Eof` vs. more input, repeat) call. No change to any
existing public signature or test.

### `ddl_codegen.gleam`'s internal driver

```gleam
pub fn generate(catalog: Catalog, source: String) -> Result(#(String, Catalog), CodegenError) {
  use tokens <- result.try(
    lexer.tokenize(source) |> result.map_error(LexFailure),
  )
  use statements <- result.try(
    ddl_parser.parse_many(token_stream.new(tokens)) |> result.map_error(ParseFailure),
  )
  use final_catalog <- result.try(validate_all(catalog, statements, 0))
  Ok(#(render_all(statements), final_catalog))
}

fn validate_all(
  catalog: Catalog,
  statements: List(DdlStatement),
  index: Int,
) -> Result(Catalog, CodegenError) {
  case statements {
    [] -> Ok(catalog)
    [stmt, ..rest] ->
      case ddl_semantics.analyze(catalog, stmt) {
        Ok(next_catalog) -> validate_all(next_catalog, rest, index + 1)
        Error(errors) -> Error(SemanticFailure(index, errors))
      }
  }
}

fn render_all(statements: List(DdlStatement)) -> String {
  statements
  |> list.map(statement_to_sql)
  |> string.join("\n\n")
  |> fn(s) { s <> "\n" }
}
```

`render_all` runs over the *original* `statements` list from
`parse_many` — `validate_all` only threads a `Catalog` for checking,
never transforms the statements themselves (there's nothing for it to
add: everything codegen needs is already in the AST — see "Design
decisions").

## Data type mapping (spec.md §9.1 → PostgreSQL)

| StruoDB `DataType`        | PostgreSQL                                   |
|----------------------------|-----------------------------------------------|
| `DtBigint`                 | `BIGINT`                                       |
| `DtBoolean`                 | `BOOLEAN`                                      |
| `DtChar(n)`                 | `CHAR(n)` if `Some(n)`, else bare `CHAR`         |
| `DtDate`                    | `DATE`                                         |
| `DtDecimal(p, s)`           | `DECIMAL(p, s)` / `DECIMAL(p)` / bare `DECIMAL`, per which of `p`/`s` are `Some` |
| `DtDouble`                  | `DOUBLE PRECISION`                              |
| `DtHlc`                      | `CHAR(15)` — see "Design decisions"             |
| `DtInt` / `DtInteger`       | `INTEGER` (PostgreSQL's canonical spelling for both) |
| `DtInterval`                 | `INTERVAL`                                     |
| `DtJson`                     | `JSON`                                         |
| `DtJsonb`                    | `JSONB`                                        |
| `DtNumeric(p, s)`            | same pattern as `DtDecimal`                     |
| `DtReal`                     | `REAL`                                         |
| `DtSmallint`                 | `SMALLINT`                                     |
| `DtText`                     | `TEXT`                                         |
| `DtTime`                     | `TIME`                                         |
| `DtTimestamp`                | `TIMESTAMP`                                    |
| `DtTimestamptz`              | `TIMESTAMPTZ`                                  |
| `DtUuid`                     | `UUID`                                         |
| `DtVarchar(n)`               | `VARCHAR(n)` if `Some(n)`, else bare `VARCHAR`   |

`Option(Int)` parameters translate straightforwardly — StruoDB's own
"bare form is unconstrained" rule (§9.1) already matches PostgreSQL's own
bare-`DECIMAL`/`NUMERIC`/`VARCHAR` meaning directly, no adaptation needed.

## Expression codegen

`expr_to_sql(expr: Expr) -> String`, one arm per `Expr` variant, each
recursively rendering its sub-expressions via a `paren_if_needed(child,
parent_level)` helper that wraps `child` in `(...)` whenever
`precedence_of(child) `is not strictly tighter than `parent_level` (see
"Reparenthesization is conservative, not minimal" above). Literals map
directly:

- `IntLiteral(text)` / `NumericLiteral(text)` → `text` verbatim (already
  separator-stripped, already PostgreSQL-syntax-compatible numeric text —
  see the parent plan's "Numeric literals keep their source text" design
  decision, cashed in here).
- `StringLiteral(value)` → `'` + `value` with every `'` doubled to `''`
  + `'` — the write-side mirror of the lexer's own read-side unescaping.
- `BoolLiteral(b)` → `TRUE`/`FALSE`; `NullLiteral` → `NULL`.
- `ColumnRef(name, _)` → the quoted identifier (its `Span` is unused here
  — codegen never needs to blame a specific reference, only render it).

Operators map to their literal PostgreSQL spelling; `CmpNeAngle`/
`CmpNeBang` map back to `<>`/`!=` respectively rather than being folded
to one spelling — cashing in the parent plan's "`<>` and `!=` stay
distinct tokens/AST nodes" decision, made specifically so this would be
possible without needing a `Span` to recover which one the user wrote.
`UnaryOperator.BitNot` and `BinaryOperator.RegexMatchOp` both render as
`~` (their own textual spelling; PostgreSQL disambiguates the same way
StruoDB's own parser does, by position).

`FunctionCall(name, args)` → `name(arg1, arg2, ...)`, `name` bare/
lower-case/unquoted (see "Design decisions"), each `arg` rendered at the
loosest level (function-call arguments never need outer parens beyond
the call's own).

## Statement codegen

- **`CreateStream`**: `CREATE TABLE "name" (\n  col1,\n  col2,\n  ...,\n
  CONSTRAINT ...\n);`, one column/table-constraint per line, 2-space
  indent (matching `gleam format`'s own indent width elsewhere in this
  codebase). Each `ColumnDef` renders as `"name" TYPE [NOT NULL |
  <nothing if OPTIONAL>] [DEFAULT expr] [GENERATED ALWAYS AS (expr)
  STORED] [PRIMARY KEY if this is the HLC column]`; each column-level
  `CHECK` becomes its own trailing `CONSTRAINT "name" CHECK (expr)` line
  rather than an inline column constraint, for a uniform, simple
  rendering of both column-level and table-level checks (PostgreSQL
  accepts a named `CONSTRAINT` clause in either position; there's no
  behavioral difference, only where it's textually attached).
- **`AlterStream`**: `ALTER TABLE "name"\n  action1,\n  action2,\n
  ...;` — one `ALTER TABLE` per `AlterStream`, all of its actions as
  comma-separated sub-clauses (matching PostgreSQL's own support for
  exactly that, and StruoDB's grammar already allowing multiple
  `alter_action`s per statement, §10.1). Each `AlterAction` maps 1:1 to
  its PostgreSQL sub-clause spelling (`ADD COLUMN ...`, `DROP COLUMN
  ...`, `ALTER COLUMN ... TYPE ...`, `ADD CONSTRAINT ...`, `DROP
  CONSTRAINT ...`).
- **`Insert`**: `INSERT INTO "name" ("col1", "col2", ...)\nVALUES\n
  (v1, v2, ...),\n  (...)\n[ON CONFLICT DO NOTHING]\n[RETURNING item1,
  item2, ...];`. A `Value` of `ValueDefault` (bare `DEFAULT`, §11.3)
  renders as the bare keyword `DEFAULT`, matching PostgreSQL's own
  identical syntax directly.

## Test plan

Three files, one per package, matching the existing per-module test
files' one-behavior-per-function style:

`shared/test/lang/expr_codegen_test.gleam`:

- One test per `DataType` mapping row above (both the `Some`/bare forms
  where a type takes parameters).
- Expression codegen: literal forms; each operator's textual spelling,
  including the `<>`/`!=` and `~`/regex-match distinctions; a
  precedence-driven reparenthesization case per adjacent pair of levels
  (mirroring `ddl_parser_test.gleam`'s/`dml_parser_test.gleam`'s own
  precedence tests, but checking output *text* against an expected string
  instead of an expected AST); a function call, including zero-arg.

`schema/test/lang/ddl_codegen_test.gleam`:

- `CreateStream`/`AlterStream` codegen for spec.md's own §9.7/§10.7
  examples, each checked against a fully literal expected PostgreSQL
  string (see the worked examples below) — built by constructing the
  `DdlStatement` AST directly (independent of parser correctness),
  matching how `ddl_semantics_test.gleam` tests are built.
- `generate`/`generate_standalone` end to end: the two examples
  concatenated into one multi-statement input string, `;`-separated,
  producing both translations in order with the `Catalog` correctly
  threaded (`ALTER STREAM` validates against the catalog `CREATE STREAM`
  produces).
- A statement containing a literal `;` inside a string literal
  (`CHECK (notes != 'a;b')`) followed by a second real statement,
  confirming the boundary is found correctly (this is the concrete
  regression test for the "never split raw text on `;`" design decision).
- Empty input (`""`, or whitespace/comments only) is a `ParseFailure`,
  not `Ok([])`.
- Each `CodegenError` variant reachable from `generate`: a lex error
  inside a later statement (`LexFailure`), a syntax error inside a later
  statement (`ParseFailure`), and a semantic error inside a later
  statement (`SemanticFailure` naming the right `statement_index`, and
  *not* also reporting cascading errors from any statement after it).

`streams/test/lang/dml_codegen_test.gleam` mirrors the last four bullets
against `Insert`/`dml_codegen.generate`/`dml_semantics.SemanticError`
instead, using `schema/ddl_parser` + `schema/ddl_semantics` (already a
`streams` dependency — see CLAUDE.md) to build a realistic `Catalog` to
validate the §11.7 `INSERT` example against, the same way
`dml_semantics_test.gleam` already does.

## Worked examples (spec.md §9.7 / §10.7 / §11.7)

As originally planned, one multi-statement input/output pair to exercise
`generate_standalone` end to end. As built, this would now be **two**
separate calls — `schema/ddl_codegen.generate_standalone` on the
`CREATE STREAM`/`ALTER STREAM` pair, `streams/dml_codegen.generate` on
the `INSERT` (needing the first call's resulting `Catalog`, or an
equivalent one built via `schema/ddl_semantics` the way
`dml_semantics_test.gleam` already does) — see "Issues" below on whether
a single call spanning both is worth adding back. The combined
before/after text below is still the right acceptance target for each
statement's *own* rendering; read it as two runs concatenated, not one:

Given, back to back:

```
CREATE STREAM sensor_reading (
    reading_hlc HLC,
    reading_time TIMESTAMPTZ GENERATED ALWAYS AS (TIMESTAMPTZ_FROM_HLC(reading_hlc)) STORED,
    reading REAL CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 100),
    units VARCHAR(32),
    sensor_id VARCHAR(24),
    notes VARCHAR(200) OPTIONAL
);

ALTER STREAM sensor_reading
    ADD COLUMN calibration_id VARCHAR(24) OPTIONAL,
    ALTER COLUMN units TYPE VARCHAR(64),
    DROP CONSTRAINT reading_in_range,
    ADD CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 90);

INSERT INTO sensor_reading (reading_hlc, reading, units, sensor_id)
VALUES ('01a2B3c4D5e6f70abcde', 42.5, 'celsius', 'sensor-001')
ON CONFLICT DO NOTHING
RETURNING reading_hlc, reading_time;
```

`generate_standalone` on the above should produce:

```sql
CREATE TABLE sensor_reading (
  reading_hlc CHAR(15) PRIMARY KEY,
  reading_time TIMESTAMPTZ GENERATED ALWAYS AS (timestamptz_from_hlc(reading_hlc)) STORED,
  reading REAL NOT NULL,
  units VARCHAR(32) NOT NULL,
  sensor_id VARCHAR(24) NOT NULL,
  notes VARCHAR(200),
  CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 100)
);

ALTER TABLE sensor_reading
  ADD COLUMN calibration_id VARCHAR(24),
  ALTER COLUMN units TYPE VARCHAR(64),
  DROP CONSTRAINT reading_in_range,
  ADD CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 90);

INSERT INTO sensor_reading (reading_hlc, reading, units, sensor_id)
VALUES
  ('01a2B3c4D5e6f70abcde', 42.5, 'celsius', 'sensor-001')
ON CONFLICT DO NOTHING
RETURNING reading_hlc, reading_time;
```

(None of these identifiers need quoting: every one is already all-lowercase
`[a-z_][a-z0-9_]*` as written in the source, and none is a PostgreSQL
reserved word — the lexer would have rejected any of them unquoted in
the source otherwise, per §3.5. A worked example using a name that
*does* need quoting looks different depending on why: a column named
`Sensor Reading` (written `"Sensor Reading"` in quoted source, since it
has to be — that content is invalid for an unquoted identifier)
round-trips to `"Sensor Reading"` via the content check; a column
deliberately named `order` (written `"order"` in quoted source — legal
content for an unquoted identifier, but written quoted anyway because
it's reserved) round-trips to `"order"` via the reserved-word check,
even though its content alone looks perfectly safe.)

(This is also the concrete acceptance target for the "Statement codegen"
section above — if the actual implementation's output differs from this
in some formatting detail once written, prefer updating this block to
match reality over silently drifting, the same way `implementation-plan.md`
treats its own worked examples as living documentation.)

## Step-by-step build order

1. `ddl_parser.gleam`/`dml_parser.gleam`: extract `parse_one_statement`,
   add `pub fn parse_many` to each + tests (multi-statement input, the
   semicolon-in-a-string-literal case, empty input).
2. `shared/src/lang/expr_codegen.gleam`: `data_type_to_sql`,
   `quote_identifier`, `quote_string_literal` + tests — pure,
   independently testable, no dependency on the rest of codegen.
3. `expr_to_sql` (same module) + precedence-aware reparenthesization +
   tests — the most subtle part, same reasoning as why the parent plan
   built the parser's expression grammar before its statement grammars.
4. `schema/src/lang/ddl_codegen.gleam`'s `create_stream_to_sql` /
   `alter_stream_to_sql` + tests against the §9.7/§10.7 worked examples
   above.
5. `streams/src/lang/dml_codegen.gleam`'s `insert_to_sql` + tests against
   the §11.7 worked example.
6. `generate` / `generate_standalone` (the `validate_all`/`render_all`
   driver) in both `ddl_codegen.gleam` and `dml_codegen.gleam` + tests,
   including every `CodegenError` variant in each.
7. `gleam test` in `shared`, `schema`, and `streams`; then a manual smoke
   check: feed the §9.7/§10.7 pair through `schema/ddl_codegen.
   generate_standalone` and the §11.7 example through
   `streams/dml_codegen.generate` (against the first call's `Catalog`),
   diffing both results against the "Worked examples" block by eye.

## Issues

Open questions and known gaps this plan doesn't resolve on its own —
worth a decision before or during implementation:

- **Does one `generate` call still need to accept mixed `CREATE STREAM`/
  `ALTER STREAM`/`INSERT` input, now that DDL and DML live in separate
  packages?** As originally planned (single package), `generate` validated
  and rendered any mix of the three in one pass over one input string —
  the "Worked examples" section's whole premise. As split, `ddl_codegen.
  generate` only ever sees `DdlStatement`s and `dml_codegen.generate` only
  `DmlStatement`s (see "Module layout"), so a single input string mixing
  `CREATE STREAM` with `INSERT` has no single `generate` to hand it to
  without one of `schema`/`streams` depending on the other purely for
  codegen purposes — the same shape of problem `implementation-plan.md`'s
  "Open questions" once flagged for `catalog.gleam` before a review
  decoupled it from `ddl_ast` and moved it to `shared/`; no equivalent
  decoupling is obvious here, since rendering `CREATE STREAM`/`ALTER
  STREAM`/`INSERT` genuinely is schema-/streams-specific, unlike a
  `Catalog`'s shape. If mixed input is
  genuinely needed (e.g. a migration file that both alters a stream and
  seeds it with data), the natural place for that orchestration is a new
  layer above both packages — not `lang/` itself — that calls
  `ddl_codegen.generate` and `dml_codegen.generate` in turn, splitting the
  input by statement keyword first. If it isn't needed (each service only
  ever processes its own statement family, per CLAUDE.md's stated service
  boundaries), this plan's original "one `generate`, any mix" framing
  should be dropped in favor of the two independent entry points already
  reflected in "Module layout" above. Not resolved here.
- ~~Always-quote identifiers, or quote only when the content requires
  it?~~ — **resolved**: this plan originally defaulted to always-quoting,
  since a purely content-based heuristic (quote only if the string
  contains uppercase/non-`[a-z0-9_]` characters or starts with a digit)
  is correct for everything *except* a name colliding with a PostgreSQL
  reserved word (`order`, `select`, ...) — which needs quoting regardless
  of how safe its content looks, and needed that reserved-word list
  sourced from somewhere (hand-maintained, or generated from
  PostgreSQL's own `pg_get_keywords()` against a target version) to
  close. That sourcing problem is resolved now: the same list is already
  canonically implemented, as `lexer.gleam`'s `is_postgres_reserved_word`
  (spec.md §3.5), which the lexer itself uses to reject such a word
  *unquoted* at parse time — codegen reuses that same table (or an
  equivalent moved somewhere both can reach) for its own quoting check,
  rather than hand-maintaining a second copy. Codegen still needs to run
  that check on every identifier it emits, content-safe-looking or not —
  the lexer enforcing this doesn't make codegen's own check optional, it
  only guarantees a bare-source name can never actually need it (a
  StruoDB source can still deliberately quote a reserved word, e.g.
  `"order"`, and codegen must still notice that on the way back out). See
  "Design decisions" above.
- **`GENERATED ALWAYS AS (...) VIRTUAL` and target PostgreSQL version.**
  This plan collapses `VIRTUAL` to the same output as `STORED` (see
  "Design decisions" for why that's safe regardless), which sidesteps
  the question — but it's still worth confirming which PostgreSQL major
  version(s) this project actually targets, since that determines
  whether a *more* literal `VIRTUAL` translation ever becomes possible
  or desirable later.
- **`TIMESTAMPTZ_FROM_HLC` (and any future built-in) has no defined
  PostgreSQL-side implementation anywhere in this repository.** Codegen
  emits a bare call to it and assumes a same-named function already
  exists in the target database — but nothing here designs, generates,
  or documents that function itself (presumably a small PL/pgSQL
  function decoding the physical-time field from `docs/hlc/spec.md`'s
  encoding). Out of scope for this plan by its own "Scope" section, but
  worth tracking as a real gap: a stream using this built-in can't
  actually be queried successfully against a fresh database without it.
- **`HLC` → `CHAR(15)` vs. `TEXT` + a length `CHECK`.** `CHAR(n)` in
  PostgreSQL blank-pads values shorter than `n` and has a
  (mild, debated) reputation for surprising comparison/storage behavior
  relative to `TEXT`/`VARCHAR` — moot here since HLC values are always
  exactly 15 characters by construction (no padding ever actually
  happens), but some PostgreSQL style guidance recommends avoiding
  `char(n)` categorically in favor of `TEXT` with an explicit `CHECK
  (length(col) = 15)`. This plan keeps `CHAR(15)`, matching
  `docs/hlc/spec.md`'s own stated intent directly; flagging the
  alternative in case that guidance matters more than the direct match.
- **Minimal vs. conservative reparenthesization.** Noted under "Design
  decisions" — the conservative rule can emit a technically-redundant
  paren pair a human wouldn't write by hand. Not a correctness problem,
  purely a "how nice is 'nicely formatted'" question.
- **No statement-index enrichment on `LexFailure`/`ParseFailure`.**
  `SemanticFailure` names which statement (0-indexed) failed, but a lex
  or parse error only carries a source `Position`/`Span` against the
  *whole* input — locating "which statement" still requires counting
  semicolons/statements up to that position by hand. Every position
  already points at the right place in the original source (a benefit of
  tokenizing once — see "Design decisions"), so this is a convenience gap
  at worst, not a correctness one.
- **Table-level vs. inline `PRIMARY KEY`/column-level `CHECK` placement**
  is an arbitrary rendering choice in "Statement codegen" above
  (inlined `PRIMARY KEY` on the `HLC` column; every `CHECK`, column-level
  or table-level in the source, rendered as a trailing table-level
  `CONSTRAINT` line) — PostgreSQL accepts either placement for both with
  no behavioral difference, so this is pure style, easy to change later
  if a different convention is preferred.
- **Formatting details in general** (2-space indent, blank line between
  statements, trailing-comma-free/leading-comma-free column lists,
  upper-case keywords) are this plan's proposed house style, not
  something spec.md or the parent plan constrains — worth confirming
  before or shortly after implementation, since changing it later means
  rewriting every literal-string test built against it.
