import asyncio/messages.{type WriterMessage, StopWriter, WriteOutput}
import gleam/otp/actor

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
