import { describe, expect, test } from "bun:test";
import { quoteIdentifier } from "../src/identifier.ts";

// Ports domain/shared/test/lang/expr_codegen_test.gleam's own
// quote_identifier coverage — same predicate, same reserved-word list.

describe("quoteIdentifier", () => {
  test("leaves a safe lower-case identifier unquoted", () => {
    expect(quoteIdentifier("sensor_reading")).toBe("sensor_reading");
    expect(quoteIdentifier("_struo_hlc")).toBe("_struo_hlc");
  });

  test("quotes an identifier with uppercase characters", () => {
    expect(quoteIdentifier("MixedCase")).toBe('"MixedCase"');
  });

  test("quotes an identifier starting with a digit", () => {
    expect(quoteIdentifier("1abc")).toBe('"1abc"');
  });

  test("quotes a PostgreSQL reserved word even though its content is safe", () => {
    expect(quoteIdentifier("select")).toBe('"select"');
    expect(quoteIdentifier("table")).toBe('"table"');
  });

  test("doubles an embedded double quote", () => {
    expect(quoteIdentifier('a"b')).toBe('"a""b"');
  });

  test("does not quote an ordinary keyword-adjacent but non-reserved word", () => {
    // "stream" itself isn't a PostgreSQL reserved word.
    expect(quoteIdentifier("stream")).toBe("stream");
  });
});
