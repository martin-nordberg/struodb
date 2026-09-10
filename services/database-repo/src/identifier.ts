// A TypeScript port of `domain/shared/src/lang/expr_codegen.gleam`'s
// `quote_identifier` — needed here because `insertForwardedEvents`
// (index.ts) builds SQL for already-materialized rows arriving from a
// peer node, entirely in TypeScript, with no StruoQL to parse and no
// compiled Gleam facade in the loop to call through. Ported faithfully
// (same predicate, same reserved-word list, sourced from
// `lexer.gleam`'s `is_postgres_reserved_word`) rather than approximated —
// see documentation/plans/architecture/event-store-implementation-plan.md,
// Phase 7. Only reference of record if these two ever need to change:
// `domain/shared/src/lang/lexer.gleam`/`expr_codegen.gleam`.

/// PostgreSQL's own reserved words (lexical-spec.md §2.3.5) — an
/// unquoted identifier matching one of these needs quoting even if its
/// own content would otherwise be safe unquoted.
const POSTGRES_RESERVED_WORDS: ReadonlySet<string> = new Set([
  "all", "analyse", "analyze", "and", "any", "array", "as", "asc",
  "asymmetric", "authorization", "binary", "both", "case", "cast", "check",
  "collate", "collation", "column", "concurrently", "constraint", "create",
  "cross", "current_catalog", "current_date", "current_role",
  "current_schema", "current_time", "current_timestamp", "current_user",
  "default", "deferrable", "desc", "distinct", "do", "else", "end",
  "except", "false", "fetch", "for", "foreign", "freeze", "from", "full",
  "grant", "group", "having", "ilike", "in", "initially", "inner",
  "intersect", "into", "is", "isnull", "join", "lateral", "leading",
  "left", "like", "limit", "localtime", "localtimestamp", "natural",
  "not", "notnull", "null", "offset", "on", "only", "or", "order",
  "outer", "overlaps", "placing", "primary", "references", "returning",
  "right", "select", "session_user", "similar", "some", "symmetric",
  "system_user", "table", "tablesample", "then", "to", "trailing", "true",
  "union", "unique", "user", "using", "variadic", "verbose", "when",
  "where", "window", "with",
]);

/// A letter (necessarily lower-case — the same "unquoted source is
/// folded to lower case by the lexer" reasoning `expr_codegen.gleam`'s
/// own comment gives), or `_`, followed by letters/digits/`_` — exactly
/// what an unquoted StruoQL `identifier` (lexical-spec.md §2) can spell.
const SAFE_UNQUOTED = /^[a-z_][a-z0-9_]*$/;

/** Quotes `name` (`"..."`, doubling any embedded `"`) only if it needs
 *  it — same two checks as the Gleam original: unsafe content, or a
 *  PostgreSQL reserved word regardless of how safe the content looks. */
export function quoteIdentifier(name: string): string {
  if (SAFE_UNQUOTED.test(name) && !POSTGRES_RESERVED_WORDS.has(name)) {
    return name;
  }
  return `"${name.replaceAll('"', '""')}"`;
}
