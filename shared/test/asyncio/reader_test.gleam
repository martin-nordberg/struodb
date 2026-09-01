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

/// Documents a known gap (`docs/todo.md` #3), not a requirement: the quit
/// check is an exact match against `"~quit\n"`, so `"~quit"` with no
/// trailing newline — e.g. the last line of piped input with no final
/// newline — is dispatched as an ordinary job instead of stopping the
/// dispatcher. If that's ever fixed, this test's expectation flips along
/// with it.
pub fn quit_without_a_trailing_newline_is_not_recognized_test() {
  let dispatcher_subject = process.new_subject()

  reader.read_loop(dispatcher_subject, scripted_read_input(["~quit"]))

  let assert Ok(AddJob("~quit")) = process.receive(dispatcher_subject, 0)
}
//-----------------------------------------------------------------------------
