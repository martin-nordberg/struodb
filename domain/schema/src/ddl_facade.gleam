import gleam/json
import gleam/string
import lang/catalog.{type Catalog}
import lang/ddl_codegen
import lang/ddl_migration

//-----------------------------------------------------------------------------
// The one module `service/src/bridges/schema-bridge.ts` imports from —
// everything else under `lang/` stays internal to this package. See
// documentation/plans/architecture/bun-typescript-migration-plan.md's
// "Facade layer" for the design this follows, and the note below for one
// way this module's actual shape differs from that plan.
//
// `source` (StruoQL text) and every function's *content* result cross the
// Gleam/TypeScript boundary as plain strings/JSON, never a Gleam ADT —
// that's the "hidden from TypeScript" promise. `Catalog` is the one
// deliberate exception, and it isn't really an exception to that promise:
// it crosses as an *opaque* value TypeScript only ever stores and hands
// back unchanged, never constructs or inspects (exactly like
// `hlc/clock.ClockState` — see `service/src/hlc-clock.ts`), so nothing
// TypeScript-visible ever needs to know `Catalog` has fields, let alone
// pattern-match on them.
//
// The migration plan's original sketch instead had `catalog_json: String`
// crossing the boundary, encoded/decoded via a new `Catalog ⇄ JSON` codec.
// Building that turned out to mean hand-writing a JSON encoding for the
// *entire* `lang/expr_ast.Expr`/`DataType` grammar too (`ColumnSchema`'s
// `default`/`generated` fields, and `NamedCheck`, all embed arbitrary
// `Expr` trees) — a large, separate undertaking, and not one this
// migration's facade layer needs to force: threading `Catalog` opaquely
// costs nothing (no serialization at all, since `schema-bridge.ts` and
// `streams-bridge.ts` run in the same TypeScript process) and — unlike a
// hand-rolled codec `streams`' facade would also need, to decode a
// `catalog_json` `schema` produced — keeps `streams`' production code
// depending on `shared` alone, never `schema`, exactly as documented in
// the root CLAUDE.md.
//-----------------------------------------------------------------------------

/// A fresh, empty catalog — the starting point before any `CREATE
/// STREAM` has been applied. A caller bootstrapping a new stream set
/// calls this once and threads the `Catalog` each `apply_ddl` call
/// returns into the next.
pub fn empty_catalog() -> Catalog {
  catalog.empty()
}

/// Validates and translates every `CREATE STREAM`/`ALTER STREAM`
/// statement in `source` against `catalog` (in order, threaded across
/// them exactly as `ddl_codegen.generate` already does), returning
/// `#(result_json, updated_catalog)`. `updated_catalog` is `catalog`
/// itself, unchanged, whenever `result_json` reports failure.
///
/// `result_json` is one of:
///   `{"ok": true, "sql": "<generated CREATE/ALTER TABLE text>"}`
///   `{"ok": false, "error": "<lex/parse/semantic failure description>"}`
pub fn apply_ddl(catalog: Catalog, source: String) -> #(String, Catalog) {
  case ddl_codegen.generate(catalog, source) {
    Ok(#(sql, updated_catalog)) -> #(ok_json(sql), updated_catalog)
    Error(err) -> #(error_json(err), catalog)
  }
}

/// Stream-scoped counterpart to `apply_ddl`: given `stream`'s *entire*
/// `CREATE STREAM` + `ALTER STREAM` history in one `source` string, plus
/// the hash codes an external migration-history store already has
/// recorded as applied for it (`previous_hashes`, in application order),
/// returns `#(result_json, updated_catalog)`. `catalog` must not already
/// contain `stream` — see `ddl_migration.gleam`'s own header comment
/// (and documentation/plans/lang/migration-plan.md) for why
/// `apply_migration` always replays a stream's full history rather than
/// threading forward incrementally the way `apply_ddl` does.
/// `updated_catalog` is `catalog` itself, unchanged, whenever
/// `result_json` reports failure.
///
/// `result_json` is one of:
///   `{"ok": true, "kind": "ok", "sql": "<new-statements-only SQL, "" if
///     none>", "hashes": ["<new hash>", ...]}`
///     — `hashes` is only the newly computed ones, in source order: what
///     a caller should append to its own external history after
///     successfully running `sql`.
///   `{"ok": false, "kind": "hash_mismatch", "statement_index": <int>,
///     "error": "<string.inspect detail>"}`
///     — a caller likely treats this as an alarm-worthy condition (a
///     previously-applied migration's source was edited), distinct from
///     an ordinary language mistake.
///   `{"ok": false, "kind": "language_error", "error": "<string.inspect
///     of the underlying ddl_codegen.CodegenError>"}`
///   `{"ok": false, "kind": "structural_error", "error": "<string.inspect
///     of the MigrationError variant>"}`
///     — caller misuse: wrong/missing stream in `source`, catalog
///     already had the stream, too many `previous_hashes`.
pub fn apply_migration(
  catalog: Catalog,
  stream: String,
  previous_hashes: List(String),
  source: String,
) -> #(String, Catalog) {
  case ddl_migration.apply_migration(catalog, stream, previous_hashes, source) {
    Ok(#(sql, hashes, updated_catalog)) -> #(
      migration_ok_json(sql, hashes),
      updated_catalog,
    )
    Error(err) -> #(migration_error_json(err), catalog)
  }
}

//-----------------------------------------------------------------------------

fn ok_json(sql: String) -> String {
  json.object([#("ok", json.bool(True)), #("sql", json.string(sql))])
  |> json.to_string
}

/// Renders any `ddl_codegen.CodegenError` via `string.inspect` rather
/// than a hand-written message per variant (there are 3 top-level
/// variants, one of which wraps a whole `List(ddl_semantics.
/// SemanticError)`, itself several variants deep) — a reasonable scope
/// cut for this early facade; a caller that needs to branch on *which*
/// failure occurred, rather than just display one, still has the real
/// `ddl_codegen.generate`/`CodegenError` to call directly from Gleam
/// code (e.g. a future test or another Gleam-side caller), just not
/// through this string/JSON boundary.
fn error_json(err: ddl_codegen.CodegenError) -> String {
  json.object([
    #("ok", json.bool(False)),
    #("error", json.string(string.inspect(err))),
  ])
  |> json.to_string
}

fn migration_ok_json(sql: String, hashes: List(String)) -> String {
  json.object([
    #("ok", json.bool(True)),
    #("kind", json.string("ok")),
    #("sql", json.string(sql)),
    #("hashes", json.array(hashes, json.string)),
  ])
  |> json.to_string
}

/// Same `string.inspect`-per-variant scope cut as `error_json` above —
/// see its own doc comment — plus one machine-readable `"kind"` tag a
/// caller can branch on without parsing `"error"`'s text: `"language_
/// error"` inspects just the wrapped `ddl_codegen.CodegenError`, so its
/// `"error"` text matches `apply_ddl`'s own `error_json` exactly for the
/// same underlying failure; every other variant inspects the whole
/// `MigrationError` value, same as `error_json` does for `CodegenError`.
fn migration_error_json(err: ddl_migration.MigrationError) -> String {
  let #(kind, error_detail) = case err {
    ddl_migration.LanguageError(codegen_err) -> #(
      "language_error",
      string.inspect(codegen_err),
    )
    ddl_migration.HashMismatch(..) -> #("hash_mismatch", string.inspect(err))
    ddl_migration.StreamAlreadyExists(..)
    | ddl_migration.FirstStatementMustBeCreateStream(..)
    | ddl_migration.UnexpectedCreateStream(..)
    | ddl_migration.StatementTargetsWrongStream(..)
    | ddl_migration.TooManyPreviousHashes(..) -> #(
      "structural_error",
      string.inspect(err),
    )
  }
  let fields = [
    #("ok", json.bool(False)),
    #("kind", json.string(kind)),
    #("error", json.string(error_detail)),
  ]
  let fields = case err {
    ddl_migration.HashMismatch(statement_index:, ..) -> [
      #("statement_index", json.int(statement_index)),
      ..fields
    ]
    _ -> fields
  }
  json.object(fields)
  |> json.to_string
}
