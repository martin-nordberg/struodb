import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/order
import gleam/string
import hlc/base62
import hlc/clock
import hlc/clock_state.{InvalidFormat, InvalidLength}
import support

//-----------------------------------------------------------------------------

const node_id = "aB3x9"

const fixed_now = 1_700_000_000_000

fn fixed_clock() -> fn() -> Int {
  fn() { fixed_now }
}

//-----------------------------------------------------------------------------

pub fn start_with_a_valid_node_id_succeeds_test() {
  let assert Ok(subject) = clock.start(node_id, fixed_clock())
  clock.stop(subject)
}

pub fn start_rejects_a_node_id_of_the_wrong_length_test() {
  let assert Error(InvalidLength(expected: 5, got: 3)) =
    clock.start("abc", fixed_clock())
}

pub fn start_rejects_a_node_id_with_an_invalid_character_test() {
  let assert Error(InvalidFormat(nested: base62.InvalidCharacter(
    char: "-",
    index: 2,
  ))) = clock.start("aB-x9", fixed_clock())
}

pub fn consecutive_next_calls_strictly_increase_test() {
  let assert Ok(subject) = clock.start(node_id, fixed_clock())

  let first = clock.next(subject)
  let second = clock.next(subject)

  assert string.compare(first, second) == order.Lt
  clock.stop(subject)
}

pub fn next_parts_matches_next_parts_decoded_from_its_own_encoded_value_test() {
  let assert Ok(subject) = clock.start(node_id, fixed_clock())

  let parts = clock.next_parts(subject)
  let #(time_ms, counter) = decode_for_test(parts.encoded)
  let assert Ok(decoded_node_id) = base62.decode(node_id)

  assert parts.physical_time_ms == time_ms
  assert parts.counter == counter
  assert parts.node_id == decoded_node_id
  clock.stop(subject)
}

pub fn next_parts_advances_the_same_state_next_does_test() {
  let assert Ok(subject) = clock.start(node_id, fixed_clock())

  let first = clock.next(subject)
  let second = clock.next_parts(subject)

  assert string.compare(first, second.encoded) == order.Lt
  clock.stop(subject)
}

pub fn rollover_advances_time_and_resets_counter_test() {
  let assert Ok(subject) = clock.start(node_id, fixed_clock())

  // 3_843 is the maximum 2-character base-62 counter value (62^2 - 1).
  // With a fixed `now`, every next() call after the first falls into the
  // "bump the counter" branch, so calling it 3_844 times exhausts the
  // counter and forces exactly one rollover on the final call.
  let values = list.repeat(Nil, 3844) |> list.map(fn(_) { clock.next(subject) })

  // Every value in the whole sequence is strictly increasing as a string.
  let is_increasing =
    values
    |> list.window_by_2
    |> list.all(fn(pair) {
      let #(earlier, later) = pair
      string.compare(earlier, later) == order.Lt
    })
  assert is_increasing

  let assert Ok(before_rollover) = list.last(list.take(values, 3843))
  let assert Ok(after_rollover) = list.last(values)

  let before_time = string.slice(before_rollover, 0, 8)
  let after_time = string.slice(after_rollover, 0, 8)
  let after_counter = string.slice(after_rollover, 8, 2)

  assert string.compare(before_time, after_time) == order.Lt
  assert after_counter == "00"
  clock.stop(subject)
}

pub fn merge_with_an_older_remote_value_increments_the_local_counter_test() {
  let assert Ok(subject) = clock.start(node_id, fixed_clock())

  let older_remote = encode_for_test(fixed_now - 1000, 0, "zzzzz")

  let assert Ok(merged) = clock.merge(subject, older_remote)
  let #(merged_time, merged_counter) = decode_for_test(merged)

  assert merged_time == fixed_now
  assert merged_counter == 1
  assert string.slice(merged, 10, 5) == node_id
  clock.stop(subject)
}

pub fn merge_with_a_newer_remote_value_adopts_remote_time_test() {
  let assert Ok(subject) = clock.start(node_id, fixed_clock())

  let remote_counter = 41
  let newer_remote = encode_for_test(fixed_now + 5000, remote_counter, "zzzzz")

  let assert Ok(merged) = clock.merge(subject, newer_remote)
  let #(merged_time, merged_counter) = decode_for_test(merged)

  assert merged_time == fixed_now + 5000
  assert merged_counter == remote_counter + 1
  assert string.slice(merged, 10, 5) == node_id
  clock.stop(subject)
}

pub fn merge_at_equal_times_combines_counters_with_max_test() {
  let assert Ok(subject) = clock.start(node_id, fixed_clock())

  // Three next() calls at a fixed `now` advance the counter to 3 (0 -> 1
  // -> 2 -> 3), at the same physical time as the remote value below.
  let _ = clock.next(subject)
  let _ = clock.next(subject)
  let local = clock.next(subject)
  let #(_, local_counter) = decode_for_test(local)
  assert local_counter == 3

  let remote_counter = 0
  let remote_at_same_time = encode_for_test(fixed_now, remote_counter, "zzzzz")

  let assert Ok(merged) = clock.merge(subject, remote_at_same_time)
  let #(merged_time, merged_counter) = decode_for_test(merged)

  assert merged_time == fixed_now
  assert merged_counter == int.max(local_counter, remote_counter) + 1
  clock.stop(subject)
}

pub fn merge_rolls_over_the_same_way_next_does_test() {
  let assert Ok(subject) = clock.start(node_id, fixed_clock())

  let remote_at_max_counter = encode_for_test(fixed_now, 3843, "zzzzz")

  let assert Ok(merged) = clock.merge(subject, remote_at_max_counter)
  let #(merged_time, merged_counter) = decode_for_test(merged)

  assert merged_time == fixed_now + 1
  assert merged_counter == 0
  clock.stop(subject)
}

pub fn merge_rejects_a_malformed_remote_value_and_leaves_state_unchanged_test() {
  let assert Ok(subject) = clock.start(node_id, fixed_clock())

  let assert Error(InvalidLength(expected: 15, got: 4)) =
    clock.merge(subject, "bad!")

  let first = clock.next(subject)
  let second = clock.next(subject)
  assert string.compare(first, second) == order.Lt
  clock.stop(subject)
}

pub fn stop_clock_terminates_the_actor_test() {
  let assert Ok(subject) = clock.start(node_id, fixed_clock())
  let assert Ok(pid) = process.subject_owner(subject)

  clock.stop(subject)

  support.wait_until_stopped(pid, 1000)
}

//-----------------------------------------------------------------------------

fn encode_for_test(time_ms: Int, counter: Int, id: String) -> String {
  encode_time_for_test(time_ms) <> encode_counter_for_test(counter) <> id
}

fn encode_time_for_test(time_ms: Int) -> String {
  let assert Ok(part) = base62.encode(time_ms, 8)
  part
}

fn encode_counter_for_test(counter: Int) -> String {
  let assert Ok(part) = base62.encode(counter, 2)
  part
}

/// Decodes an HLC value's time and counter fields back to integers, so
/// tests can assert on the numbers the spec is defined in terms of instead
/// of hand-computed base-62 characters.
fn decode_for_test(value: String) -> #(Int, Int) {
  let assert Ok(time_ms) = base62.decode(string.slice(value, 0, 8))
  let assert Ok(counter) = base62.decode(string.slice(value, 8, 2))
  #(time_ms, counter)
}
//-----------------------------------------------------------------------------
