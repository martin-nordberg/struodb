# 3. StruoQL — Expressions

## 3.1 Applicability

Expressions appear wherever `CREATE STREAM` (§3.3) or `ALTER STREAM` (§3.4)
takes an `expr` — in `DEFAULT`, `GENERATED ALWAYS AS (...)`, and
`CHECK (...)` clauses. They can appear among the values of `INSERT` 
statements. And expressions are integral to `CREATE PROJECTION` statements 
for mapping event fields into projection fields.

## 3.2 Grammar

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

literal ::= numeric_literal | string_literal | TRUE | FALSE | NULL   -- §2.4

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

`data_type` is as defined in §3.3.1 (no `CAST(expr AS type)` alternate form
— see [Open Issues](/specifications/struoql/design-decisions#a-2-open-issues)). The `IN`
list is always an explicit parenthesized expression list; there's no
subquery form (`IN (SELECT
...)`) since no querying syntax exists yet (§5).

`bound_expr` is `expr` restricted to precedence level 6 or tighter
(§3.2.2) — i.e. any `expr` production except the `BETWEEN`/`IN`/`LIKE`/
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

`identifier` is as defined in §2.2. A `column_ref` is currently always
unqualified — no stream/table-qualified form (`stream_name.column_name`)
is specified yet, since expressions today only appear inside the
`CREATE STREAM`/`ALTER STREAM` that defines the columns they reference;
qualification will matter once multi-stream querying (§5) exists.

## 3.3 Operator Precedence

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
tight "level 2" binding. Prefix `~` (bitwise NOT, §2.5.4) is not special-cased
the same way — it sits at level 6 with the other binary operators, which
is *looser* than arithmetic. So `~1 + 2` parses as `~(1 + 2)`, not
`(~1) + 2`. Parenthesize `~` operands when in doubt.

This table is now a complete match for the operators/keywords StruoDB
defines; the only PostgreSQL precedence-table entries it still doesn't
populate are `[ ]` (array subscript) and `.` (table/column separator used
within an expression) — no array types and no qualified `column_ref` form
exist yet.

## 3.4 Function Calls

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

## 3.5 Grammar Diagrams

- <a href="/struodb/x-specifications/struoql/grammar-railroad.html" target="_blank">Grammar Railroad Diagrams</a>