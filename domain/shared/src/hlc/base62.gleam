import gleam/list
import gleam/result
import gleam/string

//-----------------------------------------------------------------------------

/// Alphabet used for base-62 encoding, in increasing digit-value order.
/// `'0'` is digit 0, `'z'` is digit 61. The order matters: because it is
/// monotonic in ASCII order (`'0'…'9' < 'A'…'Z' < 'a'…'z'`), fixed-width,
/// zero-padded encodings of this alphabet sort the same way as plain
/// strings and as integers.
const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

const base = 62

//-----------------------------------------------------------------------------

/// Reasons a base-62 value could not be encoded or decoded.
pub type Base62Error {
  /// Raised by `decode` when `char`, at grapheme `index`, falls outside
  /// the base-62 alphabet.
  InvalidCharacter(char: String, index: Int)
  /// Raised by `encode` when `width` is outside the supported `1..8`
  /// range, so there is no precomputed capacity to check `value` against.
  InvalidWidth(width: Int)
  /// Raised by `encode` when `value` is too large to fit in `provided`
  /// characters; `needed` is how many it actually requires.
  InsufficientWidth(needed: Int, provided: Int)
  /// Raised by `encode` when `value` is negative — base-62 has no digit
  /// for a sign, so negative values can never be represented.
  NegativeValue(value: Int)
}

//-----------------------------------------------------------------------------

/// Encodes `value` as exactly `width` base-62 characters, left-padded with
/// `'0'`. `width` must be between 1 and 8. Errors if `value` is negative
/// or too large to fit in `width` characters.
pub fn encode(value: Int, width: Int) -> Result(String, Base62Error) {
  use capacity <- result.try(capacity_for_width(width))

  case value < 0, value >= capacity {
    True, _ -> Error(NegativeValue(value))
    _, True ->
      Error(InsufficientWidth(needed: required_width(value), provided: width))
    False, False -> Ok(encode_loop(value, width, ""))
  }
}

/// Decodes a base-62 string, of any length, back to its integer value.
/// Errors on the first character that falls outside `0-9A-Za-z`.
pub fn decode(value: String) -> Result(Int, Base62Error) {
  decode_loop(string.to_graphemes(value), digit_values(), 0, 0)
}

//-----------------------------------------------------------------------------

fn encode_loop(value: Int, remaining_width: Int, acc: String) -> String {
  case remaining_width {
    0 -> acc
    _ -> {
      let digit = value % base
      let char = string.slice(from: alphabet, at_index: digit, length: 1)
      encode_loop(value / base, remaining_width - 1, char <> acc)
    }
  }
}

fn decode_loop(
  chars: List(String),
  values: List(#(String, Int)),
  index: Int,
  acc: Int,
) -> Result(Int, Base62Error) {
  case chars {
    [] -> Ok(acc)
    [char, ..rest] ->
      case list.key_find(values, char) {
        Ok(digit) -> decode_loop(rest, values, index + 1, acc * base + digit)
        Error(Nil) -> Error(InvalidCharacter(char: char, index: index))
      }
  }
}

/// Builds the char -> digit-value lookup for `decode`, from `alphabet`
/// itself, so the two directions can never drift out of sync.
fn digit_values() -> List(#(String, Int)) {
  alphabet
  |> string.to_graphemes
  |> list.index_map(fn(char, index) { #(char, index) })
}

/// The number of base-62 digits needed to represent `value` (at least 1,
/// so that 0 is reported as needing 1 digit). Only ever called with a
/// non-negative `value` — `encode` reports negative values separately, as
/// `NegativeValue`, before this is reached.
fn required_width(value: Int) -> Int {
  case value {
    0 -> 1
    _ -> required_width_loop(value, 0)
  }
}

fn required_width_loop(value: Int, acc: Int) -> Int {
  case value {
    0 -> acc
    _ -> required_width_loop(value / base, acc + 1)
  }
}

/// `62^width` for every width this module supports, as a literal case
/// match rather than a data structure built or traversed at runtime — a
/// `case` over integer literals like this compiles into an efficient
/// decision tree, with no list/dict construction, hashing, or per-call
/// allocation on the way. A width with no arm here is exactly what
/// `InvalidWidth` rejects, via `_`.
///
/// Capped at 8, not a larger "generous ceiling" — this module targets
/// JavaScript, where `Int` is backed by a plain JS `number`, exact only
/// up to `Number.MAX_SAFE_INTEGER` (2^53 - 1 = 9_007_199_254_740_991).
/// `62^8 = 218_340_105_584_896` is safely inside that range, but
/// `62^9 = 13_537_086_546_263_552` already isn't — both the capacity
/// constant *and* every arithmetic step in `encode_loop`/`decode_loop`/
/// `required_width_loop` on a value that large would silently lose
/// precision, not just this lookup. 8 isn't an arbitrary choice either:
/// it's exactly `hlc/clock.gleam`'s widest field (`time_width`), the
/// largest width this codebase actually needs — supporting a wider field
/// than that correctly would need a different representation (e.g.
/// `BigInt` via FFI) throughout, not a bigger table entry here.
fn capacity_for_width(width: Int) -> Result(Int, Base62Error) {
  case width {
    1 -> Ok(62)
    2 -> Ok(3844)
    3 -> Ok(238_328)
    4 -> Ok(14_776_336)
    5 -> Ok(916_132_832)
    6 -> Ok(56_800_235_584)
    7 -> Ok(3_521_614_606_208)
    8 -> Ok(218_340_105_584_896)
    _ -> Error(InvalidWidth(width))
  }
}
//-----------------------------------------------------------------------------
