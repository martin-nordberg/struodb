# Hybrid Logical Clock — Implementation Plan

Implements [`spec.md`](./spec.md). Read that first; this document
covers module layout, concrete signatures, and the steps to build it.

## Design decisions carried over from discussion

- **Node ID**: passed in by the caller at clock startup (not generated).
- **Counter rollover**: `next()`/`merge()` always succeed — on overflow,
  the physical time component is force-advanced by 1ms and the counter
  resets to 0 (spec section "Operations", rollover rule).
- **Access pattern**: the clock actor's `Subject(ClockMessage)` is created
  once by `start()` and passed explicitly to `next()`/`merge()` by callers
  — the same explicit-passing style already used by
  `dispatcher.start`/`worker.start`/`writer.start` in this codebase. No
  global/singleton state, no `process.Name`/`persistent_term` machinery:
  those were considered (to get an argument-free `hlc.next()`) but add
  restart-survival semantics and FFI complexity this project doesn't need,
  for no benefit once a handle has to be created once and threaded through
  `main()` regardless.
- **Malformed `merge()` input**: returns `Result(String, HlcError)` rather
  than crashing, since the remote string is external, possibly-untrusted
  data (same reasoning applies to node ID validation at startup).
- **Actor-level start failures** (e.g. the OTP actor failing to spawn) are
  treated as infrastructure errors, not caller-data errors, and crash via
  `let assert Ok(...)` — consistent with `dispatcher.start`/`worker.start`.
  Only node-ID *format* validation returns a `Result`.
- **`HlcError` is its own type, not a `Base62Error` alias.** An earlier
  version made `HlcError = base62.Base62Error` to avoid a duplicate type,
  but that conflated two different concerns under one type: `util/hlc/clock`
  checking a whole string's length before it even tries to decode
  anything, versus `base62` failing to decode a field it was already given
  at the right length. `HlcError` now has exactly two variants —
  `InvalidLength(expected, got)` for the former (moved out of
  `Base62Error`, which no longer has any length-shaped variant at all),
  and `InvalidFormat(nested: base62.Base62Error)` wrapping the latter — so
  every base-62-level failure still reaches callers, just wrapped rather
  than reused. See `util/hlc/clock.gleam` below.

## Dependencies

`gleam_time` is currently only a transitive dependency (pulled in via
`birch`). Add it directly, since `clock.gleam` calls it explicitly:

```sh
gleam add gleam_time
```

## Module layout

```
src/util/hlc/
  base62.gleam      # pure, reusable fixed-width base-62 codec
  clock.gleam       # ClockMessage type + actor state/behavior + public start/next/merge/stop API

test/util/hlc/
  base62_test.gleam
  clock_test.gleam
```

`util/asyncio/messages.gleam` exists as a separate module because it holds
message types for three interacting actor kinds
(`DispatcherMessage`/`WorkerMessage`/`WriterMessage`). HLC has only one
actor kind, so `ClockMessage` lives directly in `clock.gleam` alongside the
actor it belongs to — no separate messages module.

No facade module (e.g. no `src/util/hlc.gleam`) — callers `import util/hlc/clock`
and call `clock.start`/`clock.next`/`clock.merge` directly, matching how
`util/asyncio/dispatcher` etc. are imported directly today with no
`util/asyncio.gleam` wrapper.

## `../../src/util/hlc/base62.gleam`

Generic, width-agnostic, no knowledge of HLC field layout — reusable and
independently testable.

```gleam
pub type Base62Error {
  InvalidCharacter(char: String, index: Int)
  InvalidWidth(width: Int)
  InsufficientWidth(needed: Int, provided: Int)
  NegativeValue(value: Int)
}

/// Encodes `value` as exactly `width` base-62 characters, zero-padded.
/// `width` must be between 1 and 16. Errors (`NegativeValue`) if `value`
/// is negative, or (`InsufficientWidth`) if it's too large to fit in
/// `width` characters.
pub fn encode(value: Int, width: Int) -> Result(String, Base62Error)

/// Decodes a base-62 string (of any length) back to its integer value.
/// Errors if any character falls outside `0-9A-Za-z`.
pub fn decode(value: String) -> Result(Int, Base62Error)
```

`Base62Error` deliberately has no length-mismatch variant of its own:
`decode` never checks length (it decodes whatever graphemes it's given),
and `encode`'s length-shaped failure is about a *value* needing more
digits than the `width` it was asked to fit into, not a *string's*
length — that's `InsufficientWidth(needed, provided)`, not something
named `InvalidLength` (which would invite confusion with `HlcError`'s
`InvalidLength`, a genuinely different check on a whole string's length;
see `util/hlc/clock.gleam` below for why they're kept as two separate
types instead of one shared between whole-string and per-value concerns).

Notes for the implementer:
- Alphabet constant: `"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"`.
  Build the char→value lookup from this single constant (e.g. via
  `string.to_graphemes` + `list.index_map`) so the encode and decode
  directions can never drift out of sync with each other.
- `encode` builds the string right-to-left (successive `value % 62`,
  `value / 62`) then left-pads with `"0"` to `width`.
- **Capacity lookup, not `int_pow`.** `encode` needs `62^width` to bound-check
  `value`, but computing that by repeated multiplication on every call is
  wasted work for a fixed, small set of possible widths. Instead, precompute
  `62^1 .. 62^16` as literal arms of a `case width { ... }` expression
  (`1 -> Ok(62)`, `2 -> Ok(3844)`, ... `16 -> Ok(...)`), with `_` as the
  fallthrough. This was chosen over both a `List` (traversed with
  `list.drop`/`list.first`, O(width)) and a `Dict` (needs building from a
  literal list on every call, since Gleam `const`s can't hold a `Dict`
  directly, plus hashing on lookup): a `case` over integer literals compiles
  on the BEAM to an efficient decision tree with no data structure built or
  traversed at runtime at all. 16 is an arbitrary but generous ceiling —
  double any width this codebase actually uses (8, 5, and 2 for the HLC
  fields) — chosen so the module stays a reusable, general-purpose codec
  rather than one hardcoded to HLC's specific widths. A `width` matching no
  arm — i.e. outside `1..16` — falls to `_`, which is exactly what
  `InvalidWidth(width)` reports.
- Once the capacity is in hand, return `NegativeValue(value)` if
  `value < 0`, or `InsufficientWidth(needed: required_width(value),
  provided: width)` if `value >= capacity`, rather than silently
  truncating.
- `decode` does not care about width/padding — that check belongs to the
  caller (`clock.gleam`), which knows the expected field widths. `decode`
  is unaffected by the width lookup table (it never takes a `width`
  argument), so it has no `InvalidWidth` case to raise.

## `../../src/util/hlc/clock.gleam`

### Error type

```gleam
/// Reasons an HLC value couldn't be validated or parsed.
pub type HlcError {
  /// A whole string — a node id, or a full 15-character HLC value —
  /// wasn't the length it needed to be. Checked before any base-62
  /// decoding is even attempted.
  InvalidLength(expected: Int, got: Int)
  /// A string was the length it needed to be, but one of its base-62
  /// fields failed to decode; see `nested` for why.
  InvalidFormat(nested: base62.Base62Error)
}
```

Not a type alias of `Base62Error` — see the "Design decisions" note above
for why. `InvalidFormat`'s `nested` field means a caller who wants the
detail (which character, at what index; which width was too small) can
still get it by matching into `base62.Base62Error`, same as before; a
caller who only cares that decoding failed can match `InvalidFormat(_)`.

### Message type

```gleam
/// Messages sent to a clock actor. Opaque: the type itself is public (so
/// it can appear in `start`/`next`/`next_parts`/`merge`/`stop`'s
/// signatures), but its constructors are not — all interaction happens
/// through those functions, so callers never need to build or match on a
/// message directly.
pub opaque type ClockMessage {
  /// Requests the next HLC value for a local event.
  Next(reply_to: Subject(String))
  /// Requests the next HLC value for a local event, decomposed into its
  /// three encoded fields — see `HlcParts`.
  NextParts(reply_to: Subject(HlcParts))
  /// Merges in an HLC value received from another node.
  Merge(remote: String, reply_to: Subject(Result(String, HlcError)))
  /// Sent to end the process.
  StopClock
}

/// One `next()`/`next_parts()` draw, already decomposed into its three
/// encoded fields — for a caller that needs the physical time/counter/
/// node id individually rather than re-parsing `encoded` itself (e.g.
/// StruoDB's own DML codegen, populating the 3 derived SQL columns
/// alongside the encoded value itself — see docs/lang/spec.md §9.2).
/// `node_id` is decoded to its integer value even though the field is
/// otherwise opaque/caller-assigned (see "Node ID" in spec.md) — decoding
/// it is a well-defined, reversible operation regardless of what the
/// digits are taken to mean.
pub type HlcParts {
  HlcParts(encoded: String, physical_time_ms: Int, counter: Int, node_id: Int)
}
```

`pub opaque type` (not plain `pub type`, and not private) is the one
combination that works here: a plain private `type` can't appear in a
`pub fn`'s signature at all (Gleam rejects "private type used in public
interface"), but the *type name* `ClockMessage` has to be nameable in
`Subject(ClockMessage)` for `start`/`next`/`next_parts`/`merge`/`stop`'s
signatures. `opaque` gets both: the name is public, the constructors
(`Next`, `NextParts`, `Merge`, `StopClock`) are not — so nothing outside
this module can send anything but what `next`/`next_parts`/`merge`/
`stop` send on its behalf. `HlcParts` is a plain (non-opaque) `pub type`,
unlike `ClockMessage` — callers are meant to read its fields directly,
there's nothing to hide.

### Public API

```gleam
/// Starts a new clock actor for `node_id` (must be exactly 5 base-62
/// characters). `now` returns the current wall-clock time in milliseconds
/// since the Unix epoch — injected (rather than called directly) so tests
/// can supply a fixed or controlled clock, the same way `dispatcher.start`
/// and `worker.start` take an injected `handle_input`.
pub fn start(
  node_id: String,
  now: fn() -> Int,
) -> Result(Subject(ClockMessage), HlcError)

/// Returns the next HLC value for a local event on this node.
pub fn next(clock: Subject(ClockMessage)) -> String

/// Returns the next HLC value for a local event on this node, the same
/// as `next`, but already decomposed into its three encoded fields — see
/// `HlcParts`. Avoids a redundant encode-then-decode round trip: the
/// actor already has `physical_time_ms`/`counter`/`node_id` in hand
/// right before encoding them for `next`.
pub fn next_parts(clock: Subject(ClockMessage)) -> HlcParts

/// Merges in an HLC value received from another node, advancing this
/// node's clock if needed. Returns an error (leaving this node's clock
/// unchanged) if `remote` is not a well-formed 15-character HLC value.
pub fn merge(clock: Subject(ClockMessage), remote: String) -> Result(String, HlcError)

/// Stops the clock actor.
pub fn stop(clock: Subject(ClockMessage)) -> Nil
```

`next`/`merge` are synchronous request/reply, via `actor.call` (a
re-export of `process.call`), matching the one existing `Int -> reply`
pattern already used for actor timeouts in this codebase. `stop` is
fire-and-forget, via `actor.send` (matching `StopDispatcher`/`StopWorker`/
`StopWriter`'s handling elsewhere in this codebase — those are sent
directly by callers since their message types aren't opaque; `stop` here
is the wrapper that plays the same role now that `StopClock` isn't
externally visible):

```gleam
const call_timeout_ms = 1000

pub fn next(clock: Subject(ClockMessage)) -> String {
  actor.call(clock, waiting: call_timeout_ms, sending: Next)
}

pub fn next_parts(clock: Subject(ClockMessage)) -> HlcParts {
  actor.call(clock, waiting: call_timeout_ms, sending: NextParts)
}

pub fn merge(clock: Subject(ClockMessage), remote: String) -> Result(String, HlcError) {
  actor.call(clock, waiting: call_timeout_ms, sending: fn(reply_to) {
    Merge(remote, reply_to)
  })
}

pub fn stop(clock: Subject(ClockMessage)) -> Nil {
  actor.send(clock, StopClock)
}
```

### Field widths and limits (private constants)

```gleam
const time_width = 8
const counter_width = 2
const node_id_width = 5
const max_counter = 3_843   // 62^2 - 1
```

Counter width was chosen as 2 (not 3) specifically so the full encoded
value is 15 characters — small enough to fit a PostgreSQL `char(15)`
column exactly, with no padding. See spec.md's "Non-goals / accepted
limitations" for the tradeoff this makes: rollover now kicks in after
3,843 `next()`/`merge()` calls per node per millisecond, versus 238,327
for a 3-character counter.

### State

```gleam
type ClockState {
  ClockState(
    physical_time_ms: Int,
    counter: Int,
    node_id: String,
    now: fn() -> Int,
  )
}
```

Unlike `DispatcherState`/`WorkerState`, this holds no `self_subject` —
the clock actor never needs to hand its own `Subject` to anyone else, so
plain `actor.new` (as `writer.gleam` uses) is enough; there's no need for
`actor.new_with_initialiser`.

### `start`

1. Validate `node_id`: check its length is exactly `node_id_width` first
   (returning `InvalidLength` if not), then `base62.decode` it (wrapping
   any failure as `InvalidFormat`) — see `decode_field` below, shared with
   `decode_value`. On failure, return `Error(..)` *without* starting an
   actor.
2. Otherwise, spawn the actor (`actor.new` + `actor.on_message` +
   `actor.start()`, the same shape as `writer.start`), seeding initial
   state with `physical_time_ms: now()`, `counter: 0`. Crash via
   `let assert Ok(..)` on an OTP-level start failure — infrastructure
   failure, not caller data.
3. Return `Ok(started.data)`.

### `handle_message`

```gleam
fn handle_message(state: ClockState, msg: ClockMessage) {
  case msg {
    Next(reply_to) -> {
      let new_state = advance(state)
      actor.send(reply_to, encode_value(new_state))
      actor.continue(new_state)
    }

    Merge(remote, reply_to) -> {
      case decode_value(remote) {
        Ok(#(remote_ms, remote_counter, _remote_node_id)) -> {
          let new_state = merge_in(state, remote_ms, remote_counter)
          actor.send(reply_to, Ok(encode_value(new_state)))
          actor.continue(new_state)
        }
        Error(err) -> {
          actor.send(reply_to, Error(err))
          actor.continue(state)
        }
      }
    }

    StopClock -> actor.stop()
  }
}
```

### Algorithm (private helpers, directly implementing the spec)

```gleam
/// Applies the rollover rule: if `counter` overflows, advance time by 1ms
/// and reset the counter instead. Always terminates in one step, since a
/// freshly-reset counter of 0 can never itself need to roll over.
fn bump(time_ms: Int, counter: Int) -> #(Int, Int) {
  case counter > max_counter {
    True -> #(time_ms + 1, 0)
    False -> #(time_ms, counter)
  }
}

fn advance(state: ClockState) -> ClockState {
  let p = state.now()
  let #(new_time, new_counter) = case p > state.physical_time_ms {
    True -> #(p, 0)
    False -> bump(state.physical_time_ms, state.counter + 1)
  }
  ClockState(..state, physical_time_ms: new_time, counter: new_counter)
}

fn merge_in(state: ClockState, remote_ms: Int, remote_counter: Int) -> ClockState {
  let p = state.now()
  let new_time = int.max(state.physical_time_ms, int.max(remote_ms, p))

  let tentative_counter = case
    new_time == state.physical_time_ms,
    new_time == remote_ms
  {
    True, True -> int.max(state.counter, remote_counter) + 1
    True, False -> state.counter + 1
    False, True -> remote_counter + 1
    False, False -> 0
  }

  let #(final_time, final_counter) = bump(new_time, tentative_counter)
  ClockState(..state, physical_time_ms: final_time, counter: final_counter)
}
```

### Encoding a full value

```gleam
fn encode_value(state: ClockState) -> String {
  let assert Ok(time_part) = base62.encode(state.physical_time_ms, time_width)
  let assert Ok(counter_part) = base62.encode(state.counter, counter_width)
  time_part <> counter_part <> state.node_id
}
```
(`let assert` is safe here: `physical_time_ms`/`counter` are maintained
internally by this module and are never allowed to exceed their field's
capacity — `bump` guarantees `counter` is always in range, and the time
field's 6,900-year headroom makes overflow there unreachable.)

```gleam
/// Decodes one already-length-checked base-62 field, wrapping any failure
/// as `InvalidFormat` so callers only ever have to handle `HlcError`.
/// Shared between `decode_value` and `start`'s node-id validation.
fn decode_field(part: String) -> Result(Int, HlcError) {
  base62.decode(part) |> result.map_error(InvalidFormat)
}

fn decode_value(value: String) -> Result(#(Int, Int, String), HlcError) {
  case string.length(value) {
    15 -> {
      let time_part = string.slice(value, 0, time_width)
      let counter_part = string.slice(value, time_width, counter_width)
      let node_id_part = string.slice(value, time_width + counter_width, node_id_width)
      use time_ms <- result.try(decode_field(time_part))
      use counter <- result.try(decode_field(counter_part))
      // validates node_id_part is well-formed base-62 without needing its value
      use _ <- result.try(decode_field(node_id_part))
      Ok(#(time_ms, counter, node_id_part))
    }
    other -> Error(InvalidLength(expected: 15, got: other))
  }
}
```

### Wiring `now` in `main()`

```gleam
import gleam/time/timestamp

fn system_now_ms() -> Int {
  let #(seconds, nanoseconds) = timestamp.system_time()
    |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1000 + nanoseconds / 1_000_000
}
```

Pass `system_now_ms` as `now` when calling `clock.start` from `main()`.
Tests instead pass a fixed or step-controlled function (see below) — this
is the same injection pattern `worker.start`/`dispatcher.start` already
use for `handle_input`, applied to time instead of input handling.

## Test plan

### `../../test/util/hlc/base62_test.gleam`

- Round-trips `0`, a mid-range value, and the maximum value for a given
  width (`encode` then `decode` recovers the original integer).
- Round-trips a value at the maximum supported width (16), exercising the
  last entry of the capacity lookup table.
- `encode` returns `InsufficientWidth` when the value doesn't fit the
  requested width.
- `encode` returns `NegativeValue` for a negative value.
- `encode` returns `InvalidWidth` for a width below 1 and for a width
  above 16 — the two ends of the lookup table's supported range.
- `decode` returns `InvalidCharacter` for a string containing a character
  outside the alphabet (e.g. `-`, space, or a non-ASCII character).
- Confirms ordering: for two values `a < b` of the same width,
  `encode(a, w) < encode(b, w)` as plain string comparison — this is the
  spec's core sortability invariant and deserves a direct test, not just
  incidental coverage.

### `../../test/util/hlc/clock_test.gleam`

Uses a fixed `now: fn() -> Int` (e.g. `fn() { 1_700_000_000_000 }`) for
determinism — no test should depend on real wall-clock timing.

- `start` with a valid 5-character node ID succeeds.
- `start` with a node ID of the wrong length returns `InvalidLength` and
  does not start an actor; one containing a character outside the
  alphabet returns `InvalidFormat` (wrapping `base62.InvalidCharacter`).
- Two consecutive `next()` calls with a fixed `now` produce strictly
  increasing values (time held, counter incremented).
- **Rollover**: calling `next()` `max_counter + 2` times with a *fixed*
  `now` demonstrates the counter climbing to `max_counter`, then rolling
  over — the next call's decoded time component is one greater than
  before, with counter reset to `0` — and that every value in the whole
  sequence is strictly increasing as a string. (A fixed `now` makes this
  deterministic: once `now` no longer exceeds the accumulated physical
  time, every subsequent call falls into the same increment/rollover path
  without needing to wait on the real clock.)
- `merge` with a remote value behind this node's own clock leaves the time
  component unchanged and increments the counter.
- `merge` with a remote value ahead of both this node's clock and `now`
  adopts the remote's time and sets `remote_counter + 1`.
- `merge` where local time, remote time, and `now` are all equal combines
  counters via `max(local_counter, remote_counter) + 1`.
- `merge` rolls over the same way `next()` does when the combined counter
  would exceed `max_counter`.
- `merge` with a malformed remote string (wrong length; invalid character)
  returns `Error(..)` and leaves the node's own next `next()`/`merge()`
  output unaffected (i.e. state truly did not change).
- `stop` terminates the actor (reuse `test/support.wait_until_stopped`, as
  `util/asyncio/worker_test.gleam` does for `StopWorker` — but calling
  `clock.stop(subject)` rather than sending `StopWorker` directly, since
  `StopClock` isn't visible outside `clock.gleam`).

## Step-by-step build order

1. `gleam add gleam_time`.
2. Implement `../../src/util/hlc/base62.gleam` + `../../test/util/hlc/base62_test.gleam`; get
   this fully correct and tested first since everything else builds on it.
3. Implement `../../src/util/hlc/clock.gleam` (opaque `ClockMessage`, state, `start`,
   `advance`, `merge_in`, `bump`, `encode_value`, `decode_value`,
   `handle_message`, public `next`/`merge`/`stop`).
4. Implement `../../test/util/hlc/clock_test.gleam`.
5. Wire `system_now_ms` and a call to `clock.start` into `src/streams.gleam`'s
   `main()` (node ID source still needs a real value here — e.g. an
   environment variable read via `gleam_erlang`'s `os`/`envoy`-style
   lookup, or a placeholder constant if that's out of scope for now).
6. `gleam test`, then a manual smoke check via `gleam run`.
