import asyncio/messages.{
  type DispatcherMessage, type WorkerMessage, type WriterMessage, AddJob, DoWork,
  StopDispatcher, StopWorker, WorkerReady,
}
import asyncio/worker
import birch as log
import gleam/deque.{type Deque}
import gleam/erlang/process.{type Subject}
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

//-----------------------------------------------------------------------------

fn handle_message(
  state: DispatcherState,
  msg: DispatcherMessage,
  writer: Subject(WriterMessage),
  input_handler: fn(String) -> String,
  max_idle_worker_count: Int,
  max_worker_count: Int,
) {
  let new_state = case msg {
    AddJob(input) -> {
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
    }

    WorkerReady(worker_subject) -> {
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
        // Otherwise, add to out list of idle workers.
        None -> {
          add_idle_worker(new_state, worker_subject)
        }
      }
    }

    StopDispatcher -> {
      state
    }
  }

  log.debug_m("Dispatcher state changed.", [
    #("idle", string.inspect(new_state.idle_worker_count)),
    #("total", string.inspect(new_state.worker_count)),
    #("inputs", string.inspect(new_state.pending_input_count)),
  ])

  case msg {
    StopDispatcher -> {
      actor.stop()
    }
    _ -> {
      actor.continue(new_state)
    }
  }
}

//-----------------------------------------------------------------------------

/// Internal state for a dispatcher actor. Tracks worker actors and queues inputs.
type DispatcherState {
  DispatcherState(
    self_subject: Subject(DispatcherMessage),
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
