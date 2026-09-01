import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lang/catalog
import lang/expr_ast as xast
import lang/token

//-----------------------------------------------------------------------------

fn dummy_span() -> token.Span {
  let pos = token.Position(line: 1, column: 1, byte_offset: 0)
  token.Span(pos, pos)
}

/// Built directly against catalog.gleam's own primitives, not via
/// ddl_ast/ddl_semantics (schema/) — catalog.gleam knows nothing about
/// those, by design; see the note on `Catalog` in catalog.gleam. This
/// keeps these tests independent of both parser and DDL-semantics
/// correctness.
fn column(name: String, data_type: xast.DataType) -> catalog.ColumnSchema {
  catalog.ColumnSchema(
    name: name,
    data_type: data_type,
    optional: False,
    default: None,
    generated: None,
  )
}

fn named_check(name: String, expr: xast.Expr) -> xast.NamedCheck {
  xast.NamedCheck(name, expr, dummy_span())
}

fn base_catalog() -> catalog.Catalog {
  catalog.create_stream(
    catalog.empty(),
    "sensor_reading",
    [
      column("reading_hlc", xast.DtHlc),
      column("reading", xast.DtReal),
      column("units", xast.DtVarchar(Some(32))),
    ],
    "reading_hlc",
    [
      named_check(
        "reading_in_range",
        xast.BinaryOp(
          xast.CmpGt,
          xast.ColumnRef("reading", dummy_span()),
          xast.IntLiteral("0"),
        ),
      ),
      named_check(
        "units_not_empty",
        xast.BinaryOp(
          xast.CmpNeBang,
          xast.ColumnRef("units", dummy_span()),
          xast.StringLiteral(""),
        ),
      ),
    ],
  )
}

fn sorted_keys(d: dict.Dict(String, a)) -> List(String) {
  list.sort(dict.keys(d), string.compare)
}

//-----------------------------------------------------------------------------
// CREATE STREAM (catalog.create_stream)
//-----------------------------------------------------------------------------

pub fn create_stream_produces_the_right_schema_test() {
  let assert Ok(schema) = dict.get(base_catalog().streams, "sensor_reading")
  assert schema.name == "sensor_reading"
  assert schema.hlc_column == "reading_hlc"
  assert sorted_keys(schema.columns) == ["reading", "reading_hlc", "units"]
  assert sorted_keys(schema.constraints)
    == [
      "reading_in_range",
      "units_not_empty",
    ]

  let assert Ok(reading) = dict.get(schema.columns, "reading")
  assert reading.data_type == xast.DtReal
  assert reading.optional == False

  let assert Ok(hlc) = dict.get(schema.columns, "reading_hlc")
  assert hlc.data_type == xast.DtHlc
}

//-----------------------------------------------------------------------------
// ALTER STREAM (catalog.add_column / drop_column / alter_column_type /
// add_constraint / drop_constraint)
//-----------------------------------------------------------------------------

pub fn add_column_adds_a_new_column_and_leaves_the_rest_unchanged_test() {
  let notes_column =
    catalog.ColumnSchema(
      name: "notes",
      data_type: xast.DtVarchar(None),
      optional: True,
      default: None,
      generated: None,
    )
  let updated =
    catalog.add_column(base_catalog(), "sensor_reading", notes_column)
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  let assert Ok(notes) = dict.get(schema.columns, "notes")
  assert notes.optional == True
  assert dict.size(schema.columns) == 4
  assert schema.hlc_column == "reading_hlc"
  assert dict.size(schema.constraints) == 2
}

pub fn drop_column_removes_only_that_column_test() {
  let updated = catalog.drop_column(base_catalog(), "sensor_reading", "units")
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  assert dict.has_key(schema.columns, "units") == False
  assert sorted_keys(schema.columns) == ["reading", "reading_hlc"]
  assert dict.size(schema.constraints) == 2
}

pub fn alter_column_type_updates_only_that_columns_type_test() {
  let updated =
    catalog.alter_column_type(
      base_catalog(),
      "sensor_reading",
      "units",
      xast.DtVarchar(Some(64)),
    )
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  let assert Ok(units) = dict.get(schema.columns, "units")
  assert units.data_type == xast.DtVarchar(Some(64))
  let assert Ok(reading) = dict.get(schema.columns, "reading")
  assert reading.data_type == xast.DtReal
}

pub fn add_constraint_adds_a_new_constraint_test() {
  let check = named_check("units_at_most_64", xast.BoolLiteral(True))
  let updated = catalog.add_constraint(base_catalog(), "sensor_reading", check)
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  assert sorted_keys(schema.constraints)
    == [
      "reading_in_range",
      "units_at_most_64",
      "units_not_empty",
    ]
  assert dict.size(schema.columns) == 3
}

pub fn drop_constraint_removes_only_that_constraint_test() {
  let updated =
    catalog.drop_constraint(
      base_catalog(),
      "sensor_reading",
      "reading_in_range",
    )
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  assert sorted_keys(schema.constraints) == ["units_not_empty"]
  assert dict.size(schema.columns) == 3
}

pub fn multiple_actions_in_sequence_all_apply_test() {
  let updated =
    base_catalog()
    |> catalog.drop_column("sensor_reading", "units")
    |> catalog.drop_constraint("sensor_reading", "units_not_empty")
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  assert sorted_keys(schema.columns) == ["reading", "reading_hlc"]
  assert sorted_keys(schema.constraints) == ["reading_in_range"]
}
//-----------------------------------------------------------------------------
