# StruoDB Query Language — Codegen Implementation Plan

Implements the "Out of scope" item `docs/lang/implementation-plan.md` left
for later: turning a validated `Statement`/`Catalog` into PostgreSQL SQL
text. Read `spec.md` and `implementation-plan.md` first — this plan builds
directly on `token`/`lexer`/`ast`/`parser`/`catalog`/`semantic` as they
exist today and doesn't re-derive their design decisions.

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
- **`parser.gleam` gains `pub fn parse_many`; `semantic.gleam` gains
  nothing new.** Multi-statement parsing needs access to "parse one
  statement, then report the leftover tokens" — currently private inside
  `parser.gleam` (`pub fn parse` immediately asserts EOF after one
  statement) — so that has to become new public API there. Folding
  `semantic.analyze` over a `List(Statement)` with a threaded `Catalog`,
  by contrast, is a three-line recursive fold any caller can write
  itself; adding an `analyze_many` to `semantic.gleam` would grow its
  public surface for no real reuse benefit, so that fold lives privately
  in `codegen.gleam` instead.
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
- **Generated identifiers are always double-quoted.** `ast.gleam`'s name
  fields (`Statement.name`, `ColumnDef.name`, `NamedCheck.constraint_name`,
  etc.) are plain `String` with no memory of whether the source spelled
  them as a bare `Identifier` (already lower-cased by the lexer, §1) or a
  case-preserving `QuotedIdentifier` — that distinction is genuinely gone
  by the time an AST exists. The tempting fix, re-quote only when the
  string's own content requires it (contains uppercase/non-`[a-z0-9_]`
  characters, or starts with a digit), is *almost* sufficient — a
  bare-source name is always already all-lowercase `[a-z_][a-z0-9_]*` by
  construction, so it'd never be spuriously re-quoted, and a
  quoted-source name needing quoting is exactly what that check catches
  — except it can't know PostgreSQL's own reserved-word list (not tracked
  anywhere in this codebase, and StruoDB's own reserved words, spec.md
  §3, are a much smaller, different set that offers no help here). A
  stream named `select` is completely legal, unquoted, StruoDB source
  today, but `CREATE TABLE select (...)` is a PostgreSQL syntax error.
  Always quoting sidesteps needing that list at all, at the cost of
  slightly noisier output for the common all-lowercase case — flagged as
  an open question below in case that trade is unwanted. Function-call
  names are the one exception: emitted bare, lower-case, unquoted, since
  today they're only ever one of a small, project-controlled set of
  built-ins (§8.3), not arbitrary user-chosen identifiers, so the same
  reserved-word concern doesn't apply.
- **The `HLC` column transpiles to `CHAR(15)`, inlined `PRIMARY KEY`, no
  explicit `NOT NULL`** (redundant once `PRIMARY KEY` is present).
  `docs/hlc/spec.md` states the encoding is fixed-width, 15 characters,
  "chosen specifically so the value fits a PostgreSQL `char(15)` column
  with no padding" — this is that decision cashed in, not a new one.
- **StruoDB's precedence table doubles as the pretty-printer's
  reparenthesization table.** `ast.gleam`'s `Expr` has no `Paren` node
  (parenthesization is only ever a parsing-time concern) and most
  variants carry no `Span`, so regenerating correct PostgreSQL text means
  re-deriving *when* a child expression needs parentheses added back —
  purely from each operator's own precedence level. Since spec.md §8.2
  is defined to match PostgreSQL's own operator precedence table exactly
  (that was the point), the same twelve levels `parser.gleam` already
  encodes are the correct levels for this, with no separate table to
  design or keep in sync.
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

```
src/lang/
  codegen.gleam       # generate, generate_standalone; CodegenError
```

One new file. `codegen.gleam` builds output with `gleam/string_tree`
(append-heavy construction, `string_tree.to_string` once at the end)
rather than repeated `String` concatenation, matching how
`gleam/string`'s own `replace` is implemented under the hood. If the
statement-emission and expression-pretty-printing code grows unwieldy in
one file, it can split into `codegen/statement.gleam` +
`codegen/expr.gleam` later — not designed that way up front, since there's
no evidence yet it needs to be.

```gleam
pub type CodegenError {
  LexFailure(lexer.LexError)
  ParseFailure(parser.ParseError)
  /// `statement_index` is 0-based, counting only statements that were
  /// successfully parsed before this one failed to validate.
  SemanticFailure(statement_index: Int, errors: List(semantic.SemanticError))
}

/// Validates every statement in `source` against `catalog` (threaded
/// across them in order, exactly as calling `semantic.analyze`
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

### `parser.gleam` additions

```gleam
/// Parses one or more `;`-separated statements from `tokens`, in order.
/// Errors (`UnexpectedEof`, reusing the existing variant) if `tokens` is
/// just `Eof` — "one or more" is not satisfied by zero.
pub fn parse_many(tokens: List(Token)) -> Result(List(Statement), ParseError)
```

Implemented by extracting the dispatch-and-return-leftover-tokens half of
today's `parse` (everything before its own `expect_eof` call) into a
private `parse_one_statement(tokens) -> Result(#(Statement, List(Token)), ParseError)`,
which both `parse` (unchanged behavior: one statement, then require EOF)
and the new `parse_many` (loop: parse one, check for `Eof` vs. more input,
repeat) call. No change to any existing public signature or test.

### `codegen.gleam`'s internal driver

```gleam
pub fn generate(catalog: Catalog, source: String) -> Result(#(String, Catalog), CodegenError) {
  use tokens <- result.try(
    lexer.tokenize(source) |> result.map_error(LexFailure),
  )
  use statements <- result.try(
    parser.parse_many(tokens) |> result.map_error(ParseFailure),
  )
  use final_catalog <- result.try(validate_all(catalog, statements, 0))
  Ok(#(render_all(statements), final_catalog))
}

fn validate_all(
  catalog: Catalog,
  statements: List(Statement),
  index: Int,
) -> Result(Catalog, CodegenError) {
  case statements {
    [] -> Ok(catalog)
    [stmt, ..rest] ->
      case semantic.analyze(catalog, stmt) {
        Ok(next_catalog) -> validate_all(next_catalog, rest, index + 1)
        Error(errors) -> Error(SemanticFailure(index, errors))
      }
  }
}

fn render_all(statements: List(Statement)) -> String {
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

`test/lang/codegen_test.gleam`, matching the existing per-module test
files' one-behavior-per-function style:

- One test per `DataType` mapping row above (both the `Some`/bare forms
  where a type takes parameters).
- Expression codegen: literal forms; each operator's textual spelling,
  including the `<>`/`!=` and `~`/regex-match distinctions; a
  precedence-driven reparenthesization case per adjacent pair of levels
  (mirroring `parser_test.gleam`'s own precedence tests, but checking
  output *text* against an expected string instead of an expected AST);
  a function call, including zero-arg.
- `CreateStream`/`AlterStream`/`Insert` codegen for spec.md's own §9.7/
  §10.7/§11.7 examples, each checked against a fully literal expected
  PostgreSQL string (see the worked examples below) — built by
  constructing the `Statement` AST directly (independent of parser
  correctness), matching how `semantic_test.gleam` tests are built.
- `generate`/`generate_standalone` end to end: the same three examples
  concatenated into one multi-statement input string, `;`-separated,
  producing all three translations in order with the `Catalog` correctly
  threaded (the `ALTER STREAM`/`INSERT` examples only validate against
  the catalog the `CREATE STREAM` example produces).
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

## Worked examples (spec.md §9.7 / §10.7 / §11.7)

Given, back to back as one multi-statement input:

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
CREATE TABLE "sensor_reading" (
  "reading_hlc" CHAR(15) PRIMARY KEY,
  "reading_time" TIMESTAMPTZ GENERATED ALWAYS AS (timestamptz_from_hlc("reading_hlc")) STORED,
  "reading" REAL NOT NULL,
  "units" VARCHAR(32) NOT NULL,
  "sensor_id" VARCHAR(24) NOT NULL,
  "notes" VARCHAR(200),
  CONSTRAINT "reading_in_range" CHECK ("reading" > 0 AND "reading" <= 100)
);

ALTER TABLE "sensor_reading"
  ADD COLUMN "calibration_id" VARCHAR(24),
  ALTER COLUMN "units" TYPE VARCHAR(64),
  DROP CONSTRAINT "reading_in_range",
  ADD CONSTRAINT "reading_in_range" CHECK ("reading" > 0 AND "reading" <= 90);

INSERT INTO "sensor_reading" ("reading_hlc", "reading", "units", "sensor_id")
VALUES
  ('01a2B3c4D5e6f70abcde', 42.5, 'celsius', 'sensor-001')
ON CONFLICT DO NOTHING
RETURNING "reading_hlc", "reading_time";
```

(This is also the concrete acceptance target for the "Statement codegen"
section above — if the actual implementation's output differs from this
in some formatting detail once written, prefer updating this block to
match reality over silently drifting, the same way `implementation-plan.md`
treats its own worked examples as living documentation.)

## Step-by-step build order

1. `parser.gleam`: extract `parse_one_statement`, add `pub fn
   parse_many` + tests (multi-statement input, the semicolon-in-a-
   string-literal case, empty input).
2. `codegen.gleam`: `data_type_to_sql`, `quote_identifier`,
   `quote_string_literal` + tests — pure, independently testable, no
   dependency on the rest of codegen.
3. `expr_to_sql` + precedence-aware reparenthesization + tests — the
   most subtle part, same reasoning as why the parent plan built the
   parser's expression grammar before its statement grammars.
4. `create_stream_to_sql` / `alter_stream_to_sql` / `insert_to_sql` +
   tests against the three worked examples above.
5. `generate` / `generate_standalone` (the `validate_all`/`render_all`
   driver) + tests, including every `CodegenError` variant.
6. `gleam test`, then a manual smoke check: feed the three-statement
   example above through `generate_standalone` and diff the result
   against the "Worked examples" block by eye.

## Issues

Open questions and known gaps this plan doesn't resolve on its own —
worth a decision before or during implementation:

- **Always-quote identifiers, or quote only when the content requires
  it?** Always-quoting sidesteps needing a PostgreSQL reserved-word list
  (which this codebase doesn't track) entirely, at the cost of noisier
  output for the overwhelmingly common all-lowercase, no-special-
  characters case (`"sensor_reading"` vs. `sensor_reading`). The
  content-based heuristic described under "Design decisions" is correct
  for everything *except* a name that happens to collide with a
  PostgreSQL reserved word — which would need that list sourced from
  somewhere (hand-maintained, or generated from PostgreSQL's own
  `pg_get_keywords()` against a target version) to close. This plan
  defaults to always-quoting; flagging in case the noisier output is
  worth avoiding.
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
