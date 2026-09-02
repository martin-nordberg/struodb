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
