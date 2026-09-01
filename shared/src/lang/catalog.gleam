import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import lang/expr_ast.{
  type DataType, type Expr, type GeneratedClause, type NamedCheck, DtChar,
  DtInteger, DtTimestamptz,
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
    /// `True` for exactly the 4 fixed `_STRUO_`-prefixed columns
    /// `system_columns()` below adds to every stream — never settable by
    /// anything derived from a parsed `ddl_ast`. Lets `dml_semantics`
    /// (streams/) exclude these from an `INSERT`'s column list the same
    /// way it already excludes `GENERATED` columns, and `ddl_semantics`
    /// (schema/) refuse `DROP COLUMN`/`ALTER COLUMN TYPE` against them,
    /// without either package needing its own notion of "which columns
    /// are these."
    system: Bool,
  )
}

pub fn empty() -> Catalog {
  Catalog(streams: dict.new())
}

//-----------------------------------------------------------------------------
// The 4 automatic system columns every stream gets, regardless of what
// `CREATE STREAM` itself declares — see "The StruoDB query language
// front end" in CLAUDE.md and docs/lang/spec.md §9.2. Defined once, here,
// since `ddl_codegen.gleam` (schema/) needs these same names/types to
// render the `CREATE TABLE` column lines, and `dml_codegen.gleam`
// (streams/) needs them to render an `INSERT`'s extra column list —
// keeping a single source of truth for "what are they called, in what
// order" is what lets both packages stay in lockstep without one
// depending on the other.
//-----------------------------------------------------------------------------

/// The whole encoded HLC value (see docs/hlc/spec.md) — a fixed 15
/// characters, and the table's `PRIMARY KEY`. Lower case, like any other
/// unquoted identifier (spec.md §2) — an uppercase name would only ever
/// force `expr_codegen.quote_identifier` to render it quoted, visually
/// distinct from every ordinary user column for no functional reason,
/// and would force a client to quote it too when referencing it (e.g. in
/// `RETURNING`) to avoid its own unquoted spelling folding away from the
/// catalog's exact-case key.
pub const hlc_column_name = "_struo_hlc"

/// The HLC's embedded physical-time field, as a real `TIMESTAMPTZ`.
pub const hlc_timestamp_column_name = "_struo_hlc_timestamp"

/// The HLC's embedded logical counter.
pub const hlc_count_column_name = "_struo_hlc_count"

/// The HLC's embedded node id, decoded from base-62 to its integer value.
pub const hlc_node_id_column_name = "_struo_hlc_node_id"

/// The 4 system columns, in the fixed order they're always rendered:
/// leading every `CREATE TABLE`'s column list and every generated
/// `INSERT`'s column list alike.
pub fn system_columns() -> List(ColumnSchema) {
  [
    ColumnSchema(
      name: hlc_column_name,
      data_type: DtChar(Some(15)),
      optional: False,
      default: None,
      generated: None,
      system: True,
    ),
    ColumnSchema(
      name: hlc_timestamp_column_name,
      data_type: DtTimestamptz,
      optional: False,
      default: None,
      generated: None,
      system: True,
    ),
    ColumnSchema(
      name: hlc_count_column_name,
      data_type: DtInteger,
      optional: False,
      default: None,
      generated: None,
      system: True,
    ),
    ColumnSchema(
      name: hlc_node_id_column_name,
      data_type: DtInteger,
      optional: False,
      default: None,
      generated: None,
      system: True,
    ),
  ]
}

//-----------------------------------------------------------------------------
// CREATE STREAM
//-----------------------------------------------------------------------------

/// Declares a new stream named `name`, with `columns` (a caller-supplied,
/// user-declared list) automatically joined by the 4 fixed
/// `system_columns()` above. Callers (`ddl_semantics.gleam`) are expected
/// to have already validated the `CreateStream` producing these arguments
/// and to call this only once that has come back `Ok` — this function
/// does not re-check any of it: in particular, that `columns`/
/// `constraints` carry no duplicate names (a later entry for the same
/// name silently wins, same as `dict.insert` always does) and that none
/// of `columns` collides with a system column name (`ddl_semantics.gleam`
/// rejects any user-declared name starting with `_STRUO_` before this is
/// ever called).
pub fn create_stream(
  catalog: Catalog,
  name: String,
  columns: List(ColumnSchema),
  constraints: List(NamedCheck),
) -> Catalog {
  let schema =
    StreamSchema(
      name: name,
      columns: index_by(list.append(system_columns(), columns), fn(col) {
        col.name
      }),
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
