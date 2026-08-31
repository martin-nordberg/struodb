import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleam/result
import gleam/string
import hlc/base62

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

//-----------------------------------------------------------------------------

/// Messages sent to a clock actor.
pub opaque type ClockMessage {
  /// Requests the next HLC value for a local event.
  Next(reply_to: Subject(String))
  /// Merges in an HLC value received from another node.
  Merge(remote: String, reply_to: Subject(Result(String, HlcError)))
  /// Sent to end the process.
  StopClock
}

//-----------------------------------------------------------------------------

const time_width = 8

const counter_width = 2

const node_id_width = 5

/// 62^counter_width - 1
const max_counter = 3843

const call_timeout_ms = 1000

//-----------------------------------------------------------------------------

/// Starts a new clock actor for `node_id`, which must be exactly 5 base-62
/// characters. `now` returns the current wall-clock time in milliseconds
/// since the Unix epoch — injected (rather than called directly) so that
/// tests can supply a fixed or controlled clock.
pub fn start(
  node_id: String,
  now: fn() -> Int,
) -> Result(Subject(ClockMessage), HlcError) {
  use _ <- result.try(validate_node_id(node_id))

  let initial_state =
    ClockState(physical_time_ms: now(), counter: 0, node_id: node_id, now: now)

  let assert Ok(clock_started) =
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.start()

  Ok(clock_started.data)
}

/// Returns the next HLC value for a local event on this node.
pub fn next(clock: Subject(ClockMessage)) -> String {
  actor.call(clock, waiting: call_timeout_ms, sending: Next)
}

/// Merges in an HLC value received from another node, advancing this
/// node's clock if needed. Returns an error, leaving this node's clock
/// unchanged if `remote` is not a well-formed 15-character HLC value.
pub fn merge(
  clock: Subject(ClockMessage),
  remote: String,
) -> Result(String, HlcError) {
  actor.call(clock, waiting: call_timeout_ms, sending: fn(reply_to) {
    Merge(remote, reply_to)
  })
}

/// Stops the clock actor.
pub fn stop(clock: Subject(ClockMessage)) -> Nil {
  actor.send(clock, StopClock)
}

//-----------------------------------------------------------------------------

fn handle_message(
  state: ClockState,
  msg: ClockMessage,
) -> actor.Next(ClockState, ClockMessage) {
  case msg {
    Next(reply_to) -> {
      let new_state = advance(state)
      actor.send(reply_to, encode_value(new_state))
      actor.continue(new_state)
    }

    Merge(remote, reply_to) -> {
      case decode_value(remote) {
        Ok(#(remote_ms, remote_counter, _remote_node_id)) -> {
          let new_state = merge_in(state, remote_ms, remote_counter)
          actor.send(reply_to, Ok(encode_value(new_state)))
          actor.continue(new_state)
        }
        Error(err) -> {
          actor.send(reply_to, Error(err))
          actor.continue(state)
        }
      }
    }

    StopClock -> actor.stop()
  }
}

//-----------------------------------------------------------------------------

/// Internal state for a clock actor.
type ClockState {
  ClockState(
    physical_time_ms: Int,
    counter: Int,
    node_id: String,
    now: fn() -> Int,
  )
}

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

/// Advances the clock for a local event (spec: `next()`).
fn advance(state: ClockState) -> ClockState {
  let wall_clock_now = state.now()

  let #(new_time, new_counter) = case wall_clock_now > state.physical_time_ms {
    True -> #(wall_clock_now, 0)
    False -> bump(state.physical_time_ms, state.counter + 1)
  }

  ClockState(..state, physical_time_ms: new_time, counter: new_counter)
}

/// Advances the clock after receiving `remote_ms`/`remote_counter` from
/// another node (spec: `merge()`). The remote node's own id plays no part
/// in the result — the merged clock always keeps this node's `node_id`.
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
