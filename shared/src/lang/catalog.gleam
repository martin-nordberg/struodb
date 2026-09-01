import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option}
import lang/expr_ast.{
  type DataType, type Expr, type GeneratedClause, type NamedCheck,
}

//-----------------------------------------------------------------------------
// A stream's currently-declared shape, and the primitive operations that
// change it. Kept separate from ddl_semantics.gleam because "what a
// stream currently looks like" is a reusable concept a later codegen
// stage will also need (e.g. to know a column's current type when
// emitting `ALTER TABLE ... TYPE`) — it shouldn't only exist as a side
// effect of validation.
//
// Deliberately knows nothing about `ddl_ast.gleam`'s `DdlStatement`/
// `StreamElement`/`AlterAction` — only `ColumnSchema`/`NamedCheck`, both
// already shared (`NamedCheck` lives in expr_ast.gleam). Every function
// below is a small, direct primitive (`create_stream`, `add_column`, ...)
// rather than one `apply_statement(catalog, stmt)` that would need
// `DdlStatement` in hand; `ddl_semantics.gleam` (schema/) does that
// translation itself, one `DdlStatement` variant at a time, since it
// already builds the same column/constraint lists for validation. This is
// what lets this module live in `shared/` rather than `schema/`, next to
// `ddl_ast.gleam` — `dml_semantics.gleam` (streams/) needs a `Catalog` too,
// to validate `INSERT` against a stream's current shape, and depending on
// `shared` alone for it (rather than the whole `schema` package, DDL
// parser and semantics included) keeps `schema` and `streams` the
// independent service boundaries CLAUDE.md describes them as.
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

//-----------------------------------------------------------------------------
// CREATE STREAM
//-----------------------------------------------------------------------------

/// Declares a new stream named `name`. Callers (`ddl_semantics.gleam`) are
/// expected to have already validated the `CreateStream` producing these
/// arguments and to call this only once that has come back `Ok` — this
/// function does not re-check any of it: in particular, that `hlc_column`
/// actually names one of `columns`, and that `columns`/`constraints`
/// carry no duplicate names (a later entry for the same name silently
/// wins, same as `dict.insert` always does).
pub fn create_stream(
  catalog: Catalog,
  name: String,
  columns: List(ColumnSchema),
  hlc_column: String,
  constraints: List(NamedCheck),
) -> Catalog {
  let schema =
    StreamSchema(
      name: name,
      columns: index_by(columns, fn(col) { col.name }),
      hlc_column: hlc_column,
      constraints: index_by(constraints, fn(check) { check.constraint_name }),
    )
  Catalog(streams: dict.insert(catalog.streams, name, schema))
}

fn index_by(items: List(a), key: fn(a) -> String) -> Dict(String, a) {
  list.fold(items, dict.new(), fn(acc, item) {
    dict.insert(acc, key(item), item)
  })
}

//-----------------------------------------------------------------------------
// ALTER STREAM
//-----------------------------------------------------------------------------

/// Adds `column` to `stream`'s declared columns. Callers are expected to
/// have already confirmed `stream` exists and that `column.name` doesn't
/// collide with an existing one — see `create_stream`'s doc comment on
/// what "not re-checked" means here too.
pub fn add_column(
  catalog: Catalog,
  stream: String,
  column: ColumnSchema,
) -> Catalog {
  update_schema(catalog, stream, fn(schema) {
    StreamSchema(
      ..schema,
      columns: dict.insert(schema.columns, column.name, column),
    )
  })
}

pub fn drop_column(
  catalog: Catalog,
  stream: String,
  column_name: String,
) -> Catalog {
  update_schema(catalog, stream, fn(schema) {
    StreamSchema(..schema, columns: dict.delete(schema.columns, column_name))
  })
}

pub fn alter_column_type(
  catalog: Catalog,
  stream: String,
  column_name: String,
  data_type: DataType,
) -> Catalog {
  update_schema(catalog, stream, fn(schema) {
    let assert Ok(col) = dict.get(schema.columns, column_name)
    StreamSchema(
      ..schema,
      columns: dict.insert(
        schema.columns,
        column_name,
        ColumnSchema(..col, data_type: data_type),
      ),
    )
  })
}

pub fn add_constraint(
  catalog: Catalog,
  stream: String,
  check: NamedCheck,
) -> Catalog {
  update_schema(catalog, stream, fn(schema) {
    StreamSchema(
      ..schema,
      constraints: dict.insert(schema.constraints, check.constraint_name, check),
    )
  })
}

pub fn drop_constraint(
  catalog: Catalog,
  stream: String,
  constraint_name: String,
) -> Catalog {
  update_schema(catalog, stream, fn(schema) {
    StreamSchema(
      ..schema,
      constraints: dict.delete(schema.constraints, constraint_name),
    )
  })
}

/// Every `ALTER STREAM` action above is "look up `stream`'s current
/// schema, replace it with an updated one" — factored out once here
/// rather than each function re-doing the same `dict.get`/`dict.insert`
/// pair. `let assert` matches `apply_statement`'s original contract: only
/// ever called once `ddl_semantics.gleam` has confirmed `stream` exists.
fn update_schema(
  catalog: Catalog,
  stream: String,
  f: fn(StreamSchema) -> StreamSchema,
) -> Catalog {
  let assert Ok(schema) = dict.get(catalog.streams, stream)
  Catalog(streams: dict.insert(catalog.streams, stream, f(schema)))
}
//-----------------------------------------------------------------------------
