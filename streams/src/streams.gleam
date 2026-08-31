import asyncio/dispatcher
import asyncio/reader
import asyncio/writer
import birch as log
import birch/handler/async
import birch/handler/json
import birch/level
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/string
import gleam/time/timestamp
import hlc/clock
import in

// TODO: source this node's id from deployment configuration (e.g. an
// environment variable) once this app actually runs on more than one node.
// Must be exactly 5 base-62 (0-9A-Za-z) characters.
const node_id = "node1"

pub fn main() {
  let max_idle_worker_count = 3
  let max_worker_count = 5

  configure_logging()

  let assert Ok(_clock) = clock.start(node_id, system_now_ms)

  let writer = writer.start(io.println)
  let dispatcher =
    dispatcher.start(
      writer,
      input_handler,
      max_idle_worker_count,
      max_worker_count,
    )

  reader.read_loop(dispatcher, fn() { in.read_line() })

  writer.stop(writer)
}

/// The current wall-clock time in milliseconds since the Unix epoch, for
/// use as the clock actor's injected `now`.
fn system_now_ms() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1000 + nanoseconds / 1_000_000
}

fn configure_logging() {
  let async_json_stderr =
    json.handler_stderr()
    |> async.make_async(async.config())

  log.configure([
    log.config_level(level.Debug),
    log.config_handlers([async_json_stderr]),
    log.config_context([#("app", "exstruo"), #("env", "dev")]),
  ])

  log.info("Logging configured")
}

fn input_handler(input: String) {
  let random_duration = int.random(400) + 100
  process.sleep(random_duration)

  let result = "Handled Input: " <> string.inspect(input)

  log.debug(result)

  result
}
