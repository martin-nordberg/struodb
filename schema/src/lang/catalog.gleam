import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option}
import lang/ddl_ast.{
  type AlterAction, type ColumnDef, type DdlStatement, type GeneratedClause,
  type NamedCheck, type StreamElement, AddColumn, AddConstraint, AlterColumnType,
  Column, DropColumn, DropConstraint, TableConstraint,
}
import lang/expr_ast.{type DataType, type Expr, DtHlc}

//-----------------------------------------------------------------------------
// A stream's currently-declared shape, and how a validated `DdlStatement`
// changes it. Kept separate from ddl_semantics.gleam because "what a
// stream currently looks like" is a reusable concept a later codegen
// stage will also need (e.g. to know a column's current type when
// emitting `ALTER TABLE ... TYPE`) — it shouldn't only exist as a side
// effect of validation. Lives in this package rather than shared/ because
// it operates on ddl_ast's `DdlStatement`/`StreamElement`/`AlterAction`
// directly (see `apply_statement` below); streams/ still needs it for
// dml_semantics.gleam's INSERT checks, which is why streams depends on
// this package — see the note in streams/gleam.toml.
//-----------------------------------------------------------------------------

pub type Catalog {
  Catalog(streams: Dict(String, StreamSchema))
}

pub type StreamSchema {
  StreamSchema(
    name: String,
    columns: Dict(String, ColumnSchema),
    /// Name of the (exactly one) `HLC` column — see spec.md §9.2.
    hlc_column: String,
    constraints: Dict(String, NamedCheck),
  )
}

pub type ColumnSchema {
  ColumnSchema(
    name: String,
    data_type: DataType,
    optional: Bool,
    default: Option(Expr),
    generated: Option(GeneratedClause),
  )
}

pub fn empty() -> Catalog {
  Catalog(streams: dict.new())
}

/// Folds one already-validated statement's effect into `catalog`. Callers
/// are expected to call `ddl_semantics.analyze` first and only pass a
/// statement here once it has come back `Ok` — this function does not
/// re-validate (ddl_semantics.gleam calls it internally as its last
/// step, once every check has passed), and relies on that guarantee: e.g. it
/// assumes an `AlterStream`'s target stream already exists, and that a
/// `CreateStream`'s elements contain exactly one `HLC` column.
pub fn apply_statement(catalog: Catalog, stmt: DdlStatement) -> Catalog {
  case stmt {
    ddl_ast.CreateStream(name:, elements:, span: _) ->
      apply_create_stream(catalog, name, elements)
    ddl_ast.AlterStream(name:, actions:, span: _) ->
      apply_alter_stream(catalog, name, actions)
  }
}

//-----------------------------------------------------------------------------
// CREATE STREAM
//-----------------------------------------------------------------------------

fn apply_create_stream(
  catalog: Catalog,
  name: String,
  elements: List(StreamElement),
) -> Catalog {
  let schema =
    StreamSchema(
      name: name,
      columns: build_columns(elements),
      hlc_column: find_hlc_column(elements),
      constraints: build_constraints(elements),
    )
  Catalog(streams: dict.insert(catalog.streams, name, schema))
}

fn build_columns(elements: List(StreamElement)) -> Dict(String, ColumnSchema) {
  list.fold(elements, dict.new(), fn(acc, element) {
    case element {
      Column(col) -> dict.insert(acc, col.name, column_schema(col))
      TableConstraint(..) -> acc
    }
  })
}

fn column_schema(col: ColumnDef) -> ColumnSchema {
  ColumnSchema(
    name: col.name,
    data_type: col.data_type,
    optional: col.optional,
    default: col.default,
    generated: col.generated,
  )
}

fn build_constraints(
  elements: List(StreamElement),
) -> Dict(String, NamedCheck) {
  list.fold(elements, dict.new(), fn(acc, element) {
    case element {
      Column(col) ->
        list.fold(col.checks, acc, fn(acc2, check) {
          dict.insert(acc2, check.constraint_name, check)
        })
      TableConstraint(check:, span: _) ->
        dict.insert(acc, check.constraint_name, check)
    }
  })
}

/// Only ever called on a `CreateStream`'s elements once ddl_semantics.gleam
/// has already confirmed exactly one column is typed `HLC` — panics
/// otherwise, since that would mean `apply_statement`'s own contract
/// (validate first, apply second) was violated by the caller.
fn find_hlc_column(elements: List(StreamElement)) -> String {
  case elements {
    [] ->
      panic as "find_hlc_column: no HLC column found on an already-validated CreateStream"
    [Column(col), ..rest] ->
      case col.data_type {
        DtHlc -> col.name
        _ -> find_hlc_column(rest)
      }
    [TableConstraint(..), ..rest] -> find_hlc_column(rest)
  }
}

//-----------------------------------------------------------------------------
// ALTER STREAM
//-----------------------------------------------------------------------------

fn apply_alter_stream(
  catalog: Catalog,
  name: String,
  actions: List(AlterAction),
) -> Catalog {
  let assert Ok(schema) = dict.get(catalog.streams, name)
  let updated = list.fold(actions, schema, apply_alter_action)
  Catalog(streams: dict.insert(catalog.streams, name, updated))
}

fn apply_alter_action(
  schema: StreamSchema,
  action: AlterAction,
) -> StreamSchema {
  case action {
    AddColumn(col, _) ->
      StreamSchema(
        ..schema,
        columns: dict.insert(schema.columns, col.name, column_schema(col)),
      )
    DropColumn(column_name:, span: _) ->
      StreamSchema(..schema, columns: dict.delete(schema.columns, column_name))
    AlterColumnType(column_name:, data_type:, span: _) -> {
      let assert Ok(col) = dict.get(schema.columns, column_name)
      StreamSchema(
        ..schema,
        columns: dict.insert(
          schema.columns,
          column_name,
          ColumnSchema(..col, data_type: data_type),
        ),
      )
    }
    AddConstraint(check) ->
      StreamSchema(
        ..schema,
        constraints: dict.insert(
          schema.constraints,
          check.constraint_name,
          check,
        ),
      )
    DropConstraint(constraint_name:, span: _) ->
      StreamSchema(
        ..schema,
        constraints: dict.delete(schema.constraints, constraint_name),
      )
  }
}
//-----------------------------------------------------------------------------
