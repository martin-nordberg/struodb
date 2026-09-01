import gleam/option.{type Option}
import lang/expr_ast as xast
import lang/token.{type Span}

//-----------------------------------------------------------------------------
// Pure data: the parsed shape of StruoDB source text (spec.md Part II).
// No logic here — see expr_parser.gleam for what builds these, catalog.gleam
// for what a validated `Statement` does to a stream's declared shape, and
// semantic.gleam for the checks a `Statement` must pass first.
//-----------------------------------------------------------------------------

pub type DdlStatement {
  CreateStream(name: String, elements: List(StreamElement), span: Span)
  AlterStream(name: String, actions: List(AlterAction), span: Span)
}

//-----------------------------------------------------------------------------
// CREATE STREAM (spec.md §9)
//-----------------------------------------------------------------------------

/// One `column_def` (§9.1) — a standalone record type, not a variant of
/// `StreamElement` directly, so `AlterAction.AddColumn` (§10.2, below)
/// can hold one too without holding an entire `StreamElement` (which
/// could otherwise also be a `TableConstraint`, a combination `ADD
/// COLUMN` never means).
pub type ColumnDef {
  ColumnDef(
    name: String,
    data_type: xast.DataType,
    optional: Bool,
    default: Option(xast.Expr),
    generated: Option(GeneratedClause),
    checks: List(NamedCheck),
    span: Span,
  )
}

pub type StreamElement {
  Column(ColumnDef)
  TableConstraint(check: NamedCheck, span: Span)
}

pub type GeneratedClause {
  GeneratedClause(expr: xast.Expr, storage: GeneratedStorage)
}

pub type GeneratedStorage {
  Stored
  Virtual
}

/// `CONSTRAINT constraint_name CHECK (expr)` (§9.1), whether attached to
/// a column (`ColumnDef.checks`) or standalone (`StreamElement.
/// TableConstraint`) — the same shape either way, per §9.5.
pub type NamedCheck {
  NamedCheck(constraint_name: String, expr: xast.Expr, span: Span)
}

//-----------------------------------------------------------------------------
// ALTER STREAM (spec.md §10)
//-----------------------------------------------------------------------------

pub type AlterAction {
  AddColumn(ColumnDef, span: Span)
  DropColumn(column_name: String, span: Span)
  AlterColumnType(column_name: String, data_type: xast.DataType, span: Span)
  AddConstraint(NamedCheck)
  DropConstraint(constraint_name: String, span: Span)
}
//-----------------------------------------------------------------------------
