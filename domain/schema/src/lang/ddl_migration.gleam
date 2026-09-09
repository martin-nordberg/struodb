import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lang/catalog.{type Catalog}
import lang/ddl_ast as ast
import lang/ddl_codegen
import lang/ddl_hash
import lang/ddl_parser
import lang/lexer
import lang/token.{type Span}
import lang/token_stream

//-----------------------------------------------------------------------------
// `apply_migration`'s real logic — see "Design decisions" and
// "`ddl_migration.gleam` (new, `domain/schema/src/lang/`)" in
// documentation/plans/lang/migration-plan.md for the reasoning this
// module builds on. `ddl_facade.apply_migration` is the only caller;
// everything here stays internal to `schema`, same as
// `ddl_ast`/`ddl_parser`/`ddl_semantics`/`ddl_codegen` already do.
//
// A stream's *entire* `CREATE STREAM` + `ALTER STREAM` history is
// replayed on every call — `cat` must not already contain `stream` (see
// `StreamAlreadyExists` below) — and `previous_hashes` (an
// externally-tracked, append-only list of hash codes already recorded as
// applied for `stream`, in order) is what lets this call emit SQL for
// only the suffix of `source` not yet run against the real database.
//
// Parameters/locals holding a `Catalog` value are named `cat`, not
// `catalog`, throughout — same convention `ddl_semantics.gleam` uses,
// for the same reason: this module calls `catalog.set_migration_hashes`
// (module-qualified) itself, and a local named `catalog` would shadow
// that module alias.
//-----------------------------------------------------------------------------

pub type MigrationError {
  /// Wraps a lex/parse/semantic failure exactly as `ddl_codegen.generate`
  /// would report it for `apply_ddl` — same `CodegenError` type, no
  /// duplicate variants.
  /// Also what a `source` with no statements at all surfaces as —
  /// `ddl_parser.parse_many` itself already refuses "zero statements"
  /// (`UnexpectedEof`), so there's no separate "empty" case for this
  /// module to add on top.
  LanguageError(ddl_codegen.CodegenError)
  /// `cat` already had `stream` — violates the "starting catalog must
  /// not include the named stream" precondition (see
  /// documentation/docs/designs/ideas/schema-migration.md).
  StreamAlreadyExists(stream: String)
  /// The first statement wasn't `CREATE STREAM`.
  FirstStatementMustBeCreateStream(span: Span)
  /// A statement after the first was `CREATE STREAM` again.
  UnexpectedCreateStream(span: Span)
  /// A statement named a stream other than `stream`.
  StatementTargetsWrongStream(expected: String, actual: String, span: Span)
  /// `previous_hashes` named more statements than `source` contains.
  TooManyPreviousHashes(previous_count: Int, statement_count: Int)
  /// `previous_hashes[statement_index]` didn't match that statement's
  /// actual hash — source modified from a prior migration.
  HashMismatch(
    statement_index: Int,
    expected: String,
    actual: String,
    span: Span,
  )
}

/// See `ddl_facade.apply_migration`'s own doc comment for the full
/// contract. Returns `#(new_sql, new_hashes, updated_catalog)`:
/// `new_sql` is the PostgreSQL for only the statements past
/// `previous_hashes`' length (`""` if none), `new_hashes` is just the
/// newly computed hash codes for those same statements, in source
/// order, and `updated_catalog` carries `stream`'s complete history
/// (`previous_hashes` ++ `new_hashes`) via `catalog.set_migration_hashes`.
pub fn apply_migration(
  cat: Catalog,
  stream: String,
  previous_hashes: List(String),
  source: String,
) -> Result(#(String, List(String), Catalog), MigrationError) {
  use _ <- result.try(case dict.has_key(cat.streams, stream) {
    True -> Error(StreamAlreadyExists(stream))
    False -> Ok(Nil)
  })
  use tokens <- result.try(
    lexer.tokenize(source)
    |> result.map_error(fn(e) { LanguageError(ddl_codegen.LexFailure(e)) }),
  )
  use statements <- result.try(
    ddl_parser.parse_many(token_stream.new(tokens))
    |> result.map_error(fn(e) { LanguageError(ddl_codegen.ParseFailure(e)) }),
  )
  // `statements` is never `[]` here — `ddl_parser.parse_many` already
  // refuses zero statements as a `ParseFailure` above.
  let previous_count = list.length(previous_hashes)
  use _ <- result.try(case previous_count > list.length(statements) {
    True ->
      Error(TooManyPreviousHashes(
        previous_count: previous_count,
        statement_count: list.length(statements),
      ))
    False -> Ok(Nil)
  })
  use _ <- result.try(check_structure(stream, statements, 0))
  use #(_index, final_cat, new_sql_rev, new_hashes_rev) <- result.try(
    list.try_fold(statements, #(0, cat, [], []), fn(acc, stmt) {
      let #(index, acc_cat, sql_acc, hash_acc) = acc
      process_statement(acc_cat, stmt, index, previous_hashes, previous_count)
      |> result.map(fn(next) {
        let #(next_cat, new) = next
        case new {
          None -> #(index + 1, next_cat, sql_acc, hash_acc)
          Some(#(sql, hash)) -> #(index + 1, next_cat, [sql, ..sql_acc], [
            hash,
            ..hash_acc
          ])
        }
      })
    }),
  )
  let new_hashes = list.reverse(new_hashes_rev)
  let tagged_cat =
    catalog.set_migration_hashes(
      final_cat,
      stream,
      list.append(previous_hashes, new_hashes),
    )
  let sql = case list.reverse(new_sql_rev) {
    [] -> ""
    lines -> string.join(lines, "\n\n") <> "\n"
  }
  Ok(#(sql, new_hashes, tagged_cat))
}

//-----------------------------------------------------------------------------
// Structural checks — see "Design decisions" in migration-plan.md on why
// these fail fast (one at a time) rather than accumulating the way
// `ddl_semantics`' own checks do.
//-----------------------------------------------------------------------------

fn check_structure(
  stream: String,
  statements: List(ast.DdlStatement),
  index: Int,
) -> Result(Nil, MigrationError) {
  case statements {
    [] -> Ok(Nil)
    [stmt, ..rest] -> {
      use _ <- result.try(case index {
        0 -> check_first_statement(stream, stmt)
        _ -> check_later_statement(stream, stmt)
      })
      check_structure(stream, rest, index + 1)
    }
  }
}

fn check_first_statement(
  stream: String,
  stmt: ast.DdlStatement,
) -> Result(Nil, MigrationError) {
  case stmt {
    ast.CreateStream(name:, span: _, ..) if name == stream -> Ok(Nil)
    ast.CreateStream(name:, span:, ..) ->
      Error(StatementTargetsWrongStream(
        expected: stream,
        actual: name,
        span: span,
      ))
    ast.AlterStream(span:, ..) -> Error(FirstStatementMustBeCreateStream(span))
  }
}

fn check_later_statement(
  stream: String,
  stmt: ast.DdlStatement,
) -> Result(Nil, MigrationError) {
  case stmt {
    ast.CreateStream(span:, ..) -> Error(UnexpectedCreateStream(span))
    ast.AlterStream(name:, span: _, ..) if name == stream -> Ok(Nil)
    ast.AlterStream(name:, span:, ..) ->
      Error(StatementTargetsWrongStream(
        expected: stream,
        actual: name,
        span: span,
      ))
  }
}

//-----------------------------------------------------------------------------
// Per-statement processing — hash-compare-or-record, then validate+apply
// via `ddl_codegen.validate_statement` either way (see "Design
// decisions": every statement is re-validated on every call, historical
// ones included). Returns `None` for an already-applied statement
// (nothing new to emit), `Some(#(sql, hash))` for a genuinely new one.
//-----------------------------------------------------------------------------

fn process_statement(
  cat: Catalog,
  stmt: ast.DdlStatement,
  index: Int,
  previous_hashes: List(String),
  previous_count: Int,
) -> Result(#(Catalog, Option(#(String, String))), MigrationError) {
  let hash = ddl_hash.hash_statement(stmt)
  case index < previous_count {
    True -> {
      // `index < previous_count == list.length(previous_hashes)`, so
      // this can never miss — a genuine failure to look up index i
      // would be a bug in this module, not a possible runtime input.
      let assert Ok(expected) = list_at(previous_hashes, index)
      use _ <- result.try(case expected == hash {
        True -> Ok(Nil)
        False ->
          Error(HashMismatch(
            statement_index: index,
            expected: expected,
            actual: hash,
            span: statement_span(stmt),
          ))
      })
      use next_cat <- result.try(
        ddl_codegen.validate_statement(cat, stmt, index)
        |> result.map_error(LanguageError),
      )
      Ok(#(next_cat, None))
    }
    False -> {
      use next_cat <- result.try(
        ddl_codegen.validate_statement(cat, stmt, index)
        |> result.map_error(LanguageError),
      )
      Ok(#(next_cat, Some(#(statement_to_sql(stmt), hash))))
    }
  }
}

fn statement_to_sql(stmt: ast.DdlStatement) -> String {
  case stmt {
    ast.CreateStream(..) -> ddl_codegen.create_stream_to_sql(stmt)
    ast.AlterStream(..) -> ddl_codegen.alter_stream_to_sql(stmt)
  }
}

fn statement_span(stmt: ast.DdlStatement) -> Span {
  case stmt {
    ast.CreateStream(span:, ..) -> span
    ast.AlterStream(span:, ..) -> span
  }
}

fn list_at(items: List(a), index: Int) -> Result(a, Nil) {
  case items, index {
    [], _ -> Error(Nil)
    [item, ..], 0 -> Ok(item)
    [_, ..rest], n -> list_at(rest, n - 1)
  }
}
//-----------------------------------------------------------------------------
