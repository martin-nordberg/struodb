import gleam/option.{type Option}
import lang/expr_ast as xast
import lang/token.{type Span}

//-----------------------------------------------------------------------------
// Pure data: the parsed shape of StruoDB source text (spec.md Part II).
// No logic here — see expr_parser.gleam/ddl_parser.gleam for what builds
// these, catalog.gleam (shared/) for what a validated `DdlStatement` does
// to a stream's declared shape, and ddl_semantics.gleam for the checks a
// `DdlStatement` must pass first. `GeneratedClause`/`NamedCheck` live in
// expr_ast.gleam (shared/), not here — see the note there.
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
    generated: Option(xast.GeneratedClause),
    checks: List(xast.NamedCheck),
    span: Span,
  )
}

pub type StreamElement {
  Column(ColumnDef)
  TableConstraint(check: xast.NamedCheck, span: Span)
}

//-----------------------------------------------------------------------------
// ALTER STREAM (spec.md §10)
//-----------------------------------------------------------------------------

pub type AlterAction {
  AddColumn(ColumnDef, span: Span)
  DropColumn(column_name: String, span: Span)
  AlterColumnType(column_name: String, data_type: xast.DataType, span: Span)
  AddConstraint(xast.NamedCheck)
  DropConstraint(constraint_name: String, span: Span)
}
//-----------------------------------------------------------------------------
