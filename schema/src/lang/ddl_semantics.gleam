import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lang/catalog.{type Catalog}
import lang/ddl_ast as ast
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
  stmt: ast.DdlStatement,
) -> Result(Catalog, List(SemanticError)) {
  let errors = case stmt {
    ast.CreateStream(name:, elements:, span:) ->
      check_create_stream(name, elements, span)
    ast.AlterStream(name:, actions:, span:) ->
      check_alter_stream(cat, name, actions, span)
  }
  case errors {
    [] -> Ok(apply_statement(cat, stmt))
    _ -> Error(errors)
  }
}

//-----------------------------------------------------------------------------
// Applying an already-validated statement to the catalog. `catalog.gleam`
// (shared/) only exposes small primitives (`create_stream`, `add_column`,
// ...) rather than one `apply_statement(catalog, DdlStatement)` — see the
// note on `Catalog` there — so this is where a `DdlStatement`'s pieces
// get translated into those calls, reusing the same `column_defs`/
// `table_constraints`/`hlc_columns` helpers `check_create_stream` above
// already builds for validation. Only ever called once every check above
// has passed, via `analyze`.
//-----------------------------------------------------------------------------

fn apply_statement(cat: Catalog, stmt: ast.DdlStatement) -> Catalog {
  case stmt {
    ast.CreateStream(name:, elements:, span: _) ->
      apply_create_stream(cat, name, elements)
    ast.AlterStream(name:, actions:, span: _) ->
      list.fold(actions, cat, fn(acc, action) {
        apply_alter_action(acc, name, action)
      })
  }
}

fn apply_create_stream(
  cat: Catalog,
  name: String,
  elements: List(ast.StreamElement),
) -> Catalog {
  let cols = column_defs(elements)
  let checks =
    list.append(
      list.flat_map(cols, fn(c) { c.checks }),
      table_constraints(elements),
    )
  // `check_create_stream`'s own `hlc_count_errors` already confirmed
  // exactly one column is typed `HLC` — `analyze` never calls this
  // otherwise.
  let assert [hlc, ..] = hlc_columns(cols)
    as "apply_create_stream: no HLC column found on an already-validated CreateStream"
  catalog.create_stream(
    cat,
    name,
    list.map(cols, to_column_schema),
    hlc.name,
    checks,
  )
}

fn to_column_schema(col: ast.ColumnDef) -> catalog.ColumnSchema {
  catalog.ColumnSchema(
    name: col.name,
    data_type: col.data_type,
    optional: col.optional,
    default: col.default,
    generated: col.generated,
  )
}

fn apply_alter_action(
  cat: Catalog,
  stream: String,
  action: ast.AlterAction,
) -> Catalog {
  case action {
    ast.AddColumn(col, _) ->
      catalog.add_column(cat, stream, to_column_schema(col))
    ast.DropColumn(column_name:, span: _) ->
      catalog.drop_column(cat, stream, column_name)
    ast.AlterColumnType(column_name:, data_type:, span: _) ->
      catalog.alter_column_type(cat, stream, column_name, data_type)
    ast.AddConstraint(check) -> catalog.add_constraint(cat, stream, check)
    ast.DropConstraint(constraint_name:, span: _) ->
      catalog.drop_constraint(cat, stream, constraint_name)
  }
}

//-----------------------------------------------------------------------------
// CREATE STREAM checks (spec.md §9)
//-----------------------------------------------------------------------------

fn check_create_stream(
  stream_name: String,
  elements: List(ast.StreamElement),
  span: Span,
) -> List(SemanticError) {
  let cols = column_defs(elements)
  let all_checks =
    list.append(
      list.flat_map(cols, fn(c) { c.checks }),
      table_constraints(elements),
    )
  let valid_names = list.map(cols, fn(c) { c.name })

  list.flatten([
    // 1. Column names unique within the stream (compared via
    // `postgres_name`, so two names colliding only after truncation
    // still raise this).
    find_duplicates(list.map(cols, fn(c) { #(c.name, c.span) }), fn(name, s) {
      DuplicateColumnName(stream: stream_name, name: name, span: s)
    }),
    // 2. Exactly one HLC column.
    hlc_count_errors(stream_name, cols, span),
    // 3. That column: not OPTIONAL, no DEFAULT/GENERATED.
    hlc_shape_errors(cols),
    // 4. DEFAULT may not reference any column, sibling or otherwise.
    list.flat_map(cols, check_default_has_no_column_refs),
    // 5. GENERATED/CHECK may only reference this stream's own columns.
    list.flat_map(cols, fn(c) {
      case c.generated {
        None -> []
        Some(g) -> check_expr_column_refs(g.expr, valid_names)
      }
    }),
    list.flat_map(all_checks, fn(check) {
      check_expr_column_refs(check.expr, valid_names)
    }),
    // 6. Constraint names unique within the stream (column-level and
    // table-level together), same `postgres_name` comparison as (1).
    find_duplicates(
      list.map(all_checks, fn(c) { #(c.constraint_name, c.span) }),
      fn(name, s) {
        DuplicateConstraintName(stream: stream_name, name: name, span: s)
      },
    ),
    // 7. data_type parameter sanity, per §9.1's data_type grammar.
    list.flat_map(cols, check_data_type_params),
  ])
}

fn column_defs(elements: List(ast.StreamElement)) -> List(ast.ColumnDef) {
  list.filter_map(elements, fn(element) {
    case element {
      ast.Column(col) -> Ok(col)
      ast.TableConstraint(..) -> Error(Nil)
    }
  })
}

fn table_constraints(
  elements: List(ast.StreamElement),
) -> List(xast.NamedCheck) {
  list.filter_map(elements, fn(element) {
    case element {
      ast.TableConstraint(check:, span: _) -> Ok(check)
      ast.Column(..) -> Error(Nil)
    }
  })
}

fn hlc_columns(cols: List(ast.ColumnDef)) -> List(ast.ColumnDef) {
  list.filter(cols, fn(c) { c.data_type == xast.DtHlc })
}

fn hlc_count_errors(
  stream_name: String,
  cols: List(ast.ColumnDef),
  span: Span,
) -> List(SemanticError) {
  case hlc_columns(cols) {
    [] -> [MissingHlcColumn(stream: stream_name, span: span)]
    [_] -> []
    [first, second, ..] -> [
      MultipleHlcColumns(
        stream: stream_name,
        first: first.name,
        second: second.name,
        span: span,
      ),
    ]
  }
}

fn hlc_shape_errors(cols: List(ast.ColumnDef)) -> List(SemanticError) {
  case hlc_columns(cols) {
    // Ambiguous (or nonexistent) which column to check further —
    // `hlc_count_errors` above already reports the real problem.
    [hlc] -> {
      let optional_err = case hlc.optional {
        True -> [HlcColumnOptional(column: hlc.name, span: hlc.span)]
        False -> []
      }
      let default_or_generated_err = case
        option.is_some(hlc.default) || option.is_some(hlc.generated)
      {
        True -> [
          HlcColumnHasDefaultOrGenerated(column: hlc.name, span: hlc.span),
        ]
        False -> []
      }
      list.append(optional_err, default_or_generated_err)
    }
    _ -> []
  }
}

fn check_default_has_no_column_refs(col: ast.ColumnDef) -> List(SemanticError) {
  case col.default {
    None -> []
    Some(expr) ->
      list.map(collect_column_refs(expr), fn(ref) {
        let #(name, span) = ref
        DefaultReferencesColumn(column: col.name, referenced: name, span: span)
      })
  }
}

fn check_data_type_params(col: ast.ColumnDef) -> List(SemanticError) {
  case col.data_type {
    xast.DtChar(length) -> check_length("CHAR", length, col)
    xast.DtVarchar(length) -> check_length("VARCHAR", length, col)
    xast.DtDecimal(precision:, scale:) ->
      check_precision_scale("DECIMAL", precision, scale, col)
    xast.DtNumeric(precision:, scale:) ->
      check_precision_scale("NUMERIC", precision, scale, col)
    _ -> []
  }
}

fn check_length(
  type_name: String,
  length: Option(Int),
  col: ast.ColumnDef,
) -> List(SemanticError) {
  case length {
    None -> []
    Some(n) ->
      case n < 1 {
        False -> []
        True -> [
          InvalidDataTypeParameter(
            column: col.name,
            span: col.span,
            reason: type_name
              <> " length must be at least 1, got "
              <> int.to_string(n),
          ),
        ]
      }
  }
}

fn check_precision_scale(
  type_name: String,
  precision: Option(Int),
  scale: Option(Int),
  col: ast.ColumnDef,
) -> List(SemanticError) {
  case precision {
    None -> []
    Some(p) -> {
      let precision_err = case p < 1 {
        False -> []
        True -> [
          InvalidDataTypeParameter(
            column: col.name,
            span: col.span,
            reason: type_name
              <> " precision must be at least 1, got "
              <> int.to_string(p),
          ),
        ]
      }
      let scale_err = case scale {
        None -> []
        Some(s) ->
          case s < 0 || s > p {
            False -> []
            True -> [
              InvalidDataTypeParameter(
                column: col.name,
                span: col.span,
                reason: type_name
                  <> " scale must be between 0 and precision ("
                  <> int.to_string(p)
                  <> "), got "
                  <> int.to_string(s),
              ),
            ]
          }
      }
      list.append(precision_err, scale_err)
    }
  }
}

//-----------------------------------------------------------------------------
// ALTER STREAM checks (spec.md §10)
//-----------------------------------------------------------------------------

fn check_alter_stream(
  cat: Catalog,
  stream_name: String,
  actions: List(ast.AlterAction),
  span: Span,
) -> List(SemanticError) {
  case dict.get(cat.streams, stream_name) {
    Error(Nil) -> [UnknownStream(name: stream_name, span: span)]
    Ok(schema) -> {
      // A `DROP CONSTRAINT x, ADD CONSTRAINT x ...` pair in the same
      // statement — spec.md §10.5's way to replace a constraint — must
      // not trip `AddConstraint`'s own duplicate-name check: every
      // action here is checked against `schema` as it was *before* this
      // statement (actions aren't applied incrementally during
      // validation, only afterward, once everything has passed — see
      // `analyze`), so without this, replacing a constraint under its
      // own name in one statement would always look like a duplicate.
      let dropped_constraint_names =
        list.filter_map(actions, fn(a) {
          case a {
            ast.DropConstraint(constraint_name:, span: _) -> Ok(constraint_name)
            _ -> Error(Nil)
          }
        })
      list.flat_map(actions, check_alter_action(
        schema,
        dropped_constraint_names,
        _,
      ))
    }
  }
}

fn check_alter_action(
  schema: catalog.StreamSchema,
  dropped_constraint_names: List(String),
  action: ast.AlterAction,
) -> List(SemanticError) {
  case action {
    ast.AddColumn(col, _) -> check_add_column(schema, col)
    ast.DropColumn(column_name:, span:) ->
      check_drop_column(schema, column_name, span)
    ast.AlterColumnType(column_name:, data_type:, span:) ->
      check_alter_column_type(schema, column_name, data_type, span)
    ast.AddConstraint(check) ->
      check_add_constraint(schema, dropped_constraint_names, check)
    ast.DropConstraint(constraint_name:, span:) ->
      check_drop_constraint(schema, constraint_name, span)
  }
}

/// Checked against the union of `schema`'s existing columns and this one
/// new one, so a `CHECK` on the new column may reference an existing
/// sibling — same `DuplicateColumnName`/`UnknownColumnReference`/
/// parameter-sanity checks as `CREATE STREAM`, plus the two rules
/// specific to `ADD COLUMN` (§10.2).
fn check_add_column(
  schema: catalog.StreamSchema,
  col: ast.ColumnDef,
) -> List(SemanticError) {
  let existing_names = dict.keys(schema.columns)
  let valid_names = [col.name, ..existing_names]

  let duplicate_err = case
    list.contains(
      list.map(existing_names, postgres_name),
      postgres_name(col.name),
    )
  {
    False -> []
    True -> [
      DuplicateColumnName(stream: schema.name, name: col.name, span: col.span),
    ]
  }
  let generated_err = case col.generated {
    None -> []
    Some(g) -> check_expr_column_refs(g.expr, valid_names)
  }
  let check_err =
    list.flat_map(col.checks, fn(c) {
      check_expr_column_refs(c.expr, valid_names)
    })
  let needs_default_err = case
    col.optional || option.is_some(col.default) || option.is_some(col.generated)
  {
    True -> []
    False -> [AddColumnNeedsOptionalOrDefault(column: col.name, span: col.span)]
  }
  let second_hlc_err = case col.data_type {
    xast.DtHlc -> [AddSecondHlcColumn(column: col.name, span: col.span)]
    _ -> []
  }

  list.flatten([
    duplicate_err,
    generated_err,
    check_default_has_no_column_refs(col),
    check_err,
    check_data_type_params(col),
    needs_default_err,
    second_hlc_err,
  ])
}

fn check_drop_column(
  schema: catalog.StreamSchema,
  column_name: String,
  span: Span,
) -> List(SemanticError) {
  case dict.get(schema.columns, column_name) {
    Error(Nil) -> [DropUnknownColumn(column: column_name, span: span)]
    Ok(col) ->
      case col.optional {
        True -> []
        False -> [DropNonOptionalColumn(column: column_name, span: span)]
      }
  }
}

fn check_alter_column_type(
  schema: catalog.StreamSchema,
  column_name: String,
  new_type: xast.DataType,
  span: Span,
) -> List(SemanticError) {
  case dict.get(schema.columns, column_name) {
    // No dedicated "unknown column" variant for this action in the
    // plan's own error listing — reusing `DropUnknownColumn` was
    // explicitly offered there as one option ("reuse DropUnknownColumn's
    // shape or a dedicated variant — open question, naming only").
    Error(Nil) -> [DropUnknownColumn(column: column_name, span: span)]
    Ok(col) ->
      case classify_type_change(col.data_type, new_type) {
        Widening -> []
        Narrowing -> [
          NarrowingTypeChange(
            column: column_name,
            from: col.data_type,
            to: new_type,
            span: span,
          ),
        ]
        Unsupported -> [
          UnsupportedTypeChange(
            column: column_name,
            from: col.data_type,
            to: new_type,
            span: span,
          ),
        ]
      }
  }
}

type TypeChangeKind {
  Widening
  Narrowing
  Unsupported
}

/// Spec.md §10.4's rules. `None` (an unconstrained `VARCHAR`/`DECIMAL`/
/// `NUMERIC`, or a bare `CHAR`) is handled as follows, beyond what §10.4
/// states explicitly: moving *to* `None` (unconstrained) is always
/// widening — it accepts everything the old, necessarily-more-specific
/// type could; moving *from* `None` to a bounded form is always
/// narrowing, symmetrically. This is this plan's own extension, not
/// something spec.md resolves — see "Remaining open details."
fn classify_type_change(
  old: xast.DataType,
  new: xast.DataType,
) -> TypeChangeKind {
  case old, new {
    xast.DtSmallint, xast.DtInt -> Widening
    xast.DtSmallint, xast.DtInteger -> Widening
    xast.DtSmallint, xast.DtBigint -> Widening
    xast.DtInt, xast.DtInteger -> Widening
    xast.DtInt, xast.DtBigint -> Widening
    xast.DtInteger, xast.DtInt -> Widening
    xast.DtInteger, xast.DtBigint -> Widening
    xast.DtInt, xast.DtSmallint -> Narrowing
    xast.DtInteger, xast.DtSmallint -> Narrowing
    xast.DtBigint, xast.DtSmallint -> Narrowing
    xast.DtBigint, xast.DtInt -> Narrowing
    xast.DtBigint, xast.DtInteger -> Narrowing
    xast.DtReal, xast.DtDouble -> Widening
    xast.DtDouble, xast.DtReal -> Narrowing
    xast.DtChar(o), xast.DtChar(n) ->
      length_change(option.unwrap(o, 1), option.unwrap(n, 1))
    xast.DtVarchar(o), xast.DtVarchar(n) -> varchar_length_change(o, n)
    xast.DtDecimal(op, os), xast.DtDecimal(np, ns) ->
      decimal_change(op, os, np, ns)
    xast.DtNumeric(op, os), xast.DtNumeric(np, ns) ->
      decimal_change(op, os, np, ns)
    _, _ ->
      case old == new {
        True -> Widening
        False -> Unsupported
      }
  }
}

fn length_change(old_n: Int, new_n: Int) -> TypeChangeKind {
  case new_n >= old_n {
    True -> Widening
    False -> Narrowing
  }
}

fn varchar_length_change(old: Option(Int), new: Option(Int)) -> TypeChangeKind {
  case new {
    None -> Widening
    Some(new_n) ->
      case old {
        None -> Narrowing
        Some(old_n) -> length_change(old_n, new_n)
      }
  }
}

fn decimal_change(
  old_precision: Option(Int),
  old_scale: Option(Int),
  new_precision: Option(Int),
  new_scale: Option(Int),
) -> TypeChangeKind {
  case new_precision {
    None -> Widening
    Some(new_p) ->
      case old_precision {
        None -> Narrowing
        Some(old_p) -> {
          let os = option.unwrap(old_scale, 0)
          let ns = option.unwrap(new_scale, 0)
          case ns >= os && new_p - ns >= old_p - os {
            True -> Widening
            False -> Narrowing
          }
        }
      }
  }
}

fn check_add_constraint(
  schema: catalog.StreamSchema,
  dropped_constraint_names: List(String),
  check: xast.NamedCheck,
) -> List(SemanticError) {
  let effective_existing_names =
    list.filter(dict.keys(schema.constraints), fn(name) {
      !list.contains(dropped_constraint_names, name)
    })
  let duplicate_err = case
    list.contains(
      list.map(effective_existing_names, postgres_name),
      postgres_name(check.constraint_name),
    )
  {
    False -> []
    True -> [
      DuplicateConstraintName(
        stream: schema.name,
        name: check.constraint_name,
        span: check.span,
      ),
    ]
  }
  list.append(
    duplicate_err,
    check_expr_column_refs(check.expr, dict.keys(schema.columns)),
  )
}

fn check_drop_constraint(
  schema: catalog.StreamSchema,
  constraint_name: String,
  span: Span,
) -> List(SemanticError) {
  case dict.has_key(schema.constraints, constraint_name) {
    True -> []
    False -> [DropUnknownConstraint(name: constraint_name, span: span)]
  }
}

//-----------------------------------------------------------------------------
// INSERT checks (spec.md §11)
//-----------------------------------------------------------------------------

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

/// Detects names in `items` that collide once compared via
/// `postgres_name`, in order, reporting every later duplicate (not the
/// first occurrence) via `make_error`.
fn find_duplicates(
  items: List(#(String, Span)),
  make_error: fn(String, Span) -> SemanticError,
) -> List(SemanticError) {
  find_duplicates_loop(items, [], make_error)
}

fn find_duplicates_loop(
  items: List(#(String, Span)),
  seen: List(String),
  make_error: fn(String, Span) -> SemanticError,
) -> List(SemanticError) {
  case items {
    [] -> []
    [#(name, span), ..rest] -> {
      let key = postgres_name(name)
      case list.contains(seen, key) {
        True -> [
          make_error(name, span),
          ..find_duplicates_loop(rest, seen, make_error)
        ]
        False -> find_duplicates_loop(rest, [key, ..seen], make_error)
      }
    }
  }
}

/// Approximates PostgreSQL's own 63-byte `NAMEDATALEN` truncation (§2),
/// purely so the column/constraint-name uniqueness checks above can
/// catch a collision the way PostgreSQL will ultimately see it — two
/// identifiers differing only after byte 63 collide there even if they
/// don't collide as written. This exists only to give an earlier,
/// friendlier diagnostic than PostgreSQL's own error at execution time
/// (see "On not truncating in the lexer" in lexer.gleam); it is **not**
/// required to match PostgreSQL's `pg_mbcliplen` byte-for-byte — backing
/// off to the last full-codepoint boundary at or before byte 63 is good
/// enough.
fn postgres_name(identifier: String) -> String {
  case string.byte_size(identifier) <= 63 {
    True -> identifier
    False -> truncate_to_63_bytes(string.to_graphemes(identifier))
  }
}

fn truncate_to_63_bytes(chars: List(String)) -> String {
  truncate_to_63_bytes_loop(chars, 0, "")
}

fn truncate_to_63_bytes_loop(
  chars: List(String),
  acc_bytes: Int,
  acc: String,
) -> String {
  case chars {
    [] -> acc
    [c, ..rest] -> {
      let new_bytes = acc_bytes + string.byte_size(c)
      case new_bytes > 63 {
        True -> acc
        False -> truncate_to_63_bytes_loop(rest, new_bytes, acc <> c)
      }
    }
  }
}
//-----------------------------------------------------------------------------
