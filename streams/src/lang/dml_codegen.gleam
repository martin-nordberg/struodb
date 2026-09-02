import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import hlc/clock
import lang/catalog.{type Catalog}
import lang/dml_ast as ast
import lang/dml_parser
import lang/dml_semantics
import lang/expr_codegen
import lang/expr_parser.{type ParseError}
import lang/lexer
import lang/token_stream

//-----------------------------------------------------------------------------
// Turns a `DmlStatement` (already validated by `dml_semantics.gleam`)
// into PostgreSQL `INSERT INTO` SQL text. See
// docs/lang/codegen-plan.md's "Statement codegen" for the rendering
// rules and "Worked examples" for the concrete acceptance target.
//-----------------------------------------------------------------------------

pub type CodegenError {
  LexFailure(lexer.LexError)
  ParseFailure(ParseError)
  /// `statement_index` is 0-based, counting only statements that were
  /// successfully parsed before this one failed to validate.
  SemanticFailure(
    statement_index: Int,
    errors: List(dml_semantics.SemanticError),
  )
}

/// Validates every statement in `source` against `catalog` (threaded
/// across them in order, exactly as calling `dml_semantics.analyze`
/// repeatedly would), and — only if every one of them passes — returns
/// the equivalent formatted PostgreSQL for all of them concatenated, plus
/// the resulting `Catalog`. `INSERT` never changes a stream's shape, so
/// the returned catalog is always identical to `catalog`; it's still
/// returned, for symmetry with `ddl_codegen.generate` and so a caller
/// chaining several batches doesn't need to special-case which kind it's
/// threading.
///
/// `next_hlc` draws one fresh HLC value — unlike `schema/ddl_codegen.
/// generate`, this is not a pure function of `catalog`/`source` alone:
/// every row actually inserted calls `next_hlc` once, one draw per row
/// across every statement in `source`, to populate 4 of the 5 automatic
/// system columns (spec.md §9.2) — the HLC-derived ones. Two calls with
/// identical `catalog`/`source` but a `next_hlc` returning different
/// values will render different `_STRUO_HLC...` values. A caller backed
/// by a live `hlc/clock_keeper` actor passes
/// `fn() { clock_keeper.next_parts(keeper_subject) }`; taking a plain
/// function here, rather than the actor `Subject` itself, keeps this
/// module decoupled from `hlc/clock_keeper`'s actor-based implementation
/// and trivial to drive with a canned sequence in tests — and is why
/// this module depends on `hlc/clock` (the pure `HlcParts` shape and
/// state machine) rather than `hlc/clock_keeper` (the actor wrapper
/// around it): this module has no actor of its own to talk to, only
/// values `next_hlc` hands it. The 5th system column,
/// `_struo_created_at`, is never rendered here at all — its
/// `DEFAULT clock_timestamp()` (`schema/ddl_codegen.gleam`) is what
/// populates it, so there's nothing for `generate` to draw for it.
pub fn generate(
  catalog: Catalog,
  source: String,
  next_hlc: fn() -> clock.HlcParts,
) -> Result(#(String, Catalog), CodegenError) {
  use tokens <- result.try(
    lexer.tokenize(source) |> result.map_error(LexFailure),
  )
  use statements <- result.try(
    dml_parser.parse_many(token_stream.new(tokens))
    |> result.map_error(ParseFailure),
  )
  use final_catalog <- result.try(validate_all(catalog, statements, 0))
  Ok(#(render_all(statements, next_hlc), final_catalog))
}

/// Convenience wrapper for the common single-shot case: validates
/// against an empty `Catalog`. Realistically only useful for a source
/// whose `INSERT`s target streams whose shape doesn't matter for this
/// call's own purposes — most callers will want `generate` with a real
/// `Catalog` (e.g. one `schema/ddl_codegen.generate` already produced).
pub fn generate_standalone(
  source: String,
  next_hlc: fn() -> clock.HlcParts,
) -> Result(String, CodegenError) {
  use #(sql, _catalog) <- result.try(generate(catalog.empty(), source, next_hlc))
  Ok(sql)
}

fn validate_all(
  catalog: Catalog,
  statements: List(ast.DmlStatement),
  index: Int,
) -> Result(Catalog, CodegenError) {
  case statements {
    [] -> Ok(catalog)
    [stmt, ..rest] ->
      case dml_semantics.analyze(catalog, stmt) {
        Ok(next_catalog) -> validate_all(next_catalog, rest, index + 1)
        Error(errors) -> Error(SemanticFailure(index, errors))
      }
  }
}

fn render_all(
  statements: List(ast.DmlStatement),
  next_hlc: fn() -> clock.HlcParts,
) -> String {
  statements
  |> list.map(fn(stmt) {
    insert_to_sql(stmt, next_hlc) |> string_tree.from_string
  })
  |> string_tree.join("\n\n")
  |> string_tree.append("\n")
  |> string_tree.to_string
}

//-----------------------------------------------------------------------------
// INSERT -> INSERT INTO
//-----------------------------------------------------------------------------

/// The 4 system column names actually written into a generated `INSERT`
/// — a prefix of `catalog.system_columns()`'s full 5, in the same fixed
/// order, leading every rendered column/value list ahead of the
/// statement's own `columns`/row values. `_struo_created_at`, the 5th,
/// is deliberately excluded: its value comes from the table's own
/// `DEFAULT clock_timestamp()`, never from generated `INSERT` text — see
/// `generate`'s doc comment above.
const system_column_names = [
  catalog.hlc_column_name, catalog.hlc_timestamp_column_name,
  catalog.hlc_count_column_name, catalog.hlc_node_id_column_name,
]

pub fn insert_to_sql(
  stmt: ast.DmlStatement,
  next_hlc: fn() -> clock.HlcParts,
) -> String {
  let ast.Insert(
    stream_name:,
    columns:,
    rows:,
    on_conflict_do_nothing:,
    returning:,
    span: _,
  ) = stmt

  let column_list =
    list.append(system_column_names, columns)
    |> list.map(expr_codegen.quote_identifier)
    |> string.join(", ")

  "INSERT INTO "
  <> expr_codegen.quote_identifier(stream_name)
  <> " ("
  <> column_list
  <> ")\nVALUES\n  "
  <> {
    rows
    |> list.map(fn(row) { row_to_sql(row, next_hlc()) })
    |> string.join(",\n  ")
  }
  <> on_conflict_sql(on_conflict_do_nothing)
  <> returning_sql(returning)
  <> ";"
}

fn row_to_sql(row: List(ast.Value), parts: clock.HlcParts) -> String {
  let values =
    list.append(system_values_to_sql(parts), list.map(row, value_to_sql))
  "(" <> string.join(values, ", ") <> ")"
}

/// The 4 system columns' own values for one row's freshly-drawn HLC
/// (`next_hlc`, typically backed by `clock_keeper.next_parts`), in
/// `system_column_names`'s order. `_STRUO_HLC_
/// TIMESTAMP` is rendered as `to_timestamp(<seconds>)` — a standard
/// PostgreSQL builtin that converts Unix-epoch seconds to `TIMESTAMPTZ`
/// — rather than any Gleam-side date/time formatting, so the embedded
/// physical time is turned into SQL text via plain integer arithmetic on
/// `physical_time_ms` (whole seconds `.` zero-padded milliseconds), with
/// no float round-tripping involved.
fn system_values_to_sql(parts: clock.HlcParts) -> List(String) {
  [
    expr_codegen.quote_string_literal(parts.encoded),
    "to_timestamp(" <> seconds_literal(parts.physical_time_ms) <> ")",
    int.to_string(parts.counter),
    int.to_string(parts.node_id),
  ]
}

/// `ms` (always non-negative — Unix epoch milliseconds) as
/// `<whole_seconds>.<millis, zero-padded to 3 digits>`.
fn seconds_literal(ms: Int) -> String {
  int.to_string(ms / 1000)
  <> "."
  <> string.pad_start(int.to_string(ms % 1000), to: 3, with: "0")
}

fn value_to_sql(value: ast.Value) -> String {
  case value {
    // Bare `DEFAULT`, §11.3 — matches PostgreSQL's own identical syntax
    // directly.
    ast.ValueDefault -> "DEFAULT"
    ast.ValueExpr(expr) -> expr_codegen.expr_to_sql(expr)
  }
}

fn on_conflict_sql(on_conflict_do_nothing: Bool) -> String {
  case on_conflict_do_nothing {
    True -> "\nON CONFLICT DO NOTHING"
    False -> ""
  }
}

fn returning_sql(returning: Option(List(ast.ReturningItem))) -> String {
  case returning {
    None -> ""
    Some(items) ->
      "\nRETURNING "
      <> { items |> list.map(returning_item_to_sql) |> string.join(", ") }
  }
}

fn returning_item_to_sql(item: ast.ReturningItem) -> String {
  case item {
    ast.ReturningStar -> "*"
    ast.ReturningExpr(expr, None) -> expr_codegen.expr_to_sql(expr)
    ast.ReturningExpr(expr, Some(alias)) ->
      expr_codegen.expr_to_sql(expr)
      <> " AS "
      <> expr_codegen.quote_identifier(alias)
  }
}
//-----------------------------------------------------------------------------
