# Struo Query Language — Schema Definition

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
— see [Open Issues](/struoql/design-decisions#open-issues)). The `IN`
list is always an explicit parenthesized expression list; there's no
subquery form (`IN (SELECT
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
`GREATEST(reading, 0)`. Function names are **ordinary identifiers, not
keywords** — recognized by the transpiler only in function-call position,
the same way PostgreSQL's own built-in functions like `now()` or
`count()` aren't reserved words. A stream or column may be named
`greatest` without conflict; only its use immediately followed by `(` is
interpreted as a call.

No built-in or user-defined functions are defined yet — see "Remaining
open details."

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

This grammar doesn't express the restriction in §9.4 (a `DEFAULT`
expression may not reference a sibling column), the reserved-prefix rule
(§2), or the uniqueness requirements below; all are enforced as semantic
checks, not by the productions above.

- **`column_name` must be unique within a stream** — a stream with two
  columns of the same name is a compile-time error. (Unstated in earlier
  drafts of this spec, but necessary: without it, a `column_ref` in an
  `expr`, or a target in `ALTER STREAM`'s `DROP COLUMN`/`ALTER COLUMN`,
  would be ambiguous.)
- **`constraint_name` must be unique within a stream**, across both
  column-level and table-level `CHECK`s — see §9.5.

Whether `column_clause`s may repeat, combine freely, or must appear in a
particular order (e.g. can a column have both `DEFAULT` and `CHECK`?) is
not yet constrained — see [Open Issues](/struoql/design-decisions#open-issues).

### 9.2 The Automatic System Columns

`HLC` is not a data type, and `CREATE STREAM` never declares a primary
key column at all. Instead, every stream automatically gets 5 columns —
none written in `CREATE STREAM`, none in `column_def`'s `data_type`
grammar — prepended ahead of whatever the statement itself declares:

| Column                  | Type          | Holds                                    |
|--------------------------|---------------|-------------------------------------------|
| `_struo_hlc`             | `CHAR(15)`    | The whole encoded HLC value ([Hybrid Logical Clock](/internals/hlc-spec)); the table's `PRIMARY KEY`. |
| `_struo_hlc_timestamp`   | `TIMESTAMPTZ` | The HLC's embedded physical-time field, as a real timestamp. |
| `_struo_hlc_count`       | `INTEGER`     | The HLC's embedded logical counter. |
| `_struo_hlc_node_id`     | `INTEGER`     | The HLC's embedded node id, decoded from base-62 to its integer value. |
| `_struo_created_at`      | `TIMESTAMPTZ` | The wall-clock UTC moment PostgreSQL actually inserts the row. |

Lower case, like every other unquoted identifier (§2) — these are never
written in source at all, so there's no "user typed it uppercase" case to
preserve; an uppercase name would only force `quote_identifier` to render
it quoted for no functional reason, and would force a client to quote it
too when referencing it (e.g. in `RETURNING`) to avoid its own unquoted
spelling folding away from the catalog's exact-case key.

All 5 are `NOT NULL` (`_struo_hlc` via `PRIMARY KEY`, same as before; the
other 4 explicitly). The first 4 revert to something like the *original*
design this spec once described and then moved away from (an implicit,
reserved, system-populated column) — except now split into 4 columns
instead of 1, and populated by the codegen layer itself rather than by
the client typing a value into `INSERT`: `INSERT` (§11) never accepts a
value for any of the 5, the same way it never accepts one for a
`GENERATED` column (§11.4) — but the 5 don't all get their actual value
the same way. The 4 HLC-derived columns come from a live HLC clock
instance passed to codegen at generation time, one fresh draw per row
inserted, and are written into the generated `INSERT` text explicitly.
`_struo_created_at` is different: it's simply left out of the generated
`INSERT`'s column list entirely, exactly like an ordinary column with a
`DEFAULT` and no value supplied (§11.3) — its value comes from the
column's own `DEFAULT clock_timestamp()`, rendered once in `CREATE
STREAM`'s transpiled `CREATE TABLE` (§9.7), so PostgreSQL itself fills it
in at the moment it actually inserts the row, not the client/codegen
layer. This is deliberately a separate value from `_struo_hlc_timestamp`:
that one is the HLC's own causality-ordering clock, which — per the
[Hybrid Logical Clock](/internals/hlc-spec) spec's merge rule — can run
ahead of true wall-clock time after a node merges in a remote clock
reading; `_struo_created_at` is
always PostgreSQL's own unadjusted idea of "now."

A node's clock producing a duplicate HLC value is misbehaving (HLC values
must be unique per the [Hybrid Logical Clock](/internals/hlc-spec) spec's
node-ID discipline); the
transpiled table's `PRIMARY KEY` constraint on `_struo_hlc` is what
actually rejects it, unless `INSERT`'s `ON CONFLICT DO NOTHING` (§11.5)
is used to absorb it silently. No additional StruoDB-level uniqueness
logic is needed.

**Reserved namespace.** No stream, column, or constraint name may be
*declared* starting with `_STRUO_`, case-insensitively (§2) — reserved
for these 5 columns and future system use. A stream may still
*reference* one of them (e.g. `RETURNING _struo_hlc`) exactly like any
other real column.

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
  omitted.

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
  primary-key uniqueness on `_struo_hlc` (§9.2).
- **Streams have no foreign keys.**

### 9.6 Built-in Functions

See §8.3 for the general rule (ordinary identifiers, not keywords). No
built-in functions are defined yet — see [Open Issues](/struoql/design-decisions#open-issues).

### 9.7 Example

```
CREATE STREAM sensor_reading (
    reading REAL CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 100),
    units VARCHAR(32),
    sensor_id VARCHAR(24),
    notes VARCHAR(200) OPTIONAL
);
```

(This corrects one thing from the original working draft: `FLOAT` →
`REAL`, since `FLOAT` isn't a data type keyword (§3.1). The transpiled
table also carries the 5 automatic system columns of §9.2, not written
here at all.)

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

The added column's name is subject to the same reserved-`_STRUO_`-prefix
rule (§2) as `CREATE STREAM`'s own columns.

### 10.3 Dropping Columns

`DROP COLUMN column_name` removes a column, allowed **only if the column
is `OPTIONAL`** — a `NOT NULL` column may not be dropped. None of the 5
automatic system columns (§9.2) may ever be dropped, `OPTIONAL` or not —
a **compile-time error** distinct from (and checked ahead of) the
`OPTIONAL` rule, since the real reason is "not yours to drop," not
incidentally failing the nullability check.

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
now — see [Open Issues](/struoql/design-decisions#open-issues). Targeting
one of the 5 automatic system columns (§9.2) is a compile-time error,
same as §10.3's drop restriction.

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
  in general. See [Open Issues](/struoql/design-decisions#open-issues)
  for the options under consideration (ranging from an unenforced
  documented convention to a pattern-matched check restricted to simple
  numeric comparisons).

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

### 10.8 Grammar Diagrams

<a href="/x-struoql/grammar-railroad.html" target="_blank">Grammar Railroad Diagrams</a>