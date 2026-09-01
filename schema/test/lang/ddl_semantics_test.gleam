import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lang/catalog
import lang/ddl_ast as ast
import lang/ddl_parser
import lang/ddl_semantics
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

fn column(name: String, data_type: xast.DataType) -> ast.ColumnDef {
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

fn col_ref(name: String) -> xast.Expr {
  xast.ColumnRef(name, dummy_span())
}

fn create_stream(
  name: String,
  elements: List(ast.StreamElement),
) -> ast.DdlStatement {
  ast.CreateStream(name: name, elements: elements, span: dummy_span())
}

fn alter_stream(
  name: String,
  actions: List(ast.AlterAction),
) -> ast.DdlStatement {
  ast.AlterStream(name: name, actions: actions, span: dummy_span())
}

fn parse_source(source: String) -> ast.DdlStatement {
  let assert Ok(tokens) = lexer.tokenize(source)
  let assert Ok(stmt) = ddl_parser.parse(token_stream.new(tokens))
  stmt
}

/// `s`: `id HLC`, `a INT`, `name VARCHAR(64)` (both `a` and `name`
/// `NOT NULL`, no default), `computed INT GENERATED ALWAYS AS (1)
/// STORED`, and a table-level `CONSTRAINT a_positive CHECK (a > 0)`.
fn base_stream_create() -> ast.DdlStatement {
  create_stream("s", [
    ast.Column(column("id", xast.DtHlc)),
    ast.Column(column("a", xast.DtInt)),
    ast.Column(column("name", xast.DtVarchar(Some(64)))),
    ast.Column(ast.ColumnDef(
      name: "computed",
      data_type: xast.DtInt,
      optional: False,
      default: None,
      generated: Some(xast.GeneratedClause(xast.IntLiteral("1"), xast.Stored)),
      checks: [],
      span: dummy_span(),
    )),
    ast.TableConstraint(
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
// CREATE STREAM — one test per SemanticError variant it can raise
//-----------------------------------------------------------------------------

pub fn missing_hlc_column_test() {
  let stmt = create_stream("s", [ast.Column(column("a", xast.DtInt))])
  let assert Error([ddl_semantics.MissingHlcColumn(stream: "s", span: _)]) =
    ddl_semantics.analyze(catalog.empty(), stmt)
}

pub fn multiple_hlc_columns_test() {
  let stmt =
    create_stream("s", [
      ast.Column(column("a", xast.DtHlc)),
      ast.Column(column("b", xast.DtHlc)),
    ])
  let assert Error([
    ddl_semantics.MultipleHlcColumns(
      stream: "s",
      first: "a",
      second: "b",
      span: _,
    ),
  ]) = ddl_semantics.analyze(catalog.empty(), stmt)
}

pub fn hlc_column_optional_test() {
  let stmt =
    create_stream("s", [
      ast.Column(ast.ColumnDef(..column("a", xast.DtHlc), optional: True)),
    ])
  let assert Error([ddl_semantics.HlcColumnOptional(column: "a", span: _)]) =
    ddl_semantics.analyze(catalog.empty(), stmt)
}

pub fn hlc_column_has_default_or_generated_test() {
  let stmt =
    create_stream("s", [
      ast.Column(
        ast.ColumnDef(
          ..column("a", xast.DtHlc),
          default: Some(xast.StringLiteral("x")),
        ),
      ),
    ])
  let assert Error([
    ddl_semantics.HlcColumnHasDefaultOrGenerated(column: "a", span: _),
  ]) = ddl_semantics.analyze(catalog.empty(), stmt)
}

pub fn default_references_column_test() {
  let stmt =
    create_stream("s", [
      ast.Column(column("id", xast.DtHlc)),
      ast.Column(
        ast.ColumnDef(..column("b", xast.DtInt), default: Some(col_ref("id"))),
      ),
    ])
  let assert Error([
    ddl_semantics.DefaultReferencesColumn(
      column: "b",
      referenced: "id",
      span: _,
    ),
  ]) = ddl_semantics.analyze(catalog.empty(), stmt)
}

pub fn unknown_column_reference_test() {
  let check = xast.NamedCheck("c1", col_ref("nonexistent"), dummy_span())
  let stmt =
    create_stream("s", [
      ast.Column(column("id", xast.DtHlc)),
      ast.TableConstraint(check: check, span: dummy_span()),
    ])
  let assert Error([
    ddl_semantics.UnknownColumnReference(referenced: "nonexistent", span: _),
  ]) = ddl_semantics.analyze(catalog.empty(), stmt)
}

pub fn duplicate_column_name_test() {
  let stmt =
    create_stream("s", [
      ast.Column(column("id", xast.DtHlc)),
      ast.Column(column("a", xast.DtInt)),
      ast.Column(column("a", xast.DtInt)),
    ])
  let assert Error([
    ddl_semantics.DuplicateColumnName(stream: "s", name: "a", span: _),
  ]) = ddl_semantics.analyze(catalog.empty(), stmt)
}

pub fn duplicate_constraint_name_test() {
  let check1 = xast.NamedCheck("c1", xast.BoolLiteral(True), dummy_span())
  let check2 = xast.NamedCheck("c1", xast.BoolLiteral(True), dummy_span())
  let stmt =
    create_stream("s", [
      ast.Column(column("id", xast.DtHlc)),
      ast.TableConstraint(check: check1, span: dummy_span()),
      ast.TableConstraint(check: check2, span: dummy_span()),
    ])
  let assert Error([
    ddl_semantics.DuplicateConstraintName(stream: "s", name: "c1", span: _),
  ]) = ddl_semantics.analyze(catalog.empty(), stmt)
}

pub fn invalid_data_type_parameter_test() {
  let stmt =
    create_stream("s", [
      ast.Column(column("id", xast.DtHlc)),
      ast.Column(column("x", xast.DtVarchar(Some(0)))),
    ])
  let assert Error([
    ddl_semantics.InvalidDataTypeParameter(column: "x", span: _, reason: _),
  ]) = ddl_semantics.analyze(catalog.empty(), stmt)
}

pub fn a_statement_with_two_independent_violations_reports_both_test() {
  let stmt =
    create_stream("bad", [
      ast.Column(column("a", xast.DtInt)),
      ast.TableConstraint(
        check: xast.NamedCheck("c", col_ref("nope"), dummy_span()),
        span: dummy_span(),
      ),
    ])
  let assert Error(errors) = ddl_semantics.analyze(catalog.empty(), stmt)
  assert list.length(errors) == 2
  assert list.contains(
    errors,
    ddl_semantics.MissingHlcColumn(stream: "bad", span: dummy_span()),
  )
  assert list.contains(
    errors,
    ddl_semantics.UnknownColumnReference(referenced: "nope", span: dummy_span()),
  )
}

pub fn unknown_column_reference_span_is_the_column_refs_own_span_test() {
  let ref_span =
    token.Span(
      token.Position(line: 5, column: 10, byte_offset: 100),
      token.Position(line: 5, column: 20, byte_offset: 110),
    )
  let check =
    xast.NamedCheck(
      "c",
      xast.BinaryOp(
        xast.LogicalAnd,
        col_ref("a"),
        xast.BinaryOp(
          xast.CmpGt,
          xast.ColumnRef("unknown_col", ref_span),
          xast.IntLiteral("0"),
        ),
      ),
      dummy_span(),
    )
  let stmt =
    create_stream("s", [
      ast.Column(column("id", xast.DtHlc)),
      ast.Column(column("a", xast.DtBoolean)),
      ast.TableConstraint(check: check, span: dummy_span()),
    ])
  let assert Error([
    ddl_semantics.UnknownColumnReference(
      referenced: "unknown_col",
      span: got_span,
    ),
  ]) = ddl_semantics.analyze(catalog.empty(), stmt)
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
      ast.Column(column("id", xast.DtHlc)),
      ast.Column(column(prefix <> "x", xast.DtInt)),
      ast.Column(column(prefix <> "y", xast.DtInt)),
    ])
  let assert Error(errors) = ddl_semantics.analyze(catalog.empty(), stmt)
  assert list.any(errors, fn(e) {
    case e {
      ddl_semantics.DuplicateColumnName(..) -> True
      _ -> False
    }
  })
}

pub fn names_differing_well_within_63_bytes_do_not_collide_test() {
  let stmt =
    create_stream("s", [
      ast.Column(column("id", xast.DtHlc)),
      ast.Column(column("alpha", xast.DtInt)),
      ast.Column(column("beta", xast.DtInt)),
    ])
  let assert Ok(_) = ddl_semantics.analyze(catalog.empty(), stmt)
}

//-----------------------------------------------------------------------------
// ALTER STREAM — one test per SemanticError variant it can raise
//-----------------------------------------------------------------------------

pub fn unknown_stream_test() {
  let stmt =
    alter_stream("nope", [ast.DropColumn(column_name: "x", span: dummy_span())])
  let assert Error([ddl_semantics.UnknownStream(name: "nope", span: _)]) =
    ddl_semantics.analyze(catalog.empty(), stmt)
}

pub fn add_column_needs_optional_or_default_test() {
  let stmt =
    alter_stream("s", [ast.AddColumn(column("b", xast.DtInt), dummy_span())])
  let assert Error([
    ddl_semantics.AddColumnNeedsOptionalOrDefault(column: "b", span: _),
  ]) = ddl_semantics.analyze(base_catalog(), stmt)
}

pub fn add_second_hlc_column_test() {
  let stmt =
    alter_stream("s", [
      ast.AddColumn(
        ast.ColumnDef(..column("b2", xast.DtHlc), optional: True),
        dummy_span(),
      ),
    ])
  let assert Error([ddl_semantics.AddSecondHlcColumn(column: "b2", span: _)]) =
    ddl_semantics.analyze(base_catalog(), stmt)
}

pub fn drop_non_optional_column_test() {
  let stmt =
    alter_stream("s", [ast.DropColumn(column_name: "a", span: dummy_span())])
  let assert Error([ddl_semantics.DropNonOptionalColumn(column: "a", span: _)]) =
    ddl_semantics.analyze(base_catalog(), stmt)
}

pub fn drop_unknown_column_test() {
  let stmt =
    alter_stream("s", [ast.DropColumn(column_name: "zzz", span: dummy_span())])
  let assert Error([ddl_semantics.DropUnknownColumn(column: "zzz", span: _)]) =
    ddl_semantics.analyze(base_catalog(), stmt)
}

pub fn narrowing_type_change_test() {
  let stmt =
    alter_stream("s", [
      ast.AlterColumnType(
        column_name: "name",
        data_type: xast.DtVarchar(Some(32)),
        span: dummy_span(),
      ),
    ])
  let assert Error([
    ddl_semantics.NarrowingTypeChange(
      column: "name",
      from: xast.DtVarchar(Some(64)),
      to: xast.DtVarchar(Some(32)),
      span: _,
    ),
  ]) = ddl_semantics.analyze(base_catalog(), stmt)
}

pub fn unsupported_type_change_test() {
  let stmt =
    alter_stream("s", [
      ast.AlterColumnType(
        column_name: "a",
        data_type: xast.DtDecimal(None, None),
        span: dummy_span(),
      ),
    ])
  let assert Error([
    ddl_semantics.UnsupportedTypeChange(
      column: "a",
      from: xast.DtInt,
      to: xast.DtDecimal(None, None),
      span: _,
    ),
  ]) = ddl_semantics.analyze(base_catalog(), stmt)
}

pub fn drop_unknown_constraint_test() {
  let stmt =
    alter_stream("s", [
      ast.DropConstraint(constraint_name: "zzz", span: dummy_span()),
    ])
  let assert Error([ddl_semantics.DropUnknownConstraint(name: "zzz", span: _)]) =
    ddl_semantics.analyze(base_catalog(), stmt)
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

pub fn create_stream_example_analyzes_clean_test() {
  let assert Ok(cat) =
    ddl_semantics.analyze(catalog.empty(), parse_source(create_stream_example))
  let assert Ok(schema) = dict.get(cat.streams, "sensor_reading")
  assert schema.hlc_column == "reading_hlc"
  assert dict.size(schema.columns) == 6
  assert dict.size(schema.constraints) == 1
}

pub fn alter_example_analyzes_clean_test() {
  let assert Ok(cat1) =
    ddl_semantics.analyze(catalog.empty(), parse_source(create_stream_example))
  let assert Ok(cat2) =
    ddl_semantics.analyze(cat1, parse_source(alter_stream_example))
  let assert Ok(schema) = dict.get(cat2.streams, "sensor_reading")
  assert dict.has_key(schema.columns, "calibration_id")
  let assert Ok(units) = dict.get(schema.columns, "units")
  assert units.data_type == xast.DtVarchar(Some(64))
}
//-----------------------------------------------------------------------------
