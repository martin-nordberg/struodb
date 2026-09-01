import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import lang/catalog
import lang/ddl_ast as dast
import lang/ddl_parser
import lang/ddl_semantics
import lang/dml_ast as ast
import lang/dml_parser
import lang/dml_semantics
import lang/expr_ast as xast
import lang/lexer
import lang/token
import lang/token_stream

//-----------------------------------------------------------------------------
// Test helpers — ASTs built directly (not via the parser), to keep these
// tests independent of parser correctness, per docs/lang/
// implementation-plan.md's own semantic_test.gleam section. The three
// "worked example" tests near the bottom are the exception: they go
// through the real lexer + parser, since that's the whole point of a
// spec.md example round-tripping end to end.
//-----------------------------------------------------------------------------

fn dummy_span() -> token.Span {
  let pos = token.Position(line: 1, column: 1, byte_offset: 0)
  token.Span(pos, pos)
}

fn column(name: String, data_type: xast.DataType) -> dast.ColumnDef {
  dast.ColumnDef(
    name: name,
    data_type: data_type,
    optional: False,
    default: None,
    generated: None,
    checks: [],
    span: dummy_span(),
  )
}

fn col_ref(name: String) -> xast.Expr {
  xast.ColumnRef(name, dummy_span())
}

fn create_stream(
  name: String,
  elements: List(dast.StreamElement),
) -> dast.DdlStatement {
  dast.CreateStream(name: name, elements: elements, span: dummy_span())
}

fn insert(
  stream_name: String,
  columns: List(String),
  rows: List(List(ast.Value)),
) -> ast.DmlStatement {
  ast.Insert(
    stream_name: stream_name,
    columns: columns,
    rows: rows,
    on_conflict_do_nothing: False,
    returning: None,
    span: dummy_span(),
  )
}

fn parse_source(source: String) -> dast.DdlStatement {
  let assert Ok(tokens) = lexer.tokenize(source)
  let assert Ok(stmt) = ddl_parser.parse(token_stream.new(tokens))
  stmt
}

fn parse_dml_source(source: String) -> ast.DmlStatement {
  let assert Ok(tokens) = lexer.tokenize(source)
  let assert Ok(stmt) = dml_parser.parse(token_stream.new(tokens))
  stmt
}

/// `s`: `id HLC`, `a INT`, `name VARCHAR(64)` (both `a` and `name`
/// `NOT NULL`, no default), `computed INT GENERATED ALWAYS AS (1)
/// STORED`, and a table-level `CONSTRAINT a_positive CHECK (a > 0)`.
fn base_stream_create() -> dast.DdlStatement {
  create_stream("s", [
    dast.Column(column("id", xast.DtHlc)),
    dast.Column(column("a", xast.DtInt)),
    dast.Column(column("name", xast.DtVarchar(Some(64)))),
    dast.Column(dast.ColumnDef(
      name: "computed",
      data_type: xast.DtInt,
      optional: False,
      default: None,
      generated: Some(xast.GeneratedClause(xast.IntLiteral("1"), xast.Stored)),
      checks: [],
      span: dummy_span(),
    )),
    dast.TableConstraint(
      check: xast.NamedCheck(
        "a_positive",
        xast.BinaryOp(xast.CmpGt, col_ref("a"), xast.IntLiteral("0")),
        dummy_span(),
      ),
      span: dummy_span(),
    ),
  ])
}

fn base_catalog() -> catalog.Catalog {
  let assert Ok(cat) =
    ddl_semantics.analyze(catalog.empty(), base_stream_create())
  cat
}

//-----------------------------------------------------------------------------
// INSERT — one test per SemanticError variant it can raise
//-----------------------------------------------------------------------------

pub fn insert_column_list_empty_test() {
  let stmt = insert("s", [], [[]])
  let assert Error(errors) = dml_semantics.analyze(base_catalog(), stmt)
  assert list.contains(
    errors,
    dml_semantics.InsertColumnListEmpty(span: dummy_span()),
  )
}

pub fn insert_unknown_column_test() {
  let stmt =
    insert("s", ["id", "a", "name", "zzz"], [
      [
        ast.ValueExpr(xast.StringLiteral("x")),
        ast.ValueExpr(xast.IntLiteral("1")),
        ast.ValueExpr(xast.StringLiteral("y")),
        ast.ValueExpr(xast.IntLiteral("1")),
      ],
    ])
  let assert Error(errors) = dml_semantics.analyze(base_catalog(), stmt)
  assert list.contains(
    errors,
    dml_semantics.InsertUnknownColumn(column: "zzz", span: dummy_span()),
  )
}

pub fn insert_generated_column_in_list_test() {
  let stmt =
    insert("s", ["id", "a", "name", "computed"], [
      [
        ast.ValueExpr(xast.StringLiteral("x")),
        ast.ValueExpr(xast.IntLiteral("1")),
        ast.ValueExpr(xast.StringLiteral("y")),
        ast.ValueExpr(xast.IntLiteral("2")),
      ],
    ])
  let assert Error(errors) = dml_semantics.analyze(base_catalog(), stmt)
  assert list.contains(
    errors,
    dml_semantics.InsertGeneratedColumnInList(
      column: "computed",
      span: dummy_span(),
    ),
  )
}

pub fn insert_missing_hlc_column_even_when_everything_else_resolves_fine_test() {
  let stmt_create =
    create_stream("s6", [
      dast.Column(column("id", xast.DtHlc)),
      dast.Column(dast.ColumnDef(..column("note", xast.DtText), optional: True)),
    ])
  let assert Ok(cat) = ddl_semantics.analyze(catalog.empty(), stmt_create)
  let stmt = insert("s6", ["note"], [[ast.ValueExpr(xast.StringLiteral("x"))]])
  let assert Error([dml_semantics.InsertMissingHlcColumn(stream: "s6", span: _)]) =
    dml_semantics.analyze(cat, stmt)
}

pub fn insert_missing_required_column_test() {
  let stmt = insert("s", ["id"], [[ast.ValueExpr(xast.StringLiteral("x"))]])
  let assert Error(errors) = dml_semantics.analyze(base_catalog(), stmt)
  assert list.contains(
    errors,
    dml_semantics.InsertMissingRequiredColumn(column: "a", span: dummy_span()),
  )
}

pub fn insert_column_count_mismatch_test() {
  let stmt =
    insert("s", ["id", "a", "name"], [
      [
        ast.ValueExpr(xast.StringLiteral("x")),
        ast.ValueExpr(xast.IntLiteral("1")),
        ast.ValueExpr(xast.StringLiteral("y")),
      ],
      [
        ast.ValueExpr(xast.StringLiteral("x")),
        ast.ValueExpr(xast.IntLiteral("1")),
      ],
    ])
  let assert Error(errors) = dml_semantics.analyze(base_catalog(), stmt)
  assert list.contains(
    errors,
    dml_semantics.InsertColumnCountMismatch(
      expected: 3,
      got: 2,
      row_index: 1,
      span: dummy_span(),
    ),
  )
}

//-----------------------------------------------------------------------------
// spec.md's worked examples, end to end (lexer -> parser -> semantic)
//-----------------------------------------------------------------------------

const create_stream_example = "
  CREATE STREAM sensor_reading (
    reading_hlc HLC,
    reading_time TIMESTAMPTZ GENERATED ALWAYS AS (TIMESTAMPTZ_FROM_HLC(reading_hlc)) STORED,
    reading REAL CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 100),
    units VARCHAR(32),
    sensor_id VARCHAR(24),
    notes VARCHAR(200) OPTIONAL
  );
"

const alter_stream_example = "
  ALTER STREAM sensor_reading
    ADD COLUMN calibration_id VARCHAR(24) OPTIONAL,
    ALTER COLUMN units TYPE VARCHAR(64),
    DROP CONSTRAINT reading_in_range,
    ADD CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 90);
"

const insert_example = "
  INSERT INTO sensor_reading (reading_hlc, reading, units, sensor_id)
  VALUES ('01a2B3c4D5e6f70abcde', 42.5, 'celsius', 'sensor-001')
  ON CONFLICT DO NOTHING
  RETURNING reading_hlc, reading_time;
"

pub fn alter_then_insert_examples_analyze_clean_against_the_create_example_test() {
  let assert Ok(cat1) =
    ddl_semantics.analyze(catalog.empty(), parse_source(create_stream_example))
  let assert Ok(cat2) =
    ddl_semantics.analyze(cat1, parse_source(alter_stream_example))
  let assert Ok(schema) = dict.get(cat2.streams, "sensor_reading")
  assert dict.has_key(schema.columns, "calibration_id")
  let assert Ok(units) = dict.get(schema.columns, "units")
  assert units.data_type == xast.DtVarchar(Some(64))

  let assert Ok(_cat3) =
    dml_semantics.analyze(cat2, parse_dml_source(insert_example))
}
//-----------------------------------------------------------------------------
