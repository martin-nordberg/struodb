import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lang/ast
import lang/catalog
import lang/lexer
import lang/parser
import lang/semantic
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

fn column(name: String, data_type: ast.DataType) -> ast.ColumnDef {
  ast.ColumnDef(
    name: name,
    data_type: data_type,
    optional: False,
    default: None,
    generated: None,
    checks: [],
    span: dummy_span(),
  )
}

fn col_ref(name: String) -> ast.Expr {
  ast.ColumnRef(name, dummy_span())
}

fn create_stream(
  name: String,
  elements: List(ast.StreamElement),
) -> ast.Statement {
  ast.CreateStream(name: name, elements: elements, span: dummy_span())
}

fn alter_stream(name: String, actions: List(ast.AlterAction)) -> ast.Statement {
  ast.AlterStream(name: name, actions: actions, span: dummy_span())
}

fn insert(
  stream_name: String,
  columns: List(String),
  rows: List(List(ast.Value)),
) -> ast.Statement {
  ast.Insert(
    stream_name: stream_name,
    columns: columns,
    rows: rows,
    on_conflict_do_nothing: False,
    returning: None,
    span: dummy_span(),
  )
}

fn parse_source(source: String) -> ast.Statement {
  let assert Ok(tokens) = lexer.tokenize(source)
  let assert Ok(stmt) = parser.parse(token_stream.new(tokens))
  stmt
}

/// `s`: `id HLC`, `a INT`, `name VARCHAR(64)` (both `a` and `name`
/// `NOT NULL`, no default), `computed INT GENERATED ALWAYS AS (1)
/// STORED`, and a table-level `CONSTRAINT a_positive CHECK (a > 0)`.
fn base_stream_create() -> ast.Statement {
  create_stream("s", [
    ast.Column(column("id", ast.DtHlc)),
    ast.Column(column("a", ast.DtInt)),
    ast.Column(column("name", ast.DtVarchar(Some(64)))),
    ast.Column(ast.ColumnDef(
      name: "computed",
      data_type: ast.DtInt,
      optional: False,
      default: None,
      generated: Some(ast.GeneratedClause(ast.IntLiteral("1"), ast.Stored)),
      checks: [],
      span: dummy_span(),
    )),
    ast.TableConstraint(
      check: ast.NamedCheck(
        "a_positive",
        ast.BinaryOp(ast.CmpGt, col_ref("a"), ast.IntLiteral("0")),
        dummy_span(),
      ),
      span: dummy_span(),
    ),
  ])
}

fn base_catalog() -> catalog.Catalog {
  let assert Ok(cat) = semantic.analyze(catalog.empty(), base_stream_create())
  cat
}

//-----------------------------------------------------------------------------
// CREATE STREAM — one test per SemanticError variant it can raise
//-----------------------------------------------------------------------------

pub fn missing_hlc_column_test() {
  let stmt = create_stream("s", [ast.Column(column("a", ast.DtInt))])
  let assert Error([semantic.MissingHlcColumn(stream: "s", span: _)]) =
    semantic.analyze(catalog.empty(), stmt)
}

pub fn multiple_hlc_columns_test() {
  let stmt =
    create_stream("s", [
      ast.Column(column("a", ast.DtHlc)),
      ast.Column(column("b", ast.DtHlc)),
    ])
  let assert Error([
    semantic.MultipleHlcColumns(stream: "s", first: "a", second: "b", span: _),
  ]) = semantic.analyze(catalog.empty(), stmt)
}

pub fn hlc_column_optional_test() {
  let stmt =
    create_stream("s", [
      ast.Column(ast.ColumnDef(..column("a", ast.DtHlc), optional: True)),
    ])
  let assert Error([semantic.HlcColumnOptional(column: "a", span: _)]) =
    semantic.analyze(catalog.empty(), stmt)
}

pub fn hlc_column_has_default_or_generated_test() {
  let stmt =
    create_stream("s", [
      ast.Column(
        ast.ColumnDef(
          ..column("a", ast.DtHlc),
          default: Some(ast.StringLiteral("x")),
        ),
      ),
    ])
  let assert Error([
    semantic.HlcColumnHasDefaultOrGenerated(column: "a", span: _),
  ]) = semantic.analyze(catalog.empty(), stmt)
}

pub fn default_references_column_test() {
  let stmt =
    create_stream("s", [
      ast.Column(column("id", ast.DtHlc)),
      ast.Column(
        ast.ColumnDef(..column("b", ast.DtInt), default: Some(col_ref("id"))),
      ),
    ])
  let assert Error([
    semantic.DefaultReferencesColumn(column: "b", referenced: "id", span: _),
  ]) = semantic.analyze(catalog.empty(), stmt)
}

pub fn unknown_column_reference_test() {
  let check = ast.NamedCheck("c1", col_ref("nonexistent"), dummy_span())
  let stmt =
    create_stream("s", [
      ast.Column(column("id", ast.DtHlc)),
      ast.TableConstraint(check: check, span: dummy_span()),
    ])
  let assert Error([
    semantic.UnknownColumnReference(referenced: "nonexistent", span: _),
  ]) = semantic.analyze(catalog.empty(), stmt)
}

pub fn duplicate_column_name_test() {
  let stmt =
    create_stream("s", [
      ast.Column(column("id", ast.DtHlc)),
      ast.Column(column("a", ast.DtInt)),
      ast.Column(column("a", ast.DtInt)),
    ])
  let assert Error([
    semantic.DuplicateColumnName(stream: "s", name: "a", span: _),
  ]) = semantic.analyze(catalog.empty(), stmt)
}

pub fn duplicate_constraint_name_test() {
  let check1 = ast.NamedCheck("c1", ast.BoolLiteral(True), dummy_span())
  let check2 = ast.NamedCheck("c1", ast.BoolLiteral(True), dummy_span())
  let stmt =
    create_stream("s", [
      ast.Column(column("id", ast.DtHlc)),
      ast.TableConstraint(check: check1, span: dummy_span()),
      ast.TableConstraint(check: check2, span: dummy_span()),
    ])
  let assert Error([
    semantic.DuplicateConstraintName(stream: "s", name: "c1", span: _),
  ]) = semantic.analyze(catalog.empty(), stmt)
}

pub fn invalid_data_type_parameter_test() {
  let stmt =
    create_stream("s", [
      ast.Column(column("id", ast.DtHlc)),
      ast.Column(column("x", ast.DtVarchar(Some(0)))),
    ])
  let assert Error([
    semantic.InvalidDataTypeParameter(column: "x", span: _, reason: _),
  ]) = semantic.analyze(catalog.empty(), stmt)
}

pub fn a_statement_with_two_independent_violations_reports_both_test() {
  let stmt =
    create_stream("bad", [
      ast.Column(column("a", ast.DtInt)),
      ast.TableConstraint(
        check: ast.NamedCheck("c", col_ref("nope"), dummy_span()),
        span: dummy_span(),
      ),
    ])
  let assert Error(errors) = semantic.analyze(catalog.empty(), stmt)
  assert list.length(errors) == 2
  assert list.contains(
    errors,
    semantic.MissingHlcColumn(stream: "bad", span: dummy_span()),
  )
  assert list.contains(
    errors,
    semantic.UnknownColumnReference(referenced: "nope", span: dummy_span()),
  )
}

pub fn unknown_column_reference_span_is_the_column_refs_own_span_test() {
  let ref_span =
    token.Span(
      token.Position(line: 5, column: 10, byte_offset: 100),
      token.Position(line: 5, column: 20, byte_offset: 110),
    )
  let check =
    ast.NamedCheck(
      "c",
      ast.BinaryOp(
        ast.LogicalAnd,
        col_ref("a"),
        ast.BinaryOp(
          ast.CmpGt,
          ast.ColumnRef("unknown_col", ref_span),
          ast.IntLiteral("0"),
        ),
      ),
      dummy_span(),
    )
  let stmt =
    create_stream("s", [
      ast.Column(column("id", ast.DtHlc)),
      ast.Column(column("a", ast.DtBoolean)),
      ast.TableConstraint(check: check, span: dummy_span()),
    ])
  let assert Error([
    semantic.UnknownColumnReference(referenced: "unknown_col", span: got_span),
  ]) = semantic.analyze(catalog.empty(), stmt)
  // Not `dummy_span()` (the enclosing CHECK/statement's span) — proves the
  // check reads the ColumnRef's own span, not a fallback.
  assert got_span == ref_span
}

//-----------------------------------------------------------------------------
// `postgres_name` — approximate 63-byte truncation for duplicate detection
//-----------------------------------------------------------------------------

pub fn names_colliding_only_after_63_bytes_are_a_duplicate_test() {
  let prefix = string.repeat("a", 63)
  let stmt =
    create_stream("s", [
      ast.Column(column("id", ast.DtHlc)),
      ast.Column(column(prefix <> "x", ast.DtInt)),
      ast.Column(column(prefix <> "y", ast.DtInt)),
    ])
  let assert Error(errors) = semantic.analyze(catalog.empty(), stmt)
  assert list.any(errors, fn(e) {
    case e {
      semantic.DuplicateColumnName(..) -> True
      _ -> False
    }
  })
}

pub fn names_differing_well_within_63_bytes_do_not_collide_test() {
  let stmt =
    create_stream("s", [
      ast.Column(column("id", ast.DtHlc)),
      ast.Column(column("alpha", ast.DtInt)),
      ast.Column(column("beta", ast.DtInt)),
    ])
  let assert Ok(_) = semantic.analyze(catalog.empty(), stmt)
}

//-----------------------------------------------------------------------------
// ALTER STREAM — one test per SemanticError variant it can raise
//-----------------------------------------------------------------------------

pub fn unknown_stream_test() {
  let stmt =
    alter_stream("nope", [ast.DropColumn(column_name: "x", span: dummy_span())])
  let assert Error([semantic.UnknownStream(name: "nope", span: _)]) =
    semantic.analyze(catalog.empty(), stmt)
}

pub fn add_column_needs_optional_or_default_test() {
  let stmt =
    alter_stream("s", [ast.AddColumn(column("b", ast.DtInt), dummy_span())])
  let assert Error([
    semantic.AddColumnNeedsOptionalOrDefault(column: "b", span: _),
  ]) = semantic.analyze(base_catalog(), stmt)
}

pub fn add_second_hlc_column_test() {
  let stmt =
    alter_stream("s", [
      ast.AddColumn(
        ast.ColumnDef(..column("b2", ast.DtHlc), optional: True),
        dummy_span(),
      ),
    ])
  let assert Error([semantic.AddSecondHlcColumn(column: "b2", span: _)]) =
    semantic.analyze(base_catalog(), stmt)
}

pub fn drop_non_optional_column_test() {
  let stmt =
    alter_stream("s", [ast.DropColumn(column_name: "a", span: dummy_span())])
  let assert Error([semantic.DropNonOptionalColumn(column: "a", span: _)]) =
    semantic.analyze(base_catalog(), stmt)
}

pub fn drop_unknown_column_test() {
  let stmt =
    alter_stream("s", [ast.DropColumn(column_name: "zzz", span: dummy_span())])
  let assert Error([semantic.DropUnknownColumn(column: "zzz", span: _)]) =
    semantic.analyze(base_catalog(), stmt)
}

pub fn narrowing_type_change_test() {
  let stmt =
    alter_stream("s", [
      ast.AlterColumnType(
        column_name: "name",
        data_type: ast.DtVarchar(Some(32)),
        span: dummy_span(),
      ),
    ])
  let assert Error([
    semantic.NarrowingTypeChange(
      column: "name",
      from: ast.DtVarchar(Some(64)),
      to: ast.DtVarchar(Some(32)),
      span: _,
    ),
  ]) = semantic.analyze(base_catalog(), stmt)
}

pub fn unsupported_type_change_test() {
  let stmt =
    alter_stream("s", [
      ast.AlterColumnType(
        column_name: "a",
        data_type: ast.DtDecimal(None, None),
        span: dummy_span(),
      ),
    ])
  let assert Error([
    semantic.UnsupportedTypeChange(
      column: "a",
      from: ast.DtInt,
      to: ast.DtDecimal(None, None),
      span: _,
    ),
  ]) = semantic.analyze(base_catalog(), stmt)
}

pub fn drop_unknown_constraint_test() {
  let stmt =
    alter_stream("s", [
      ast.DropConstraint(constraint_name: "zzz", span: dummy_span()),
    ])
  let assert Error([semantic.DropUnknownConstraint(name: "zzz", span: _)]) =
    semantic.analyze(base_catalog(), stmt)
}

//-----------------------------------------------------------------------------
// INSERT — one test per SemanticError variant it can raise
//-----------------------------------------------------------------------------

pub fn insert_column_list_empty_test() {
  let stmt = insert("s", [], [[]])
  let assert Error(errors) = semantic.analyze(base_catalog(), stmt)
  assert list.contains(
    errors,
    semantic.InsertColumnListEmpty(span: dummy_span()),
  )
}

pub fn insert_unknown_column_test() {
  let stmt =
    insert("s", ["id", "a", "name", "zzz"], [
      [
        ast.ValueExpr(ast.StringLiteral("x")),
        ast.ValueExpr(ast.IntLiteral("1")),
        ast.ValueExpr(ast.StringLiteral("y")),
        ast.ValueExpr(ast.IntLiteral("1")),
      ],
    ])
  let assert Error(errors) = semantic.analyze(base_catalog(), stmt)
  assert list.contains(
    errors,
    semantic.InsertUnknownColumn(column: "zzz", span: dummy_span()),
  )
}

pub fn insert_generated_column_in_list_test() {
  let stmt =
    insert("s", ["id", "a", "name", "computed"], [
      [
        ast.ValueExpr(ast.StringLiteral("x")),
        ast.ValueExpr(ast.IntLiteral("1")),
        ast.ValueExpr(ast.StringLiteral("y")),
        ast.ValueExpr(ast.IntLiteral("2")),
      ],
    ])
  let assert Error(errors) = semantic.analyze(base_catalog(), stmt)
  assert list.contains(
    errors,
    semantic.InsertGeneratedColumnInList(column: "computed", span: dummy_span()),
  )
}

pub fn insert_missing_hlc_column_even_when_everything_else_resolves_fine_test() {
  let stmt_create =
    create_stream("s6", [
      ast.Column(column("id", ast.DtHlc)),
      ast.Column(ast.ColumnDef(..column("note", ast.DtText), optional: True)),
    ])
  let assert Ok(cat) = semantic.analyze(catalog.empty(), stmt_create)
  let stmt = insert("s6", ["note"], [[ast.ValueExpr(ast.StringLiteral("x"))]])
  let assert Error([semantic.InsertMissingHlcColumn(stream: "s6", span: _)]) =
    semantic.analyze(cat, stmt)
}

pub fn insert_missing_required_column_test() {
  let stmt = insert("s", ["id"], [[ast.ValueExpr(ast.StringLiteral("x"))]])
  let assert Error(errors) = semantic.analyze(base_catalog(), stmt)
  assert list.contains(
    errors,
    semantic.InsertMissingRequiredColumn(column: "a", span: dummy_span()),
  )
}

pub fn insert_column_count_mismatch_test() {
  let stmt =
    insert("s", ["id", "a", "name"], [
      [
        ast.ValueExpr(ast.StringLiteral("x")),
        ast.ValueExpr(ast.IntLiteral("1")),
        ast.ValueExpr(ast.StringLiteral("y")),
      ],
      [
        ast.ValueExpr(ast.StringLiteral("x")),
        ast.ValueExpr(ast.IntLiteral("1")),
      ],
    ])
  let assert Error(errors) = semantic.analyze(base_catalog(), stmt)
  assert list.contains(
    errors,
    semantic.InsertColumnCountMismatch(
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

pub fn create_stream_example_analyzes_clean_test() {
  let assert Ok(cat) =
    semantic.analyze(catalog.empty(), parse_source(create_stream_example))
  let assert Ok(schema) = dict.get(cat.streams, "sensor_reading")
  assert schema.hlc_column == "reading_hlc"
  assert dict.size(schema.columns) == 6
  assert dict.size(schema.constraints) == 1
}

pub fn alter_then_insert_examples_analyze_clean_against_the_create_example_test() {
  let assert Ok(cat1) =
    semantic.analyze(catalog.empty(), parse_source(create_stream_example))
  let assert Ok(cat2) =
    semantic.analyze(cat1, parse_source(alter_stream_example))
  let assert Ok(schema) = dict.get(cat2.streams, "sensor_reading")
  assert dict.has_key(schema.columns, "calibration_id")
  let assert Ok(units) = dict.get(schema.columns, "units")
  assert units.data_type == ast.DtVarchar(Some(64))

  let assert Ok(_cat3) = semantic.analyze(cat2, parse_source(insert_example))
}
//-----------------------------------------------------------------------------
