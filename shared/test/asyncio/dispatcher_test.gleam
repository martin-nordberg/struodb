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
// Graceful shutdown: Ready -> Draining -> Stopping -> Stopped
//-----------------------------------------------------------------------------

/// `dispatcher.stop` — as opposed to just sending `StopDispatcher`, above —
/// is the public API real callers use, and blocks until the actor has
/// actually exited.
pub fn stop_function_blocks_until_the_actor_has_exited_test() {
  let writer_subject = process.new_subject()

  let dispatcher_subject =
    dispatcher.start(writer_subject, fn(input) { input }, 1, 2)
  let assert Ok(pid) = process.subject_owner(dispatcher_subject)

  dispatcher.stop(dispatcher_subject)

  assert !process.is_alive(pid)
}

/// `max_worker_count = 1` with two jobs already queued ahead of the stop
/// means both must finish — through the ordinary drain-through-workers
/// path — before `dispatcher.stop` can return; if draining stopped
/// prematurely or a queued job were dropped, one of the two outputs
/// would never arrive and `stop` would hang until the test's own timeout.
pub fn jobs_queued_before_stop_are_all_processed_before_it_stops_test() {
  let writer_subject = process.new_subject()

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

  dispatcher.stop(dispatcher_subject)

  let outputs =
    support.receive_n(writer_subject, 3, 500)
    |> list.map(fn(message) {
      let assert WriteOutput(text) = message
      text
    })
  assert outputs == ["a-done", "b-done", "c-done"]
}

/// A job submitted after `StopDispatcher` but while a still-pending job is
/// still draining must be rejected, not queued behind it — `"c"` here
/// never appears among the outputs even though the dispatcher is still
/// very much alive and processing (`"b"`) when it arrives.
pub fn a_job_added_while_draining_is_rejected_test() {
  let writer_subject = process.new_subject()

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

  // "a" starts immediately on the sole worker; "b" queues behind it since
  // max_worker_count = 1.
  process.send(dispatcher_subject, AddJob("a"))
  process.send(dispatcher_subject, AddJob("b"))

  // Still Draining at this point ("b" hasn't drained yet), so "c" is
  // rejected rather than queued.
  process.send(dispatcher_subject, StopDispatcher)
  process.send(dispatcher_subject, AddJob("c"))

  let outputs =
    support.receive_n(writer_subject, 2, 2000)
    |> list.map(fn(message) {
      let assert WriteOutput(text) = message
      text
    })
  assert outputs == ["a-done", "b-done"]

  // No third output ever arrives for the rejected "c".
  let assert Error(Nil) = process.receive(writer_subject, 200)
}

/// A `StopDispatcher` received while already draining must be a harmless
/// no-op, not a crash or a reset back to some earlier state — the
/// in-flight drain still runs to completion either way.
pub fn a_second_stop_dispatcher_while_draining_is_a_no_op_test() {
  let writer_subject = process.new_subject()

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
  process.send(dispatcher_subject, StopDispatcher)
  process.send(dispatcher_subject, StopDispatcher)

  let outputs =
    support.receive_n(writer_subject, 2, 2000)
    |> list.map(fn(message) {
      let assert WriteOutput(text) = message
      text
    })
  assert outputs == ["a-done", "b-done"]
}
//-----------------------------------------------------------------------------
