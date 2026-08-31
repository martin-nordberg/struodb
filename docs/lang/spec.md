# StruoDB Query Language — Specification

## Status

Part I specifies the **lexical structure** (keywords, identifiers, literals,
operators/punctuation, comments) of the StruoDB query language. Part II
specifies its **grammar**: expressions and function calls (§8), which
`CREATE STREAM` (§9), `ALTER STREAM` (§10), and `INSERT` (§11) all depend
on, plus those three statements themselves — only querying or subscribing
to a stream's events is still out of scope (see §7, §12). See §13 for
design decisions that are settled but not fully reflected below, and
"Remaining open details" at the end for what's still undecided.

## Purpose

StruoDB is an event-stream-oriented query language that transpiles to
PostgreSQL. Where this spec is silent, the language follows PostgreSQL's own
conventions (case folding, quoting, comment syntax) so that the language
feels native to anyone who already knows SQL, and so the transpiler can stay
close to a straightforward syntactic mapping.

# Part I: Lexical Specification

## 1. Case Sensitivity

StruoDB follows PostgreSQL convention:

- Keywords are case-insensitive (`CREATE`, `create`, and `CrEaTe` are
  equivalent).
- Unquoted identifiers are case-insensitive and are folded to lower case
  when interpreted (`Foo` and `foo` refer to the same identifier; the
  transpiled PostgreSQL identifier is `foo`).
- Quoted identifiers (see below) preserve case exactly as written and are
  case-sensitive (`"Foo"` and `"foo"` are distinct identifiers).

## 2. Identifiers

- **Unquoted identifiers**: begin with a letter (`A`–`Z`, `a`–`z`) or
  underscore (`_`), followed by zero or more letters, digits, or
  underscores. Folded to lower case per §1.
- **Quoted identifiers**: delimited by double quotes (`"..."`), may contain
  any character including whitespace and keywords, and are case-sensitive.
  A literal double quote inside a quoted identifier is written as two
  consecutive double quotes (`""`), matching PostgreSQL.
- **Length limit**: an identifier (quoted or unquoted) longer than 63 bytes
  is silently truncated to 63 bytes, matching PostgreSQL's default
  `NAMEDATALEN`-based behavior — not rejected as an error. Two identifiers
  that differ only after byte 63 are therefore indistinguishable. This
  describes the identifier's meaning once it reaches PostgreSQL — since
  StruoDB transpiles straight to PostgreSQL SQL, PostgreSQL's own
  truncation (already correct and encoding-aware) is what actually
  applies; nothing here requires StruoDB itself to perform or replicate
  that truncation before then.

## 3. Keywords

Keywords are grouped below by role. Unlike PostgreSQL — which splits
keywords into reserved and non-reserved categories, the latter usable as
identifiers in most positions — every StruoDB keyword is **reserved**: none
of the words below may be used as an unquoted identifier, regardless of
grammar position. (A quoted identifier, §2, is unaffected — `"create"` is
always a valid identifier.)

### 3.1 Data Type Keywords
* BIGINT
* BOOLEAN
* CHAR
* DATE
* DECIMAL
* DOUBLE
* HLC
* INT
* INTEGER
* INTERVAL
* JSON
* JSONB
* NUMERIC
* PRECISION
* REAL
* SMALLINT
* TEXT
* TIME
* TIMESTAMP
* TIMESTAMPTZ
* UUID
* VARCHAR

`HLC` is a fixed-width value — see §9.2 — and is not parameterized (unlike
`CHAR`/`VARCHAR`/`DECIMAL`).

### 3.2 Value Keywords
* FALSE
* NULL
* TRUE

### 3.3 Query Structure Keywords
* ADD
* ALTER
* ALWAYS
* AS
* CHECK
* COLUMN
* CONFLICT
* CONSTRAINT
* CREATE
* DEFAULT
* DO
* DROP
* GENERATED
* INSERT
* INTO
* NOTHING
* ON
* OPTIONAL
* RETURNING
* STORED
* STREAM
* TYPE
* VALUES
* VIRTUAL

`ALWAYS` and `GENERATED` appear together, in that fixed order, in a
generated-column clause, followed by either `STORED` or `VIRTUAL` (§9.4);
none of the four stands alone. Unlike PostgreSQL, where `COLUMN` may be
omitted from `ADD`/`DROP`/`ALTER COLUMN` (§10), StruoDB requires it, for
the same explicitness-over-brevity reasons `CONSTRAINT constraint_name` is
mandatory (§9.5). `ON`, `CONFLICT`, `DO`, and `NOTHING` appear together as
the fixed sequence `ON CONFLICT DO NOTHING` (§11.5); there is no `DO
UPDATE` form. Built-in functions such as
`TIMESTAMPTZ_FROM_HLC` (§8.3) are deliberately **not** keywords — see §8.3
for why.

### 3.4 Expression Keywords
* AND
* BETWEEN
* DISTINCT
* FROM
* ILIKE
* IN
* IS
* LIKE
* NOT
* OR
* SIMILAR
* TO

`SIMILAR` and `TO` appear together as `SIMILAR TO` (§8.1); `DISTINCT` and
`FROM` appear together as `IS [NOT] DISTINCT FROM` (§8.1); neither stands
alone. `FROM` is not (yet) usable to introduce a table list the way it is
in PostgreSQL's `SELECT` — see §12.

## 4. Literals

### 4.1 Boolean and Null Literals
Written using the keywords `TRUE`, `FALSE`, and `NULL` (§3.2).

### 4.2 Numeric Literals

Following PostgreSQL/SQL-standard form:

- **Integer literal**: one or more decimal digits (`0`, `42`, `007`).
- **Numeric (decimal) literal**: a decimal point with digits on at least
  one side — `digits.digits` (`3.14`), `digits.` (`3.`), or `.digits`
  (`.14`).
- **Exponent suffix**: either form above may be followed by
  `[eE][+-]?digits` for scientific notation (`1e10`, `1.5e-3`, `2E5`).
  `1e10` is itself an integer-valued numeric literal, not an integer
  literal — same as in PostgreSQL.
- **Digit-group separator**: an underscore may appear between two digits
  for readability (`1_000_000`), matching PostgreSQL 16+. It may not lead,
  trail, double up, or sit next to the decimal point or exponent marker
  (`_1`, `1_`, `1__0`, `1_.5`, `1._5`, `1e_5` are all invalid).
- No sign (`+`/`-`) is part of a numeric literal; a leading sign is the
  unary arithmetic operator (§5.1) applied to the literal, per SQL
  convention, not part of the token itself.

Not included: PostgreSQL's `0x`/`0o`/`0b` non-decimal integer literals
(added in PostgreSQL 16). Decimal is the only base for now; see "Remaining
open details" below.

### 4.3 String Literals

Delimited by single quotes: `'...'`. A literal single quote inside the
string is written by doubling it (`'it''s'`), matching PostgreSQL/the SQL
standard.

- No backslash-escape processing inside a plain `'...'` literal — `\n`
  inside one is the two characters backslash and `n`, not a newline. (This
  matches PostgreSQL's default; it does not affect the *decoding* of
  JSON/JSONB payloads, only the outer SQL string syntax.)
- Two string literals separated only by whitespace containing at least one
  newline are concatenated into a single literal (`'foo'` newline `'bar'`
  is equivalent to `'foobar'`), matching PostgreSQL/the SQL standard —
  useful for splitting one long literal across lines.

Not included, deferred: PostgreSQL's `E'...'` backslash-escape string
syntax and its `$$...$$` / `$tag$...$tag$` dollar-quoted strings (the
latter mainly earns its keep for function bodies, which StruoDB doesn't
have yet). See "Remaining open details" below.

## 5. Operators and Punctuation

Multi-character operators are tokenized by longest match (maximal munch),
matching PostgreSQL. This matters more now that several operators share a
leading character: `<` / `<=` / `<>` / `<<` / `<@`; `>` / `>=` / `>>`;
`-` / `->` / `->>`; `#` / `#>` / `#>>`; `|` / `||`; `~` / `~*`; `!=` / `!~`
/ `!~*`.

### 5.1 Arithmetic Operators
* `+`
* `-`
* `*`
* `/`
* `%`
* `^` — exponentiation

### 5.2 Comparison Operators
* `=`
* `>`
* `<`
* `<=`
* `>=`
* `<>`
* `!=`

### 5.3 String Operators
* `||` — string concatenation, matching PostgreSQL/the SQL standard
  (`'foo' || 'bar'` evaluates to `'foobar'`).

### 5.4 Bitwise Operators
* `&` — AND
* `|` — OR
* `#` — XOR
* `~` — NOT (prefix/unary only)
* `<<` — shift left
* `>>` — shift right

Meaningful on the integer types (§3.1: `SMALLINT`/`INT`/`INTEGER`/
`BIGINT`), matching PostgreSQL's own bitwise operators. `~` is also used,
in binary/infix position, as a regex-match operator (§5.5) — the two
don't conflict since PostgreSQL itself overloads `~` the same way,
disambiguated by arity/operand type (prefix on an integer vs. infix
between two text values) rather than by separate tokens.

### 5.5 Regex Operators
* `~` — matches (POSIX regular expression)
* `~*` — matches, case-insensitive
* `!~` — does not match
* `!~*` — does not match, case-insensitive

Meaningful on the string types (§3.1: `TEXT`/`CHAR`/`VARCHAR`), matching
PostgreSQL's own regex-match operators (POSIX extended regular
expressions).

### 5.6 JSON Operators
* `->` — get JSON object field or array element, as `JSON`/`JSONB`
* `->>` — get JSON object field or array element, as text
* `#>` — get JSON object at the given path, as `JSON`/`JSONB`
* `#>>` — get JSON object at the given path, as text
* `@>` — contains
* `<@` — contained by

Meaningful on the `JSON`/`JSONB` types (§3.1), matching PostgreSQL's own
JSON/JSONB operators.

### 5.7 Typecast
* `::` — PostgreSQL-style typecast (`expr :: data_type`), matching
  PostgreSQL directly rather than the SQL-standard `CAST(expr AS type)`
  (which isn't included — see "Remaining open details").

### 5.8 Punctuation
* `(` `)` — grouping
* `,` — list separator
* `;` — statement terminator
* `.` — qualified-name separator

### 5.9 Context-Dependent Symbols
* `*` also serves double duty as the arithmetic multiplication operator
  (§5.1) and, in SQL, conventionally as a "select all columns" wildcard.
  Which meanings apply, and how the grammar disambiguates them, is not yet
  defined.

## 6. Comments

* `-- ...` — single-line comment, extending to the end of the line.
* `/* ... */` — multi-line (block) comment. These nest, matching
  PostgreSQL (`/* outer /* inner */ still in outer */` is one comment).

# Part II: Grammar

## 7. Scope

`CREATE STREAM` and `ALTER STREAM` — declaring a stream's shape and
evolving it — `INSERT` (§11, appending events to a stream), and the
expression/function call grammar all three depend on, are specified below.
Querying or subscribing to a stream's events is entirely out of scope for
now — no syntax, keywords, or semantics for it are decided (§12).

A stream's shape is a **fixed schema**, declared up front like
PostgreSQL's `CREATE TABLE` — named, typed columns — rather than a
schema-flexible envelope (e.g. a CloudEvents-style envelope with a
JSON/JSONB payload).

## 8. Expressions and Function Calls

Expressions appear wherever `CREATE STREAM` (§9) or `ALTER STREAM` (§10)
takes an `expr` — in `DEFAULT`, `GENERATED ALWAYS AS (...)`, and
`CHECK (...)` clauses — and will be reused as-is once `WHERE`-like
querying syntax exists (§12).

### 8.1 Grammar

```
expr ::= literal
       | column_ref
       | unary_op expr
       | expr binary_op expr
       | expr '::' data_type
       | expr [NOT] BETWEEN bound_expr AND bound_expr
       | expr [NOT] IN '(' expr (',' expr)* ')'
       | expr [NOT] LIKE bound_expr
       | expr [NOT] ILIKE bound_expr
       | expr [NOT] SIMILAR TO bound_expr
       | expr IS [NOT] NULL
       | expr IS [NOT] TRUE
       | expr IS [NOT] FALSE
       | expr IS [NOT] DISTINCT FROM bound_expr
       | function_call
       | '(' expr ')'

literal ::= numeric_literal | string_literal | TRUE | FALSE | NULL   -- §4

column_ref ::= identifier

function_call ::= identifier '(' ( expr (',' expr)* )? ')'

unary_op ::= '+' | '-' | '~' | NOT

binary_op ::= '+' | '-' | '*' | '/' | '%' | '^'
            | '||' | '&' | '|' | '#' | '<<' | '>>'
            | '~' | '~*' | '!~' | '!~*'
            | '->' | '->>' | '#>' | '#>>' | '@>' | '<@'
            | '=' | '<' | '>' | '<=' | '>=' | '<>' | '!='
            | AND | OR
```

`data_type` is as defined in §9.1 (no `CAST(expr AS type)` alternate form
— see "Remaining open details"). The `IN` list is always an explicit
parenthesized expression list; there's no subquery form (`IN (SELECT
...)`) since no querying syntax exists yet (§12).

`bound_expr` is `expr` restricted to precedence level 6 or tighter
(§8.2) — i.e. any `expr` production except the `BETWEEN`/`IN`/`LIKE`/
`ILIKE`/`SIMILAR TO` (level 7), comparison (level 8), `IS` (level 9),
`NOT` (level 10), `AND` (level 11), and `OR` (level 12) alternatives
above. `BETWEEN`'s bounds, `LIKE`/`ILIKE`/`SIMILAR TO`'s pattern, and
`IS DISTINCT FROM`'s right side use `bound_expr` rather than the
unrestricted `expr` so that, matching PostgreSQL, an operator looser than
level 7 doesn't get silently absorbed into them — `a LIKE b OR c` parses
as `(a LIKE b) OR c`, not `a LIKE (b OR c)`. `IN`'s list items don't need
this restriction: each sits inside explicit `(...)`/`,` delimiters, which
already make the boundary unambiguous, so they use the unrestricted
`expr`.

`identifier` is as defined in §2. A `column_ref` is currently always
unqualified — no stream/table-qualified form (`stream_name.column_name`)
is specified yet, since expressions today only appear inside the
`CREATE STREAM`/`ALTER STREAM` that defines the columns they reference;
qualification will matter once multi-stream querying (§12) exists.

### 8.2 Operator Precedence

Following PostgreSQL's own precedence table exactly, highest (tightest
binding) to lowest:

1. `::` (typecast) — left-associative
2. Unary `+` `-` — right-associative
3. `^` (exponentiation) — left-associative
4. `*` `/` `%` — left-associative
5. Binary `+` `-` — left-associative
6. All other operators — left-associative: `||`, `&`, `|`, `#`, `<<`,
   `>>`, `->`, `->>`, `#>`, `#>>`, `@>`, `<@`, infix `~`/`~*`/`!~`/`!~*`
   (regex match), and prefix `~` (bitwise NOT)
7. `BETWEEN` / `IN` / `LIKE` / `ILIKE` / `SIMILAR TO`
8. `=` `<` `>` `<=` `>=` `<>` `!=` (non-associative)
9. `IS [NOT] NULL` / `IS [NOT] TRUE` / `IS [NOT] FALSE` /
   `IS [NOT] DISTINCT FROM`
10. `NOT` — right-associative
11. `AND` — left-associative
12. `OR` — left-associative

Parentheses `( )` override precedence as usual.

**A PostgreSQL quirk worth flagging, since it's non-obvious and this spec
follows PostgreSQL's grammar exactly here:** only unary `+`/`-` get the
tight "level 2" binding. Prefix `~` (bitwise NOT, §5.4) is not special-cased
the same way — it sits at level 6 with the other binary operators, which
is *looser* than arithmetic. So `~1 + 2` parses as `~(1 + 2)`, not
`(~1) + 2`. Parenthesize `~` operands when in doubt.

This table is now a complete match for the operators/keywords StruoDB
defines; the only PostgreSQL precedence-table entries it still doesn't
populate are `[ ]` (array subscript) and `.` (table/column separator used
within an expression) — no array types and no qualified `column_ref` form
exist yet.

### 8.3 Function Calls

A function call is an identifier immediately followed by `(`, a
comma-separated list of zero or more expressions, and `)` — e.g.
`TIMESTAMPTZ_FROM_HLC(reading_hlc)`. Function names are **ordinary
identifiers, not keywords** — recognized by the transpiler only in
function-call position, the same way PostgreSQL's own built-in functions
like `now()` or `count()` aren't reserved words. A stream or column may be
named `timestamptz_from_hlc` without conflict; only its use immediately
followed by `(` is interpreted as a call.

No user-defined functions exist in StruoDB yet — only built-ins (starting
with `TIMESTAMPTZ_FROM_HLC`, §9.7) can appear in function-call position.

## 9. CREATE STREAM

### 9.1 Synopsis

```
create_stream_stmt ::= CREATE STREAM stream_name '(' stream_element (',' stream_element)* ')' ';'?

stream_element ::= column_def
                  | table_constraint

column_def ::= column_name data_type column_clause*

column_clause ::= OPTIONAL
                 | DEFAULT expr
                 | GENERATED ALWAYS AS '(' expr ')' (STORED | VIRTUAL)
                 | CONSTRAINT constraint_name CHECK '(' expr ')'

table_constraint ::= CONSTRAINT constraint_name CHECK '(' expr ')'
```

`stream_name`, `column_name`, and `constraint_name` are identifiers (§2).
`expr` is defined in §8. `data_type` is formally:

```
data_type ::= BIGINT
            | BOOLEAN
            | CHAR ('(' integer_literal ')')?
            | DATE
            | DECIMAL ('(' integer_literal (',' integer_literal)? ')')?
            | DOUBLE PRECISION
            | HLC
            | INT
            | INTEGER
            | INTERVAL
            | JSON
            | JSONB
            | NUMERIC ('(' integer_literal (',' integer_literal)? ')')?
            | REAL
            | SMALLINT
            | TEXT
            | TIME
            | TIMESTAMP
            | TIMESTAMPTZ
            | UUID
            | VARCHAR ('(' integer_literal ')')?
```

`integer_literal` is as defined in §4.2. Per PostgreSQL convention:

- `CHAR`/`VARCHAR`'s `(n)` is optional; bare `CHAR` defaults to length 1,
  bare `VARCHAR` to unlimited length. Where given, `n` must be at least 1.
- `DECIMAL`/`NUMERIC`'s `(p)` or `(p, s)` is optional; bare `DECIMAL`/
  `NUMERIC` is unconstrained precision/scale. Where given, `p` (precision)
  must be at least 1, and `s` (scale, default 0 if only `p` is given) must
  satisfy `0 <= s <= p`.
- `DOUBLE` is **always** followed by `PRECISION` — the two keywords
  (§3.1) together name one type, `DOUBLE PRECISION`; `DOUBLE` alone is not
  a valid `data_type`.
- Every other keyword above is bare, with no parameters.

This grammar doesn't express the semantic constraint in §9.2 (exactly one
column must be typed `HLC`), the restriction in §9.4 (a `DEFAULT`
expression may not reference a sibling column), or the uniqueness
requirements below; all are enforced as semantic checks, not by the
productions above.

- **`column_name` must be unique within a stream** — a stream with two
  columns of the same name is a compile-time error. (Unstated in earlier
  drafts of this spec, but necessary: without it, a `column_ref` in an
  `expr`, or a target in `ALTER STREAM`'s `DROP COLUMN`/`ALTER COLUMN`,
  would be ambiguous.)
- **`constraint_name` must be unique within a stream**, across both
  column-level and table-level `CHECK`s — see §9.5.

Whether `column_clause`s may repeat, combine freely, or must appear in a
particular order (e.g. can a column have both `DEFAULT` and `CHECK`?) is
not yet constrained — see "Remaining open details."

### 9.2 The HLC Column

Every stream must declare **exactly one** column of type `HLC`. That
column automatically becomes the `PRIMARY KEY` of the transpiled table —
no `PRIMARY KEY` keyword exists or is needed. Unlike the earlier design
(an implicit, reserved, client-populated column not visible in
`CREATE STREAM`), the column is now ordinary: user-named, declared like
any other column, and — per §9.3 — implicitly `NOT NULL` as a consequence
of being the primary key.

Its value is supplied by the client using the hybrid logical clock already
implemented in this repo (see `docs/hlc/spec.md`) and, being an ordinary
column, is written like any other value in `INSERT` (§11) — a plain string
literal (§4.3) holding the HLC's 15-character encoding.

A node that sends a duplicate HLC value is misbehaving (HLC values must
be unique per docs/hlc/spec.md's node-ID discipline); the transpiled
table's `PRIMARY KEY` constraint is what actually rejects it, unless
`INSERT`'s `ON CONFLICT DO NOTHING` (§11.5) is used to absorb it silently.
No additional StruoDB-level uniqueness logic is needed — this is a
consequence of §9.2, not new machinery.

Marking the `HLC` column `OPTIONAL` (§9.3) is a **compile-time error**: it
contradicts the column's role as primary key. So is giving it a `DEFAULT`
or `GENERATED ALWAYS AS (...)` clause (§9.4): the entire point of the
column is that only the client — via its own hybrid logical clock state —
knows the correct value to assign; a server-computed default would
undermine that and risks producing non-monotonic or colliding values
across nodes. This wasn't stated when §9.4 was written and is a gap this
pass closes.

### 9.3 Nullability

Columns are `NOT NULL` by default after transpiling to PostgreSQL — the
opposite of PostgreSQL's own default (nullable unless `NOT NULL` is
written). This is a deliberate, intentional divergence from PostgreSQL
convention, not an oversight — everywhere else this spec follows
PostgreSQL's conventions, this one case does not. The `OPTIONAL` keyword
marks a column nullable; writing `NOT NULL` explicitly on a column
definition is a **compile-time error** rather than a legal, redundant
no-op — it is already the default, and permitting it would just invite
writing `NOT NULL OPTIONAL` or otherwise implying the two are independent
toggles rather than one one-way switch. `NOT` (§3.4) and `NULL` (§3.2)
remain keywords for other purposes (e.g. within `expr`, §8.1); this
grammar just doesn't attach a column-clause meaning to writing them
together.

### 9.4 Defaults and Generated Columns

Two distinct clauses, matching PostgreSQL's own distinction and its own
restrictions — deliberately not merged into one, because they have
different rules about what the expression may reference:

- **`DEFAULT expr`** — `expr` is evaluated at insert time and may not
  reference another column of the same row, matching PostgreSQL's own
  restriction on plain `DEFAULT` clauses. This isn't an extra check
  StruoDB needs to implement: transpiling `DEFAULT expr` straight to
  PostgreSQL's own `DEFAULT expr` means PostgreSQL's existing restriction
  applies for free.
- **`GENERATED ALWAYS AS (expr) STORED`** or **`... VIRTUAL`** — `expr`
  *may* reference other columns of the same row, matching PostgreSQL's own
  generated columns (which this transpiles straight to):
  - `STORED` computes the value at insert/update time and physically
    stores it, like a regular column.
  - `VIRTUAL` computes the value at read time instead, storing nothing.

  One of the two must be written explicitly — there is no default if
  omitted. `STORED` is the form the example in §9.7 needs.

### 9.5 Constraints

- **`CONSTRAINT constraint_name CHECK (expr)`** may appear attached to a
  single column (`column_def`) or as a standalone `table_constraint`.
  Unlike PostgreSQL, naming is **not optional**: an unnamed `CHECK` would
  transpile to a system-assigned name (e.g. PostgreSQL's own
  `stream_column_check` pattern), which complicates later schema
  evolution — a migration that needs to drop or alter the constraint has
  to already know or look up that generated name. Requiring
  `CONSTRAINT constraint_name` up front avoids that entirely.
- **`constraint_name` must be unique within a stream** — a second
  `CONSTRAINT` of the same name, whether column-level or table-level, is
  a compile-time error. This is what makes `ALTER STREAM`'s
  `DROP CONSTRAINT constraint_name`/`ADD CONSTRAINT constraint_name`
  (§10.5) unambiguous by name alone, the same way `column_name`
  uniqueness (§9.1) makes `DROP COLUMN`/`ALTER COLUMN` unambiguous.
- **No `UNIQUE` constraint** exists for a stream, apart from the implicit
  primary-key uniqueness on its `HLC` column (§9.2).
- **Streams have no foreign keys.**

### 9.6 Built-in Functions

See §8.3 for the general rule (ordinary identifiers, not keywords).
`TIMESTAMPTZ_FROM_HLC` (used in §9.7 to derive a `TIMESTAMPTZ` from an
`HLC` value's embedded physical-time field) is the first built-in
function defined.

### 9.7 Example

```
CREATE STREAM sensor_reading (
    reading_hlc HLC,
    reading_time TIMESTAMPTZ GENERATED ALWAYS AS (TIMESTAMPTZ_FROM_HLC(reading_hlc)) STORED,
    reading REAL CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 100),
    units VARCHAR(32),
    sensor_id VARCHAR(24),
    notes VARCHAR(200) OPTIONAL
);
```

(This corrects two things from the original working draft: `FLOAT` →
`REAL`, since `FLOAT` isn't a data type keyword (§3.1); and `reading_time`
now uses `GENERATED ALWAYS AS (...) STORED` rather than `DEFAULT`, since
its expression references the sibling column `reading_hlc` — see §9.4.)

## 10. ALTER STREAM

`ALTER STREAM` works analogously to PostgreSQL's `ALTER TABLE`, with
several deliberate semantic restrictions specific to an event stream's
schema evolution: a column may not be dropped unless it's `OPTIONAL`, an
added column must be `OPTIONAL` or carry a default/generated value, a
replaced `CHECK` constraint must be stronger than what it replaced, and a
column's type may only widen, never narrow. The unifying goal behind all
of these restrictions is that a schema change made through `ALTER STREAM`
is always **backwards compatible** — nothing that was a valid row before
the change can become invalid after it.

### 10.1 Synopsis

```
alter_stream_stmt ::= ALTER STREAM stream_name alter_action (',' alter_action)* ';'?

alter_action ::= ADD COLUMN column_def
               | DROP COLUMN column_name
               | ALTER COLUMN column_name TYPE data_type
               | ADD CONSTRAINT constraint_name CHECK '(' expr ')'
               | DROP CONSTRAINT constraint_name
```

`column_def` and `data_type` are as defined in §9.1; `expr` as in §8.
Multiple `alter_action`s may appear in one statement, comma-separated,
matching PostgreSQL's own `ALTER TABLE` — this is assumed rather than
confirmed; flag it if a single action per statement is preferred instead.
`COLUMN` is mandatory here (§3.3), unlike PostgreSQL where it's optional.

### 10.2 Adding Columns

`ADD COLUMN column_def` appends a new column, using the same `column_def`
grammar as `CREATE STREAM` (§9.1). Existing rows have no value for a
brand-new column, and columns are `NOT NULL` by default (§9.3), so the
added `column_def` **must** include at least one of:

- `OPTIONAL` (§9.3), or
- `DEFAULT expr` (§9.4), or
- `GENERATED ALWAYS AS (...) STORED`/`VIRTUAL` (§9.4)

Adding a second column of type `HLC` is a **compile-time error** — exactly
one `HLC` column per stream is fixed at `CREATE STREAM` time (§9.2) and
can't change.

### 10.3 Dropping Columns

`DROP COLUMN column_name` removes a column, allowed **only if the column
is `OPTIONAL`** — a `NOT NULL` column may not be dropped. Since the `HLC`
column can never be `OPTIONAL` (§9.2), this rule already makes it
undroppable; no separate rule is needed to protect it.

### 10.4 Altering Column Types

`ALTER COLUMN column_name TYPE data_type` changes a column's declared
type, but **only to a strictly widening type** — one guaranteed to accept
every value the old type could hold, so no previously-valid row can
become invalid under the new type:

- `VARCHAR(n)` / `CHAR(n)`: `n` may increase, never decrease.
- `DECIMAL(p, s)` / `NUMERIC(p, s)`: neither the scale `s` nor the
  integer-part capacity `p - s` (digits left of the decimal point) may
  shrink. Increasing `p` alone, or increasing both `p` and `s` together,
  is fine; increasing `s` alone is **not**, since it shrinks `p - s`.
- Integer types: widening only along the chain `SMALLINT → INT`/`INTEGER
  → BIGINT`, but a jump may skip an intermediate step — `SMALLINT →
  BIGINT` directly is allowed, not just one adjacent step at a time.
- Floating-point types: widening only along `REAL → DOUBLE PRECISION`.

Narrowing, and converting between unrelated type families (e.g. `INT` to
`DECIMAL`), aren't addressed by this rule and are presumed disallowed for
now — see "Remaining open details."

### 10.5 Constraints

- `ADD CONSTRAINT constraint_name CHECK (expr)` adds a new named `CHECK`
  constraint (§9.5), validated against existing rows.
- `DROP CONSTRAINT constraint_name` removes one.
- **Replacing** a constraint is `DROP CONSTRAINT` followed by
  `ADD CONSTRAINT` under the same name — PostgreSQL itself has no way to
  alter a `CHECK` expression in place. When doing so, **the replacement
  must be stronger** than what it replaced (e.g. a smaller maximum, a
  larger minimum) — never weaker, so a value once rejected can't become
  newly accepted.

  **How this is verified is not yet decided** — checking that one
  arbitrary boolean expression logically implies another is undecidable
  in general. See "Remaining open details" for the options under
  consideration (ranging from an unenforced documented convention to a
  pattern-matched check restricted to simple numeric comparisons).

### 10.6 No Renaming

`ALTER STREAM` does not support renaming anything — not the stream, a
column, or a constraint. Once created, names are stable; this differs
deliberately from PostgreSQL's `RENAME TO`/`RENAME COLUMN`/
`RENAME CONSTRAINT`, since an event stream's readers and writers
referencing a name are more exposed to a silent rename than an ordinary
table's would be.

### 10.7 Example

```
ALTER STREAM sensor_reading
    ADD COLUMN calibration_id VARCHAR(24) OPTIONAL,
    ALTER COLUMN units TYPE VARCHAR(64),
    DROP CONSTRAINT reading_in_range,
    ADD CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 90);
```

(Widens `units` from `VARCHAR(32)` to `VARCHAR(64)` — legal per §10.4 —
adds an optional column, and replaces `reading_in_range` with a stricter
bound, 90 instead of 100, as required by §10.5.)

## 11. INSERT

`INSERT` appends events to a stream. It follows standard SQL/PostgreSQL
`INSERT` closely, with restrictions and one addition specific to how
streams are shaped (§9): an always-explicit column list, `GENERATED`
columns excluded from it entirely, and an idempotency mechanism
(`ON CONFLICT DO NOTHING`) built in because redelivering the same event
twice is a normal occurrence for an event-sourcing client, not just an
edge case.

### 11.1 Synopsis

```
insert_stmt ::= INSERT INTO stream_name '(' column_name (',' column_name)* ')'
                VALUES value_row (',' value_row)*
                [ON CONFLICT DO NOTHING]
                [RETURNING returning_item (',' returning_item)*]
                ';'?

value_row ::= '(' value (',' value)* ')'

value ::= expr | DEFAULT

returning_item ::= '*' | expr [AS identifier]
```

`stream_name` and `column_name` are identifiers (§2); `expr` is as defined
in §8. Unlike `CREATE STREAM`/`ALTER STREAM` (§9, §10), the statement
doesn't repeat `STREAM` after `INTO` — matching plain SQL's
`INSERT INTO table_name` rather than this spec's own `CREATE`/`ALTER`
pattern.

### 11.2 Column List

The column list is **mandatory** — `INSERT INTO stream VALUES (...)` with
no column list, relying on `CREATE STREAM`'s declared column order, is not
legal. This is a deliberate divergence from standard SQL, which allows
that positional form: an explicit list is self-documenting and immune to
`ALTER STREAM` (§10) changing a stream's column order or count over time.

The list may still be a **subset** of the stream's columns — any column
left out is resolved the same way a bare `DEFAULT` value would be
(§11.3): its own `DEFAULT`/`GENERATED` clause if it has one, `NULL` if
it's `OPTIONAL` with neither, or an insert-time error if it's `NOT NULL`
with neither. The `HLC` column (§9.2) has no `DEFAULT`/`GENERATED` clause
and is never `OPTIONAL`, so it can never be left out in practice — it must
always appear in the column list with an explicit value.

### 11.3 Values

Each `value_row` supplies one value per column in the column list,
positionally. A `value` is either a general expression (§8) or the bare
keyword `DEFAULT`, which stands for that column's own `DEFAULT` expression
(§9.4) — or `NULL`, if the column is `OPTIONAL` and has no `DEFAULT` — the
same resolution described in §11.2 for an omitted column, just spelled out
explicitly instead of left out.

There's no `INSERT ... SELECT` form — only `VALUES` — since no querying
grammar exists yet (§12).

### 11.4 Generated Columns

A column declared `GENERATED ALWAYS AS (...)` (§9.4) may **never** appear
in the column list, not even paired with the `DEFAULT` placeholder value.
This is simpler than PostgreSQL, which allows `DEFAULT` specifically for a
generated column while rejecting any other value; StruoDB just excludes
generated columns from the column list entirely, since they're never
something an `INSERT` supplies — they're always computed from the row
being inserted.

### 11.5 Conflict Handling

`ON CONFLICT DO NOTHING`, if present, makes a duplicate `HLC` value a
silent no-op instead of a `PRIMARY KEY`-violation error — for absorbing
redelivered/retried events, which is routine for an event-sourcing client,
not exceptional. No conflict target (a column list or constraint name, as
PostgreSQL's `ON CONFLICT` generally requires or allows) is written or
needed: a stream has exactly one possible source of conflict, its `HLC`
primary key (§9.5 — there's no `UNIQUE` constraint to disambiguate
between), so `ON CONFLICT DO NOTHING` is unambiguous as written.

There is no `DO UPDATE` form. Streams are an append-only log; silently
rewriting a previously-inserted row on conflict doesn't fit that model,
so only the no-op form is offered.

The clause is optional. Without it, a duplicate `HLC` is a hard error,
exactly as it would be in plain SQL.

### 11.6 RETURNING

`RETURNING` mirrors PostgreSQL: `*` for every column of the inserted row,
or a comma-separated list of expressions (each optionally aliased with
`AS identifier`), evaluated against the row as it was actually written —
including any `GENERATED` column's computed value (§9.4), which is
otherwise not knowable to the client in advance. One result row is
returned per row actually inserted; a row skipped by
`ON CONFLICT DO NOTHING` (§11.5) produces no `RETURNING` output at all, so
`RETURNING` doubles as a way to tell whether a given retry actually
inserted anything new.

### 11.7 Example

```
INSERT INTO sensor_reading (reading_hlc, reading, units, sensor_id)
VALUES ('01a2B3c4D5e6f70abcde', 42.5, 'celsius', 'sensor-001')
ON CONFLICT DO NOTHING
RETURNING reading_hlc, reading_time;
```

(`reading_time`, `GENERATED ALWAYS AS (...) STORED` in §9.7's
`CREATE STREAM`, is correctly omitted from the column list per §11.4, and
its computed value is read back via `RETURNING` per §11.6. `notes`,
`OPTIONAL` with no `DEFAULT`, is omitted from the column list and
resolves to `NULL` per §11.2.)

## 12. Querying and Subscribing

Deferred entirely — not yet specified whether, or how, a stream's events
can be queried (SQL-`SELECT`-like, historical) or subscribed to (a
standing "watch for new events" query).

## 13. Settled Design Decisions

Architectural decisions that are settled, recorded here so the choices
above can be read in context and aren't re-litigated later:

- **Scope, for now: expressions/function calls, `CREATE STREAM`,
  `ALTER STREAM`, and `INSERT`.** See §7.
- **Fixed per-stream schema.** See §7.
- **The `HLC` column is ordinary, user-declared, and exactly one per
  stream** — see §9.2. (This supersedes an earlier design where the
  event-time column was implicit, reserved, and invisible in
  `CREATE STREAM`; that design's open questions — the column's reserved
  name, its exact type, and how a client would supply its value through
  `INSERT` — are moot now that the column is just a normal, user-named,
  user-typed column like any other.)
- **`NOT NULL` by default; `OPTIONAL` for nullable; explicit `NOT NULL` is
  a compile-time error.** A deliberate inversion of PostgreSQL's own
  default — see §9.3.
- **`DEFAULT` vs. `GENERATED ALWAYS AS (...) STORED/VIRTUAL` kept
  distinct**, matching PostgreSQL's own distinction and restrictions — see
  §9.4.
- **`data_type` has a formal grammar**, matching PostgreSQL's own
  parameter defaults/bounds for `CHAR`/`VARCHAR`/`DECIMAL`/`NUMERIC`, with
  `DOUBLE PRECISION` as the one two-keyword type. See §9.1.
- **`column_name` and `constraint_name` must each be unique within a
  stream** — required for `column_ref`, `DROP COLUMN`/`ALTER COLUMN`, and
  `DROP CONSTRAINT`/`ADD CONSTRAINT` to resolve a name unambiguously. See
  §9.1, §9.5.
- **Built-in functions are ordinary identifiers, not keywords.** See §8.3.
- **`CHECK` constraints must be named — no unnamed form.** A deliberate
  divergence from PostgreSQL, which allows omitting `CONSTRAINT
  constraint_name`; StruoDB requires it so schema evolution never has to
  look up a system-generated name. See §9.5.
- **No `UNIQUE`, no foreign keys.** See §9.5.
- **All keywords reserved.** See §3.
- **Expression grammar and precedence follow PostgreSQL**, restricted to
  the operators/keywords StruoDB currently defines. See §8.
- **`BETWEEN`'s bounds, `LIKE`/`ILIKE`/`SIMILAR TO`'s pattern, and
  `IS DISTINCT FROM`'s right side bind at precedence level 6 or tighter
  (`bound_expr`), not full `expr`** — so an operator looser than level 7
  (`OR`, `AND`, another comparison, etc.) isn't silently absorbed into
  them, matching PostgreSQL. `IN`'s list items are unaffected, since
  their `(...)`/`,` delimiters already make the boundary unambiguous. See
  §8.1.
- **All of PostgreSQL's remaining common operators added**: `::`
  (typecast), `^` (exponentiation), bitwise (`&` `|` `#` `~` `<<` `>>`),
  regex-match (`~` `~*` `!~` `!~*`), JSON/JSONB (`->` `->>` `#>` `#>>`
  `@>` `<@`), and the keyword-form operators `BETWEEN`/`IN`/`LIKE`/
  `ILIKE`/`SIMILAR TO`/`IS [NOT] NULL`/`IS [NOT] TRUE`/`IS [NOT] FALSE`/
  `IS [NOT] DISTINCT FROM` — chosen because they transpile to PostgreSQL
  directly. See §5.4–§5.7, §8.1, §8.2.
- **`ALTER STREAM` may not rename anything** (stream, column, or
  constraint) — a deliberate divergence from PostgreSQL's `ALTER TABLE`.
  See §10.6.
- **`ADD COLUMN` requires `OPTIONAL` or a `DEFAULT`/`GENERATED` clause**,
  mirroring the drop-only-if-`OPTIONAL` rule, since existing rows need a
  value for a new column. See §10.2.
- **`ALTER COLUMN ... TYPE` allows only widening changes** — string
  length, numeric precision/scale, and the integer/float widening chains
  — never narrowing. A widening change may skip an intermediate step in
  the integer chain (`SMALLINT → BIGINT` directly, not just one adjacent
  step at a time). See §10.4.
- **Replacing a `CHECK` constraint must produce a stronger constraint**,
  though the verification mechanism for that isn't decided yet. See
  §10.5.
- **The `HLC` column may not have a `DEFAULT`/`GENERATED` clause either**,
  not just not `OPTIONAL` — only the client's own hybrid logical clock
  state can produce a correct value. See §9.2.
- **`INSERT`'s column list is mandatory**, unlike standard SQL's
  positional form — self-documenting and immune to `ALTER STREAM`
  reordering columns. See §11.2.
- **`GENERATED` columns are excluded from the `INSERT` column list
  entirely** — simpler than PostgreSQL's DEFAULT-only carve-out for them.
  See §11.4.
- **`INSERT` gains a built-in `ON CONFLICT DO NOTHING`**, with no conflict
  target needed since a stream has exactly one possible source of
  conflict (its `HLC` primary key); there is no `DO UPDATE` form, since an
  append-only stream shouldn't silently rewrite a prior row. See §11.5.
- **`INSERT` supports `RETURNING`**, including reading back a `GENERATED`
  column's computed value. See §11.6.
- **`INSERT INTO stream_name` doesn't repeat `STREAM`** — matching plain
  SQL rather than `CREATE STREAM`/`ALTER STREAM`'s own pattern. See §11.1.

## Remaining open details

Not yet specified, and not blocking further design work, but worth
resolving eventually:

- Non-decimal integer literals (`0x`/`0o`/`0b`) — omitted for now (§4.2).
- `E'...'` escape strings and `$$...$$` dollar-quoted strings — omitted
  for now (§4.3); dollar-quoting in particular may be worth revisiting if
  StruoDB ever grows function-body-like syntax.
- The meaning, if any, of `*` outside arithmetic.
- Whether `column_clause`s (§9.1) may repeat, combine freely, or must
  follow a fixed order.
- Whether/how `column_ref` (§8.1) will need stream-qualification once
  multi-stream querying exists.
- Any querying/subscribing syntax (§12) — entirely unspecified.
- How "stronger" is verified when replacing a `CHECK` constraint (§10.5):
  an unenforced documented convention, a pattern-matched check restricted
  to simple numeric comparisons, or something else.
- Whether multiple `alter_action`s may really appear in one `ALTER STREAM`
  statement (§10.1) — assumed from PostgreSQL, not confirmed.
- Narrowing type changes and cross-family type changes in `ALTER COLUMN
  ... TYPE` (§10.4) — e.g. `INT` to `DECIMAL` — presumed disallowed but
  not explicitly specified.
- `LIKE`/`ILIKE`'s `ESCAPE` clause (§8.1) — PostgreSQL allows
  `LIKE pattern ESCAPE escape_char`; not included yet.
- `CAST(expr AS type)` as an alternate spelling of `::` (§5.7) — the SQL
  standard form, not included since `::` alone was requested.
- `[ ]` array subscript and `.` used within an expression (as opposed to
  as a qualified-name separator, §5.8) — the two PostgreSQL precedence-
  table entries §8.2 still doesn't populate; no array types exist yet.