import gleam/erlang/process.{type Subject}

//-----------------------------------------------------------------------------

/// Messages sent to a dispatcher.
pub type DispatcherMessage {
  // Sent by clients to add a line of input
  AddJob(input: String)
  // Sent by workers when they are free
  WorkerReady(worker_subject: Subject(WorkerMessage))
  // Sent to end the process.
  StopDispatcher
}

//-----------------------------------------------------------------------------

/// Messages sent to a worker.
pub type WorkerMessage {
  /// Sent with an input to work on.
  DoWork(input: String)
  /// Sent to end the process.
  StopWorker
}

//-----------------------------------------------------------------------------

/// Messages sent to a writer.
pub type WriterMessage {
  /// Sent to output a result.
  WriteOutput(String)
  /// Sent to end the process.
  StopWriter
}
//-----------------------------------------------------------------------------
