import asyncio/messages.{type WriterMessage, StopWriter, WriteOutput}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

//-----------------------------------------------------------------------------

const call_timeout_ms = 1000

//-----------------------------------------------------------------------------

/// Initializes and starts the actor with an empty queue
pub fn start(write_output: fn(String) -> Nil) {
  let assert Ok(writer_started) =
    actor.new(Nil)
    |> actor.on_message(fn(state, msg) {
      handle_message(state, msg, write_output)
    })
    |> actor.start()

  writer_started.data
}

/// Stops the writer actor, blocking until it has actually finished exiting
/// (or up to `call_timeout_ms`, whichever comes first).
pub fn stop(writer: Subject(WriterMessage)) -> Nil {
  case process.subject_owner(writer) {
    Ok(pid) -> {
      let monitor = process.monitor(pid)
      actor.send(writer, StopWriter)
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
  state: Nil,
  message: WriterMessage,
  write_output: fn(String) -> Nil,
) -> actor.Next(Nil, WriterMessage) {
  case message {
    WriteOutput(text) -> {
      write_output(text)
      actor.continue(state)
    }
    StopWriter -> {
      actor.stop()
    }
  }
}
//-----------------------------------------------------------------------------
