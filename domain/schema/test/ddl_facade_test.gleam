import ddl_facade
import gleam/string

//-----------------------------------------------------------------------------
// Exercises `ddl_facade`'s actual JSON-in/JSON-out contract directly —
// not re-testing `ddl_semantics`/`ddl_codegen` themselves (those already
// have their own suites), just confirming this module wires them
// together and renders the two JSON shapes it promises.
//-----------------------------------------------------------------------------

pub fn apply_ddl_on_a_valid_statement_returns_ok_json_test() {
  let #(result, _catalog) =
    ddl_facade.apply_ddl(ddl_facade.empty_catalog(), "CREATE STREAM s (a INT);")

  let assert True = string.contains(result, "\"ok\":true")
  let assert True = string.contains(result, "CREATE TABLE")
}

pub fn apply_ddl_threads_the_updated_catalog_across_calls_test() {
  let #(_result, after_create) =
    ddl_facade.apply_ddl(ddl_facade.empty_catalog(), "CREATE STREAM s (a INT);")

  // A second statement against a stream only the *returned* catalog
  // knows about — proves the catalog handle really did thread through,
  // not just that the first call succeeded in isolation.
  let #(result, _after_alter) =
    ddl_facade.apply_ddl(
      after_create,
      "ALTER STREAM s ADD COLUMN b INT OPTIONAL;",
    )

  let assert True = string.contains(result, "\"ok\":true")
  let assert True = string.contains(result, "ALTER TABLE")
}

pub fn apply_ddl_on_an_unknown_stream_returns_error_json_test() {
  let #(result, unchanged) =
    ddl_facade.apply_ddl(
      ddl_facade.empty_catalog(),
      "ALTER STREAM nonexistent ADD COLUMN b INT;",
    )

  let assert True = string.contains(result, "\"ok\":false")
  let assert True = string.contains(result, "\"error\":")
  assert unchanged == ddl_facade.empty_catalog()
}

pub fn apply_ddl_on_unparseable_source_returns_error_json_test() {
  let #(result, unchanged) =
    ddl_facade.apply_ddl(ddl_facade.empty_catalog(), "not struoql at all")

  let assert True = string.contains(result, "\"ok\":false")
  assert unchanged == ddl_facade.empty_catalog()
}

//-----------------------------------------------------------------------------
// apply_migration
//-----------------------------------------------------------------------------

const create_sql = "CREATE STREAM s (a INT);"

const alter_sql = "ALTER STREAM s ADD COLUMN b INT OPTIONAL;"

pub fn apply_migration_on_a_fresh_stream_returns_ok_json_with_all_hashes_test() {
  let #(result, updated) =
    ddl_facade.apply_migration(
      ddl_facade.empty_catalog(),
      "s",
      [],
      create_sql <> "\n" <> alter_sql,
    )

  let assert True = string.contains(result, "\"ok\":true")
  let assert True = string.contains(result, "\"kind\":\"ok\"")
  let assert True = string.contains(result, "CREATE TABLE")
  let assert True = string.contains(result, "ALTER TABLE")
  let assert True = string.contains(result, "\"hashes\":[")
  assert updated != ddl_facade.empty_catalog()
}

pub fn apply_migration_resuming_from_a_known_hash_emits_only_new_sql_test() {
  // First call to learn the CREATE statement's real hash, exactly as an
  // external caller would on its very first run.
  let #(first_result, _) =
    ddl_facade.apply_migration(ddl_facade.empty_catalog(), "s", [], create_sql)
  let assert True = string.contains(first_result, "\"kind\":\"ok\"")

  let #(second_result, _) =
    ddl_facade.apply_migration(
      ddl_facade.empty_catalog(),
      "s",
      [first_hash(first_result)],
      create_sql <> "\n" <> alter_sql,
    )

  let assert True = string.contains(second_result, "\"kind\":\"ok\"")
  let assert False = string.contains(second_result, "CREATE TABLE")
  let assert True = string.contains(second_result, "ALTER TABLE")
}

/// Pulls the one hash out of a single-statement `apply_migration`
/// success JSON's `"hashes":["<hash>"]` array — just enough ad hoc
/// parsing to chain the two calls above without a JSON library on the
/// test side.
fn first_hash(result_json: String) -> String {
  let assert [_, after] = string.split(result_json, "\"hashes\":[\"")
  let assert [hash, ..] = string.split(after, "\"")
  hash
}

pub fn apply_migration_with_a_hash_mismatch_returns_a_hash_mismatch_kind_test() {
  let #(result, unchanged) =
    ddl_facade.apply_migration(
      ddl_facade.empty_catalog(),
      "s",
      ["not-the-real-hash"],
      create_sql,
    )

  let assert True = string.contains(result, "\"ok\":false")
  let assert True = string.contains(result, "\"kind\":\"hash_mismatch\"")
  let assert True = string.contains(result, "\"statement_index\":0")
  assert unchanged == ddl_facade.empty_catalog()
}

pub fn apply_migration_on_a_catalog_that_already_has_the_stream_is_a_structural_error_test() {
  let #(_, already) =
    ddl_facade.apply_ddl(ddl_facade.empty_catalog(), create_sql)

  let #(result, unchanged) =
    ddl_facade.apply_migration(already, "s", [], create_sql)

  let assert True = string.contains(result, "\"ok\":false")
  let assert True = string.contains(result, "\"kind\":\"structural_error\"")
  assert unchanged == already
}

pub fn apply_migration_on_unparseable_source_is_a_language_error_test() {
  let #(result, unchanged) =
    ddl_facade.apply_migration(
      ddl_facade.empty_catalog(),
      "s",
      [],
      "not struoql at all",
    )

  let assert True = string.contains(result, "\"ok\":false")
  let assert True = string.contains(result, "\"kind\":\"language_error\"")
  assert unchanged == ddl_facade.empty_catalog()
}
