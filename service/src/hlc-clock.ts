// TypeScript-held HLC state — what replaced `hlc/clock_keeper.gleam`'s
// actor once StruoDB moved to the JavaScript/Bun target (see
// documentation/plans/architecture/bun-typescript-migration-plan.md,
// "HLC clock"). `hlc/clock.gleam` is a pure `(time, counter, node_id)`
// state machine with no actor, no mutable state, and no `gleam/erlang`/
// `gleam/otp` dependency of its own; this class is the "one clock per
// process, called synchronously" wrapper around it, now living here
// instead of in a Gleam actor's mailbox loop.
//
// This is the one file (besides the bridges under `src/bridges/`)
// allowed to import compiled Gleam output directly — everything it
// returns to the rest of the application is either a plain `string`
// (`next`/`merge`) or the compiled `HlcParts` record (`nextParts`,
// consumed only by `src/bridges/streams-bridge.ts`, never by
// application code — see that file for why `HlcParts` crossing this one
// narrow boundary doesn't violate "no Gleam ADTs facing TypeScript").
//
// @ts-expect-error — no .d.ts for compiled Gleam output.
import { new$ as clockNew, next as clockNext, next_parts as clockNextParts, merge as clockMerge, InvalidLength, InvalidFormat } from "../../domain/shared/build/dev/javascript/shared/hlc/clock.mjs";

/** The 4 encoded HLC fields, as `hlc/clock.gleam`'s `HlcParts` — kept as
 *  the compiled Gleam record rather than flattened, since the only
 *  consumer is `streams-bridge.ts`'s own Gleam-aware boundary. */
export interface HlcParts {
  encoded: string;
  physical_time_ms: number;
  counter: number;
  node_id: number;
}

/** Opaque: never constructed or inspected here, only threaded from one
 *  `hlc/clock` call to the next — mirrors how `ClockState` is `opaque`
 *  on the Gleam side too. */
type ClockState = unknown;

/** Shape of a compiled Gleam `Result(T, E)` (see the Gleam JS prelude's
 *  `Ok`/`Error` classes): `isOk()` is a real type predicate here (not
 *  just `boolean`) so `if (!result.isOk()) throw ...` narrows `result`
 *  to `Ok<T, E>` in the rest of each method below, the same way
 *  matching `Ok(_)`/`Error(_)` would on the Gleam side. */
interface Result<T, E> {
  isOk(): this is Ok<T, E>;
  0: T | E;
}
interface Ok<T, E> extends Result<T, E> {
  0: T;
}

function describeHlcError(error: unknown): string {
  if (error instanceof InvalidLength) {
    const e = error as { expected: number; got: number };
    return `invalid HLC field length: expected ${e.expected}, got ${e.got}`;
  }
  if (error instanceof InvalidFormat) {
    const e = error as { nested: unknown };
    return `invalid HLC field format: ${String(e.nested)}`;
  }
  return `invalid HLC value: ${String(error)}`;
}

/** Node id must be exactly 5 base-62 (`0-9A-Za-z`) characters — see
 *  `documentation/docs/specifications/internals/hlc-spec.md`. */
export class HlcClock {
  #state: ClockState;

  private constructor(state: ClockState) {
    this.#state = state;
  }

  /** `now` defaults to `Date.now`, overridable so tests can supply a
   *  fixed or stepped clock (the same role `hlc/clock.gleam`'s own
   *  injected `now: fn() -> Int` parameter plays on the Gleam side). */
  static create(nodeId: string, now: () => number = Date.now): HlcClock {
    const result = clockNew(nodeId, now) as Result<ClockState, unknown>;
    if (!result.isOk()) {
      throw new Error(describeHlcError(result[0]));
    }
    return new HlcClock(result[0]);
  }

  /** The next HLC value for a local event on this node, as its full
   *  15-character encoded string. */
  next(): string {
    const [state, value] = clockNext(this.#state) as [ClockState, string];
    this.#state = state;
    return value;
  }

  /** The same draw as `next`, already decomposed into its four encoded
   *  fields — see `HlcParts`. */
  nextParts(): HlcParts {
    const [state, parts] = clockNextParts(this.#state) as [
      ClockState,
      HlcParts,
    ];
    this.#state = state;
    return parts;
  }

  /** Merges in an HLC value received from another node, advancing this
   *  node's clock if needed. Throws if `remote` is not a well-formed
   *  15-character HLC value, leaving this node's clock unchanged. */
  merge(remote: string): string {
    const result = clockMerge(this.#state, remote) as Result<
      [ClockState, string],
      unknown
    >;
    if (!result.isOk()) {
      throw new Error(describeHlcError(result[0]));
    }
    const [state, value] = result[0];
    this.#state = state;
    return value;
  }
}
