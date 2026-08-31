import gleam/order
import gleam/string
import hlc/base62.{
  InsufficientWidth, InvalidCharacter, InvalidWidth, NegativeValue,
}

//-----------------------------------------------------------------------------

pub fn round_trips_zero_test() {
  let assert Ok(encoded) = base62.encode(0, 3)
  assert encoded == "000"

  let assert Ok(decoded) = base62.decode(encoded)
  assert decoded == 0
}

pub fn round_trips_a_mid_range_value_test() {
  let assert Ok(encoded) = base62.encode(12_345, 5)

  let assert Ok(decoded) = base62.decode(encoded)
  assert decoded == 12_345
}

pub fn round_trips_the_maximum_value_for_a_width_test() {
  // 62^3 - 1: the largest value that fits in 3 base-62 characters.
  let assert Ok(encoded) = base62.encode(238_327, 3)
  assert encoded == "zzz"

  let assert Ok(decoded) = base62.decode(encoded)
  assert decoded == 238_327
}

pub fn encode_rejects_a_value_too_large_for_the_width_test() {
  // 62^3: one past the largest value that fits in 3 characters.
  let assert Error(InsufficientWidth(needed: needed, provided: 3)) =
    base62.encode(238_328, 3)
  assert needed == 4
}

pub fn encode_rejects_a_negative_value_test() {
  let assert Error(NegativeValue(value: -1)) = base62.encode(-1, 3)
}

pub fn decode_rejects_a_character_outside_the_alphabet_test() {
  let assert Error(InvalidCharacter(char: "-", index: 2)) =
    base62.decode("00-00")
}

pub fn round_trips_the_maximum_supported_width_test() {
  // 16 is the widest width the capacity lookup table covers.
  let assert Ok(encoded) = base62.encode(12_345, 16)
  assert string.length(encoded) == 16

  let assert Ok(decoded) = base62.decode(encoded)
  assert decoded == 12_345
}

pub fn encode_rejects_a_width_below_one_test() {
  let assert Error(InvalidWidth(width: 0)) = base62.encode(0, 0)
}

pub fn encode_rejects_a_width_above_the_maximum_supported_test() {
  let assert Error(InvalidWidth(width: 17)) = base62.encode(0, 17)
}

pub fn encoding_preserves_numeric_order_as_string_order_test() {
  let assert Ok(smaller) = base62.encode(5, 3)
  let assert Ok(larger) = base62.encode(1000, 3)

  assert string.compare(smaller, larger) == order.Lt
}
//-----------------------------------------------------------------------------
