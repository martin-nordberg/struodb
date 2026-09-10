import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import lang/catalog.{type Catalog}
import lang/ddl_ast as ast
import lang/ddl_parser
import lang/ddl_semantics
import lang/expr_ast as xast
import lang/expr_codegen
import lang/expr_parser.{type ParseError}
import lang/lexer
import lang/token_stream

//-----------------------------------------------------------------------------
// Turns a `DdlStatement` (already validated by `ddl_semantics.gleam`)
// into PostgreSQL `CREATE TABLE`/`ALTER TABLE` SQL text. See
// docs/lang/codegen-plan.md's "Statement codegen" for the rendering
// rules and "Worked examples" for the concrete acceptance target.
//-----------------------------------------------------------------------------

pub type CodegenError {
  LexFailure(lexer.LexError)
  ParseFailure(ParseError)
  /// `statement_index` is 0-based, counting only statements that were
  /// successfully parsed before this one failed to validate.
  SemanticFailure(
    statement_index: Int,
    errors: List(ddl_semantics.SemanticError),
  )
}

/// Validates every statement in `source` against `catalog` (threaded
/// across them in order, exactly as calling `ddl_semantics.analyze`
/// repeatedly would), and — only if every one of them passes — returns
/// the equivalent formatted PostgreSQL for all of them concatenated, plus
/// the resulting `Catalog`. Returning the catalog lets a caller
/// processing several files/batches in sequence chain calls, passing
/// each result's catalog into the next.
pub fn generate(
  catalog: Catalog,
  source: String,
) -> Result(#(String, Catalog), CodegenError) {
  use tokens <- result.try(
    lexer.tokenize(source) |> result.map_error(LexFailure),
  )
  use statements <- result.try(
    ddl_parser.parse_many(token_stream.new(tokens))
    |> result.map_error(ParseFailure),
  )
  use final_catalog <- result.try(validate_all(catalog, statements, 0))
  Ok(#(render_all(statements), final_catalog))
}

/// Convenience wrapper for the common single-shot case: no prior
/// migration history to seed the catalog with.
pub fn generate_standalone(source: String) -> Result(String, CodegenError) {
  use #(sql, _catalog) <- result.try(generate(catalog.empty(), source))
  Ok(sql)
}

fn validate_all(
  catalog: Catalog,
  statements: List(ast.DdlStatement),
  index: Int,
) -> Result(Catalog, CodegenError) {
  case statements {
    [] -> Ok(catalog)
    [stmt, ..rest] ->
      case validate_statement(catalog, stmt, index) {
        Ok(next_catalog) -> validate_all(next_catalog, rest, index + 1)
        Error(err) -> Error(err)
      }
  }
}

/// Validates one already-parsed statement against `catalog`, wrapping a
/// failure into `SemanticFailure(index, ..)` — the per-statement step
/// `validate_all`'s own fold above is built from. Exposed as `pub` so
/// `ddl_migration.gleam` (see
/// documentation/plans/lang/migration-plan.md) can reuse this exact
/// step — same `ddl_semantics.analyze`-and-wrap behavior, same error
/// shape `apply_ddl`'s callers already see — without its own copy or a
/// direct `ddl_semantics` dependency. `index` is a caller-supplied
/// 0-based position, not necessarily this statement's index within some
/// larger list `ddl_migration.gleam` is itself iterating (it skips
/// *rendering*, not *validating*, some statements — see that module).
pub fn validate_statement(
  catalog: Catalog,
  stmt: ast.DdlStatement,
  index: Int,
) -> Result(Catalog, CodegenError) {
  case ddl_semantics.analyze(catalog, stmt) {
    Ok(next_catalog) -> Ok(next_catalog)
    Error(errors) -> Error(SemanticFailure(index, errors))
  }
}

/// Runs over the *original* `statements` list from `parse_many` —
/// `validate_all` only threads a `Catalog` for checking, never
/// transforms the statements themselves (there's nothing for it to add:
/// everything codegen needs is already in the AST — see
/// docs/lang/codegen-plan.md's "Design decisions").
fn render_all(statements: List(ast.DdlStatement)) -> String {
  statements
  |> list.map(fn(stmt) { statement_to_sql(stmt) |> string_tree.from_string })
  |> string_tree.join("\n\n")
  |> string_tree.append("\n")
  |> string_tree.to_string
}

fn statement_to_sql(stmt: ast.DdlStatement) -> String {
  case stmt {
    ast.CreateStream(..) -> create_stream_to_sql(stmt)
    ast.AlterStream(..) -> alter_stream_to_sql(stmt)
  }
}

//-----------------------------------------------------------------------------
// CREATE STREAM -> CREATE TABLE
//-----------------------------------------------------------------------------

/// Renders `stmt`'s own `CREATE TABLE` plus the two event-store
/// bookkeeping tables every stream gets alongside it (see
/// `documentation/plans/architecture/event-store-implementation-plan.md`,
/// Phase 3, and `catalog.migration_history_table_name`/
/// `pending_aggregations_table_name`'s own doc comments for each
/// table's schema) — 3 statements, joined the same way `render_all`
/// joins multiple top-level statements. Neither bookkeeping table is
/// part of a stream's *declared shape*: `ddl_semantics.gleam`/
/// `catalog.gleam` never track columns/constraints for them, only the
/// name each is rendered under.
pub fn create_stream_to_sql(stmt: ast.DdlStatement) -> String {
  let assert ast.CreateStream(name:, ..) = stmt

  [
    main_table_sql(stmt),
    migration_history_table_sql(name),
    pending_aggregations_table_sql(name),
  ]
  |> string.join("\n\n")
}

fn main_table_sql(stmt: ast.DdlStatement) -> String {
  let assert ast.CreateStream(name:, elements:, span: _) = stmt

  let columns = column_defs(elements)
  let column_lines =
    list.append(system_column_lines(), list.map(columns, column_def_to_sql))
  let check_lines =
    list.map(
      list.append(
        list.flat_map(columns, fn(c) { c.checks }),
        table_constraints(elements),
      ),
      named_check_to_sql,
    )

  "CREATE TABLE "
  <> expr_codegen.quote_identifier(name)
  <> " (\n"
  <> {
    list.append(column_lines, check_lines)
    |> list.map(fn(line) { "  " <> line })
    |> string.join(",\n")
  }
  <> "\n);"
}

fn migration_history_table_sql(stream: String) -> String {
  "CREATE TABLE "
  <> expr_codegen.quote_identifier(catalog.migration_history_table_name(stream))
  <> " (\n  seq INTEGER NOT NULL PRIMARY KEY,\n  hash CHAR(64) NOT NULL\n);"
}

fn pending_aggregations_table_sql(stream: String) -> String {
  "CREATE TABLE "
  <> expr_codegen.quote_identifier(catalog.pending_aggregations_table_name(
    stream,
  ))
  <> " (\n"
  <> "  aggregator_node_id INTEGER NOT NULL,\n"
  <> "  event_hlc "
  <> expr_codegen.data_type_to_sql(xast.DtChar(Some(15)))
  <> " NOT NULL REFERENCES "
  <> expr_codegen.quote_identifier(stream)
  <> "("
  <> expr_codegen.quote_identifier(catalog.hlc_column_name)
  <> ") ON DELETE CASCADE,\n"
  <> "  PRIMARY KEY (aggregator_node_id, event_hlc)\n);"
}

/// The 5 automatic system columns (catalog.gleam's `system_columns()`),
/// rendered exactly once here — every stream gets these regardless of
/// what `CREATE STREAM` itself declares (spec.md §9.2). `_STRUO_HLC`
/// omits an explicit `NOT NULL` the same way a `PRIMARY KEY` column
/// always has, below, since `PRIMARY KEY` already implies it.
/// `_struo_created_at` is the one column here with a `DEFAULT`: unlike
/// the other 4, `dml_codegen.gleam` never writes it into a generated
/// `INSERT` at all, so `DEFAULT clock_timestamp()` — PostgreSQL's own
/// "now," evaluated at actual insert time — is what actually populates
/// it.
fn system_column_lines() -> List(String) {
  [
    expr_codegen.quote_identifier(catalog.hlc_column_name)
      <> " "
      <> expr_codegen.data_type_to_sql(xast.DtChar(Some(15)))
      <> " PRIMARY KEY",
    expr_codegen.quote_identifier(catalog.hlc_timestamp_column_name)
      <> " "
      <> expr_codegen.data_type_to_sql(xast.DtTimestamptz)
      <> " NOT NULL",
    expr_codegen.quote_identifier(catalog.hlc_count_column_name)
      <> " "
      <> expr_codegen.data_type_to_sql(xast.DtInteger)
      <> " NOT NULL",
    expr_codegen.quote_identifier(catalog.hlc_node_id_column_name)
      <> " "
      <> expr_codegen.data_type_to_sql(xast.DtInteger)
      <> " NOT NULL",
    expr_codegen.quote_identifier(catalog.created_at_column_name)
      <> " "
      <> expr_codegen.data_type_to_sql(xast.DtTimestamptz)
      <> " NOT NULL DEFAULT "
      <> expr_codegen.expr_to_sql(xast.FunctionCall("clock_timestamp", [])),
  ]
}

fn column_defs(elements: List(ast.StreamElement)) -> List(ast.ColumnDef) {
  list.filter_map(elements, fn(element) {
    case element {
      ast.Column(col) -> Ok(col)
      ast.TableConstraint(..) -> Error(Nil)
    }
  })
}

fn table_constraints(
  elements: List(ast.StreamElement),
) -> List(xast.NamedCheck) {
  list.filter_map(elements, fn(element) {
    case element {
      ast.TableConstraint(check:, span: _) -> Ok(check)
      ast.Column(..) -> Error(Nil)
    }
  })
}

/// `"name" TYPE [NOT NULL | nothing if OPTIONAL or GENERATED] [DEFAULT
/// expr] [GENERATED ALWAYS AS (expr) STORED] [PRIMARY KEY if this is the
/// HLC column]` — see "Statement codegen" in docs/lang/codegen-plan.md.
/// Every column-level `CHECK` is rendered separately, as its own
/// trailing `CONSTRAINT` line (`named_check_to_sql`), not inlined here —
/// see `create_stream_to_sql`.
fn column_def_to_sql(col: ast.ColumnDef) -> String {
  [
    expr_codegen.quote_identifier(col.name),
    expr_codegen.data_type_to_sql(col.data_type),
    case !col.optional && option.is_none(col.generated) {
      True -> "NOT NULL"
      False -> ""
    },
    case col.default {
      Some(expr) -> "DEFAULT " <> expr_codegen.expr_to_sql(expr)
      None -> ""
    },
    case col.generated {
      Some(xast.GeneratedClause(expr, _storage)) ->
        "GENERATED ALWAYS AS (" <> expr_codegen.expr_to_sql(expr) <> ") STORED"
      None -> ""
    },
  ]
  |> list.filter(fn(part) { part != "" })
  |> string.join(" ")
}

fn named_check_to_sql(check: xast.NamedCheck) -> String {
  "CONSTRAINT "
  <> expr_codegen.quote_identifier(check.constraint_name)
  <> " CHECK ("
  <> expr_codegen.expr_to_sql(check.expr)
  <> ")"
}

//-----------------------------------------------------------------------------
// ALTER STREAM -> ALTER TABLE
//-----------------------------------------------------------------------------

pub fn alter_stream_to_sql(stmt: ast.DdlStatement) -> String {
  let assert ast.AlterStream(name:, actions:, span: _) = stmt

  "ALTER TABLE "
  <> expr_codegen.quote_identifier(name)
  <> "\n"
  <> {
    actions
    |> list.map(alter_action_to_sql)
    |> list.map(fn(line) { "  " <> line })
    |> string.join(",\n")
  }
  <> ";"
}

fn alter_action_to_sql(action: ast.AlterAction) -> String {
  case action {
    ast.AddColumn(col, _span) -> "ADD COLUMN " <> column_def_to_sql(col)
    ast.DropColumn(column_name:, span: _) ->
      "DROP COLUMN " <> expr_codegen.quote_identifier(column_name)
    ast.AlterColumnType(column_name:, data_type:, span: _) ->
      "ALTER COLUMN "
      <> expr_codegen.quote_identifier(column_name)
      <> " TYPE "
      <> expr_codegen.data_type_to_sql(data_type)
    ast.AddConstraint(check) -> "ADD " <> named_check_to_sql(check)
    ast.DropConstraint(constraint_name:, span: _) ->
      "DROP CONSTRAINT " <> expr_codegen.quote_identifier(constraint_name)
  }
}
//-----------------------------------------------------------------------------
