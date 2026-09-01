import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import lang/catalog.{type Catalog}
import lang/dml_ast as ast
import lang/expr_ast as xast
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
  MissingHlcColumn(stream: String, span: Span)
  MultipleHlcColumns(stream: String, first: String, second: String, span: Span)
  /// §9.2
  HlcColumnOptional(column: String, span: Span)
  /// §9.2
  HlcColumnHasDefaultOrGenerated(column: String, span: Span)
  /// §9.4. `span` is the offending `ColumnRef`'s own span, not the
  /// enclosing `DEFAULT`'s — see "Expression-level spans" in the plan.
  DefaultReferencesColumn(column: String, referenced: String, span: Span)
  /// `span` is the offending `ColumnRef`'s own span, ditto.
  UnknownColumnReference(referenced: String, span: Span)
  DuplicateColumnName(stream: String, name: String, span: Span)
  DuplicateConstraintName(stream: String, name: String, span: Span)
  UnknownStream(name: String, span: Span)
  /// §10.2
  AddColumnNeedsOptionalOrDefault(column: String, span: Span)
  /// §10.2
  AddSecondHlcColumn(column: String, span: Span)
  /// §10.3
  DropNonOptionalColumn(column: String, span: Span)
  DropUnknownColumn(column: String, span: Span)
  /// §10.4
  NarrowingTypeChange(
    column: String,
    from: xast.DataType,
    to: xast.DataType,
    span: Span,
  )
  /// §10.4 — a change between unrelated type families entirely.
  UnsupportedTypeChange(
    column: String,
    from: xast.DataType,
    to: xast.DataType,
    span: Span,
  )
  DropUnknownConstraint(name: String, span: Span)
  InsertColumnListEmpty(span: Span)
  InsertUnknownColumn(column: String, span: Span)
  /// §11.4
  InsertGeneratedColumnInList(column: String, span: Span)
  /// §11.2
  InsertMissingHlcColumn(stream: String, span: Span)
  /// §11.2/§11.3 — `NOT NULL` with no default and no explicit value.
  InsertMissingRequiredColumn(column: String, span: Span)
  InsertColumnCountMismatch(expected: Int, got: Int, row_index: Int, span: Span)
  /// §9.1's `data_type` parameter bounds (`VARCHAR`/`CHAR` length >= 1;
  /// `DECIMAL`/`NUMERIC` precision >= 1, `0 <= scale <= precision`) —
  /// **not** in the implementation plan's own `SemanticError` listing,
  /// even though the plan's "CREATE STREAM checks" step 7 calls for the
  /// check itself; added here to actually carry it out.
  InvalidDataTypeParameter(column: String, span: Span, reason: String)
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
      // in the AST (see xast.gleam's `Insert`) — every error below that
      // blames a specific column or row uses the statement's own `span`
      // instead of a more local one.
      let list_empty_err = case columns {
        [] -> [InsertColumnListEmpty(span: span)]
        _ -> []
      }
      let column_list_errs =
        list.flat_map(columns, check_insert_column_list_entry(schema, _, span))
      let hlc_missing_err = case list.contains(columns, schema.hlc_column) {
        True -> []
        False -> [InsertMissingHlcColumn(stream: stream_name, span: span)]
      }
      let missing_required_err =
        list.flat_map(dict.to_list(schema.columns), fn(entry) {
          check_insert_omitted_column(schema, columns, entry, span)
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
              ast.ValueExpr(expr) -> check_expr_column_refs(expr, valid_names)
              ast.ValueDefault -> []
            }
          })
        })

      list.flatten([
        list_empty_err,
        column_list_errs,
        hlc_missing_err,
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
      case col.generated {
        None -> []
        Some(_) -> [
          InsertGeneratedColumnInList(column: column_name, span: span),
        ]
      }
  }
}

/// A column not in the `INSERT`'s own column list resolves the same way
/// a bare `DEFAULT` value would (§11.2): its own `DEFAULT`/`GENERATED`
/// clause, `NULL` if `OPTIONAL`, or an error if neither. The `HLC`
/// column is excluded here — its own absence is `InsertMissingHlcColumn`
/// above, not this — and so are `GENERATED` columns, which may never
/// appear in the column list at all (checked separately, above).
fn check_insert_omitted_column(
  schema: catalog.StreamSchema,
  columns: List(String),
  entry: #(String, catalog.ColumnSchema),
  span: Span,
) -> List(SemanticError) {
  let #(name, col) = entry
  case
    name == schema.hlc_column
    || option.is_some(col.generated)
    || list.contains(columns, name)
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
// Shared helpers
//-----------------------------------------------------------------------------

/// Every `ColumnRef` reachable inside `expr`, with its own span — the
/// only kind of subexpression this module's checks ever need to blame
/// individually; see the note on `Expr` in xast.gleam.
fn collect_column_refs(expr: xast.Expr) -> List(#(String, Span)) {
  case expr {
    xast.IntLiteral(_)
    | xast.NumericLiteral(_)
    | xast.StringLiteral(_)
    | xast.BoolLiteral(_)
    | xast.NullLiteral -> []
    xast.ColumnRef(name:, span:) -> [#(name, span)]
    xast.UnaryOp(op: _, operand:) -> collect_column_refs(operand)
    xast.BinaryOp(op: _, left:, right:) ->
      list.append(collect_column_refs(left), collect_column_refs(right))
    xast.Cast(expr:, data_type: _) -> collect_column_refs(expr)
    xast.Between(expr:, negated: _, low:, high:) ->
      list.flatten([
        collect_column_refs(expr),
        collect_column_refs(low),
        collect_column_refs(high),
      ])
    xast.InList(expr:, negated: _, items:) ->
      list.append(
        collect_column_refs(expr),
        list.flat_map(items, collect_column_refs),
      )
    xast.Like(expr:, negated: _, case_insensitive: _, pattern:) ->
      list.append(collect_column_refs(expr), collect_column_refs(pattern))
    xast.SimilarTo(expr:, negated: _, pattern:) ->
      list.append(collect_column_refs(expr), collect_column_refs(pattern))
    xast.IsNull(expr:, negated: _) -> collect_column_refs(expr)
    xast.IsBool(expr:, negated: _, value: _) -> collect_column_refs(expr)
    xast.IsDistinctFrom(left:, negated: _, right:) ->
      list.append(collect_column_refs(left), collect_column_refs(right))
    xast.FunctionCall(name: _, args:) ->
      list.flat_map(args, collect_column_refs)
  }
}

fn check_expr_column_refs(
  expr: xast.Expr,
  valid_names: List(String),
) -> List(SemanticError) {
  list.filter_map(collect_column_refs(expr), fn(ref) {
    let #(name, span) = ref
    case list.contains(valid_names, name) {
      True -> Error(Nil)
      False -> Ok(UnknownColumnReference(referenced: name, span: span))
    }
  })
}
//-----------------------------------------------------------------------------
