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

/// `max_worker_count = 1` is what makes this deterministic: with only one
/// worker ever allowed to exist, `b` and `c` can only complete if the
/// dispatcher successfully routes work to the one worker it already has
/// once it's idle (whether by dispatching to it directly, or via
/// `WorkerReady`/the pending queue) rather than getting stuck trying —
/// and failing — to spawn a worker it isn't allowed to. If idle-worker
/// reuse were broken, this test would hang until `receive_n` times out.
pub fn an_idle_worker_is_reused_for_later_work_test() {
  let writer_subject = process.new_subject()

  let dispatcher_subject =
    dispatcher.start(writer_subject, fn(input) { input <> "-done" }, 1, 1)

  process.send(dispatcher_subject, AddJob("a"))
  let assert Ok(WriteOutput("a-done")) = process.receive(writer_subject, 1000)

  // Give the dispatcher a moment to process the worker's own `WorkerReady`
  // and record it as idle before submitting more work.
  process.sleep(50)

  process.send(dispatcher_subject, AddJob("b"))
  process.send(dispatcher_subject, AddJob("c"))

  let outputs =
    support.receive_n(writer_subject, 2, 1000)
    |> list.map(fn(message) {
      let assert WriteOutput(text) = message
      text
    })
    |> list.sort(string.compare)

  assert outputs == ["b-done", "c-done"]
}

/// `max_idle_worker_count = 0` means the sole worker is told to stop the
/// instant it goes idle; `max_worker_count = 1` means `b` can only ever
/// complete if that stop actually happened and `worker_count` dropped
/// back down — otherwise the dispatcher still believes it's at capacity
/// and queues `b` forever, since nothing else would ever prompt it to
/// look at the queue again. If the idle-cap stop were broken (e.g. never
/// actually decremented `worker_count`), this test would hang.
pub fn an_idle_worker_beyond_the_cap_is_stopped_freeing_capacity_test() {
  let writer_subject = process.new_subject()

  let dispatcher_subject =
    dispatcher.start(writer_subject, fn(input) { input <> "-done" }, 0, 1)

  process.send(dispatcher_subject, AddJob("a"))
  let assert Ok(WriteOutput("a-done")) = process.receive(writer_subject, 1000)

  // Give the dispatcher a moment to process WorkerReady, tell the
  // now-idle worker to stop (it's beyond the idle cap), and record the
  // resulting drop in worker_count.
  process.sleep(50)

  process.send(dispatcher_subject, AddJob("b"))

  let assert Ok(WriteOutput("b-done")) = process.receive(writer_subject, 1000)
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
