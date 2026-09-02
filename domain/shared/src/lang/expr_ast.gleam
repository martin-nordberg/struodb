import gleam/option.{type Option}
import lang/token.{type Span}

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

//-----------------------------------------------------------------------------
// Expression-attached metadata (spec.md §9.1, §9.5) — not `Expr` itself,
// but small wrappers around one that both `schema/ddl_ast.gleam` (as
// parsed) and `catalog.gleam` (as stored, once a `CREATE`/`ALTER STREAM`
// validates) need the same shape for. Living here rather than in
// `ddl_ast.gleam` is what lets `catalog.gleam` — which `dml_semantics.
// gleam` (streams) also needs, to validate `INSERT` against a stream's
// current shape — stay in `shared/` instead of depending on schema-only
// DDL syntax types; see the note on `Catalog` in catalog.gleam.
//-----------------------------------------------------------------------------

pub type GeneratedClause {
  GeneratedClause(expr: Expr, storage: GeneratedStorage)
}

pub type GeneratedStorage {
  Stored
  Virtual
}

/// `CONSTRAINT constraint_name CHECK (expr)` (§9.1), whether attached to
/// a column, standalone at table level, or (once a `CREATE`/`ALTER
/// STREAM` validates) recorded in a `Catalog`'s `StreamSchema` — the same
/// shape throughout, per §9.5.
pub type NamedCheck {
  NamedCheck(constraint_name: String, expr: Expr, span: Span)
}
//-----------------------------------------------------------------------------
