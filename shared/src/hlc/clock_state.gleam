import gleam/int
import gleam/result
import gleam/string
import hlc/base62

//-----------------------------------------------------------------------------
// The pure `(time, counter, node_id)` state machine behind a hybrid
// logical clock — see docs/hlc/spec.md for the algorithm. Deliberately
// free of `gleam/erlang`/`gleam/otp`: `clock.gleam` is the actor wrapper
// around this module, holding one `ClockState` as its own actor state
// and calling straight through to `new`/`next`/`next_parts`/`merge`
// below on every message — this module has no notion of an actor, a
// `Subject`, or message-passing at all. Splitting it out this way is
// what lets `HlcParts` (and everything else here) build for a target
// `gleam/otp`/`gleam/erlang` don't support (e.g. JavaScript) without
// dragging the actor machinery along.
//-----------------------------------------------------------------------------

/// Reasons an HLC value couldn't be validated or parsed. See
/// `docs/hlc/spec.md` for the full 15-character base-62 encoding and
/// algorithm this guards.
pub type HlcError {
  /// A whole string — a node id, or a full 15-character HLC value — wasn't
  /// the length it needed to be. Checked before any base-62 decoding is
  /// even attempted.
  InvalidLength(expected: Int, got: Int)
  /// A string was the length it needed to be, but one of its base-62
  /// fields failed to decode; see `nested` for why.
  InvalidFormat(nested: base62.Base62Error)
}

/// One `next()` draw, already decomposed into its three encoded fields —
/// for a caller (e.g. streams/lang/dml_codegen.gleam) that needs the
/// physical time/counter/node id individually rather than re-parsing
/// `encoded` itself. `node_id` is decoded to its integer value (base-62
/// digits, per docs/hlc/spec.md), even though the field is otherwise
/// opaque/caller-assigned — decoding it is a well-defined, reversible
/// operation regardless of what the digits are taken to mean.
pub type HlcParts {
  HlcParts(encoded: String, physical_time_ms: Int, counter: Int, node_id: Int)
}

/// A clock's own `(physical_time_ms, counter, node_id)` state, plus the
/// `now` function it advances against — opaque, since every field is
/// only ever read or updated through the functions below, the same
/// contract `clock.gleam`'s actor state used to enforce by being a
/// private type local to that module.
pub opaque type ClockState {
  ClockState(
    physical_time_ms: Int,
    counter: Int,
    node_id: String,
    now: fn() -> Int,
  )
}

//-----------------------------------------------------------------------------

const time_width = 8

const counter_width = 2

const node_id_width = 5

/// 62^counter_width - 1
const max_counter = 3843

//-----------------------------------------------------------------------------

/// Builds a fresh clock state for `node_id`, which must be exactly 5
/// base-62 characters. `now` returns the current wall-clock time in
/// milliseconds since the Unix epoch — injected (rather than called
/// directly) so that tests can supply a fixed or controlled clock.
pub fn new(node_id: String, now: fn() -> Int) -> Result(ClockState, HlcError) {
  use _ <- result.try(validate_node_id(node_id))
  Ok(ClockState(physical_time_ms: now(), counter: 0, node_id:, now:))
}

/// Advances `state` for a local event (spec: `next()`), returning the
/// updated state alongside the encoded HLC value.
pub fn next(state: ClockState) -> #(ClockState, String) {
  let new_state = advance(state)
  #(new_state, encode_value(new_state))
}

/// Advances `state` for a local event, the same as `next`, but returns
/// the value already decomposed into its three encoded fields — see
/// `HlcParts`. Avoids a redundant encode-then-decode round trip: the new
/// state already has `physical_time_ms`/`counter`/`node_id` in hand right
/// before encoding them for `next`.
pub fn next_parts(state: ClockState) -> #(ClockState, HlcParts) {
  let new_state = advance(state)
  // Safe: `new_state.node_id` was already validated as well-formed
  // base-62 once, in `new()` — `validate_node_id` — and never changes
  // after that.
  let assert Ok(node_id) = base62.decode(new_state.node_id)
  #(
    new_state,
    HlcParts(
      encoded: encode_value(new_state),
      physical_time_ms: new_state.physical_time_ms,
      counter: new_state.counter,
      node_id:,
    ),
  )
}

/// Merges in an HLC value received from another node, advancing `state`
/// if needed (spec: `merge()`). Returns an error, leaving `state`
/// unchanged, if `remote` is not a well-formed 15-character HLC value.
pub fn merge(
  state: ClockState,
  remote: String,
) -> Result(#(ClockState, String), HlcError) {
  case decode_value(remote) {
    Ok(#(remote_ms, remote_counter, _remote_node_id)) -> {
      let new_state = merge_in(state, remote_ms, remote_counter)
      Ok(#(new_state, encode_value(new_state)))
    }
    Error(err) -> Error(err)
  }
}

//-----------------------------------------------------------------------------

/// Applies the rollover rule: if `counter` overflows the field's capacity,
/// advance time by 1ms and reset the counter instead. Always terminates in
/// a single step, since a freshly-reset counter of 0 can never itself need
/// to roll over.
fn bump(time_ms: Int, counter: Int) -> #(Int, Int) {
  case counter > max_counter {
    True -> #(time_ms + 1, 0)
    False -> #(time_ms, counter)
  }
}

fn advance(state: ClockState) -> ClockState {
  let wall_clock_now = state.now()

  let #(new_time, new_counter) = case wall_clock_now > state.physical_time_ms {
    True -> #(wall_clock_now, 0)
    False -> bump(state.physical_time_ms, state.counter + 1)
  }

  ClockState(..state, physical_time_ms: new_time, counter: new_counter)
}

/// The remote node's own id plays no part in the result — the merged
/// clock always keeps this node's `node_id`.
fn merge_in(
  state: ClockState,
  remote_ms: Int,
  remote_counter: Int,
) -> ClockState {
  let wall_clock_now = state.now()
  let new_time =
    int.max(state.physical_time_ms, int.max(remote_ms, wall_clock_now))

  let tentative_counter = case
    new_time == state.physical_time_ms,
    new_time == remote_ms
  {
    True, True -> int.max(state.counter, remote_counter) + 1
    True, False -> state.counter + 1
    False, True -> remote_counter + 1
    False, False -> 0
  }

  let #(final_time, final_counter) = bump(new_time, tentative_counter)
  ClockState(..state, physical_time_ms: final_time, counter: final_counter)
}

//-----------------------------------------------------------------------------

fn validate_node_id(node_id: String) -> Result(Nil, HlcError) {
  case string.length(node_id) {
    n if n == node_id_width -> decode_field(node_id) |> result.replace(Nil)
    other -> Error(InvalidLength(expected: node_id_width, got: other))
  }
}

/// Decodes one already-length-checked base-62 field, wrapping any failure
/// as `InvalidFormat` so callers only ever have to handle `HlcError`.
fn decode_field(part: String) -> Result(Int, HlcError) {
  base62.decode(part) |> result.map_error(InvalidFormat)
}

fn encode_value(state: ClockState) -> String {
  // Safe: `physical_time_ms`/`counter` are maintained entirely within this
  // module, `bump` guarantees `counter` never exceeds its field's
  // capacity, and the time field's ~6,900-year headroom makes overflow
  // there unreachable.
  let assert Ok(time_part) = base62.encode(state.physical_time_ms, time_width)
  let assert Ok(counter_part) = base62.encode(state.counter, counter_width)
  time_part <> counter_part <> state.node_id
}

fn decode_value(value: String) -> Result(#(Int, Int, String), HlcError) {
  case string.length(value) {
    15 -> {
      let time_part = string.slice(from: value, at_index: 0, length: time_width)
      let counter_part =
        string.slice(from: value, at_index: time_width, length: counter_width)
      let node_id_part =
        string.slice(
          from: value,
          at_index: time_width + counter_width,
          length: node_id_width,
        )

      use time_ms <- result.try(decode_field(time_part))
      use counter <- result.try(decode_field(counter_part))
      // Validates that node_id_part is well-formed base-62 without needing
      // its decoded value — the remote node's id is otherwise unused.
      use _ <- result.try(decode_field(node_id_part))
      Ok(#(time_ms, counter, node_id_part))
    }
    other -> Error(InvalidLength(expected: 15, got: other))
  }
}
//-----------------------------------------------------------------------------
