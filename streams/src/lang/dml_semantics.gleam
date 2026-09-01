import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import lang/catalog.{type Catalog}
import lang/dml_ast as ast
import lang/expr_semantics
import lang/token.{type Span}

//-----------------------------------------------------------------------------
// Validates a `Statement` against its `Catalog` — every rule spec.md
// states as "not expressed by the grammar, enforced as a semantic check."
// Every check below accumulates: a `CreateStream`/`AlterStream`/`Insert`
// with several independent violations reports all of them in one
// `Error(list)`, not just the first (see "Design decisions" in
// docs/lang/implementation-plan.md for why).
//-----------------------------------------------------------------------------

pub type SemanticError {
  UnknownStream(name: String, span: Span)
  /// `span` is the offending `ColumnRef`'s own span, not the enclosing
  /// expression's — see "Expression-level spans" in the plan.
  UnknownColumnReference(referenced: String, span: Span)
  InsertColumnListEmpty(span: Span)
  InsertUnknownColumn(column: String, span: Span)
  /// §11.4
  InsertGeneratedColumnInList(column: String, span: Span)
  /// An automatic system column (spec.md §9.2) appeared in an `INSERT`'s
  /// column list — never legal, the same way a `GENERATED` column never
  /// is, since its value is always supplied by the codegen layer itself,
  /// never the client.
  InsertSystemColumnInList(column: String, span: Span)
  /// §11.2/§11.3 — `NOT NULL` with no default and no explicit value.
  InsertMissingRequiredColumn(column: String, span: Span)
  InsertColumnCountMismatch(expected: Int, got: Int, row_index: Int, span: Span)
}

/// Validates `stmt` against `catalog`'s current declared shape (relevant
/// to `AlterStream`/`Insert`; irrelevant to `CreateStream`, which can
/// only ever declare something new), returning every violation found or,
/// if there are none, `catalog` updated with `stmt`'s effect.
pub fn analyze(
  cat: Catalog,
  stmt: ast.DmlStatement,
) -> Result(Catalog, List(SemanticError)) {
  let errors = case stmt {
    ast.Insert(stream_name:, columns:, rows:, span:, ..) ->
      check_insert(cat, stream_name, columns, rows, span)
  }
  case errors {
    [] -> Ok(apply_statement(cat, stmt))
    _ -> Error(errors)
  }
}

pub fn apply_statement(catalog: Catalog, stmt: ast.DmlStatement) -> Catalog {
  case stmt {
    // Never changes a stream's shape.
    ast.Insert(..) -> catalog
  }
}

//-----------------------------------------------------------------------------
// INSERT checks (spec.md §11)
//-----------------------------------------------------------------------------

fn check_insert(
  cat: Catalog,
  stream_name: String,
  columns: List(String),
  rows: List(List(ast.Value)),
  span: Span,
) -> List(SemanticError) {
  case dict.get(cat.streams, stream_name) {
    Error(Nil) -> [UnknownStream(name: stream_name, span: span)]
    Ok(schema) -> {
      // Neither the column list nor a `value_row` carries its own `Span`
      // in the AST (see dml_ast.gleam's `Insert`) — every error below that
      // blames a specific column or row uses the statement's own `span`
      // instead of a more local one.
      let list_empty_err = case columns {
        [] -> [InsertColumnListEmpty(span: span)]
        _ -> []
      }
      let column_list_errs =
        list.flat_map(columns, check_insert_column_list_entry(schema, _, span))
      let missing_required_err =
        list.flat_map(dict.to_list(schema.columns), fn(entry) {
          check_insert_omitted_column(columns, entry, span)
        })
      let expected = list.length(columns)
      let count_errs =
        list.flatten(
          list.index_map(rows, fn(row, i) {
            case list.length(row) == expected {
              True -> []
              False -> [
                InsertColumnCountMismatch(
                  expected: expected,
                  got: list.length(row),
                  row_index: i,
                  span: span,
                ),
              ]
            }
          }),
        )
      let valid_names = dict.keys(schema.columns)
      let ref_errs =
        list.flat_map(rows, fn(row) {
          list.flat_map(row, fn(value) {
            case value {
              ast.ValueExpr(expr) ->
                expr_semantics.check_expr_column_refs(
                  expr,
                  valid_names,
                  UnknownColumnReference,
                )
              ast.ValueDefault -> []
            }
          })
        })

      list.flatten([
        list_empty_err,
        column_list_errs,
        missing_required_err,
        count_errs,
        ref_errs,
      ])
    }
  }
}

fn check_insert_column_list_entry(
  schema: catalog.StreamSchema,
  column_name: String,
  span: Span,
) -> List(SemanticError) {
  case dict.get(schema.columns, column_name) {
    Error(Nil) -> [InsertUnknownColumn(column: column_name, span: span)]
    Ok(col) ->
      case col.system {
        True -> [InsertSystemColumnInList(column: column_name, span: span)]
        False ->
          case col.generated {
            None -> []
            Some(_) -> [
              InsertGeneratedColumnInList(column: column_name, span: span),
            ]
          }
      }
  }
}

/// A column not in the `INSERT`'s own column list resolves the same way
/// a bare `DEFAULT` value would (§11.2): its own `DEFAULT`/`GENERATED`
/// clause, `NULL` if `OPTIONAL`, or an error if neither. The 4 automatic
/// system columns are excluded here, same as `GENERATED` columns — both
/// may never appear in the column list at all (checked separately,
/// above), so their absence is never an error.
fn check_insert_omitted_column(
  columns: List(String),
  entry: #(String, catalog.ColumnSchema),
  span: Span,
) -> List(SemanticError) {
  let #(name, col) = entry
  case
    col.system || option.is_some(col.generated) || list.contains(columns, name)
  {
    True -> []
    False ->
      case col.optional || option.is_some(col.default) {
        True -> []
        False -> [InsertMissingRequiredColumn(column: name, span: span)]
      }
  }
}
//-----------------------------------------------------------------------------
