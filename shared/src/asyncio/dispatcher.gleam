import asyncio/messages.{
  type DispatcherMessage, type WorkerMessage, type WriterMessage, AddJob, DoWork,
  StopDispatcher, StopWorker, WorkerReady,
}
import asyncio/worker
import birch as log
import gleam/deque.{type Deque}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string

//-----------------------------------------------------------------------------

/// Initializes and starts the dispatcher with an empty queue.
pub fn start(
  writer: Subject(WriterMessage),
  handle_input: fn(String) -> String,
  max_idle_worker_count: Int,
  max_worker_count: Int,
) {
  let assert Ok(dispatcher_started) =
    actor.new_with_initialiser(1000, fn(subject) {
      actor.initialised(initial_state(subject))
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(fn(state, msg) {
      handle_message(
        state,
        msg,
        writer,
        handle_input,
        max_idle_worker_count,
        max_worker_count,
      )
    })
    |> actor.start()

  dispatcher_started.data
}

/// Stops the dispatcher gracefully and blocks until it has actually
/// finished exiting. "Gracefully" means: jobs already queued or in flight
/// are allowed to run to completion, no new `AddJob` is accepted from the
/// moment this is called, and each worker is told to stop only once it's
/// idle — see `DispatcherStatus` below for the full
/// `Ready -> Draining -> Stopping -> Stopped` sequence this drives the
/// dispatcher through. There's no bound on how long draining a large
/// backlog of slow jobs might take, so — unlike `writer.stop`, which waits
/// against a short fixed timeout — this waits indefinitely.
pub fn stop(dispatcher: Subject(DispatcherMessage)) -> Nil {
  case process.subject_owner(dispatcher) {
    Ok(pid) -> {
      let monitor = process.monitor(pid)
      actor.send(dispatcher, StopDispatcher)
      let _down =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
        |> process.selector_receive_forever()
      Nil
    }
    // No owning process to wait on (subject already invalid) — nothing to do.
    Error(Nil) -> Nil
  }
}

//-----------------------------------------------------------------------------

/// The dispatcher's own lifecycle, independent of how many jobs or workers
/// it happens to have at any given moment:
///
/// - `Ready` — normal operation: `AddJob` queues or dispatches work as
///   usual.
/// - `Draining` — entered on `StopDispatcher`. New `AddJob`s are rejected
///   (logged and dropped — there's no reply channel to refuse them
///   through), but whatever was already queued keeps draining through
///   workers exactly as it would in `Ready`.
/// - `Stopping` — entered the instant the queue empties. Every currently
///   idle worker is told to stop right away; any worker still mid-job gets
///   `StopWorker` the moment it next reports `WorkerReady`, instead of
///   being reused or added to the idle pool.
/// - `Stopped` — entered once every worker has been told to stop
///   (`worker_count` reaches 0). Transient: the dispatcher calls
///   `actor.stop()` in the same step it enters this state.
type DispatcherStatus {
  Ready
  Draining
  Stopping
  Stopped
}

//-----------------------------------------------------------------------------

fn handle_message(
  state: DispatcherState,
  msg: DispatcherMessage,
  writer: Subject(WriterMessage),
  input_handler: fn(String) -> String,
  max_idle_worker_count: Int,
  max_worker_count: Int,
) {
  let new_state =
    case msg {
      AddJob(input) ->
        handle_add_job(state, input, writer, input_handler, max_worker_count)
      WorkerReady(worker_subject) ->
        handle_worker_ready(state, worker_subject, max_idle_worker_count)
      StopDispatcher -> handle_stop_dispatcher(state)
    }
    |> finish_stopping_if_no_workers_remain()

  log.debug_m("Dispatcher state changed.", [
    #("status", string.inspect(new_state.status)),
    #("idle", string.inspect(new_state.idle_worker_count)),
    #("total", string.inspect(new_state.worker_count)),
    #("inputs", string.inspect(new_state.pending_input_count)),
  ])

  case new_state.status {
    Stopped -> actor.stop()
    _ -> actor.continue(new_state)
  }
}

//-----------------------------------------------------------------------------

fn handle_add_job(
  state: DispatcherState,
  input: String,
  writer: Subject(WriterMessage),
  input_handler: fn(String) -> String,
  max_worker_count: Int,
) -> DispatcherState {
  case state.status {
    Ready ->
      case state.idle_workers {
        // No idle workers and worker count maxed? Queue the job.
        [] if state.worker_count >= max_worker_count -> {
          add_pending_input(state, input)
        }
        // No idle workers? Create a new worker and give them the job.
        [] -> {
          let new_worker =
            worker.start(state.self_subject, writer, input_handler)
          actor.send(new_worker, DoWork(input))
          add_active_worker(state)
        }
        // Worker available? Push the job to them immediately.
        [worker, ..] -> {
          actor.send(worker, DoWork(input))
          remove_idle_worker(state)
        }
      }
    // Draining/Stopping/Stopped: no longer accepting new work.
    _ -> {
      log.warn_m("Rejecting job: dispatcher is shutting down.", [
        #("status", string.inspect(state.status)),
        #("input", input),
      ])
      state
    }
  }
}

fn handle_worker_ready(
  state: DispatcherState,
  worker_subject: Subject(WorkerMessage),
  max_idle_worker_count: Int,
) -> DispatcherState {
  case state.status {
    Ready -> {
      let #(opt_next_input, new_state) = remove_pending_input(state)

      case opt_next_input {
        // Input is pending? Put the worker immediately back to work.
        Some(input) -> {
          actor.send(worker_subject, DoWork(input))
          new_state
        }
        // We have enough idle workers? Stop the worker.
        None if state.idle_worker_count >= max_idle_worker_count -> {
          actor.send(worker_subject, StopWorker)
          remove_active_worker(state)
        }
        // Otherwise, add to our list of idle workers.
        None -> {
          add_idle_worker(new_state, worker_subject)
        }
      }
    }

    Draining -> {
      let #(opt_next_input, new_state) = remove_pending_input(state)

      case opt_next_input {
        // Still draining the queue: keep this worker busy.
        Some(input) -> {
          actor.send(worker_subject, DoWork(input))
          new_state
        }
        // The queue just emptied: this worker (and any other already-idle
        // ones) are done — start stopping.
        None -> enter_stopping(add_idle_worker(new_state, worker_subject))
      }
    }

    Stopping -> {
      // No pending input can exist once Ready is left, so every worker
      // that reports ready from here on is simply told to stop.
      actor.send(worker_subject, StopWorker)
      remove_active_worker(state)
    }

    // No worker should still be reporting in once every worker has
    // already been told to stop — defensive no-op.
    Stopped -> state
  }
}

fn handle_stop_dispatcher(state: DispatcherState) -> DispatcherState {
  case state.status {
    Ready -> {
      let draining_state = DispatcherState(..state, status: Draining)
      case draining_state.pending_input_count {
        // Nothing queued: skip straight past Draining.
        0 -> enter_stopping(draining_state)
        _ -> draining_state
      }
    }
    // Already draining, stopping, or stopped — idempotent.
    _ -> state
  }
}

/// Tells every currently idle worker to stop and empties the idle pool;
/// `worker_count` is left counting only the workers still mid-job. Shared
/// by both ways `Stopping` is entered: directly from `StopDispatcher`
/// (queue was already empty) and from the queue draining empty via
/// `WorkerReady` (which folds the just-freed worker into `idle_workers`
/// first so it's included here too).
fn enter_stopping(state: DispatcherState) -> DispatcherState {
  list.each(state.idle_workers, fn(w) { actor.send(w, StopWorker) })
  DispatcherState(
    ..state,
    status: Stopping,
    idle_workers: [],
    idle_worker_count: 0,
    worker_count: state.worker_count - state.idle_worker_count,
  )
}

/// Once every worker has been told to stop, there's nothing left to wait
/// for.
fn finish_stopping_if_no_workers_remain(
  state: DispatcherState,
) -> DispatcherState {
  case state.status {
    Stopping if state.worker_count == 0 ->
      DispatcherState(..state, status: Stopped)
    _ -> state
  }
}

//-----------------------------------------------------------------------------

/// Internal state for a dispatcher actor. Tracks worker actors and queues inputs.
type DispatcherState {
  DispatcherState(
    self_subject: Subject(DispatcherMessage),
    status: DispatcherStatus,
    pending_inputs: Deque(String),
    pending_input_count: Int,
    idle_workers: List(Subject(WorkerMessage)),
    idle_worker_count: Int,
    worker_count: Int,
  )
}

fn initial_state(subject: Subject(DispatcherMessage)) {
  DispatcherState(
    self_subject: subject,
    status: Ready,
    pending_inputs: deque.new(),
    pending_input_count: 0,
    idle_workers: [],
    idle_worker_count: 0,
    worker_count: 0,
  )
}

fn add_active_worker(state: DispatcherState) {
  DispatcherState(..state, worker_count: state.worker_count + 1)
}

fn add_idle_worker(state: DispatcherState, worker: Subject(WorkerMessage)) {
  DispatcherState(
    ..state,
    idle_workers: [worker, ..state.idle_workers],
    idle_worker_count: state.idle_worker_count + 1,
  )
}

fn add_pending_input(state: DispatcherState, input: String) {
  DispatcherState(
    ..state,
    pending_inputs: deque.push_back(state.pending_inputs, input),
    pending_input_count: state.pending_input_count + 1,
  )
}

fn remove_active_worker(state: DispatcherState) {
  DispatcherState(..state, worker_count: state.worker_count - 1)
}

fn remove_idle_worker(state: DispatcherState) {
  case state.idle_workers {
    [_, ..remaining_workers] -> {
      DispatcherState(
        ..state,
        idle_workers: remaining_workers,
        idle_worker_count: state.idle_worker_count - 1,
      )
    }
    [] -> state
  }
}

fn remove_pending_input(state: DispatcherState) {
  case deque.pop_front(state.pending_inputs) {
    Ok(#(next_input, remaining_inputs)) -> {
      let new_state =
        DispatcherState(
          ..state,
          pending_inputs: remaining_inputs,
          pending_input_count: state.pending_input_count - 1,
        )
      #(Some(next_input), new_state)
    }
    Error(Nil) -> {
      #(None, state)
    }
  }
}
//-----------------------------------------------------------------------------
