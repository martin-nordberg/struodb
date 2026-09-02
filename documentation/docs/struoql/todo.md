# Struo Query Language — Remaining Open Details

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