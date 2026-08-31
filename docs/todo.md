# Code Review To-Do

1. **`../src/util/asyncio/reader.gleam:15` — quit path exits before pending work finishes.**
   On the quit sentinel, `read_loop` sends `StopDispatcher` and immediately
   prints `"Exiting ..."` and returns, without waiting for the dispatcher (and
   its in-flight workers/writer) to actually finish processing already-queued
   jobs (see the `TODO: wait for dispatcher to exit` comment). If jobs are
   still queued or in progress when `"~quit\n"` is read, the program can exit
   before their output is written, silently dropping submitted work.

2. **`../src/util/asyncio/dispatcher.gleam:96` — `StopDispatcher` leaks worker actors.**
   The `StopDispatcher` branch only stops the dispatcher actor itself; it
   never sends `StopWorker` to the active/idle workers it spawned. If the
   dispatcher has idle or busy workers when it stops, those worker processes
   are never told to stop and keep running indefinitely, listening on
   subjects that will never receive another message — a process leak
   whenever the dispatcher's lifetime is shorter than the hosting runtime's.

3. **`../src/util/asyncio/reader.gleam:15` — fragile quit-sentinel match.**
   The quit sentinel is matched via exact string equality against
   `"~quit\n"`, so it silently fails to match if the final line lacks a
   trailing newline (e.g., piped input whose last line is `"~quit"` with no
   trailing `\n` before EOF) or uses a different line ending. In that case
   the line is dispatched as a normal job instead of stopping the
   dispatcher, and the next read then hits EOF/Error, ending the loop
   without ever sending `StopDispatcher`.
