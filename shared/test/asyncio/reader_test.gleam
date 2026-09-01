import asyncio/messages.{AddJob, StopDispatcher}
import asyncio/reader
import gleam/erlang/process
import gleam/list
import in

//-----------------------------------------------------------------------------
// `read_loop` takes `read_input` as a plain injected function (not stdin
// directly), so it's testable without any real I/O — same reasoning as
// `hlc/clock`'s injected `now`. `scripted_read_input` below turns a fixed
// list of canned lines into one: each call pops the next line, and once
// the list is exhausted, every further call reports `in.Eof`, standing in
// for "no more input"/an actual read error. It works by pre-loading a
// fresh Subject's own mailbox (a process can always send to and receive
// from its own subject), so the lines come back in the same order they
// went in.
//-----------------------------------------------------------------------------

fn scripted_read_input(
  lines: List(String),
) -> fn() -> Result(String, in.Error) {
  let subject = process.new_subject()
  list.each(lines, fn(line) { process.send(subject, line) })
  fn() {
    case process.receive(subject, 0) {
      Ok(line) -> Ok(line)
      Error(Nil) -> Error(in.Eof)
    }
  }
}

pub fn each_line_is_dispatched_as_a_job_in_order_test() {
  let dispatcher_subject = process.new_subject()

  reader.read_loop(dispatcher_subject, scripted_read_input(["a", "b"]))

  let assert Ok(AddJob("a")) = process.receive(dispatcher_subject, 0)
  let assert Ok(AddJob("b")) = process.receive(dispatcher_subject, 0)
  // Input exhausted (an `Error` from `read_input`, per `scripted_read_input`
  // above) ends the loop without sending anything further.
  let assert Error(Nil) = process.receive(dispatcher_subject, 0)
}

pub fn the_quit_sentinel_stops_the_dispatcher_test() {
  let dispatcher_subject = process.new_subject()

  reader.read_loop(dispatcher_subject, scripted_read_input(["~quit\n"]))

  let assert Ok(StopDispatcher) = process.receive(dispatcher_subject, 0)
}

pub fn lines_before_the_quit_sentinel_are_dispatched_first_test() {
  let dispatcher_subject = process.new_subject()

  reader.read_loop(
    dispatcher_subject,
    scripted_read_input(["a", "b", "~quit\n"]),
  )

  let assert Ok(AddJob("a")) = process.receive(dispatcher_subject, 0)
  let assert Ok(AddJob("b")) = process.receive(dispatcher_subject, 0)
  let assert Ok(StopDispatcher) = process.receive(dispatcher_subject, 0)
}

pub fn a_read_error_ends_the_loop_without_dispatching_anything_test() {
  let dispatcher_subject = process.new_subject()

  reader.read_loop(dispatcher_subject, scripted_read_input([]))

  let assert Error(Nil) = process.receive(dispatcher_subject, 0)
}

/// The formerly-fragile case (`docs/todo.md`'s old #3, now fixed): the
/// last line of piped input with no trailing newline before EOF must still
/// be recognized as the quit sentinel, not dispatched as an ordinary job.
pub fn quit_without_a_trailing_newline_is_recognized_test() {
  let dispatcher_subject = process.new_subject()

  reader.read_loop(dispatcher_subject, scripted_read_input(["~quit"]))

  let assert Ok(StopDispatcher) = process.receive(dispatcher_subject, 0)
}

/// A Windows-style line ending is stripped the same as a bare `\n`.
pub fn quit_with_a_carriage_return_line_ending_is_recognized_test() {
  let dispatcher_subject = process.new_subject()

  reader.read_loop(dispatcher_subject, scripted_read_input(["~quit\r\n"]))

  let assert Ok(StopDispatcher) = process.receive(dispatcher_subject, 0)
}

pub fn the_abbreviated_quit_sentinel_stops_the_dispatcher_test() {
  let dispatcher_subject = process.new_subject()

  reader.read_loop(dispatcher_subject, scripted_read_input(["~q\n"]))

  let assert Ok(StopDispatcher) = process.receive(dispatcher_subject, 0)
}

pub fn the_abbreviated_quit_sentinel_without_a_trailing_newline_is_recognized_test() {
  let dispatcher_subject = process.new_subject()

  reader.read_loop(dispatcher_subject, scripted_read_input(["~q"]))

  let assert Ok(StopDispatcher) = process.receive(dispatcher_subject, 0)
}

/// A line that merely starts with the sentinel isn't a match — the
/// comparison is exact (after trimming trailing whitespace), not a prefix
/// check.
pub fn a_line_that_only_starts_with_the_sentinel_is_not_recognized_test() {
  let dispatcher_subject = process.new_subject()

  reader.read_loop(dispatcher_subject, scripted_read_input(["~quitter\n"]))

  let assert Ok(AddJob("~quitter\n")) = process.receive(dispatcher_subject, 0)
}
//-----------------------------------------------------------------------------
