//-----------------------------------------------------------------------------
// A minimal mutable reference cell, JavaScript-target only. Test-only:
// production code never needs mutable state of its own to drive
// `dml_codegen`'s `next_hlc: fn() -> clock.HlcParts` supplier — a real
// caller closes over a TypeScript-held `HlcClock` instance instead (see
// `service/src/hlc-clock.ts` and `service/src/bridges/streams-bridge.ts`).
// This module exists purely so `dml_codegen_test.gleam` can build that
// same `fn() -> HlcParts` shape in pure Gleam, without an actor, by
// wrapping a `hlc/clock.ClockState` in a cell it can read and overwrite
// on each call.
//-----------------------------------------------------------------------------

pub type Ref(a)

@external(javascript, "./ref_ffi.mjs", "make_ref")
pub fn new(initial: a) -> Ref(a)

@external(javascript, "./ref_ffi.mjs", "get_ref")
pub fn get(ref: Ref(a)) -> a

@external(javascript, "./ref_ffi.mjs", "set_ref")
pub fn set(ref: Ref(a), value: a) -> Nil
