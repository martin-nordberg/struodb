import gleam/list
import lang/expr_ast as xast
import lang/expr_semantics
import lang/token

//-----------------------------------------------------------------------------
// Direct tests for the Expr-walking helpers ddl_semantics.gleam (schema)
// and dml_semantics.gleam (streams) both build their column-reference
// checks on, so a regression here is caught by shared's own `gleam test`
// rather than only by whichever downstream package happens to exercise
// the broken case first.
//-----------------------------------------------------------------------------

fn dummy_span() -> token.Span {
  let pos = token.Position(line: 1, column: 1, byte_offset: 0)
  token.Span(pos, pos)
}

fn col_ref(name: String) -> xast.Expr {
  xast.ColumnRef(name, dummy_span())
}

//-----------------------------------------------------------------------------
// collect_column_refs
//-----------------------------------------------------------------------------

pub fn a_literal_has_no_column_refs_test() {
  assert expr_semantics.collect_column_refs(xast.IntLiteral("1")) == []
}

pub fn a_bare_column_ref_is_itself_test() {
  let span = dummy_span()
  assert expr_semantics.collect_column_refs(xast.ColumnRef("a", span))
    == [#("a", span)]
}

pub fn every_column_ref_nested_anywhere_is_found_test() {
  // Buried across several unrelated Expr constructors (unary, binary,
  // cast, function call) — proves the walk actually recurses into all of
  // them, not just the ones a narrower test happens to cover.
  let expr =
    xast.FunctionCall("coalesce", [
      xast.Cast(xast.UnaryOp(xast.Neg, col_ref("a")), xast.DtInt),
      xast.BinaryOp(xast.Add, col_ref("b"), xast.IntLiteral("1")),
    ])
  let names =
    expr_semantics.collect_column_refs(expr)
    |> list.map(fn(ref) {
      let #(name, _) = ref
      name
    })
  assert names == ["a", "b"]
}

pub fn a_repeated_column_ref_is_reported_once_per_occurrence_test() {
  let expr = xast.BinaryOp(xast.Add, col_ref("a"), col_ref("a"))
  assert expr_semantics.collect_column_refs(expr)
    == [#("a", dummy_span()), #("a", dummy_span())]
}

//-----------------------------------------------------------------------------
// check_expr_column_refs — generic over the caller's own error type, so
// this exercises it with a throwaway local type rather than either
// package's real `SemanticError`, to prove it isn't accidentally coupled
// to one.
//-----------------------------------------------------------------------------

type TestError {
  UnknownRef(name: String, span: token.Span)
}

pub fn every_valid_reference_produces_no_errors_test() {
  let expr = xast.BinaryOp(xast.CmpGt, col_ref("a"), col_ref("b"))
  assert expr_semantics.check_expr_column_refs(expr, ["a", "b"], UnknownRef)
    == []
}

pub fn an_invalid_reference_is_reported_via_the_callers_constructor_test() {
  let expr = col_ref("nope")
  assert expr_semantics.check_expr_column_refs(expr, ["a"], UnknownRef)
    == [UnknownRef(name: "nope", span: dummy_span())]
}

pub fn only_the_unknown_references_among_several_are_reported_test() {
  let expr =
    xast.Between(col_ref("a"), False, col_ref("nope"), xast.IntLiteral("10"))
  assert expr_semantics.check_expr_column_refs(expr, ["a"], UnknownRef)
    == [UnknownRef(name: "nope", span: dummy_span())]
}

pub fn an_expr_with_no_column_refs_at_all_is_never_flagged_test() {
  let expr = xast.Cast(xast.IntLiteral("1"), xast.DtBigint)
  assert expr_semantics.check_expr_column_refs(expr, [], UnknownRef) == []
}
//-----------------------------------------------------------------------------
