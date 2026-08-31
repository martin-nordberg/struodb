import asyncio/messages.{type DispatcherMessage, AddJob, StopDispatcher}
import gleam/erlang/process
import gleam/io
import gleam/otp/actor
import in.{type Error}

//-----------------------------------------------------------------------------

/// Reads from read_input line by line in a forever loop. Each line is queued to the given dispatcher.
pub fn read_loop(
  dispatcher: process.Subject(DispatcherMessage),
  read_input: fn() -> Result(String, Error),
) -> Nil {
  case read_input() {
    Ok(input) if input == "~quit\n" -> {
      actor.send(dispatcher, StopDispatcher)
      // TODO: wait for dispatcher to exit
      io.println("Exiting ...")
    }
    Ok(input) -> {
      actor.send(dispatcher, AddJob(input))
      read_loop(dispatcher, read_input)
    }
    Error(_) -> {
      io.println_error("Error reading stdin or EOF reached.")
    }
  }
}
//-----------------------------------------------------------------------------
