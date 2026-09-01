import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lang/ddl_ast as ast
import lang/expr_ast as xast
import lang/expr_parser.{
  type ParseError, ExplicitNotNull, MissingGeneratedStorage,
} as ep
import lang/token
import lang/token_stream.{type TokenStream} as ts

//-----------------------------------------------------------------------------
// Recursive descent, one token of lookahead for statement dispatch and
// most productions; the expression grammar needs 2-token lookahead in
// exactly one place (`parse_keyword_ops_after`, level 7). Every parse_*
// function below takes the remaining `TokenStream` (always ending in
// `Eof`, never fully consumed) and returns
// `Result(#(<thing>, TokenStream), ParseError)`.
//-----------------------------------------------------------------------------

pub fn parse(tokstrm: TokenStream) -> Result(ast.DdlStatement, ParseError) {
  use #(stmt, tokstrm1) <- result.try(case ts.current(tokstrm).kind {
    token.Keyword(token.KwCreate) -> parse_create_stream(tokstrm)
    token.Keyword(token.KwAlter) -> parse_alter_stream(tokstrm)
    _ -> Error(ep.fail(tokstrm, "CREATE or ALTER"))
  })
  use _ <- result.try(ep.expect_eof(tokstrm1))
  Ok(stmt)
}

//-----------------------------------------------------------------------------
// CREATE STREAM (spec.md §9.1)
//-----------------------------------------------------------------------------

pub fn parse_create_stream(
  tokstrm: TokenStream,
) -> Result(#(ast.DdlStatement, TokenStream), ParseError) {
  let start_span = ts.current(tokstrm).span
  use #(_, tokstrm1) <- result.try(ep.expect_keyword(
    tokstrm,
    token.KwCreate,
    "CREATE",
  ))
  use #(_, tokstrm2) <- result.try(ep.expect_keyword(
    tokstrm1,
    token.KwStream,
    "STREAM",
  ))
  use #(name, _, tokstrm3) <- result.try(ep.expect_identifier(
    tokstrm2,
    "a stream name",
  ))
  use #(_, tokstrm4) <- result.try(ep.expect_punct(
    tokstrm3,
    token.LeftParen,
    "(",
  ))
  use #(elements, tokstrm5) <- result.try(parse_stream_elements(tokstrm4))
  use #(rparen_span, tokstrm6) <- result.try(ep.expect_punct(
    tokstrm5,
    token.RightParen,
    ")",
  ))
  let #(end_pos, tokstrm7) =
    ts.consume_optional_semicolon(tokstrm6, rparen_span.end)
  let span = token.Span(start_span.start, end_pos)
  Ok(#(ast.CreateStream(name, elements, span), tokstrm7))
}

fn parse_stream_elements(
  tokstrm: TokenStream,
) -> Result(#(List(ast.StreamElement), TokenStream), ParseError) {
  use #(first, tokstrm1) <- result.try(parse_stream_element(tokstrm))
  parse_stream_elements_loop([first], tokstrm1)
}

fn parse_stream_elements_loop(
  acc: List(ast.StreamElement),
  tokstrm: TokenStream,
) -> Result(#(List(ast.StreamElement), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokstrm))
    True -> {
      use #(next, tokstrm1) <- result.try(
        parse_stream_element(ts.advance(tokstrm)),
      )
      parse_stream_elements_loop([next, ..acc], tokstrm1)
    }
  }
}

/// Dispatches on `CONSTRAINT` (→ `table_constraint`) vs. an identifier
/// (→ `column_def`) — the only two `stream_element` alternatives (§9.1).
fn parse_stream_element(
  tokstrm: TokenStream,
) -> Result(#(ast.StreamElement, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Keyword(token.KwConstraint) -> {
      use #(check, tokstrm1) <- result.try(parse_named_check(tokstrm))
      Ok(#(ast.TableConstraint(check, check.span), tokstrm1))
    }
    _ -> {
      use #(col, tokstrm1) <- result.try(parse_column_def(tokstrm))
      Ok(#(ast.Column(col), tokstrm1))
    }
  }
}

/// `CONSTRAINT constraint_name CHECK ( expr )` — shared by a column's own
/// `CONSTRAINT` clause, a standalone `table_constraint`, `ADD
/// CONSTRAINT`, and (via its `expr`) nothing else.
fn parse_named_check(
  tokstrm: TokenStream,
) -> Result(#(ast.NamedCheck, TokenStream), ParseError) {
  let start_span = ts.current(tokstrm).span
  use #(_, tokstrm1) <- result.try(ep.expect_keyword(
    tokstrm,
    token.KwConstraint,
    "CONSTRAINT",
  ))
  use #(name, _, tokstrm2) <- result.try(ep.expect_identifier(
    tokstrm1,
    "a constraint name",
  ))
  use #(_, tokstrm3) <- result.try(ep.expect_keyword(
    tokstrm2,
    token.KwCheck,
    "CHECK",
  ))
  use #(_, tokstrm4) <- result.try(ep.expect_punct(
    tokstrm3,
    token.LeftParen,
    "(",
  ))
  use #(expr, tokstrm5) <- result.try(ep.parse_or(tokstrm4))
  use #(rparen_span, tokstrm6) <- result.try(ep.expect_punct(
    tokstrm5,
    token.RightParen,
    ")",
  ))
  let span = token.Span(start_span.start, rparen_span.end)
  Ok(#(ast.NamedCheck(name, expr, span), tokstrm6))
}

/// Clauses accumulated while scanning a `column_def`'s `column_clause*`
/// (§9.1). `checks` accumulates in reverse (prepend, then
/// `list.reverse` once done in `parse_column_def`) — the usual O(n) list-
/// building idiom rather than O(n²) appending.
type ClauseAcc {
  ClauseAcc(
    optional: Bool,
    default: Option(xast.Expr),
    generated: Option(ast.GeneratedClause),
    checks: List(ast.NamedCheck),
  )
}

fn parse_column_def(
  tokstrm: TokenStream,
) -> Result(#(ast.ColumnDef, TokenStream), ParseError) {
  let start_span = ts.current(tokstrm).span
  use #(name, _, tokstrm1) <- result.try(ep.expect_identifier(
    tokstrm,
    "a column name",
  ))
  use #(dt, tokstrm2) <- result.try(ep.parse_data_type(tokstrm1))
  use #(acc, tokstrm3) <- result.try(parse_column_clauses(
    tokstrm2,
    ClauseAcc(optional: False, default: None, generated: None, checks: []),
  ))
  // The span ends where the next token (`,` or `)`) begins — good enough
  // to underline "this column_def" without threading a precise end
  // position out of an arbitrary `DEFAULT`/`CHECK` expr, which carries
  // no span of its own; see the note on `Expr` spans in expr_ast.gleam.
  let span = token.Span(start_span.start, ts.current(tokstrm3).span.start)
  let col =
    ast.ColumnDef(
      name: name,
      data_type: dt,
      optional: acc.optional,
      default: acc.default,
      generated: acc.generated,
      checks: list.reverse(acc.checks),
      span: span,
    )
  Ok(#(col, tokstrm3))
}

fn parse_column_clauses(
  tokstrm: TokenStream,
  acc: ClauseAcc,
) -> Result(#(ClauseAcc, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Keyword(token.KwOptional) ->
      parse_column_clauses(
        ts.advance(tokstrm),
        ClauseAcc(..acc, optional: True),
      )
    token.Keyword(token.KwDefault) -> {
      use #(expr, tokstrm1) <- result.try(ep.parse_or(ts.advance(tokstrm)))
      parse_column_clauses(tokstrm1, ClauseAcc(..acc, default: Some(expr)))
    }
    token.Keyword(token.KwGenerated) -> {
      use #(clause, tokstrm1) <- result.try(parse_generated_clause(tokstrm))
      parse_column_clauses(tokstrm1, ClauseAcc(..acc, generated: Some(clause)))
    }
    token.Keyword(token.KwConstraint) -> {
      use #(check, tokstrm1) <- result.try(parse_named_check(tokstrm))
      parse_column_clauses(
        tokstrm1,
        ClauseAcc(..acc, checks: [check, ..acc.checks]),
      )
    }
    token.Keyword(token.KwNot) -> {
      // §9.3: `NOT NULL` is never legal to write (columns are `NOT NULL`
      // by default already) — reported as `ExplicitNotNull`, not a
      // generic parse error, so the caller can render spec.md's own
      // guidance ("use OPTIONAL instead").
      let not_span = ts.current(tokstrm).span
      case ts.current(ts.advance(tokstrm)).kind {
        token.Keyword(token.KwNull) -> {
          let null_span = ts.current(ts.advance(tokstrm)).span
          Error(
            ExplicitNotNull(span: token.Span(not_span.start, null_span.end)),
          )
        }
        _ ->
          Error(ep.fail(tokstrm, "OPTIONAL, DEFAULT, GENERATED, or CONSTRAINT"))
      }
    }
    _ -> Ok(#(acc, tokstrm))
  }
}

fn parse_generated_clause(
  tokstrm: TokenStream,
) -> Result(#(ast.GeneratedClause, TokenStream), ParseError) {
  use #(_, tokstrm1) <- result.try(ep.expect_keyword(
    tokstrm,
    token.KwGenerated,
    "GENERATED",
  ))
  use #(_, tokstrm2) <- result.try(ep.expect_keyword(
    tokstrm1,
    token.KwAlways,
    "ALWAYS",
  ))
  use #(_, tokstrm3) <- result.try(ep.expect_keyword(tokstrm2, token.KwAs, "AS"))
  use #(_, tokstrm4) <- result.try(ep.expect_punct(
    tokstrm3,
    token.LeftParen,
    "(",
  ))
  use #(expr, tokstrm5) <- result.try(ep.parse_or(tokstrm4))
  use #(_, tokstrm6) <- result.try(ep.expect_punct(
    tokstrm5,
    token.RightParen,
    ")",
  ))
  case ts.current(tokstrm6).kind {
    token.Keyword(token.KwStored) ->
      Ok(#(ast.GeneratedClause(expr, ast.Stored), ts.advance(tokstrm6)))
    token.Keyword(token.KwVirtual) ->
      Ok(#(ast.GeneratedClause(expr, ast.Virtual), ts.advance(tokstrm6)))
    _ -> Error(MissingGeneratedStorage(span: ts.current(tokstrm6).span))
  }
}

//-----------------------------------------------------------------------------
// ALTER STREAM (spec.md §10.1)
//-----------------------------------------------------------------------------

fn parse_alter_stream(
  tokstrm: TokenStream,
) -> Result(#(ast.DdlStatement, TokenStream), ParseError) {
  let start_span = ts.current(tokstrm).span
  use #(_, tokstrm1) <- result.try(ep.expect_keyword(
    tokstrm,
    token.KwAlter,
    "ALTER",
  ))
  use #(_, tokstrm2) <- result.try(ep.expect_keyword(
    tokstrm1,
    token.KwStream,
    "STREAM",
  ))
  use #(name, _, tokstrm3) <- result.try(ep.expect_identifier(
    tokstrm2,
    "a tokstrm name",
  ))
  use #(actions, tokstrm4) <- result.try(parse_alter_actions(tokstrm3))
  let #(end_pos, tokstrm5) =
    ts.consume_optional_semicolon(tokstrm4, ts.current(tokstrm4).span.start)
  let span = token.Span(start_span.start, end_pos)
  Ok(#(ast.AlterStream(name, actions, span), tokstrm5))
}

fn parse_alter_actions(
  tokstrm: TokenStream,
) -> Result(#(List(ast.AlterAction), TokenStream), ParseError) {
  use #(first, tokstrm1) <- result.try(parse_alter_action(tokstrm))
  parse_alter_actions_loop([first], tokstrm1)
}

fn parse_alter_actions_loop(
  acc: List(ast.AlterAction),
  tokstrm: TokenStream,
) -> Result(#(List(ast.AlterAction), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokstrm))
    True -> {
      use #(next, tokstrm1) <- result.try(
        parse_alter_action(ts.advance(tokstrm)),
      )
      parse_alter_actions_loop([next, ..acc], tokstrm1)
    }
  }
}

/// `ADD`/`DROP` (each further dispatching on `COLUMN` vs. `CONSTRAINT`)
/// or `ALTER COLUMN name TYPE data_type` (§10.1). `COLUMN` is mandatory
/// throughout, unlike PostgreSQL — see spec.md §3.3.
fn parse_alter_action(
  tokstrm: TokenStream,
) -> Result(#(ast.AlterAction, TokenStream), ParseError) {
  let start_span = ts.current(tokstrm).span
  case ts.current(tokstrm).kind {
    token.Keyword(token.KwAdd) ->
      case ts.current(ts.advance(tokstrm)).kind {
        token.Keyword(token.KwColumn) -> {
          use #(col, tokstrm1) <- result.try(
            parse_column_def(ts.advance(ts.advance(tokstrm))),
          )
          let span =
            token.Span(start_span.start, ts.current(tokstrm1).span.start)
          Ok(#(ast.AddColumn(col, span), tokstrm1))
        }
        token.Keyword(token.KwConstraint) -> {
          use #(check, tokstrm1) <- result.try(
            parse_named_check(ts.advance(tokstrm)),
          )
          Ok(#(ast.AddConstraint(check), tokstrm1))
        }
        _ -> Error(ep.fail(ts.advance(tokstrm), "COLUMN or CONSTRAINT"))
      }
    token.Keyword(token.KwDrop) ->
      case ts.current(ts.advance(tokstrm)).kind {
        token.Keyword(token.KwColumn) -> {
          use #(name, name_span, tokstrm1) <- result.try(ep.expect_identifier(
            ts.advance(ts.advance(tokstrm)),
            "a column name",
          ))
          let span = token.Span(start_span.start, name_span.end)
          Ok(#(ast.DropColumn(name, span), tokstrm1))
        }
        token.Keyword(token.KwConstraint) -> {
          use #(name, name_span, tokstrm1) <- result.try(ep.expect_identifier(
            ts.advance(ts.advance(tokstrm)),
            "a constraint name",
          ))
          let span = token.Span(start_span.start, name_span.end)
          Ok(#(ast.DropConstraint(name, span), tokstrm1))
        }
        _ -> Error(ep.fail(ts.advance(tokstrm), "COLUMN or CONSTRAINT"))
      }
    token.Keyword(token.KwAlter) -> {
      use #(_, tokstrm1) <- result.try(ep.expect_keyword(
        ts.advance(tokstrm),
        token.KwColumn,
        "COLUMN",
      ))
      use #(name, _, tokstrm2) <- result.try(ep.expect_identifier(
        tokstrm1,
        "a column name",
      ))
      use #(_, tokstrm3) <- result.try(ep.expect_keyword(
        tokstrm2,
        token.KwType,
        "TYPE",
      ))
      use #(dt, tokstrm4) <- result.try(ep.parse_data_type(tokstrm3))
      let span = token.Span(start_span.start, ts.current(tokstrm4).span.start)
      Ok(#(ast.AlterColumnType(name, dt, span), tokstrm4))
    }
    _ -> Error(ep.fail(tokstrm, "ADD, DROP, or ALTER"))
  }
}
//-----------------------------------------------------------------------------
