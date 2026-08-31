import asyncio/dispatcher
import asyncio/messages.{AddJob, StopDispatcher, WriteOutput}
import gleam/erlang/process
import gleam/list
import gleam/string
import support

//-----------------------------------------------------------------------------

pub fn add_job_is_dispatched_to_a_worker_test() {
  let writer_subject = process.new_subject()

  let dispatcher_subject =
    dispatcher.start(writer_subject, fn(input) { "handled:" <> input }, 1, 2)

  process.send(dispatcher_subject, AddJob("x"))

  let assert Ok(WriteOutput(output)) = process.receive(writer_subject, 1000)
  assert output == "handled:x"
}

pub fn concurrent_jobs_are_all_processed_test() {
  let writer_subject = process.new_subject()

  let dispatcher_subject =
    dispatcher.start(writer_subject, fn(input) { input <> "!" }, 1, 4)

  process.send(dispatcher_subject, AddJob("a"))
  process.send(dispatcher_subject, AddJob("b"))
  process.send(dispatcher_subject, AddJob("c"))

  let outputs =
    support.receive_n(writer_subject, 3, 1000)
    |> list.map(fn(message) {
      let assert WriteOutput(text) = message
      text
    })
    |> list.sort(string.compare)

  assert outputs == ["a!", "b!", "c!"]
}

pub fn jobs_beyond_max_worker_count_are_queued_and_processed_in_order_test() {
  let writer_subject = process.new_subject()

  // With max_worker_count = 1, only one job can be worked on at a time, so
  // the rest must queue up in the dispatcher and be handled FIFO.
  let dispatcher_subject =
    dispatcher.start(
      writer_subject,
      fn(input) {
        process.sleep(100)
        input <> "-done"
      },
      0,
      1,
    )

  process.send(dispatcher_subject, AddJob("a"))
  process.send(dispatcher_subject, AddJob("b"))
  process.send(dispatcher_subject, AddJob("c"))

  let outputs =
    support.receive_n(writer_subject, 3, 2000)
    |> list.map(fn(message) {
      let assert WriteOutput(text) = message
      text
    })

  assert outputs == ["a-done", "b-done", "c-done"]
}

pub fn stop_dispatcher_terminates_the_actor_test() {
  let writer_subject = process.new_subject()

  let dispatcher_subject =
    dispatcher.start(writer_subject, fn(input) { input }, 1, 2)
  let assert Ok(pid) = process.subject_owner(dispatcher_subject)

  process.send(dispatcher_subject, StopDispatcher)

  support.wait_until_stopped(pid, 1000)
}
//-----------------------------------------------------------------------------
