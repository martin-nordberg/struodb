import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lang/dml_ast as ast
import lang/expr_parser.{type ParseError} as ep
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

pub fn parse(tokstrm: TokenStream) -> Result(ast.DmlStatement, ParseError) {
  use #(stmt, tokstrm1) <- result.try(case ts.current(tokstrm).kind {
    token.Keyword(token.KwInsert) -> parse_insert(tokstrm)
    _ -> Error(ep.fail(tokstrm, "INSERT"))
  })
  use _ <- result.try(ep.expect_eof(tokstrm1))
  Ok(stmt)
}

//-----------------------------------------------------------------------------
// INSERT (spec.md §11.1)
//-----------------------------------------------------------------------------

fn parse_insert(
  tokstrm: TokenStream,
) -> Result(#(ast.DmlStatement, TokenStream), ParseError) {
  let start_span = ts.current(tokstrm).span
  use #(_, tokstrm1) <- result.try(ep.expect_keyword(
    tokstrm,
    token.KwInsert,
    "INSERT",
  ))
  use #(_, tokstrm2) <- result.try(ep.expect_keyword(
    tokstrm1,
    token.KwInto,
    "INTO",
  ))
  use #(name, _, tokstrm3) <- result.try(ep.expect_identifier(
    tokstrm2,
    "a stream name",
  ))
  // §11.2: the column list is mandatory — no positional form.
  use #(_, tokstrm4) <- result.try(ep.expect_punct(
    tokstrm3,
    token.LeftParen,
    "(",
  ))
  use #(columns, tokstrm5) <- result.try(parse_identifier_list(tokstrm4))
  use #(_, tokstrm6) <- result.try(ep.expect_punct(
    tokstrm5,
    token.RightParen,
    ")",
  ))
  use #(_, tokstrm7) <- result.try(ep.expect_keyword(
    tokstrm6,
    token.KwValues,
    "VALUES",
  ))
  use #(rows, tokstrm8) <- result.try(parse_value_rows(tokstrm7))
  use #(on_conflict, tokstrm9) <- result.try(parse_optional_on_conflict(
    tokstrm8,
  ))
  use #(returning, tokstrm10) <- result.try(parse_optional_returning(tokstrm9))
  let #(end_pos, tokstrm11) =
    ts.consume_optional_semicolon(tokstrm10, ts.current(tokstrm10).span.start)
  let span = token.Span(start_span.start, end_pos)
  Ok(#(ast.Insert(name, columns, rows, on_conflict, returning, span), tokstrm11))
}

fn parse_identifier_list(
  tokstrm: TokenStream,
) -> Result(#(List(String), TokenStream), ParseError) {
  use #(first, _, tokstrm1) <- result.try(ep.expect_identifier(
    tokstrm,
    "a column name",
  ))
  parse_identifier_list_loop([first], tokstrm1)
}

fn parse_identifier_list_loop(
  acc: List(String),
  tokstrm: TokenStream,
) -> Result(#(List(String), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokstrm))
    True -> {
      use #(next, _, tokstrm1) <- result.try(ep.expect_identifier(
        ts.advance(tokstrm),
        "a column name",
      ))
      parse_identifier_list_loop([next, ..acc], tokstrm1)
    }
  }
}

fn parse_value_rows(
  tokstrm: TokenStream,
) -> Result(#(List(List(ast.Value)), TokenStream), ParseError) {
  use #(first, tokstrm1) <- result.try(parse_value_row(tokstrm))
  parse_value_rows_loop([first], tokstrm1)
}

fn parse_value_rows_loop(
  acc: List(List(ast.Value)),
  tokstrm: TokenStream,
) -> Result(#(List(List(ast.Value)), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokstrm))
    True -> {
      use #(next, tokstrm1) <- result.try(parse_value_row(ts.advance(tokstrm)))
      parse_value_rows_loop([next, ..acc], tokstrm1)
    }
  }
}

fn parse_value_row(
  tokstrm: TokenStream,
) -> Result(#(List(ast.Value), TokenStream), ParseError) {
  use #(_, tokstrm1) <- result.try(ep.expect_punct(
    tokstrm,
    token.LeftParen,
    "(",
  ))
  use #(values, tokstrm2) <- result.try(parse_values(tokstrm1))
  use #(_, tokstrm3) <- result.try(ep.expect_punct(
    tokstrm2,
    token.RightParen,
    ")",
  ))
  Ok(#(values, tokstrm3))
}

fn parse_values(
  tokstrm: TokenStream,
) -> Result(#(List(ast.Value), TokenStream), ParseError) {
  use #(first, tokstrm1) <- result.try(parse_value(tokstrm))
  parse_values_loop([first], tokstrm1)
}

fn parse_values_loop(
  acc: List(ast.Value),
  tokstrm: TokenStream,
) -> Result(#(List(ast.Value), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokstrm))
    True -> {
      use #(next, tokstrm1) <- result.try(parse_value(ts.advance(tokstrm)))
      parse_values_loop([next, ..acc], tokstrm1)
    }
  }
}

fn parse_value(
  tokstrm: TokenStream,
) -> Result(#(ast.Value, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Keyword(token.KwDefault) ->
      Ok(#(ast.ValueDefault, ts.advance(tokstrm)))
    _ -> {
      use #(expr, tokstrm1) <- result.try(ep.parse_or(tokstrm))
      Ok(#(ast.ValueExpr(expr), tokstrm1))
    }
  }
}

fn parse_optional_on_conflict(
  tokstrm: TokenStream,
) -> Result(#(Bool, TokenStream), ParseError) {
  case ts.peek_keyword(tokstrm, token.KwOn) {
    False -> Ok(#(False, tokstrm))
    True -> {
      use #(_, tokstrm1) <- result.try(ep.expect_keyword(
        ts.advance(tokstrm),
        token.KwConflict,
        "CONFLICT",
      ))
      use #(_, tokstrm2) <- result.try(ep.expect_keyword(
        tokstrm1,
        token.KwDo,
        "DO",
      ))
      use #(_, tokstrm3) <- result.try(ep.expect_keyword(
        tokstrm2,
        token.KwNothing,
        "NOTHING",
      ))
      Ok(#(True, tokstrm3))
    }
  }
}

fn parse_optional_returning(
  tokstrm: TokenStream,
) -> Result(#(Option(List(ast.ReturningItem)), TokenStream), ParseError) {
  case ts.peek_keyword(tokstrm, token.KwReturning) {
    False -> Ok(#(None, tokstrm))
    True -> {
      use #(items, tokstrm1) <- result.try(
        parse_returning_items(ts.advance(tokstrm)),
      )
      Ok(#(Some(items), tokstrm1))
    }
  }
}

fn parse_returning_items(
  tokstrm: TokenStream,
) -> Result(#(List(ast.ReturningItem), TokenStream), ParseError) {
  use #(first, tokstrm1) <- result.try(parse_returning_item(tokstrm))
  parse_returning_items_loop([first], tokstrm1)
}

fn parse_returning_items_loop(
  acc: List(ast.ReturningItem),
  tokstrm: TokenStream,
) -> Result(#(List(ast.ReturningItem), TokenStream), ParseError) {
  case ts.peek_kind(tokstrm, token.Comma) {
    False -> Ok(#(list.reverse(acc), tokstrm))
    True -> {
      use #(next, tokstrm1) <- result.try(
        parse_returning_item(ts.advance(tokstrm)),
      )
      parse_returning_items_loop([next, ..acc], tokstrm1)
    }
  }
}

fn parse_returning_item(
  tokstrm: TokenStream,
) -> Result(#(ast.ReturningItem, TokenStream), ParseError) {
  case ts.current(tokstrm).kind {
    token.Operator(token.Star) -> Ok(#(ast.ReturningStar, ts.advance(tokstrm)))
    _ -> {
      use #(expr, tokstrm1) <- result.try(ep.parse_or(tokstrm))
      case ts.peek_keyword(tokstrm1, token.KwAs) {
        False -> Ok(#(ast.ReturningExpr(expr, None), tokstrm1))
        True -> {
          use #(alias, _, tokstrm2) <- result.try(ep.expect_identifier(
            ts.advance(tokstrm1),
            "an alias",
          ))
          Ok(#(ast.ReturningExpr(expr, Some(alias)), tokstrm2))
        }
      }
    }
  }
}
//-----------------------------------------------------------------------------
