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
/// correctness. Always a user-declared (non-`system`) column — every
/// `ddl_ast`-derived column is, by construction; see `to_column_schema`
/// in ddl_semantics.gleam.
fn column(name: String, data_type: xast.DataType) -> catalog.ColumnSchema {
  catalog.ColumnSchema(
    name: name,
    data_type: data_type,
    optional: False,
    default: None,
    generated: None,
    system: False,
  )
}

fn named_check(name: String, expr: xast.Expr) -> xast.NamedCheck {
  xast.NamedCheck(name, expr, dummy_span())
}

/// The 5 system-column names, sorted the same way `sorted_keys` below
/// sorts everything else — used as a fixed prefix every `sorted_keys`
/// assertion below expects, since `create_stream` adds them to every
/// stream regardless of what it's asked to declare.
const system_column_names = [
  catalog.created_at_column_name, catalog.hlc_column_name,
  catalog.hlc_count_column_name, catalog.hlc_node_id_column_name,
  catalog.hlc_timestamp_column_name,
]

fn base_catalog() -> catalog.Catalog {
  catalog.create_stream(
    catalog.empty(),
    "sensor_reading",
    [column("reading", xast.DtReal), column("units", xast.DtVarchar(Some(32)))],
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
  assert sorted_keys(schema.columns)
    == list.append(system_column_names, ["reading", "units"])
  assert sorted_keys(schema.constraints)
    == [
      "reading_in_range",
      "units_not_empty",
    ]

  let assert Ok(reading) = dict.get(schema.columns, "reading")
  assert reading.data_type == xast.DtReal
  assert reading.optional == False
  assert reading.system == False
}

/// The 5 fixed system columns (catalog.gleam's own `system_columns()`)
/// are joined onto every stream automatically — `create_stream` never
/// needs to be told about them, and there's no way to opt out.
pub fn create_stream_always_adds_the_5_system_columns_test() {
  let assert Ok(schema) = dict.get(base_catalog().streams, "sensor_reading")

  let assert Ok(hlc) = dict.get(schema.columns, catalog.hlc_column_name)
  assert hlc.data_type == xast.DtChar(Some(15))
  assert hlc.optional == False
  assert hlc.system == True

  let assert Ok(hlc_timestamp) =
    dict.get(schema.columns, catalog.hlc_timestamp_column_name)
  assert hlc_timestamp.data_type == xast.DtTimestamptz
  assert hlc_timestamp.system == True

  let assert Ok(hlc_count) =
    dict.get(schema.columns, catalog.hlc_count_column_name)
  assert hlc_count.data_type == xast.DtInteger
  assert hlc_count.system == True

  let assert Ok(hlc_node_id) =
    dict.get(schema.columns, catalog.hlc_node_id_column_name)
  assert hlc_node_id.data_type == xast.DtInteger
  assert hlc_node_id.system == True

  let assert Ok(created_at) =
    dict.get(schema.columns, catalog.created_at_column_name)
  assert created_at.data_type == xast.DtTimestamptz
  assert created_at.optional == False
  assert created_at.default == Some(xast.FunctionCall("clock_timestamp", []))
  assert created_at.system == True
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
      system: False,
    )
  let updated =
    catalog.add_column(base_catalog(), "sensor_reading", notes_column)
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  let assert Ok(notes) = dict.get(schema.columns, "notes")
  assert notes.optional == True
  // 2 original user columns + "notes" + 5 system columns.
  assert dict.size(schema.columns) == 8
  assert dict.size(schema.constraints) == 2
}

pub fn drop_column_removes_only_that_column_test() {
  let updated = catalog.drop_column(base_catalog(), "sensor_reading", "units")
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  assert dict.has_key(schema.columns, "units") == False
  assert sorted_keys(schema.columns)
    == list.append(system_column_names, ["reading"])
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
  // 2 user columns + 5 system columns, untouched by this action.
  assert dict.size(schema.columns) == 7
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
  assert dict.size(schema.columns) == 7
}

pub fn multiple_actions_in_sequence_all_apply_test() {
  let updated =
    base_catalog()
    |> catalog.drop_column("sensor_reading", "units")
    |> catalog.drop_constraint("sensor_reading", "units_not_empty")
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  assert sorted_keys(schema.columns)
    == list.append(system_column_names, ["reading"])
  assert sorted_keys(schema.constraints) == ["reading_in_range"]
}
//-----------------------------------------------------------------------------
