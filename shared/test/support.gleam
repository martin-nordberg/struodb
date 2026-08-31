import gleam/erlang/process.{type Pid, type Subject}

// Test helpers shared by the `asyncio` test suites.

//-----------------------------------------------------------------------------

/// Blocks until the process behind `pid` terminates, failing the calling
/// test (via a pattern match panic) if it does not exit within `timeout_ms`.
pub fn wait_until_stopped(pid: Pid, timeout_ms: Int) -> Nil {
  let monitor = process.monitor(pid)

  let assert Ok(_down) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(timeout_ms)

  Nil
}

/// Receives `count` messages from `subject`, in the order they arrive,
/// failing the calling test if any one of them does not arrive within
/// `timeout_ms`.
pub fn receive_n(subject: Subject(a), count: Int, timeout_ms: Int) -> List(a) {
  case count {
    0 -> []
    _ -> {
      let assert Ok(message) = process.receive(subject, timeout_ms)
      [message, ..receive_n(subject, count - 1, timeout_ms)]
    }
  }
}
//-----------------------------------------------------------------------------
