import gleam/option.{type Option}
import lang/token.{type Span}

//-----------------------------------------------------------------------------
// Pure data: the parsed shape of StruoDB source text (spec.md Part II).
// No logic here — see parser.gleam for what builds these, catalog.gleam
// for what a validated `Statement` does to a stream's declared shape, and
// semantic.gleam for the checks a `Statement` must pass first.
//-----------------------------------------------------------------------------

pub type Statement {
  CreateStream(name: String, elements: List(StreamElement), span: Span)
  AlterStream(name: String, actions: List(AlterAction), span: Span)
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
    data_type: DataType,
    optional: Bool,
    default: Option(Expr),
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
  GeneratedClause(expr: Expr, storage: GeneratedStorage)
}

pub type GeneratedStorage {
  Stored
  Virtual
}

/// `CONSTRAINT constraint_name CHECK (expr)` (§9.1), whether attached to
/// a column (`ColumnDef.checks`) or standalone (`StreamElement.
/// TableConstraint`) — the same shape either way, per §9.5.
pub type NamedCheck {
  NamedCheck(constraint_name: String, expr: Expr, span: Span)
}

//-----------------------------------------------------------------------------
// ALTER STREAM (spec.md §10)
//-----------------------------------------------------------------------------

pub type AlterAction {
  AddColumn(ColumnDef, span: Span)
  DropColumn(column_name: String, span: Span)
  AlterColumnType(column_name: String, data_type: DataType, span: Span)
  AddConstraint(NamedCheck)
  DropConstraint(constraint_name: String, span: Span)
}

//-----------------------------------------------------------------------------
// INSERT (spec.md §11)
//-----------------------------------------------------------------------------

pub type Value {
  ValueExpr(Expr)
  /// Bare `DEFAULT` keyword (§11.3).
  ValueDefault
}

pub type ReturningItem {
  ReturningStar
  ReturningExpr(expr: Expr, alias: Option(String))
}

//-----------------------------------------------------------------------------
// data_type (spec.md §9.1)
//-----------------------------------------------------------------------------

pub type DataType {
  DtBigint
  DtBoolean
  DtChar(length: Option(Int))
  DtDate
  DtDecimal(precision: Option(Int), scale: Option(Int))
  /// `DOUBLE PRECISION` — two keywords, one type; see the parser's
  /// `data_type` section for why this is special-cased there.
  DtDouble
  DtHlc
  DtInt
  DtInteger
  DtInterval
  DtJson
  DtJsonb
  DtNumeric(precision: Option(Int), scale: Option(Int))
  DtReal
  DtSmallint
  DtText
  DtTime
  DtTimestamp
  DtTimestamptz
  DtUuid
  DtVarchar(length: Option(Int))
}

//-----------------------------------------------------------------------------
// Expressions (spec.md §8)
//-----------------------------------------------------------------------------

/// `ColumnRef` is the one variant here that carries a `Span`, deliberately
/// — it's the only kind of subexpression semantic.gleam's checks ever
/// need to blame individually (an unknown or disallowed column
/// reference), and the parser already has the identifier `Token` in hand
/// at the point it builds one, so capturing its span costs nothing extra.
/// See "Expression-level spans: a narrower alternative" in
/// docs/lang/implementation-plan.md for why the other thirteen variants
/// don't get the same treatment.
///
/// Deliberately no `Paren(Expr)` wrapper: parenthesization only ever
/// affects how the parser groups operators, never anything the AST needs
/// to remember afterward — `(a + b) * c` and any differently-
/// parenthesized-but-equivalent input both just produce
/// `BinaryOp(Mul, BinaryOp(Add, a, b), c)`.
pub type Expr {
  IntLiteral(text: String)
  NumericLiteral(text: String)
  StringLiteral(value: String)
  BoolLiteral(Bool)
  NullLiteral
  ColumnRef(name: String, span: Span)
  UnaryOp(op: UnaryOperator, operand: Expr)
  BinaryOp(op: BinaryOperator, left: Expr, right: Expr)
  Cast(expr: Expr, data_type: DataType)
  Between(expr: Expr, negated: Bool, low: Expr, high: Expr)
  InList(expr: Expr, negated: Bool, items: List(Expr))
  Like(expr: Expr, negated: Bool, case_insensitive: Bool, pattern: Expr)
  SimilarTo(expr: Expr, negated: Bool, pattern: Expr)
  IsNull(expr: Expr, negated: Bool)
  IsBool(expr: Expr, negated: Bool, value: Bool)
  IsDistinctFrom(left: Expr, negated: Bool, right: Expr)
  FunctionCall(name: String, args: List(Expr))
}

pub type UnaryOperator {
  /// Unary `+`
  Pos
  /// Unary `-`
  Neg
  /// `~`
  BitNot
  /// `NOT`
  LogicalNot
}

pub type BinaryOperator {
  Add
  Sub
  Mul
  Div
  Mod
  Pow
  ConcatOp
  BitAnd
  BitOr
  BitXor
  ShiftLeft
  ShiftRight
  RegexMatchOp
  RegexMatchCiOp
  RegexNoMatchOp
  RegexNoMatchCiOp
  JsonGet
  JsonGetText
  JsonGetPath
  JsonGetPathText
  JsonContains
  JsonContainedBy
  CmpEq
  CmpLt
  CmpGt
  CmpLe
  CmpGe
  /// `<>` — kept distinct from `CmpNeBang`, not merged into one `Ne`; see
  /// the note on `NeAngle`/`NeBang` in token.gleam.
  CmpNeAngle
  /// `!=`
  CmpNeBang
  LogicalAnd
  LogicalOr
}
//-----------------------------------------------------------------------------
