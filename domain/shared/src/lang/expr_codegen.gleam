import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import lang/expr_ast.{
  type BinaryOperator, type DataType, type Expr, type UnaryOperator, Add,
  Between, BinaryOp, BitAnd, BitNot, BitOr, BitXor, BoolLiteral, Cast, CmpEq,
  CmpGe, CmpGt, CmpLe, CmpLt, CmpNeAngle, CmpNeBang, ColumnRef, ConcatOp, Div,
  DtBigint, DtBoolean, DtChar, DtDate, DtDecimal, DtDouble, DtInt, DtInteger,
  DtInterval, DtJson, DtJsonb, DtNumeric, DtReal, DtSmallint, DtText, DtTime,
  DtTimestamp, DtTimestamptz, DtUuid, DtVarchar, FunctionCall, InList,
  IntLiteral, IsBool, IsDistinctFrom, IsNull, JsonContainedBy, JsonContains,
  JsonGet, JsonGetPath, JsonGetPathText, JsonGetText, Like, LogicalAnd,
  LogicalNot, LogicalOr, Mod, Mul, Neg, NullLiteral, NumericLiteral, Pos, Pow,
  RegexMatchCiOp, RegexMatchOp, RegexNoMatchCiOp, RegexNoMatchOp, ShiftLeft,
  ShiftRight, SimilarTo, StringLiteral, Sub, UnaryOp,
}
import lang/lexer

//-----------------------------------------------------------------------------
// Turns validated `expr_ast`/`token`-level pieces into PostgreSQL SQL
// text — the one piece of codegen genuinely shared by DDL (schema/
// ddl_codegen.gleam) and DML (streams/dml_codegen.gleam), since both
// embed expressions and data types. See docs/lang/codegen-plan.md for
// the full design (reparenthesization, identifier quoting, the
// StruoDB-precedence-table-doubles-as-reparenthesization-table decision).
//-----------------------------------------------------------------------------

//-----------------------------------------------------------------------------
// Identifiers and string literals (spec.md §2, §4.3)
//-----------------------------------------------------------------------------

/// Quotes `name` (`"..."`, doubling any embedded `"`) only if it needs
/// it: either its own content couldn't have been written unquoted in
/// StruoDB source (uppercase, a character outside `[a-z0-9_]`, or a
/// leading digit), or it's one of PostgreSQL's own reserved words —
/// which PostgreSQL requires quoting regardless of how safe the content
/// looks. See "Generated identifiers are quoted only when needed" in
/// docs/lang/codegen-plan.md for why *both* checks are required.
pub fn quote_identifier(name: String) -> String {
  case is_safe_unquoted(name) && !lexer.is_postgres_reserved_word(name) {
    True -> name
    False -> "\"" <> string.replace(name, "\"", "\"\"") <> "\""
  }
}

/// True if `name` is exactly what an unquoted `identifier` (spec.md §2)
/// can spell: a letter (necessarily already lower-case — an unquoted
/// source identifier is folded to lower case by the lexer, so any
/// uppercase here could only have come from quoted source) or `_`,
/// followed by letters/digits/`_`.
fn is_safe_unquoted(name: String) -> Bool {
  case string.to_graphemes(name) {
    [] -> False
    [first, ..rest] ->
      is_ident_start(first) && list.all(rest, is_ident_continue)
  }
}

fn is_ident_start(c: String) -> Bool {
  is_lower_letter(c) || c == "_"
}

fn is_ident_continue(c: String) -> Bool {
  is_lower_letter(c) || is_digit(c) || c == "_"
}

fn is_lower_letter(c: String) -> Bool {
  is_between(c, "a", "z")
}

fn is_digit(c: String) -> Bool {
  is_between(c, "0", "9")
}

/// `c`, `lo`, and `hi` are each expected to be a single grapheme;
/// grapheme ordering via `string.compare` matches ASCII order for the
/// plain letters/digits this is ever called with — same helper as
/// `lexer.gleam`'s own, kept as a private copy here rather than shared,
/// since it's a two-line primitive not worth a new export.
fn is_between(c: String, lo: String, hi: String) -> Bool {
  case string.compare(c, lo), string.compare(c, hi) {
    order.Lt, _ -> False
    _, order.Gt -> False
    _, _ -> True
  }
}

/// `'` + `value` with every `'` doubled to `''` + `'` — the write-side
/// mirror of the lexer's own read-side unescaping (spec.md §4.3).
pub fn quote_string_literal(value: String) -> String {
  "'" <> string.replace(value, "'", "''") <> "'"
}

//-----------------------------------------------------------------------------
// data_type (spec.md §9.1 → PostgreSQL)
//-----------------------------------------------------------------------------

pub fn data_type_to_sql(data_type: DataType) -> String {
  case data_type {
    DtBigint -> "BIGINT"
    DtBoolean -> "BOOLEAN"
    DtChar(length) -> "CHAR" <> optional_length_sql(length)
    DtDate -> "DATE"
    DtDecimal(precision, scale) ->
      "DECIMAL" <> optional_precision_scale_sql(precision, scale)
    DtDouble -> "DOUBLE PRECISION"
    DtInt -> "INTEGER"
    DtInteger -> "INTEGER"
    DtInterval -> "INTERVAL"
    DtJson -> "JSON"
    DtJsonb -> "JSONB"
    DtNumeric(precision, scale) ->
      "NUMERIC" <> optional_precision_scale_sql(precision, scale)
    DtReal -> "REAL"
    DtSmallint -> "SMALLINT"
    DtText -> "TEXT"
    DtTime -> "TIME"
    DtTimestamp -> "TIMESTAMP"
    DtTimestamptz -> "TIMESTAMPTZ"
    DtUuid -> "UUID"
    DtVarchar(length) -> "VARCHAR" <> optional_length_sql(length)
  }
}

fn optional_length_sql(length: Option(Int)) -> String {
  case length {
    None -> ""
    Some(n) -> "(" <> int.to_string(n) <> ")"
  }
}

fn optional_precision_scale_sql(
  precision: Option(Int),
  scale: Option(Int),
) -> String {
  case precision, scale {
    None, _ -> ""
    Some(p), None -> "(" <> int.to_string(p) <> ")"
    Some(p), Some(s) ->
      "(" <> int.to_string(p) <> ", " <> int.to_string(s) <> ")"
  }
}

//-----------------------------------------------------------------------------
// Expressions (spec.md §8 → PostgreSQL) — precedence-driven
// reparenthesization, mirroring expr_parser.gleam's own twelve levels
// (loosest, 12, to tightest, 1; primaries are an implicit "level 0",
// never needing parens as anyone's child). `paren_if_needed` wraps a
// child whenever its own top-level precedence is not *strictly tighter*
// than the level of the operator rendering it — conservative, not
// minimal; see "Reparenthesization is conservative, not minimal" in
// docs/lang/codegen-plan.md.
//-----------------------------------------------------------------------------

pub fn expr_to_sql(expr: Expr) -> String {
  case expr {
    IntLiteral(text) -> text
    NumericLiteral(text) -> text
    StringLiteral(value) -> quote_string_literal(value)
    BoolLiteral(True) -> "TRUE"
    BoolLiteral(False) -> "FALSE"
    NullLiteral -> "NULL"
    ColumnRef(name, _) -> quote_identifier(name)
    UnaryOp(LogicalNot, operand) -> "NOT " <> paren_if_needed(operand, 10)
    UnaryOp(Pos, operand) -> "+" <> paren_if_needed(operand, 2)
    UnaryOp(Neg, operand) -> "-" <> paren_if_needed(operand, 2)
    UnaryOp(BitNot, operand) -> "~" <> paren_if_needed(operand, 6)
    BinaryOp(op, left, right) -> {
      let level = binary_operator_precedence(op)
      paren_if_needed(left, level)
      <> " "
      <> binary_operator_to_sql(op)
      <> " "
      <> paren_if_needed(right, level)
    }
    Cast(inner, data_type) ->
      paren_if_needed(inner, 1) <> "::" <> data_type_to_sql(data_type)
    Between(inner, negated, low, high) ->
      paren_if_needed(inner, 7)
      <> " "
      <> negated_keyword(negated, "BETWEEN")
      <> " "
      <> paren_if_needed(low, 7)
      <> " AND "
      <> paren_if_needed(high, 7)
    InList(inner, negated, items) ->
      paren_if_needed(inner, 7)
      <> " "
      <> negated_keyword(negated, "IN")
      <> " ("
      // Delimited by `(...)`/`,`, so — like function-call arguments below
      // — each item is unrestricted `expr` with no ambiguity risk; no
      // parens needed beyond the list's own.
      <> { items |> list.map(expr_to_sql) |> string.join(", ") }
      <> ")"
    Like(inner, negated, case_insensitive, pattern) ->
      paren_if_needed(inner, 7)
      <> " "
      <> negated_keyword(negated, case_insensitive_keyword(case_insensitive))
      <> " "
      <> paren_if_needed(pattern, 7)
    SimilarTo(inner, negated, pattern) ->
      paren_if_needed(inner, 7)
      <> " "
      <> negated_keyword(negated, "SIMILAR TO")
      <> " "
      <> paren_if_needed(pattern, 7)
    IsNull(inner, negated) ->
      paren_if_needed(inner, 9) <> " IS " <> negated_prefix(negated) <> "NULL"
    IsBool(inner, negated, True) ->
      paren_if_needed(inner, 9) <> " IS " <> negated_prefix(negated) <> "TRUE"
    IsBool(inner, negated, False) ->
      paren_if_needed(inner, 9) <> " IS " <> negated_prefix(negated) <> "FALSE"
    IsDistinctFrom(left, negated, right) ->
      paren_if_needed(left, 9)
      <> " IS "
      <> negated_prefix(negated)
      <> "DISTINCT FROM "
      <> paren_if_needed(right, 9)
    FunctionCall(name, args) ->
      // Quoted the same way any other identifier is (bare only when
      // that's actually safe): the parser accepts a quoted identifier
      // here too (§8.3's grammar doesn't otherwise restrict function-
      // call position to a fixed built-in set), so `name` may carry
      // arbitrary content — quoting is what keeps it inert as SQL
      // rather than splicing it in verbatim. See "Generated
      // identifiers..." in codegen-plan.md.
      quote_identifier(name)
      <> "("
      // Same "delimiters already disambiguate" reasoning as IN's list
      // above.
      <> { args |> list.map(expr_to_sql) |> string.join(", ") }
      <> ")"
  }
}

fn paren_if_needed(expr: Expr, parent_level: Int) -> String {
  case precedence_of(expr) >= parent_level {
    True -> "(" <> expr_to_sql(expr) <> ")"
    False -> expr_to_sql(expr)
  }
}

/// Every `Expr` variant's own top-level precedence, in `expr_parser.
/// gleam`'s own 12 (loosest) to 1 (tightest) numbering; a primary
/// (literal/`ColumnRef`/`FunctionCall`) is `0` — stricter than every
/// real level, so it's never parenthesized as anyone's child.
fn precedence_of(expr: Expr) -> Int {
  case expr {
    IntLiteral(_)
    | NumericLiteral(_)
    | StringLiteral(_)
    | BoolLiteral(_)
    | NullLiteral
    | ColumnRef(_, _)
    | FunctionCall(_, _) -> 0
    Cast(_, _) -> 1
    UnaryOp(op, _) -> unary_operator_precedence(op)
    BinaryOp(op, _, _) -> binary_operator_precedence(op)
    Between(_, _, _, _)
    | InList(_, _, _)
    | Like(_, _, _, _)
    | SimilarTo(_, _, _) -> 7
    IsNull(_, _) | IsBool(_, _, _) | IsDistinctFrom(_, _, _) -> 9
  }
}

fn unary_operator_precedence(op: UnaryOperator) -> Int {
  case op {
    LogicalNot -> 10
    BitNot -> 6
    Pos | Neg -> 2
  }
}

fn binary_operator_precedence(op: BinaryOperator) -> Int {
  case op {
    LogicalOr -> 12
    LogicalAnd -> 11
    CmpEq | CmpLt | CmpGt | CmpLe | CmpGe | CmpNeAngle | CmpNeBang -> 8
    ConcatOp
    | BitAnd
    | BitOr
    | BitXor
    | ShiftLeft
    | ShiftRight
    | RegexMatchOp
    | RegexMatchCiOp
    | RegexNoMatchOp
    | RegexNoMatchCiOp
    | JsonGet
    | JsonGetText
    | JsonGetPath
    | JsonGetPathText
    | JsonContains
    | JsonContainedBy -> 6
    Add | Sub -> 5
    Mul | Div | Mod -> 4
    Pow -> 3
  }
}

/// Textual spelling for every `BinaryOperator` — `CmpNeAngle`/`CmpNeBang`
/// map back to `<>`/`!=` respectively rather than being folded to one
/// spelling, cashing in "`<>` and `!=` stay distinct tokens/AST nodes"
/// from the parent plan, made specifically so this would be possible.
fn binary_operator_to_sql(op: BinaryOperator) -> String {
  case op {
    Add -> "+"
    Sub -> "-"
    Mul -> "*"
    Div -> "/"
    Mod -> "%"
    Pow -> "^"
    ConcatOp -> "||"
    BitAnd -> "&"
    BitOr -> "|"
    BitXor -> "#"
    ShiftLeft -> "<<"
    ShiftRight -> ">>"
    RegexMatchOp -> "~"
    RegexMatchCiOp -> "~*"
    RegexNoMatchOp -> "!~"
    RegexNoMatchCiOp -> "!~*"
    JsonGet -> "->"
    JsonGetText -> "->>"
    JsonGetPath -> "#>"
    JsonGetPathText -> "#>>"
    JsonContains -> "@>"
    JsonContainedBy -> "<@"
    CmpEq -> "="
    CmpLt -> "<"
    CmpGt -> ">"
    CmpLe -> "<="
    CmpGe -> ">="
    CmpNeAngle -> "<>"
    CmpNeBang -> "!="
    LogicalAnd -> "AND"
    LogicalOr -> "OR"
  }
}

/// `keyword`, prefixed with `NOT ` if `negated` — for the level-7
/// keyword-operator forms (`BETWEEN`, `IN`, `LIKE`/`ILIKE`, `SIMILAR
/// TO`), where a leading `NOT` negates the whole form.
fn negated_keyword(negated: Bool, keyword: String) -> String {
  case negated {
    True -> "NOT " <> keyword
    False -> keyword
  }
}

fn case_insensitive_keyword(case_insensitive: Bool) -> String {
  case case_insensitive {
    True -> "ILIKE"
    False -> "LIKE"
  }
}

/// `"NOT "` if `negated`, else `""` — for the `IS [NOT] ...` forms
/// (level 9), where `NOT` sits *after* `IS` rather than before the whole
/// form, unlike `negated_keyword` above.
fn negated_prefix(negated: Bool) -> String {
  case negated {
    True -> "NOT "
    False -> ""
  }
}
//-----------------------------------------------------------------------------
