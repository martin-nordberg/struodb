import gleam/dict
import gleam/option.{None, Some}
import lang/catalog
import lang/ddl_ast as ast
import lang/ddl_codegen
import lang/ddl_semantics
import lang/expr_ast as xast
import lang/expr_parser
import lang/lexer
import lang/token

//-----------------------------------------------------------------------------
// Built directly against ddl_ast, not via the parser, so these stay
// independent of parser correctness — same reasoning as
// ddl_semantics_test.gleam. "..._end_to_end_test" below is the
// exception: going through the real lexer/parser/semantics is the whole
// point there.
//-----------------------------------------------------------------------------

fn dummy_span() -> token.Span {
  let pos = token.Position(line: 1, column: 1, byte_offset: 0)
  token.Span(pos, pos)
}

fn col_ref(name: String) -> xast.Expr {
  xast.ColumnRef(name, dummy_span())
}

//-----------------------------------------------------------------------------
// spec.md §9.7's worked example
//-----------------------------------------------------------------------------

fn create_stream_example() -> ast.DdlStatement {
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
        name: "reading_time",
        data_type: xast.DtTimestamptz,
        optional: False,
        default: None,
        generated: Some(xast.GeneratedClause(
          xast.FunctionCall("timestamptz_from_hlc", [col_ref("reading_hlc")]),
          xast.Stored,
        )),
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
          xast.NamedCheck(
            "reading_in_range",
            xast.BinaryOp(
              xast.LogicalAnd,
              xast.BinaryOp(
                xast.CmpGt,
                col_ref("reading"),
                xast.IntLiteral("0"),
              ),
              xast.BinaryOp(
                xast.CmpLe,
                col_ref("reading"),
                xast.IntLiteral("100"),
              ),
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
      ast.Column(ast.ColumnDef(
        name: "sensor_id",
        data_type: xast.DtVarchar(Some(24)),
        optional: False,
        default: None,
        generated: None,
        checks: [],
        span: dummy_span(),
      )),
      ast.Column(ast.ColumnDef(
        name: "notes",
        data_type: xast.DtVarchar(Some(200)),
        optional: True,
        default: None,
        generated: None,
        checks: [],
        span: dummy_span(),
      )),
    ],
    span: dummy_span(),
  )
}

const create_stream_expected = "CREATE TABLE sensor_reading (
  reading_hlc CHAR(15) PRIMARY KEY,
  reading_time TIMESTAMPTZ GENERATED ALWAYS AS (timestamptz_from_hlc(reading_hlc)) STORED,
  reading REAL NOT NULL,
  units VARCHAR(32) NOT NULL,
  sensor_id VARCHAR(24) NOT NULL,
  notes VARCHAR(200),
  CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 100)
);"

pub fn create_stream_matches_the_spec_worked_example_test() {
  assert ddl_codegen.create_stream_to_sql(create_stream_example())
    == create_stream_expected
}

//-----------------------------------------------------------------------------
// spec.md §10.7's worked example
//-----------------------------------------------------------------------------

fn alter_stream_example() -> ast.DdlStatement {
  ast.AlterStream(
    name: "sensor_reading",
    actions: [
      ast.AddColumn(
        ast.ColumnDef(
          name: "calibration_id",
          data_type: xast.DtVarchar(Some(24)),
          optional: True,
          default: None,
          generated: None,
          checks: [],
          span: dummy_span(),
        ),
        dummy_span(),
      ),
      ast.AlterColumnType(
        column_name: "units",
        data_type: xast.DtVarchar(Some(64)),
        span: dummy_span(),
      ),
      ast.DropConstraint(
        constraint_name: "reading_in_range",
        span: dummy_span(),
      ),
      ast.AddConstraint(xast.NamedCheck(
        "reading_in_range",
        xast.BinaryOp(
          xast.LogicalAnd,
          xast.BinaryOp(xast.CmpGt, col_ref("reading"), xast.IntLiteral("0")),
          xast.BinaryOp(xast.CmpLe, col_ref("reading"), xast.IntLiteral("90")),
        ),
        dummy_span(),
      )),
    ],
    span: dummy_span(),
  )
}

const alter_stream_expected = "ALTER TABLE sensor_reading
  ADD COLUMN calibration_id VARCHAR(24),
  ALTER COLUMN units TYPE VARCHAR(64),
  DROP CONSTRAINT reading_in_range,
  ADD CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 90);"

pub fn alter_stream_matches_the_spec_worked_example_test() {
  assert ddl_codegen.alter_stream_to_sql(alter_stream_example())
    == alter_stream_expected
}

//-----------------------------------------------------------------------------
// generate / generate_standalone, end to end
//-----------------------------------------------------------------------------

const create_stream_source = "
  CREATE STREAM sensor_reading (
    reading_hlc HLC,
    reading_time TIMESTAMPTZ GENERATED ALWAYS AS (TIMESTAMPTZ_FROM_HLC(reading_hlc)) STORED,
    reading REAL CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 100),
    units VARCHAR(32),
    sensor_id VARCHAR(24),
    notes VARCHAR(200) OPTIONAL
  );
"

const alter_stream_source = "
  ALTER STREAM sensor_reading
    ADD COLUMN calibration_id VARCHAR(24) OPTIONAL,
    ALTER COLUMN units TYPE VARCHAR(64),
    DROP CONSTRAINT reading_in_range,
    ADD CONSTRAINT reading_in_range CHECK (reading > 0 AND reading <= 90);
"

pub fn generate_standalone_end_to_end_test() {
  let assert Ok(sql) =
    ddl_codegen.generate_standalone(create_stream_source <> alter_stream_source)
  assert sql
    == create_stream_expected <> "\n\n" <> alter_stream_expected <> "\n"
}

pub fn generate_threads_the_catalog_and_validates_alter_against_it_test() {
  let assert Ok(#(_sql, catalog_after_create)) =
    ddl_codegen.generate(catalog.empty(), create_stream_source)
  let assert Ok(schema) =
    dict.get(catalog_after_create.streams, "sensor_reading")
  assert dict.size(schema.columns) == 6

  let assert Ok(#(_sql2, catalog_after_alter)) =
    ddl_codegen.generate(catalog_after_create, alter_stream_source)
  let assert Ok(schema2) =
    dict.get(catalog_after_alter.streams, "sensor_reading")
  assert dict.has_key(schema2.columns, "calibration_id")
}

pub fn a_semicolon_inside_a_string_literal_is_not_a_statement_boundary_test() {
  let source =
    "CREATE STREAM s (a HLC, CONSTRAINT c CHECK (a != 'x;y'));
     ALTER STREAM s ADD COLUMN b INT OPTIONAL;"
  let assert Ok(sql) = ddl_codegen.generate_standalone(source)
  assert sql
    == "CREATE TABLE s (\n"
    <> "  a CHAR(15) PRIMARY KEY,\n"
    <> "  CONSTRAINT c CHECK (a != 'x;y')\n"
    <> ");\n\n"
    <> "ALTER TABLE s\n"
    <> "  ADD COLUMN b INTEGER;\n"
}

pub fn empty_input_is_a_parse_failure_not_ok_empty_test() {
  let assert Error(ddl_codegen.ParseFailure(expr_parser.UnexpectedEof(
    expected: _,
  ))) = ddl_codegen.generate_standalone("")
}

//-----------------------------------------------------------------------------
// Each CodegenError variant
//-----------------------------------------------------------------------------

pub fn a_lex_error_in_a_later_statement_is_reported_test() {
  let assert Error(ddl_codegen.LexFailure(lexer.UnterminatedString(at: _))) =
    ddl_codegen.generate_standalone(
      create_stream_source <> "CREATE STREAM t ('",
    )
}

pub fn a_syntax_error_in_a_later_statement_is_reported_test() {
  let assert Error(ddl_codegen.ParseFailure(expr_parser.UnexpectedToken(
    found: _,
    expected: _,
  ))) =
    ddl_codegen.generate_standalone(
      create_stream_source <> "CREATE STREAM (a HLC);",
    )
}

pub fn a_semantic_error_names_the_right_statement_and_does_not_cascade_test() {
  // The second statement (index 1) fails — `nonexistent` was never
  // created — reported as exactly one `UnknownStream`, not accumulated
  // with anything from a statement after it (there is none reached:
  // `validate_all` returns as soon as the first failure is hit).
  let source = create_stream_source <> "ALTER STREAM nonexistent DROP COLUMN x;"
  let assert Error(ddl_codegen.SemanticFailure(
    statement_index: 1,
    errors: [ddl_semantics.UnknownStream(name: "nonexistent", span: _)],
  )) = ddl_codegen.generate_standalone(source)
}
//-----------------------------------------------------------------------------
