# StruoDB Query Language — Event Creation

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
with neither. The 5 automatic system columns (§9.2) may **never** appear
in the column list at all — the same restriction §11.4 states for
`GENERATED` columns — so they're always "left out," and never hit that
insert-time error: 4 of them resolve to that row's freshly-drawn HLC
value; the 5th, `_struo_created_at`, resolves to its own `DEFAULT
clock_timestamp()` exactly like an ordinary `DEFAULT` column left out of
the list.

### 11.3 Values

Each `value_row` supplies one value per column in the column list,
positionally. A `value` is either a general expression (§8) or the bare
keyword `DEFAULT`, which stands for that column's own `DEFAULT` expression
(§9.4) — or `NULL`, if the column is `OPTIONAL` and has no `DEFAULT` — the
same resolution described in §11.2 for an omitted column, just spelled out
explicitly instead of left out.

There's no `INSERT ... SELECT` form — only `VALUES` — since no querying
grammar exists yet (§12).

### 11.4 Generated and System Columns

A column declared `GENERATED ALWAYS AS (...)` (§9.4) may **never** appear
in the column list, not even paired with the `DEFAULT` placeholder value.
This is simpler than PostgreSQL, which allows `DEFAULT` specifically for a
generated column while rejecting any other value; StruoDB just excludes
generated columns from the column list entirely, since they're never
something an `INSERT` supplies — they're always computed from the row
being inserted.

The 5 automatic system columns (§9.2) are excluded from the column list
the same way, for the same reason: their values are never
client-supplied. 4 of them, codegen draws a fresh HLC value per row from
a live clock instance and fills them in itself; the 5th,
`_struo_created_at`, is left for PostgreSQL to fill in via its own
`DEFAULT clock_timestamp()`, the same as any other omitted `DEFAULT`
column (§11.2).

### 11.5 Conflict Handling

`ON CONFLICT DO NOTHING`, if present, makes a duplicate `_struo_hlc` value
a silent no-op instead of a `PRIMARY KEY`-violation error — for absorbing
redelivered/retried events, which is routine for an event-sourcing client,
not exceptional (this is now more of a defensive measure than an expected
occurrence, since `_struo_hlc` is drawn fresh from a live clock per row
rather than client-supplied — see §9.2). No conflict target (a column
list or constraint name, as PostgreSQL's `ON CONFLICT` generally requires
or allows) is written or needed: a stream has exactly one possible source
of conflict, its `_struo_hlc` primary key (§9.5 — there's no `UNIQUE`
constraint to disambiguate between), so `ON CONFLICT DO NOTHING` is
unambiguous as written.

There is no `DO UPDATE` form. Streams are an append-only log; silently
rewriting a previously-inserted row on conflict doesn't fit that model,
so only the no-op form is offered.

The clause is optional. Without it, a duplicate `_struo_hlc` is a hard
error, exactly as it would be in plain SQL.

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
INSERT INTO sensor_reading (reading, units, sensor_id)
VALUES (42.5, 'celsius', 'sensor-001')
ON CONFLICT DO NOTHING
RETURNING _struo_hlc;
```

(The 5 automatic system columns are correctly omitted from the column
list per §11.4; `_struo_hlc` reads back the value codegen actually
assigned this row via `RETURNING`, per §11.6. `notes`, `OPTIONAL` with no
`DEFAULT`, is omitted
from the column list and resolves to `NULL` per §11.2.)

