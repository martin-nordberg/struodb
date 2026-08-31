import asyncio/messages.{
  type DispatcherMessage, type WorkerMessage, type WriterMessage, DoWork,
  StopWorker, WorkerReady, WriteOutput,
}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

//-----------------------------------------------------------------------------

/// Starts a new worker actor.
pub fn start(
  dispatcher: Subject(DispatcherMessage),
  writer: Subject(WriterMessage),
  handle_input: fn(String) -> String,
) {
  let assert Ok(worker_started) =
    actor.new_with_initialiser(1000, fn(subject) {
      let initial_state = WorkerState(self_subject: subject)
      actor.initialised(initial_state)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(fn(state, msg) {
      handle_message(state, msg, dispatcher, writer, handle_input)
    })
    |> actor.start()

  worker_started.data
}

//-----------------------------------------------------------------------------

fn handle_message(
  state: WorkerState,
  msg: WorkerMessage,
  dispatcher: Subject(DispatcherMessage),
  writer: Subject(WriterMessage),
  handle_input: fn(String) -> String,
) -> actor.Next(WorkerState, WorkerMessage) {
  case msg {
    DoWork(input) -> {
      let output = handle_input(input)

      actor.send(writer, WriteOutput(output))

      actor.send(dispatcher, WorkerReady(worker_subject: state.self_subject))
      actor.continue(state)
    }
    StopWorker -> {
      actor.stop()
    }
  }
}

//-----------------------------------------------------------------------------

type WorkerState {
  WorkerState(self_subject: Subject(WorkerMessage))
}
//-----------------------------------------------------------------------------
