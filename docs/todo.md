# Code Review To-Do

1. **`../src/util/asyncio/reader.gleam:15` — fragile quit-sentinel match.**
   The quit sentinel is matched via exact string equality against
   `"~quit\n"`, so it silently fails to match if the final line lacks a
   trailing newline (e.g., piped input whose last line is `"~quit"` with no
   trailing `\n` before EOF) or uses a different line ending. In that case
   the line is dispatched as a normal job instead of stopping the
   dispatcher, and the next read then hits EOF/Error, ending the loop
   without ever sending `StopDispatcher`.
