import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/string
import lang/ddl_ast as ast
import lang/expr_ast as xast

//-----------------------------------------------------------------------------
// A stable, whitespace/position-invariant identity for one `DdlStatement`
// — see "Design decisions" in
// documentation/plans/lang/migration-plan.md for why this is a canonical
// JSON encoding of the statement itself, built independently of
// `ddl_codegen.gleam`'s SQL rendering, rather than a hash of the
// generated SQL text: `ddl_codegen` stays free to change how it *prints*
// a statement without silently invalidating every hash already recorded
// against a live external migration-history database.
//
// Every `canonical_*` function below is an exhaustive `case` over one
// `ddl_ast`/`expr_ast` type's constructors, each producing a `json.object`
// explicitly tagged with that constructor's own name — this is what
// guarantees two differently-shaped statements can never encode to the
// same JSON text (unlike hand-rolled string concatenation, which would
// need its own escaping scheme to get the same guarantee). Every `Span`
// field, wherever `ddl_ast`/`expr_ast` carries one, is simply omitted —
// the entire point is that reformatting source text (which only ever
// changes byte offsets, never the statement's own meaning) never changes
// the hash.
//-----------------------------------------------------------------------------

/// SHA-256 of `stmt`'s canonical JSON encoding, as lower-case hex (64
/// characters).
pub fn hash_statement(stmt: ast.DdlStatement) -> String {
  canonical_statement(stmt)
  |> json.to_string
  |> bit_array.from_string
  |> crypto.hash(crypto.Sha256, _)
  |> hex_encode
}

//-----------------------------------------------------------------------------
// DdlStatement / StreamElement / ColumnDef / AlterAction
//-----------------------------------------------------------------------------

fn canonical_statement(stmt: ast.DdlStatement) -> Json {
  case stmt {
    ast.CreateStream(name:, elements:, span: _) ->
      json.object([
        #("stmt", json.string("create_stream")),
        #("name", json.string(name)),
        #("elements", json.array(elements, canonical_stream_element)),
      ])
    ast.AlterStream(name:, actions:, span: _) ->
      json.object([
        #("stmt", json.string("alter_stream")),
        #("name", json.string(name)),
        #("actions", json.array(actions, canonical_alter_action)),
      ])
  }
}

fn canonical_stream_element(element: ast.StreamElement) -> Json {
  case element {
    ast.Column(col) ->
      json.object([
        #("kind", json.string("column")),
        #("column", canonical_column_def(col)),
      ])
    ast.TableConstraint(check:, span: _) ->
      json.object([
        #("kind", json.string("table_constraint")),
        #("check", canonical_named_check(check)),
      ])
  }
}

fn canonical_column_def(col: ast.ColumnDef) -> Json {
  json.object([
    #("name", json.string(col.name)),
    #("data_type", canonical_data_type(col.data_type)),
    #("optional", json.bool(col.optional)),
    #("default", json.nullable(col.default, canonical_expr)),
    #("generated", json.nullable(col.generated, canonical_generated_clause)),
    #("checks", json.array(col.checks, canonical_named_check)),
  ])
}

fn canonical_alter_action(action: ast.AlterAction) -> Json {
  case action {
    ast.AddColumn(col, span: _) ->
      json.object([
        #("action", json.string("add_column")),
        #("column", canonical_column_def(col)),
      ])
    ast.DropColumn(column_name:, span: _) ->
      json.object([
        #("action", json.string("drop_column")),
        #("name", json.string(column_name)),
      ])
    ast.AlterColumnType(column_name:, data_type:, span: _) ->
      json.object([
        #("action", json.string("alter_column_type")),
        #("name", json.string(column_name)),
        #("data_type", canonical_data_type(data_type)),
      ])
    ast.AddConstraint(check) ->
      json.object([
        #("action", json.string("add_constraint")),
        #("check", canonical_named_check(check)),
      ])
    ast.DropConstraint(constraint_name:, span: _) ->
      json.object([
        #("action", json.string("drop_constraint")),
        #("name", json.string(constraint_name)),
      ])
  }
}

fn canonical_named_check(check: xast.NamedCheck) -> Json {
  json.object([
    #("name", json.string(check.constraint_name)),
    #("expr", canonical_expr(check.expr)),
  ])
}

fn canonical_generated_clause(g: xast.GeneratedClause) -> Json {
  let storage_tag = case g.storage {
    xast.Stored -> "stored"
    xast.Virtual -> "virtual"
  }
  json.object([
    #("expr", canonical_expr(g.expr)),
    #("storage", json.string(storage_tag)),
  ])
}

//-----------------------------------------------------------------------------
// data_type
//-----------------------------------------------------------------------------

fn canonical_data_type(dt: xast.DataType) -> Json {
  case dt {
    xast.DtBigint -> tagged_type("bigint", [])
    xast.DtBoolean -> tagged_type("boolean", [])
    xast.DtChar(length) -> tagged_type("char", [length_field(length)])
    xast.DtDate -> tagged_type("date", [])
    xast.DtDecimal(precision:, scale:) ->
      tagged_type("decimal", precision_scale_fields(precision, scale))
    xast.DtDouble -> tagged_type("double", [])
    xast.DtInt -> tagged_type("int", [])
    xast.DtInteger -> tagged_type("integer", [])
    xast.DtInterval -> tagged_type("interval", [])
    xast.DtJson -> tagged_type("json", [])
    xast.DtJsonb -> tagged_type("jsonb", [])
    xast.DtNumeric(precision:, scale:) ->
      tagged_type("numeric", precision_scale_fields(precision, scale))
    xast.DtReal -> tagged_type("real", [])
    xast.DtSmallint -> tagged_type("smallint", [])
    xast.DtText -> tagged_type("text", [])
    xast.DtTime -> tagged_type("time", [])
    xast.DtTimestamp -> tagged_type("timestamp", [])
    xast.DtTimestamptz -> tagged_type("timestamptz", [])
    xast.DtUuid -> tagged_type("uuid", [])
    xast.DtVarchar(length) -> tagged_type("varchar", [length_field(length)])
  }
}

fn tagged_type(tag: String, extra_fields: List(#(String, Json))) -> Json {
  json.object([#("type", json.string(tag)), ..extra_fields])
}

fn length_field(length: Option(Int)) -> #(String, Json) {
  #("length", json.nullable(length, json.int))
}

fn precision_scale_fields(
  precision: Option(Int),
  scale: Option(Int),
) -> List(#(String, Json)) {
  [
    #("precision", json.nullable(precision, json.int)),
    #("scale", json.nullable(scale, json.int)),
  ]
}

//-----------------------------------------------------------------------------
// Expr
//-----------------------------------------------------------------------------

fn canonical_expr(expr: xast.Expr) -> Json {
  case expr {
    xast.IntLiteral(text:) ->
      tagged_expr("int_literal", [#("text", json.string(text))])
    xast.NumericLiteral(text:) ->
      tagged_expr("numeric_literal", [#("text", json.string(text))])
    xast.StringLiteral(value:) ->
      tagged_expr("string_literal", [#("value", json.string(value))])
    xast.BoolLiteral(value) ->
      tagged_expr("bool_literal", [#("value", json.bool(value))])
    xast.NullLiteral -> tagged_expr("null_literal", [])
    xast.ColumnRef(name:, span: _) ->
      tagged_expr("column_ref", [#("name", json.string(name))])
    xast.UnaryOp(op:, operand:) ->
      tagged_expr("unary_op", [
        #("op", json.string(canonical_unary_operator(op))),
        #("operand", canonical_expr(operand)),
      ])
    xast.BinaryOp(op:, left:, right:) ->
      tagged_expr("binary_op", [
        #("op", json.string(canonical_binary_operator(op))),
        #("left", canonical_expr(left)),
        #("right", canonical_expr(right)),
      ])
    xast.Cast(expr:, data_type:) ->
      tagged_expr("cast", [
        #("expr_value", canonical_expr(expr)),
        #("data_type", canonical_data_type(data_type)),
      ])
    xast.Between(expr:, negated:, low:, high:) ->
      tagged_expr("between", [
        #("expr_value", canonical_expr(expr)),
        #("negated", json.bool(negated)),
        #("low", canonical_expr(low)),
        #("high", canonical_expr(high)),
      ])
    xast.InList(expr:, negated:, items:) ->
      tagged_expr("in_list", [
        #("expr_value", canonical_expr(expr)),
        #("negated", json.bool(negated)),
        #("items", json.array(items, canonical_expr)),
      ])
    xast.Like(expr:, negated:, case_insensitive:, pattern:) ->
      tagged_expr("like", [
        #("expr_value", canonical_expr(expr)),
        #("negated", json.bool(negated)),
        #("case_insensitive", json.bool(case_insensitive)),
        #("pattern", canonical_expr(pattern)),
      ])
    xast.SimilarTo(expr:, negated:, pattern:) ->
      tagged_expr("similar_to", [
        #("expr_value", canonical_expr(expr)),
        #("negated", json.bool(negated)),
        #("pattern", canonical_expr(pattern)),
      ])
    xast.IsNull(expr:, negated:) ->
      tagged_expr("is_null", [
        #("expr_value", canonical_expr(expr)),
        #("negated", json.bool(negated)),
      ])
    xast.IsBool(expr:, negated:, value:) ->
      tagged_expr("is_bool", [
        #("expr_value", canonical_expr(expr)),
        #("negated", json.bool(negated)),
        #("value", json.bool(value)),
      ])
    xast.IsDistinctFrom(left:, negated:, right:) ->
      tagged_expr("is_distinct_from", [
        #("left", canonical_expr(left)),
        #("negated", json.bool(negated)),
        #("right", canonical_expr(right)),
      ])
    xast.FunctionCall(name:, args:) ->
      tagged_expr("function_call", [
        #("name", json.string(name)),
        #("args", json.array(args, canonical_expr)),
      ])
  }
}

fn tagged_expr(tag: String, extra_fields: List(#(String, Json))) -> Json {
  json.object([#("expr", json.string(tag)), ..extra_fields])
}

fn canonical_unary_operator(op: xast.UnaryOperator) -> String {
  case op {
    xast.Pos -> "pos"
    xast.Neg -> "neg"
    xast.BitNot -> "bit_not"
    xast.LogicalNot -> "logical_not"
  }
}

fn canonical_binary_operator(op: xast.BinaryOperator) -> String {
  case op {
    xast.Add -> "add"
    xast.Sub -> "sub"
    xast.Mul -> "mul"
    xast.Div -> "div"
    xast.Mod -> "mod"
    xast.Pow -> "pow"
    xast.ConcatOp -> "concat"
    xast.BitAnd -> "bit_and"
    xast.BitOr -> "bit_or"
    xast.BitXor -> "bit_xor"
    xast.ShiftLeft -> "shift_left"
    xast.ShiftRight -> "shift_right"
    xast.RegexMatchOp -> "regex_match"
    xast.RegexMatchCiOp -> "regex_match_ci"
    xast.RegexNoMatchOp -> "regex_no_match"
    xast.RegexNoMatchCiOp -> "regex_no_match_ci"
    xast.JsonGet -> "json_get"
    xast.JsonGetText -> "json_get_text"
    xast.JsonGetPath -> "json_get_path"
    xast.JsonGetPathText -> "json_get_path_text"
    xast.JsonContains -> "json_contains"
    xast.JsonContainedBy -> "json_contained_by"
    xast.CmpEq -> "cmp_eq"
    xast.CmpLt -> "cmp_lt"
    xast.CmpGt -> "cmp_gt"
    xast.CmpLe -> "cmp_le"
    xast.CmpGe -> "cmp_ge"
    xast.CmpNeAngle -> "cmp_ne_angle"
    xast.CmpNeBang -> "cmp_ne_bang"
    xast.LogicalAnd -> "logical_and"
    xast.LogicalOr -> "logical_or"
  }
}

//-----------------------------------------------------------------------------
// Hex encoding — the pinned gleam_stdlib (1.0.5, see manifest.toml) has
// no `bit_array.base16_encode` (added in a later stdlib version); this
// hand-rolls it rather than bumping an unrelated dependency just for
// this. Walks the digest via Gleam's native bit-array pattern matching,
// one byte at a time.
//-----------------------------------------------------------------------------

fn hex_encode(digest: BitArray) -> String {
  hex_encode_loop(digest, "")
}

fn hex_encode_loop(bits: BitArray, acc: String) -> String {
  case bits {
    <<>> -> acc
    <<byte, rest:bytes>> -> hex_encode_loop(rest, acc <> hex_byte(byte))
    _ -> acc
  }
}

fn hex_byte(byte: Int) -> String {
  let assert Ok(digits) = int.to_base_string(byte, 16)
  case string.length(digits) {
    1 -> "0" <> string.lowercase(digits)
    _ -> string.lowercase(digits)
  }
}
//-----------------------------------------------------------------------------
