import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option}
import lang/ast.{type DataType, type Expr, type GeneratedClause, type Statement}

//-----------------------------------------------------------------------------
// A stream's currently-declared shape, and how a validated `Statement`
// changes it. Kept separate from semantic.gleam because "what a stream
// currently looks like" is a reusable concept a later codegen stage will
// also need (e.g. to know a column's current type when emitting
// `ALTER TABLE ... TYPE`) — it shouldn't only exist as a side effect of
// validation.
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
    constraints: Dict(String, ast.NamedCheck),
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
/// are expected to call `semantic.analyze` first and only pass a
/// statement here once it has come back `Ok` — this function does not
/// re-validate (semantic.gleam calls it internally as its last step,
/// once every check has passed), and relies on that guarantee: e.g. it
/// assumes an `AlterStream`'s target stream already exists, and that a
/// `CreateStream`'s elements contain exactly one `HLC` column.
pub fn apply_statement(catalog: Catalog, stmt: Statement) -> Catalog {
  case stmt {
    ast.CreateStream(name:, elements:, span: _) ->
      apply_create_stream(catalog, name, elements)
    ast.AlterStream(name:, actions:, span: _) ->
      apply_alter_stream(catalog, name, actions)
    // Never changes a stream's shape.
    ast.Insert(..) -> catalog
  }
}

//-----------------------------------------------------------------------------
// CREATE STREAM
//-----------------------------------------------------------------------------

fn apply_create_stream(
  catalog: Catalog,
  name: String,
  elements: List(ast.StreamElement),
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

fn build_columns(
  elements: List(ast.StreamElement),
) -> Dict(String, ColumnSchema) {
  list.fold(elements, dict.new(), fn(acc, element) {
    case element {
      ast.Column(col) -> dict.insert(acc, col.name, column_schema(col))
      ast.TableConstraint(..) -> acc
    }
  })
}

fn column_schema(col: ast.ColumnDef) -> ColumnSchema {
  ColumnSchema(
    name: col.name,
    data_type: col.data_type,
    optional: col.optional,
    default: col.default,
    generated: col.generated,
  )
}

fn build_constraints(
  elements: List(ast.StreamElement),
) -> Dict(String, ast.NamedCheck) {
  list.fold(elements, dict.new(), fn(acc, element) {
    case element {
      ast.Column(col) ->
        list.fold(col.checks, acc, fn(acc2, check) {
          dict.insert(acc2, check.constraint_name, check)
        })
      ast.TableConstraint(check:, span: _) ->
        dict.insert(acc, check.constraint_name, check)
    }
  })
}

/// Only ever called on a `CreateStream`'s elements once semantic.gleam
/// has already confirmed exactly one column is typed `HLC` — panics
/// otherwise, since that would mean `apply_statement`'s own contract
/// (validate first, apply second) was violated by the caller.
fn find_hlc_column(elements: List(ast.StreamElement)) -> String {
  case elements {
    [] ->
      panic as "find_hlc_column: no HLC column found on an already-validated CreateStream"
    [ast.Column(col), ..rest] ->
      case col.data_type {
        ast.DtHlc -> col.name
        _ -> find_hlc_column(rest)
      }
    [ast.TableConstraint(..), ..rest] -> find_hlc_column(rest)
  }
}

//-----------------------------------------------------------------------------
// ALTER STREAM
//-----------------------------------------------------------------------------

fn apply_alter_stream(
  catalog: Catalog,
  name: String,
  actions: List(ast.AlterAction),
) -> Catalog {
  let assert Ok(schema) = dict.get(catalog.streams, name)
  let updated = list.fold(actions, schema, apply_alter_action)
  Catalog(streams: dict.insert(catalog.streams, name, updated))
}

fn apply_alter_action(
  schema: StreamSchema,
  action: ast.AlterAction,
) -> StreamSchema {
  case action {
    ast.AddColumn(col, _) ->
      StreamSchema(
        ..schema,
        columns: dict.insert(schema.columns, col.name, column_schema(col)),
      )
    ast.DropColumn(column_name:, span: _) ->
      StreamSchema(..schema, columns: dict.delete(schema.columns, column_name))
    ast.AlterColumnType(column_name:, data_type:, span: _) -> {
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
    ast.AddConstraint(check) ->
      StreamSchema(
        ..schema,
        constraints: dict.insert(
          schema.constraints,
          check.constraint_name,
          check,
        ),
      )
    ast.DropConstraint(constraint_name:, span: _) ->
      StreamSchema(
        ..schema,
        constraints: dict.delete(schema.constraints, constraint_name),
      )
  }
}
//-----------------------------------------------------------------------------
