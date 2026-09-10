// TypeScript-held HLC state — what replaced `hlc/clock_keeper.gleam`'s
// actor once StruoDB moved to the JavaScript/Bun target (see
// documentation/plans/architecture/bun-typescript-migration-plan.md,
// "HLC clock"). `hlc/clock.gleam` is a pure `(time, counter, node_id)`
// state machine with no actor, no mutable state, and no `gleam/erlang`/
// `gleam/otp` dependency of its own; this class is the "one clock per
// process, called synchronously" wrapper around it, now living here
// instead of in a Gleam actor's mailbox loop.
//
// Moved here (from `service/src/hlc-clock.ts`) in
// documentation/plans/architecture/event-store-implementation-plan.md's
// Phase 2/6: once `services/event-creation`/`services/event-store` also
// need a real `HlcClock`, it can no longer live only inside `service/`
// — today's throwaway smoke-test app (see that plan's "Scope"). `service/`
// now depends on this package instead of holding its own copy.
//
// This is the one file (besides the bridges under
// `service/src/bridges/`) allowed to import compiled Gleam output
// directly — everything it returns to the rest of the application is
// either a plain `string` (`next`/`merge`) or the compiled `HlcParts`
// record (`nextParts`, consumed only by `streams-bridge.ts`'s own
// Gleam-aware boundary, never by application code).
//
// @ts-expect-error — no .d.ts for compiled Gleam output.
import { new$ as clockNew, next as clockNext, next_parts as clockNextParts, merge as clockMerge, threshold_for_time as clockThresholdForTime, InvalidLength, InvalidFormat } from "../../../domain/shared/build/dev/javascript/shared/hlc/clock.mjs";
// @ts-expect-error — no .d.ts for compiled Gleam output.
import { encode as base62Encode, InvalidWidth, InsufficientWidth, NegativeValue } from "../../../domain/shared/build/dev/javascript/shared/hlc/base62.mjs";

/** Node ids are plain integers everywhere except as an HLC's own
 *  5-character base-62 subfield (see
 *  documentation/plans/architecture/event-store-implementation-plan.md,
 *  Phase 2) — this is the upper bound that field imposes: `62^5 - 1`,
 *  the largest value `base62.encode(nodeId, 5)` below can represent.
 *  `hlc/clock.gleam`'s own `start`/`new` is unaffected by any of this —
 *  it still takes the pre-encoded 5-character string, since that
 *  parameter already *is* the literal subfield value every HLC this
 *  clock produces will embed (hlc-spec.md §2.6); `HlcClock.create`
 *  below is the one place a plain integer becomes that string. */
export const MAX_NODE_ID = 916_132_831; // 62^5 - 1, node_id_width = 5

function describeBase62Error(error: unknown): string {
  if (error instanceof NegativeValue) {
    const e = error as { value: number };
    return `node id must not be negative: got ${e.value}`;
  }
  if (error instanceof InsufficientWidth) {
    const e = error as { needed: number; provided: number };
    return `node id too large for a ${e.provided}-character base-62 field (needs ${e.needed}); max is ${MAX_NODE_ID}`;
  }
  if (error instanceof InvalidWidth) {
    // Unreachable in practice — this module always calls encode with the
    // literal width 5 — but handled for completeness alongside the two
    // variants above.
    const e = error as { width: number };
    return `invalid base-62 field width: ${e.width}`;
  }
  return `invalid node id: ${String(error)}`;
}

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

/** Node id is a plain integer, `0 <= nodeId <= MAX_NODE_ID` — see
 *  `documentation/docs/specifications/internals/hlc-spec.md` for the
 *  5-character base-62 field it gets encoded into. */
export class HlcClock {
  #state: ClockState;

  private constructor(state: ClockState) {
    this.#state = state;
  }

  /** `now` defaults to `Date.now`, overridable so tests can supply a
   *  fixed or stepped clock (the same role `hlc/clock.gleam`'s own
   *  injected `now: fn() -> Int` parameter plays on the Gleam side).
   *  Throws if `nodeId` is negative or exceeds `MAX_NODE_ID`. */
  static create(nodeId: number, now: () => number = Date.now): HlcClock {
    const encoded = base62Encode(nodeId, 5) as Result<string, unknown>;
    if (!encoded.isOk()) {
      throw new Error(describeBase62Error(encoded[0]));
    }
    const result = clockNew(encoded[0], now) as Result<ClockState, unknown>;
    if (!result.isOk()) {
      throw new Error(describeHlcError(result[0]));
    }
    return new HlcClock(result[0]);
  }

  /** A synthetic HLC value for `physicalTimeMs` with counter and node id
   *  both zeroed — for range-comparing against real `_struo_hlc` values
   *  (e.g. a retention sweep's `WHERE _struo_hlc < thresholdForTime(t)`).
   *  Not a real clock reading; needs no instance. See
   *  `hlc/clock.gleam`'s `threshold_for_time` for the full rationale. */
  static thresholdForTime(physicalTimeMs: number): string {
    return clockThresholdForTime(physicalTimeMs) as string;
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
