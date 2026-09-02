import gleam/list
import lang/expr_ast.{type Expr}
import lang/token.{type Span}

//-----------------------------------------------------------------------------
// Expr-only semantic helpers shared by ddl_semantics.gleam (schema) and
// dml_semantics.gleam (streams) — neither statement family's checks care
// what kind of statement an Expr came from, only whether every column it
// references is one of the caller's `valid_names`. Kept separate from
// expr_ast.gleam, which is pure data with no logic of its own, and out of
// either `*_semantics.gleam` module, since both need the exact same
// behavior and previously kept two verbatim copies in sync by hand.
//-----------------------------------------------------------------------------

/// Every `ColumnRef` reachable inside `expr`, with its own span — the
/// only kind of subexpression either caller's checks ever need to blame
/// individually; see the note on `Expr` in expr_ast.gleam.
pub fn collect_column_refs(expr: Expr) -> List(#(String, Span)) {
  case expr {
    expr_ast.IntLiteral(_)
    | expr_ast.NumericLiteral(_)
    | expr_ast.StringLiteral(_)
    | expr_ast.BoolLiteral(_)
    | expr_ast.NullLiteral -> []
    expr_ast.ColumnRef(name:, span:) -> [#(name, span)]
    expr_ast.UnaryOp(op: _, operand:) -> collect_column_refs(operand)
    expr_ast.BinaryOp(op: _, left:, right:) ->
      list.append(collect_column_refs(left), collect_column_refs(right))
    expr_ast.Cast(expr:, data_type: _) -> collect_column_refs(expr)
    expr_ast.Between(expr:, negated: _, low:, high:) ->
      list.flatten([
        collect_column_refs(expr),
        collect_column_refs(low),
        collect_column_refs(high),
      ])
    expr_ast.InList(expr:, negated: _, items:) ->
      list.append(
        collect_column_refs(expr),
        list.flat_map(items, collect_column_refs),
      )
    expr_ast.Like(expr:, negated: _, case_insensitive: _, pattern:) ->
      list.append(collect_column_refs(expr), collect_column_refs(pattern))
    expr_ast.SimilarTo(expr:, negated: _, pattern:) ->
      list.append(collect_column_refs(expr), collect_column_refs(pattern))
    expr_ast.IsNull(expr:, negated: _) -> collect_column_refs(expr)
    expr_ast.IsBool(expr:, negated: _, value: _) -> collect_column_refs(expr)
    expr_ast.IsDistinctFrom(left:, negated: _, right:) ->
      list.append(collect_column_refs(left), collect_column_refs(right))
    expr_ast.FunctionCall(name: _, args:) ->
      list.flat_map(args, collect_column_refs)
  }
}

/// Every `ColumnRef` inside `expr` not found in `valid_names`, each
/// reported via `unknown_column_reference` — a caller-supplied
/// constructor rather than a fixed error type, since `ddl_semantics.
/// gleam` and `dml_semantics.gleam` each have their own `SemanticError`
/// with their own `UnknownColumnReference` variant. Passing that
/// variant's own two-argument constructor directly (e.g.
/// `check_expr_column_refs(expr, valid_names, UnknownColumnReference)`)
/// is all a caller needs to do — Gleam constructors are ordinary
/// functions.
pub fn check_expr_column_refs(
  expr: Expr,
  valid_names: List(String),
  unknown_column_reference: fn(String, Span) -> e,
) -> List(e) {
  list.filter_map(collect_column_refs(expr), fn(ref) {
    let #(name, span) = ref
    case list.contains(valid_names, name) {
      True -> Error(Nil)
      False -> Ok(unknown_column_reference(name, span))
    }
  })
}
//-----------------------------------------------------------------------------
