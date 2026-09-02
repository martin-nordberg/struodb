import gleam/option.{type Option}
import lang/expr_ast as xast
import lang/token.{type Span}

//-----------------------------------------------------------------------------
// Pure data: the parsed shape of StruoDB DML source text (spec.md Part II).
// No logic here — see expr_parser.gleam for what builds these, and
// dml_semantics.gleam for the checks a `DmlStatement` must pass first.
//-----------------------------------------------------------------------------

pub type DmlStatement {
  Insert(
    stream_name: String,
    columns: List(String),
    rows: List(List(Value)),
    on_conflict_do_nothing: Bool,
    returning: Option(List(ReturningItem)),
    span: Span,
  )
}

//-----------------------------------------------------------------------------
// INSERT (spec.md §11)
//-----------------------------------------------------------------------------

pub type Value {
  ValueExpr(xast.Expr)
  /// Bare `DEFAULT` keyword (§11.3).
  ValueDefault
}

pub type ReturningItem {
  ReturningStar
  ReturningExpr(expr: xast.Expr, alias: Option(String))
}
//-----------------------------------------------------------------------------
