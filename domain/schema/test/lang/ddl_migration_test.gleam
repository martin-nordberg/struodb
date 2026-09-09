import gleam/dict
import gleam/string
import lang/catalog
import lang/ddl_ast as ast
import lang/ddl_codegen
import lang/ddl_hash
import lang/ddl_migration
import lang/ddl_parser
import lang/lexer
import lang/token_stream

//-----------------------------------------------------------------------------
// See "Test plan" in documentation/plans/lang/migration-plan.md.
//-----------------------------------------------------------------------------

fn parse_one(source: String) -> ast.DdlStatement {
  let assert Ok(tokens) = lexer.tokenize(source)
  let assert Ok(stmt) = ddl_parser.parse(token_stream.new(tokens))
  stmt
}

fn hash_of(source: String) -> String {
  ddl_hash.hash_statement(parse_one(source))
}

const create_sql = "CREATE STREAM s (a INT);"

const alter1_sql = "ALTER STREAM s ADD COLUMN b INT OPTIONAL;"

const alter2_sql = "ALTER STREAM s ADD COLUMN c INT OPTIONAL;"

fn full_history() -> String {
  create_sql <> "\n" <> alter1_sql <> "\n" <> alter2_sql
}

//-----------------------------------------------------------------------------
// Happy paths
//-----------------------------------------------------------------------------

pub fn a_fresh_migration_emits_sql_and_hashes_for_every_statement_test() {
  let assert Ok(#(sql, hashes, updated)) =
    ddl_migration.apply_migration(catalog.empty(), "s", [], full_history())

  assert string.contains(sql, "CREATE TABLE")
  assert string.contains(sql, "ALTER TABLE")
  assert hashes
    == [hash_of(create_sql), hash_of(alter1_sql), hash_of(alter2_sql)]

  let assert Ok(schema) = dict.get(updated.streams, "s")
  assert schema.migration_hashes == hashes
}

pub fn resuming_from_a_partial_history_emits_only_the_new_statements_test() {
  let previous = [hash_of(create_sql)]
  let assert Ok(#(sql, hashes, updated)) =
    ddl_migration.apply_migration(
      catalog.empty(),
      "s",
      previous,
      full_history(),
    )

  assert !string.contains(sql, "CREATE TABLE")
  assert string.contains(sql, "ALTER TABLE")
  assert hashes == [hash_of(alter1_sql), hash_of(alter2_sql)]

  let assert Ok(schema) = dict.get(updated.streams, "s")
  assert schema.migration_hashes
    == [hash_of(create_sql), hash_of(alter1_sql), hash_of(alter2_sql)]
}

pub fn a_fully_up_to_date_migration_emits_no_new_sql_or_hashes_test() {
  let previous = [hash_of(create_sql), hash_of(alter1_sql), hash_of(alter2_sql)]
  let assert Ok(#(sql, hashes, updated)) =
    ddl_migration.apply_migration(
      catalog.empty(),
      "s",
      previous,
      full_history(),
    )

  assert sql == ""
  assert hashes == []

  let assert Ok(schema) = dict.get(updated.streams, "s")
  assert schema.migration_hashes == previous
}

//-----------------------------------------------------------------------------
// Errors
//-----------------------------------------------------------------------------

pub fn a_hash_mismatch_is_reported_with_its_statement_index_test() {
  let previous = ["not-the-real-hash"]
  let assert Error(err) =
    ddl_migration.apply_migration(
      catalog.empty(),
      "s",
      previous,
      full_history(),
    )

  let assert ddl_migration.HashMismatch(statement_index: 0, ..) = err
}

pub fn a_starting_catalog_that_already_has_the_stream_is_rejected_test() {
  let already = catalog.create_stream(catalog.empty(), "s", [], [])
  let assert Error(ddl_migration.StreamAlreadyExists(stream: "s")) =
    ddl_migration.apply_migration(already, "s", [], full_history())
}

pub fn the_first_statement_must_be_create_stream_test() {
  let assert Error(err) =
    ddl_migration.apply_migration(catalog.empty(), "s", [], alter1_sql)

  let assert ddl_migration.FirstStatementMustBeCreateStream(..) = err
}

pub fn a_second_create_stream_is_rejected_test() {
  let source = create_sql <> "\n" <> create_sql
  let assert Error(err) =
    ddl_migration.apply_migration(catalog.empty(), "s", [], source)

  let assert ddl_migration.UnexpectedCreateStream(..) = err
}

pub fn a_statement_naming_a_different_stream_is_rejected_test() {
  let source = create_sql <> "\nALTER STREAM other ADD COLUMN b INT OPTIONAL;"
  let assert Error(err) =
    ddl_migration.apply_migration(catalog.empty(), "s", [], source)

  let assert ddl_migration.StatementTargetsWrongStream(
    expected: "s",
    actual: "other",
    ..,
  ) = err
}

pub fn more_previous_hashes_than_statements_is_rejected_test() {
  let previous = [
    hash_of(create_sql),
    hash_of(alter1_sql),
    hash_of(alter2_sql),
    "one-too-many",
  ]
  let assert Error(err) =
    ddl_migration.apply_migration(
      catalog.empty(),
      "s",
      previous,
      full_history(),
    )

  let assert ddl_migration.TooManyPreviousHashes(
    previous_count: 4,
    statement_count: 3,
  ) = err
}

/// Empty source has no statements at all — `ddl_parser.parse_many`
/// itself already refuses that ("one or more" is its own documented
/// contract), so this surfaces as an ordinary language error, the same
/// as `apply_ddl` would report it; there's no separate "empty" case for
/// this module to add on top.
pub fn empty_source_is_rejected_as_a_language_error_test() {
  let assert Error(ddl_migration.LanguageError(ddl_codegen.ParseFailure(..))) =
    ddl_migration.apply_migration(catalog.empty(), "s", [], "")
}

pub fn a_semantic_failure_surfaces_as_a_language_error_test() {
  // ALTER on a column that doesn't exist yet — a real ddl_semantics
  // failure, not a structural one.
  let source = create_sql <> "\nALTER STREAM s DROP COLUMN nonexistent;"
  let assert Error(err) =
    ddl_migration.apply_migration(catalog.empty(), "s", [], source)

  let assert ddl_migration.LanguageError(ddl_codegen.SemanticFailure(
    statement_index: 1,
    ..,
  )) = err
}
//-----------------------------------------------------------------------------
