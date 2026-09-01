import asyncio/messages.{type DispatcherMessage, AddJob, StopDispatcher}
import gleam/erlang/process
import gleam/io
import gleam/otp/actor
import gleam/string
import in.{type Error}

//-----------------------------------------------------------------------------

/// Reads from read_input line by line in a forever loop. Each line is queued to the given dispatcher.
pub fn read_loop(
  dispatcher: process.Subject(DispatcherMessage),
  read_input: fn() -> Result(String, Error),
) -> Nil {
  case read_input() {
    Ok(input) -> {
      case is_quit_sentinel(input) {
        True -> {
          // This send is fire-and-forget: `read_loop` returning doesn't
          // itself wait for the dispatcher to actually finish draining and
          // stopping. The caller that started the dispatcher owns that
          // wait — see `dispatcher.stop`, called from `streams.gleam`'s
          // `main` after `read_loop` returns, before it stops the writer.
          actor.send(dispatcher, StopDispatcher)
          io.println("Exiting ...")
        }
        False -> {
          actor.send(dispatcher, AddJob(input))
          read_loop(dispatcher, read_input)
        }
      }
    }
    Error(_) -> {
      io.println_error("Error reading stdin or EOF reached.")
    }
  }
}

/// A line is the quit sentinel if it's `~quit` or its abbreviation `~q`,
/// once any trailing line-ending whitespace (`\n`, `\r\n`, or a missing
/// one entirely on the final line of input with no trailing newline) is
/// stripped — `in.read_line`'s underlying `file:read_line/1` includes
/// whatever trailing newline was actually present, or none at all for the
/// last line before EOF, so comparing the raw line directly would miss
/// exactly that last-line-with-no-newline case.
fn is_quit_sentinel(input: String) -> Bool {
  case string.trim_end(input) {
    "~quit" | "~q" -> True
    _ -> False
  }
}
//-----------------------------------------------------------------------------
