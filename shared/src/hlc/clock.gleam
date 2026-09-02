import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import hlc/clock_state.{type ClockState, type HlcError, type HlcParts}

//-----------------------------------------------------------------------------
// The actor wrapper around `hlc/clock_state`'s pure `(time, counter,
// node_id)` state machine: owns one `ClockState` as its own actor state
// and, on every message, calls straight through to `clock_state.next`/
// `next_parts`/`merge` to get the next state and reply value. Everything
// actually algorithmic — the rollover rule, the merge rule, the base-62
// encoding — lives in `clock_state.gleam`; this module's own job is
// purely "run that state machine as a process, one call at a time." See
// `clock_state.gleam`'s own header comment for why the split exists.
//-----------------------------------------------------------------------------

/// Messages sent to a clock actor.
pub opaque type ClockMessage {
  /// Requests the next HLC value for a local event.
  Next(reply_to: Subject(String))
  /// Requests the next HLC value for a local event, decomposed into its
  /// three encoded fields — see `HlcParts`.
  NextParts(reply_to: Subject(HlcParts))
  /// Merges in an HLC value received from another node.
  Merge(remote: String, reply_to: Subject(Result(String, HlcError)))
  /// Sent to end the process.
  StopClock
}

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
  use initial_state <- result.try(clock_state.new(node_id, now))

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

/// Returns the next HLC value for a local event on this node, the same
/// as `next`, but already decomposed into its three encoded fields — see
/// `HlcParts`.
pub fn next_parts(clock: Subject(ClockMessage)) -> HlcParts {
  actor.call(clock, waiting: call_timeout_ms, sending: NextParts)
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

/// Stops the clock actor, blocking until it has actually finished exiting
/// (or up to `call_timeout_ms`, whichever comes first).
pub fn stop(clock: Subject(ClockMessage)) -> Nil {
  case process.subject_owner(clock) {
    Ok(pid) -> {
      let monitor = process.monitor(pid)
      actor.send(clock, StopClock)
      let assert Ok(_down) =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
        |> process.selector_receive(call_timeout_ms)
      Nil
    }
    // No owning process to wait on (subject already invalid) — nothing to do.
    Error(Nil) -> Nil
  }
}

//-----------------------------------------------------------------------------

fn handle_message(
  state: ClockState,
  msg: ClockMessage,
) -> actor.Next(ClockState, ClockMessage) {
  case msg {
    Next(reply_to) -> {
      let #(new_state, value) = clock_state.next(state)
      actor.send(reply_to, value)
      actor.continue(new_state)
    }

    NextParts(reply_to) -> {
      let #(new_state, parts) = clock_state.next_parts(state)
      actor.send(reply_to, parts)
      actor.continue(new_state)
    }

    Merge(remote, reply_to) -> {
      case clock_state.merge(state, remote) {
        Ok(#(new_state, value)) -> {
          actor.send(reply_to, Ok(value))
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
