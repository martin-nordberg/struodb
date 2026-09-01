import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lang/catalog
import lang/ddl_ast as ast
import lang/expr_ast as xast
import lang/token

//-----------------------------------------------------------------------------

fn dummy_span() -> token.Span {
  let pos = token.Position(line: 1, column: 1, byte_offset: 0)
  token.Span(pos, pos)
}

/// Built directly, not via the lexer/parser — catalog.gleam only ever
/// operates on a `Statement`, regardless of where it came from, and this
/// keeps these tests independent of parser correctness.
fn sensor_reading_create() -> ast.DdlStatement {
  ast.CreateStream(
    name: "sensor_reading",
    elements: [
      ast.Column(ast.ColumnDef(
        name: "reading_hlc",
        data_type: xast.DtHlc,
        optional: False,
        default: None,
        generated: None,
        checks: [],
        span: dummy_span(),
      )),
      ast.Column(ast.ColumnDef(
        name: "reading",
        data_type: xast.DtReal,
        optional: False,
        default: None,
        generated: None,
        checks: [
          ast.NamedCheck(
            "reading_in_range",
            xast.BinaryOp(
              xast.CmpGt,
              xast.ColumnRef("reading", dummy_span()),
              xast.IntLiteral("0"),
            ),
            dummy_span(),
          ),
        ],
        span: dummy_span(),
      )),
      ast.Column(ast.ColumnDef(
        name: "units",
        data_type: xast.DtVarchar(Some(32)),
        optional: False,
        default: None,
        generated: None,
        checks: [],
        span: dummy_span(),
      )),
      ast.TableConstraint(
        check: ast.NamedCheck(
          "units_not_empty",
          xast.BinaryOp(
            xast.CmpNeBang,
            xast.ColumnRef("units", dummy_span()),
            xast.StringLiteral(""),
          ),
          dummy_span(),
        ),
        span: dummy_span(),
      ),
    ],
    span: dummy_span(),
  )
}

fn base_catalog() -> catalog.Catalog {
  catalog.apply_statement(catalog.empty(), sensor_reading_create())
}

fn sorted_keys(d: dict.Dict(String, a)) -> List(String) {
  list.sort(dict.keys(d), string.compare)
}

//-----------------------------------------------------------------------------
// CREATE STREAM
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
// ALTER STREAM
//-----------------------------------------------------------------------------

pub fn add_column_adds_a_new_column_and_leaves_the_rest_unchanged_test() {
  let action =
    ast.AddColumn(
      ast.ColumnDef(
        name: "notes",
        data_type: xast.DtVarchar(None),
        optional: True,
        default: None,
        generated: None,
        checks: [],
        span: dummy_span(),
      ),
      dummy_span(),
    )
  let stmt =
    ast.AlterStream(
      name: "sensor_reading",
      actions: [action],
      span: dummy_span(),
    )
  let updated = catalog.apply_statement(base_catalog(), stmt)
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  let assert Ok(notes) = dict.get(schema.columns, "notes")
  assert notes.optional == True
  assert dict.size(schema.columns) == 4
  assert schema.hlc_column == "reading_hlc"
  assert dict.size(schema.constraints) == 2
}

pub fn drop_column_removes_only_that_column_test() {
  let stmt =
    ast.AlterStream(
      name: "sensor_reading",
      actions: [ast.DropColumn(column_name: "units", span: dummy_span())],
      span: dummy_span(),
    )
  let updated = catalog.apply_statement(base_catalog(), stmt)
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  assert dict.has_key(schema.columns, "units") == False
  assert sorted_keys(schema.columns) == ["reading", "reading_hlc"]
  assert dict.size(schema.constraints) == 2
}

pub fn alter_column_type_updates_only_that_columns_type_test() {
  let stmt =
    ast.AlterStream(
      name: "sensor_reading",
      actions: [
        ast.AlterColumnType(
          column_name: "units",
          data_type: xast.DtVarchar(Some(64)),
          span: dummy_span(),
        ),
      ],
      span: dummy_span(),
    )
  let updated = catalog.apply_statement(base_catalog(), stmt)
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  let assert Ok(units) = dict.get(schema.columns, "units")
  assert units.data_type == xast.DtVarchar(Some(64))
  let assert Ok(reading) = dict.get(schema.columns, "reading")
  assert reading.data_type == xast.DtReal
}

pub fn add_constraint_adds_a_new_constraint_test() {
  let check =
    ast.NamedCheck("units_at_most_64", xast.BoolLiteral(True), dummy_span())
  let stmt =
    ast.AlterStream(
      name: "sensor_reading",
      actions: [ast.AddConstraint(check)],
      span: dummy_span(),
    )
  let updated = catalog.apply_statement(base_catalog(), stmt)
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
  let stmt =
    ast.AlterStream(
      name: "sensor_reading",
      actions: [
        ast.DropConstraint(
          constraint_name: "reading_in_range",
          span: dummy_span(),
        ),
      ],
      span: dummy_span(),
    )
  let updated = catalog.apply_statement(base_catalog(), stmt)
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  assert sorted_keys(schema.constraints) == ["units_not_empty"]
  assert dict.size(schema.columns) == 3
}

pub fn multiple_actions_in_one_statement_all_apply_test() {
  let stmt =
    ast.AlterStream(
      name: "sensor_reading",
      actions: [
        ast.DropColumn(column_name: "units", span: dummy_span()),
        ast.DropConstraint(
          constraint_name: "units_not_empty",
          span: dummy_span(),
        ),
      ],
      span: dummy_span(),
    )
  let updated = catalog.apply_statement(base_catalog(), stmt)
  let assert Ok(schema) = dict.get(updated.streams, "sensor_reading")

  assert sorted_keys(schema.columns) == ["reading", "reading_hlc"]
  assert sorted_keys(schema.constraints) == ["reading_in_range"]
}
//-----------------------------------------------------------------------------
