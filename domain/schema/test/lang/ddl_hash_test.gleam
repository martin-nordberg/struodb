import gleam/list
import gleam/string
import lang/ddl_ast as ast
import lang/ddl_hash
import lang/ddl_parser
import lang/lexer
import lang/token_stream

//-----------------------------------------------------------------------------
// See "Test plan" in documentation/plans/lang/migration-plan.md.
//-----------------------------------------------------------------------------

fn parse(source: String) -> ast.DdlStatement {
  let assert Ok(tokens) = lexer.tokenize(source)
  let assert Ok(stmt) = ddl_parser.parse(token_stream.new(tokens))
  stmt
}

pub fn whitespace_and_formatting_differences_hash_identically_test() {
  let compact = parse("CREATE STREAM s (a INT,b VARCHAR(10) OPTIONAL);")
  let spread =
    parse("CREATE   STREAM   s (\n  a INT,\n  b VARCHAR(10) OPTIONAL\n) ;")

  assert ddl_hash.hash_statement(compact) == ddl_hash.hash_statement(spread)
}

pub fn a_trailing_semicolon_does_not_affect_the_hash_test() {
  let with_semicolon = parse("CREATE STREAM s (a INT);")
  let without_semicolon = parse("CREATE STREAM s (a INT)")

  assert ddl_hash.hash_statement(with_semicolon)
    == ddl_hash.hash_statement(without_semicolon)
}

pub fn two_different_statements_hash_differently_test() {
  let a = parse("CREATE STREAM s (a INT);")
  let b = parse("CREATE STREAM s (a BIGINT);")

  assert ddl_hash.hash_statement(a) != ddl_hash.hash_statement(b)
}

/// Regression guard on "every node tags its own constructor" — two
/// `AlterAction`s naming the same column, differing only in which action
/// they are, must not collide just because their field values otherwise
/// line up.
pub fn different_alter_actions_on_the_same_column_hash_differently_test() {
  let drop = parse("ALTER STREAM s DROP COLUMN a;")
  let alter_type = parse("ALTER STREAM s ALTER COLUMN a TYPE BIGINT;")

  assert ddl_hash.hash_statement(drop) != ddl_hash.hash_statement(alter_type)
}

pub fn the_hash_is_a_64_character_lowercase_hex_string_test() {
  let hash = ddl_hash.hash_statement(parse("CREATE STREAM s (a INT);"))

  assert string.length(hash) == 64
  assert string.to_graphemes(hash)
    |> list.all(fn(c) { string.contains("0123456789abcdef", c) })
}
//-----------------------------------------------------------------------------
