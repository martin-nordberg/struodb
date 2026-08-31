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
  /// Raised by `encode` when `width` is outside the supported `1..16`
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
/// `'0'`. `width` must be between 1 and 16. Errors if `value` is negative
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
/// match rather than a data structure built or traversed at runtime — the
/// BEAM compiles a `case` over integer literals like this into an
/// efficient decision tree, with no list/dict construction, hashing, or
/// per-call allocation on the way. A width with no arm here is exactly
/// what `InvalidWidth` rejects, via `_`.
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
    9 -> Ok(13_537_086_546_263_552)
    10 -> Ok(839_299_365_868_340_224)
    11 -> Ok(52_036_560_683_837_093_888)
    12 -> Ok(3_226_266_762_397_899_821_056)
    13 -> Ok(200_028_539_268_669_788_905_472)
    14 -> Ok(12_401_769_434_657_526_912_139_264)
    15 -> Ok(768_909_704_948_766_668_552_634_368)
    16 -> Ok(47_672_401_706_823_533_450_263_330_816)
    _ -> Error(InvalidWidth(width))
  }
}
//-----------------------------------------------------------------------------
