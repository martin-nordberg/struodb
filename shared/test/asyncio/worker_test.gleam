import asyncio/messages.{DoWork, StopWorker, WorkerReady, WriteOutput}
import asyncio/worker
import gleam/erlang/process
import support

//-----------------------------------------------------------------------------

pub fn do_work_reports_output_then_readiness_test() {
  let dispatcher_subject = process.new_subject()
  let writer_subject = process.new_subject()

  let worker_subject =
    worker.start(dispatcher_subject, writer_subject, fn(input) {
      "handled:" <> input
    })

  process.send(worker_subject, DoWork("hello"))

  let assert Ok(WriteOutput(output)) = process.receive(writer_subject, 1000)
  assert output == "handled:hello"

  let assert Ok(WorkerReady(ready_subject)) =
    process.receive(dispatcher_subject, 1000)
  assert ready_subject == worker_subject
}

pub fn worker_can_be_reused_for_further_work_test() {
  let dispatcher_subject = process.new_subject()
  let writer_subject = process.new_subject()

  let worker_subject =
    worker.start(dispatcher_subject, writer_subject, fn(input) {
      "handled:" <> input
    })

  process.send(worker_subject, DoWork("one"))
  let assert Ok(_) = process.receive(writer_subject, 1000)
  let assert Ok(_) = process.receive(dispatcher_subject, 1000)

  process.send(worker_subject, DoWork("two"))
  let assert Ok(WriteOutput(second_output)) =
    process.receive(writer_subject, 1000)
  assert second_output == "handled:two"
}

pub fn stop_worker_terminates_the_actor_test() {
  let dispatcher_subject = process.new_subject()
  let writer_subject = process.new_subject()

  let worker_subject =
    worker.start(dispatcher_subject, writer_subject, fn(input) { input })
  let assert Ok(pid) = process.subject_owner(worker_subject)

  process.send(worker_subject, StopWorker)

  support.wait_until_stopped(pid, 1000)
}
//-----------------------------------------------------------------------------
