# Struo Query Language — Specification

## 1. Case Sensitivity

StruoDB follows PostgreSQL conventions:

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
- **Reserved words**: an unquoted identifier may not be one of StruoDB's
  own keywords (§3) or one of PostgreSQL's own reserved keywords (§3.5)
  either — quoting is required to use such a word as an identifier.
- **Reserved prefix**: a *new* stream, column, or constraint name (i.e.
  one being declared, not merely referenced) may not start with `_STRUO_`,
  case-insensitively, quoted or not — reserved for the automatic system
  columns (§9.2) and future system use. Unlike the length limit above,
  this is a compile-time error, not silent truncation/passthrough. It's
  checked only where a name is declared (`CREATE STREAM`/`ALTER STREAM`);
  *referencing* an existing `_STRUO_`-prefixed name (a `column_ref`, a
  `RETURNING` item) is unrestricted — it either names a real column and
  resolves normally, or it doesn't and is already an ordinary "unknown
  column"/"unknown stream" error.

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
UPDATE` form. Built-in functions, once any are defined, are deliberately
**not** keywords — see §8.3 for why.

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

### 3.5 PostgreSQL Reserved Words

None of the words below carry any meaning in StruoDB's own grammar — they
are ordinary PostgreSQL keywords, not StruoDB ones — but an unquoted
identifier may not be one of them either, on top of not being one of
§3.1–§3.4's own keywords. Specifically: the keywords PostgreSQL's own
keyword list
([sql-keywords-appendix](https://www.postgresql.org/docs/current/sql-keywords-appendix.html),
"PostgreSQL" column, as of PostgreSQL 18) categorizes as **reserved** or
**reserved (can be function or type name)**. (PostgreSQL's own
"non-reserved" keywords — e.g. `VALUE`, `TYPE`, `TEXT` — are unaffected;
only its two "reserved" categories matter here, since both require
quoting for any identifier that isn't specifically a function or type
name, which covers every identifier position this grammar has.)

This exists so that every unquoted identifier the parser accepts is
guaranteed usable, unquoted, in the transpiled PostgreSQL SQL: without
it, a stream named `table` or a column named `select` would parse
cleanly here but produce a PostgreSQL syntax error once transpiled,
since PostgreSQL itself requires these words to be quoted wherever an
identifier is expected. Enforcing it here — at the lexer, before parsing
even begins — guarantees an *unquoted* source identifier is always safe
to transpile bare: only a *quoted* source identifier can ever need
requoting on the way out (whether for its content, or because it's one
of the words below chosen deliberately, quoted), a narrower problem than
checking every identifier regardless of how it was written; see
`documentation/plans/lang/codegen-plan.md`'s identifier-quoting design
decision. A
quoted identifier is unaffected — `"table"` is always valid, same as any
other identifier, per §2.

* ALL
* ANALYSE
* ANALYZE
* AND
* ANY
* ARRAY
* AS
* ASC
* ASYMMETRIC
* AUTHORIZATION
* BINARY
* BOTH
* CASE
* CAST
* CHECK
* COLLATE
* COLLATION
* COLUMN
* CONCURRENTLY
* CONSTRAINT
* CREATE
* CROSS
* CURRENT_CATALOG
* CURRENT_DATE
* CURRENT_ROLE
* CURRENT_SCHEMA
* CURRENT_TIME
* CURRENT_TIMESTAMP
* CURRENT_USER
* DEFAULT
* DEFERRABLE
* DESC
* DISTINCT
* DO
* ELSE
* END
* EXCEPT
* FALSE
* FETCH
* FOR
* FOREIGN
* FREEZE
* FROM
* FULL
* GRANT
* GROUP
* HAVING
* ILIKE
* IN
* INITIALLY
* INNER
* INTERSECT
* INTO
* IS
* ISNULL
* JOIN
* LATERAL
* LEADING
* LEFT
* LIKE
* LIMIT
* LOCALTIME
* LOCALTIMESTAMP
* NATURAL
* NOT
* NOTNULL
* NULL
* OFFSET
* ON
* ONLY
* OR
* ORDER
* OUTER
* OVERLAPS
* PLACING
* PRIMARY
* REFERENCES
* RETURNING
* RIGHT
* SELECT
* SESSION_USER
* SIMILAR
* SOME
* SYMMETRIC
* SYSTEM_USER
* TABLE
* TABLESAMPLE
* THEN
* TO
* TRAILING
* TRUE
* UNION
* UNIQUE
* USER
* USING
* VARIADIC
* VERBOSE
* WHEN
* WHERE
* WINDOW
* WITH

Twenty-four of these (`AND`, `AS`, `CHECK`, `COLUMN`, `CONSTRAINT`,
`CREATE`, `DEFAULT`, `DISTINCT`, `DO`, `FALSE`, `FROM`, `ILIKE`, `IN`,
`INTO`, `IS`, `LIKE`, `NOT`, `NULL`, `ON`, `OR`, `RETURNING`, `SIMILAR`,
`TO`, `TRUE`) already appear in §3.1–§3.4 as StruoDB's own keywords, and
were already unusable as unquoted identifiers before this section
existed; they're repeated here only for completeness against
PostgreSQL's own list.

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
have yet). See [Open Issues](/struoql/design-decisions#open-issues).

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
  (which isn't included — see
  [Open Issues](/struoql/design-decisions#open-issues)).

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

