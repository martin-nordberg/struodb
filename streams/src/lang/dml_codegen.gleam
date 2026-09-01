import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import lang/catalog.{type Catalog}
import lang/dml_ast as ast
import lang/dml_parser
import lang/dml_semantics
import lang/expr_codegen
import lang/expr_parser.{type ParseError}
import lang/lexer
import lang/token_stream

//-----------------------------------------------------------------------------
// Turns a `DmlStatement` (already validated by `dml_semantics.gleam`)
// into PostgreSQL `INSERT INTO` SQL text. See
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
    errors: List(dml_semantics.SemanticError),
  )
}

/// Validates every statement in `source` against `catalog` (threaded
/// across them in order, exactly as calling `dml_semantics.analyze`
/// repeatedly would), and — only if every one of them passes — returns
/// the equivalent formatted PostgreSQL for all of them concatenated, plus
/// the resulting `Catalog`. `INSERT` never changes a stream's shape, so
/// the returned catalog is always identical to `catalog`; it's still
/// returned, for symmetry with `ddl_codegen.generate` and so a caller
/// chaining several batches doesn't need to special-case which kind it's
/// threading.
pub fn generate(
  catalog: Catalog,
  source: String,
) -> Result(#(String, Catalog), CodegenError) {
  use tokens <- result.try(
    lexer.tokenize(source) |> result.map_error(LexFailure),
  )
  use statements <- result.try(
    dml_parser.parse_many(token_stream.new(tokens))
    |> result.map_error(ParseFailure),
  )
  use final_catalog <- result.try(validate_all(catalog, statements, 0))
  Ok(#(render_all(statements), final_catalog))
}

/// Convenience wrapper for the common single-shot case: validates
/// against an empty `Catalog`. Realistically only useful for a source
/// whose `INSERT`s target streams whose shape doesn't matter for this
/// call's own purposes — most callers will want `generate` with a real
/// `Catalog` (e.g. one `schema/ddl_codegen.generate` already produced).
pub fn generate_standalone(source: String) -> Result(String, CodegenError) {
  use #(sql, _catalog) <- result.try(generate(catalog.empty(), source))
  Ok(sql)
}

fn validate_all(
  catalog: Catalog,
  statements: List(ast.DmlStatement),
  index: Int,
) -> Result(Catalog, CodegenError) {
  case statements {
    [] -> Ok(catalog)
    [stmt, ..rest] ->
      case dml_semantics.analyze(catalog, stmt) {
        Ok(next_catalog) -> validate_all(next_catalog, rest, index + 1)
        Error(errors) -> Error(SemanticFailure(index, errors))
      }
  }
}

fn render_all(statements: List(ast.DmlStatement)) -> String {
  statements
  |> list.map(fn(stmt) { insert_to_sql(stmt) |> string_tree.from_string })
  |> string_tree.join("\n\n")
  |> string_tree.append("\n")
  |> string_tree.to_string
}

//-----------------------------------------------------------------------------
// INSERT -> INSERT INTO
//-----------------------------------------------------------------------------

pub fn insert_to_sql(stmt: ast.DmlStatement) -> String {
  let ast.Insert(
    stream_name:,
    columns:,
    rows:,
    on_conflict_do_nothing:,
    returning:,
    span: _,
  ) = stmt

  "INSERT INTO "
  <> expr_codegen.quote_identifier(stream_name)
  <> " ("
  <> { columns |> list.map(expr_codegen.quote_identifier) |> string.join(", ") }
  <> ")\nVALUES\n  "
  <> { rows |> list.map(row_to_sql) |> string.join(",\n  ") }
  <> on_conflict_sql(on_conflict_do_nothing)
  <> returning_sql(returning)
  <> ";"
}

fn row_to_sql(row: List(ast.Value)) -> String {
  "(" <> { row |> list.map(value_to_sql) |> string.join(", ") } <> ")"
}

fn value_to_sql(value: ast.Value) -> String {
  case value {
    // Bare `DEFAULT`, §11.3 — matches PostgreSQL's own identical syntax
    // directly.
    ast.ValueDefault -> "DEFAULT"
    ast.ValueExpr(expr) -> expr_codegen.expr_to_sql(expr)
  }
}

fn on_conflict_sql(on_conflict_do_nothing: Bool) -> String {
  case on_conflict_do_nothing {
    True -> "\nON CONFLICT DO NOTHING"
    False -> ""
  }
}

fn returning_sql(returning: Option(List(ast.ReturningItem))) -> String {
  case returning {
    None -> ""
    Some(items) ->
      "\nRETURNING "
      <> { items |> list.map(returning_item_to_sql) |> string.join(", ") }
  }
}

fn returning_item_to_sql(item: ast.ReturningItem) -> String {
  case item {
    ast.ReturningStar -> "*"
    ast.ReturningExpr(expr, None) -> expr_codegen.expr_to_sql(expr)
    ast.ReturningExpr(expr, Some(alias)) ->
      expr_codegen.expr_to_sql(expr)
      <> " AS "
      <> expr_codegen.quote_identifier(alias)
  }
}
//-----------------------------------------------------------------------------
