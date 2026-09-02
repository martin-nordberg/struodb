# Struo Query Language — Design Decisions History

## Settled Design Decisions

Architectural decisions that are settled, recorded here so the choices
above can be read in context and aren't re-litigated later:

- **Scope, for now: expressions/function calls, `CREATE STREAM`,
  `ALTER STREAM`, and `INSERT`.** See §7.
- **Fixed per-stream schema.** See §7.
- **`HLC` is not a data type; every stream automatically gets 4 fixed,
  system-populated `_struo_hlc...` columns, never written in
  `CREATE STREAM`** — see §9.2. (This supersedes an intervening design
  where the event-time column was an ordinary, user-declared `HLC`
  column; that design's own supersession note — reverting to something
  like the *original* implicit/reserved/system-populated design, this
  time split into 4 columns and populated by codegen from a live clock
  instance rather than typed by the client into `INSERT` — is this
  bullet.) Any stream/column/constraint name starting with `_STRUO_` is
  reserved and rejected at declaration time — see §2.
- **A 5th automatic system column, `_struo_created_at TIMESTAMPTZ NOT
  NULL`, holds the wall-clock UTC moment PostgreSQL actually inserts the
  row** — added after the 4 `_struo_hlc...` columns above, and populated
  differently from them: rather than a value codegen draws from a live
  HLC clock and writes into the generated `INSERT`, it's left out of the
  `INSERT` entirely and comes from the column's own
  `DEFAULT clock_timestamp()`, evaluated by PostgreSQL itself at insert
  time. Deliberately distinct from `_struo_hlc_timestamp`, which is the
  HLC's own causality clock and can run ahead of true wall-clock time
  after a merge — see §9.2.
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
- **All keywords reserved**, and, additionally, an unquoted identifier
  may not be one of PostgreSQL's own reserved keywords either, so every
  unquoted identifier this grammar accepts is guaranteed safe to emit
  unquoted in transpiled PostgreSQL SQL. See §3, §3.5.
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
- **`INSERT`'s column list is mandatory**, unlike standard SQL's
  positional form — self-documenting and immune to `ALTER STREAM`
  reordering columns. See §11.2.
- **`GENERATED` and the 5 automatic system columns are excluded from the
  `INSERT` column list entirely** — simpler than PostgreSQL's
  DEFAULT-only carve-out for `GENERATED`; the system columns are never
  client-supplied at all. 4 are drawn from a live HLC clock instance
  passed to codegen, one draw per row; the 5th, `_struo_created_at`, is
  left to its own table-level `DEFAULT clock_timestamp()`. See §11.4.
- **`INSERT` gains a built-in `ON CONFLICT DO NOTHING`**, with no conflict
  target needed since a stream has exactly one possible source of
  conflict (its `_struo_hlc` primary key); there is no `DO UPDATE` form,
  since an append-only stream shouldn't silently rewrite a prior row. See
  §11.5.
- **`INSERT` supports `RETURNING`**, including reading back a `GENERATED`
  column's computed value or a system column's server-assigned one. See
  §11.6.
- **`INSERT INTO stream_name` doesn't repeat `STREAM`** — matching plain
  SQL rather than `CREATE STREAM`/`ALTER STREAM`'s own pattern. See §11.1.

## Open Issues

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
- No built-in functions are defined yet (§8.3, §9.6) — the earlier
  `TIMESTAMPTZ_FROM_HLC` was never implemented and is retired along with
  the `HLC` data type it depended on (§9.2); function-call position
  currently accepts any identifier, unchecked against any allowlist.