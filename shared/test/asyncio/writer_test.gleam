import asyncio/messages.{StopWriter, WriteOutput}
import asyncio/writer
import gleam/erlang/process
import gleam/io
import support

//-----------------------------------------------------------------------------

pub fn write_output_keeps_the_actor_alive_test() {
  let check_output = fn(output: String) {
    assert output == "hello"
  }

  let writer_subject = writer.start(check_output)
  let assert Ok(pid) = process.subject_owner(writer_subject)
  let monitor = process.monitor(pid)

  process.send(writer_subject, WriteOutput("hello"))

  // No Down message should arrive: the actor handled the message and is
  // still running.
  let assert Error(Nil) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(200)

  process.demonitor_process(monitor)
}

pub fn stop_writer_terminates_the_actor_test() {
  let writer_subject = writer.start(io.println)
  let assert Ok(pid) = process.subject_owner(writer_subject)

  process.send(writer_subject, StopWriter)

  support.wait_until_stopped(pid, 1000)
}

/// `writer.stop` (as opposed to just sending `StopWriter`, above) is the
/// public API real callers use, and blocks until the actor has actually
/// exited — asserting the process is already dead the moment `stop`
/// returns, not just "eventually", is the whole point of that blocking.
pub fn stop_function_blocks_until_the_actor_has_exited_test() {
  let writer_subject = writer.start(io.println)
  let assert Ok(pid) = process.subject_owner(writer_subject)

  writer.stop(writer_subject)

  assert !process.is_alive(pid)
}
//-----------------------------------------------------------------------------
