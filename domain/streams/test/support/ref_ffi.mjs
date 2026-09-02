// FFI backing `support/ref.gleam`'s mutable cell. See that module's header
// comment for why this exists (test-only stand-in for real, TypeScript-held
// mutable state).

export function make_ref(initial) {
  return { value: initial };
}

export function get_ref(ref) {
  return ref.value;
}

export function set_ref(ref, value) {
  ref.value = value;
  return undefined;
}
