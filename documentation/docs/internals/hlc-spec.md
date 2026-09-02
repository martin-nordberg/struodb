# Hybrid Logical Clock — Specification

## Purpose

A hybrid logical clock (HLC) combines wall-clock time with a logical
counter so that clock values across nodes are both causally ordered (like a
Lamport clock) and stay close to real time (unlike a pure Lamport clock).
Each value is encoded as a single 15-character string that is directly
comparable and sortable without decoding — 15 was chosen specifically so
the value fits a PostgreSQL `char(15)` column with no padding. StruoDB's
query language stores that encoded value, plus its 3 fields decoded back
out into their own columns, as 4 of the 5 automatic system columns every
stream gets — `_struo_hlc`/`_struo_hlc_timestamp`/`_struo_hlc_count`/
`_struo_hlc_node_id` (the 5th, `_struo_created_at`, isn't
HLC-derived) — see [Schema Definition §9.2](/struoql/ddl-spec#_9-2-the-automatic-system-columns).

## Encoding

- **Alphabet**: exactly `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz`
  (base 62; digit `0` is value 0, `Z` is value 35, `z` is value 61).
- **Layout**: three fixed-width, zero-padded fields concatenated in order,
  15 characters total:

  | Field         | Chars | Positions | Range                                   |
  |---------------|-------|-----------|------------------------------------------|
  | Physical time | 8     | 0–7       | `0 .. 62^8 - 1` (218,340,105,584,895)     |
  | Counter       | 2     | 8–9       | `0 .. 62^2 - 1` (3,843)                   |
  | Node ID       | 5     | 10–14     | caller-assigned, opaque                   |

  Physical time is milliseconds since the Unix epoch (1970-01-01T00:00:00Z),
  with no custom epoch offset. 62^8 milliseconds is about 6,921 years, so
  the field does not wrap within any realistic deployment lifetime.

- **Invariant — lexicographic order equals value order.** Because every
  field is fixed-width and zero-padded, and because the alphabet's
  character-to-value mapping is monotonic in ASCII order
  (`'0'…'9' < 'A'…'Z' < 'a'…'z'`), plain string comparison of two 15-character
  HLC values gives the same result as comparing them as
  `(time, counter, node_id)` tuples. This is what makes the encoded value
  usable directly as a sort key (e.g. a database primary key or a log
  sequence key) without decoding it first. Encoders must never emit a
  narrower/unpadded field — doing so would break this invariant.

## Per-node state

Each node holds exactly one clock, conceptually:

```
(physical_time_ms: Int, counter: Int, node_id: String)
```

`node_id` is fixed for the lifetime of the running node; `physical_time_ms`
and `counter` change on every operation below.

## Operations

### 1. `next()` — record a local event

Given current state `(t, c)` and the node's own wall-clock reading `p`:

1. If `p > t`: the wall clock has caught up or moved past our logical
   time. New state is `(p, 0)`.
2. Otherwise (`p <= t`: the wall clock has not advanced past our logical
   time, including the case where it appears to have gone backward):
   tentatively bump to `(t, c + 1)`.
3. **Rollover.** If the tentative counter from step 2 would exceed
   `62^2 - 1`, discard it and instead advance to `(t + 1, 0)`.

   This rule is what makes `next()` robust under sustained load: it always
   terminates in a single step (a freshly rolled-over counter is `0`, which
   can never itself need to roll over again), it always produces a value
   strictly greater than the previous one, and it never fails, no matter
   how many times `next()` is called within one wall-clock millisecond or
   how far the physical component has drifted ahead of true wall-clock time.
   A physical component running ahead of real time is an accepted,
   self-correcting characteristic of HLCs under load — not a defect — and
   is not to be treated as an error condition anywhere in this design. Note
   that the 2-character counter (3,843 values/ms) rolls over far sooner
   under load than a 3-character one would (238,327 values/ms) — see
   "Non-goals / accepted limitations" below.
4. Encode the new state and return it.

### 2. `merge(remote)` — record a message received from another node

1. Parse `remote` (a 15-character HLC string from another node) into
   `(rt, rc, _)` — the remote node ID is decoded only to validate the
   string's shape and is otherwise discarded; the merged result always
   keeps *this* node's own `node_id`.
2. If `remote` cannot be parsed (wrong length, or a character outside the
   base-62 alphabet in any field), return an error and leave this node's
   state unchanged.
3. Otherwise, with local state `(t, c)` and this node's own wall-clock
   reading `p`:
   - `new_t = max(t, rt, p)`
   - Tentative counter:
     - `new_t == t` and `new_t == rt` → `max(c, rc) + 1`
     - `new_t == t` only → `c + 1`
     - `new_t == rt` only → `rc + 1`
     - otherwise (`new_t == p`, strictly greater than both `t` and `rt`) → `0`
   - Apply the same **rollover** rule as `next()` step 3 to `(new_t, tentative counter)`.
4. Encode the new state, update local state, and return it.

## Errors

Merging (and node ID validation at startup — see below) can fail because
the input string is malformed. There are exactly two ways a base-62 field
can be malformed:

- its length doesn't match the field's fixed width, or
- it contains a character outside the base-62 alphabet.

The implementation plan defines a single error type covering both cases,
reused for node ID validation and for `merge()`'s input validation.

## Node ID

- Exactly 5 base-62 characters.
- Supplied by the caller when the clock is started (e.g. derived from
  hostname, pod ordinal, or shard ID) — this design does not generate or
  coordinate node IDs itself. **Uniqueness across nodes is the deployer's
  responsibility**; a collision is a deployment error, not something this
  clock can detect.
- Validated once, at clock startup, using the same length/alphabet check
  used to validate `merge()` input. An invalid node ID is reported as an
  error at startup rather than silently accepted or truncated.
- "Opaque" here means this spec assigns no meaning to a node ID beyond
  identity/uniqueness — it doesn't mean non-numeric. StruoDB's query
  language decodes it to its base-62 integer value for storage in
  `_struo_hlc_node_id INTEGER` ([Schema Definition §9.2](/struoql/ddl-spec#_9-2-the-automatic-system-columns)); decoding a
  base-62 string to an integer is well-defined and reversible regardless
  of what the digits are taken to mean.

## Non-goals / accepted limitations

- No detection of duplicate node IDs across nodes.
- No special-case handling of the system clock moving backward beyond what
  falls out of the algorithm above (time never moves backward in the
  clock's own state, by construction of `max`/`p > t` above).
- No support for a custom epoch — always milliseconds since the Unix epoch.
- The physical component may run ahead of true wall-clock time indefinitely
  under sustained per-millisecond overflow (see rollover). It self-corrects
  as soon as real time catches back up. This is inherent to how HLCs stay
  monotonic and is intentional.
- The counter's 2-character width caps it at 3,843 `next()`/`merge()`
  calls per node per millisecond before rollover kicks in — chosen to keep
  the whole value at 15 characters (fitting a PostgreSQL `char(15)` column
  exactly), trading away the much larger 238,327/ms headroom a 3-character
  counter would give. A node sustaining more than ~3.8M `next()` calls/sec
  will drift its physical component ahead of real time (see above) instead
  of erroring; this is expected, not a defect, but is worth knowing before
  picking this encoding for a very high-throughput single node.

## Reference material

An earlier, unrelated project contains a structurally similar TypeScript
HLC (`src/util/hlc.ts` in this repo, kept only as inspiration). It differs
from this spec in several material ways — hexadecimal instead of base 62,
a 3-character node ID instead of 5, a custom epoch, and no rollover
handling (it throws on counter overflow) — and should not be treated as
a reference implementation to port; this spec supersedes it for this
project.
