# Module: iss203_idempotency_keys

**Covers:** ISS-203 — Deterministic idempotency keys for engine-emitted cascade events  
**Depends on:** ISS-201 (COMPLETED) — `transition()` returns `TransitionResult{state, emitted_events}`  
**Files affected:** `src/engine/transition.zig`, `src/event_store/store.zig`

---

## Overview

When `transition()` fires it returns a slice of `PendingEvent` values representing side effects
the engine decided on (parallel splits, timer creations, sub-process starts, etc.). The
orchestrator persists each of these into the event store in the same transaction as the
triggering event. Without stable, deterministic keys on those emitted events, a retry of the
whole orchestrator step would insert duplicate rows.

ISS-203 adds a hash-based idempotency key to every engine-emitted cascade event. Client-supplied
trigger-event keys are left completely untouched — the scheme applies only to events that
originate inside `transition()`.

---

## 1. Hash function choice

**Selected function: FNV-1a (64-bit)**

Rationale:

- FNV-1a is a non-cryptographic hash that produces a deterministic, collision-resistant output
  for the input domain we are hashing (fixed-width UUID bytes + a small integer sequence + two
  short ASCII strings). The probability of a collision within a single instance's event set is
  negligible.
- It requires no external library. Zig's standard library does not ship a general-purpose
  non-cryptographic hash at the time of writing, but FNV-1a is a handful of lines of pure
  integer arithmetic that a single internal helper can implement without any I/O, heap
  allocation, or syscall — keeping `transition.zig` I/O-free.
- BLAKE3 and SHA-256 both produce longer, cryptographically strong digests. That strength is
  unnecessary here: the key's purpose is deduplication against a UNIQUE DB constraint, not
  security. The extra width bloats the index and the `idempotency_key` column without benefit.
- FNV-1a's output is a `u64`, which is serialised to a 16-character lowercase hex string and
  prefixed with `"engine:"` to namespace it away from client-supplied keys. The resulting string
  is at most 23 characters — well within the existing 255-char column limit.

The hash is computed by feeding the following fields in order, with each field separated by a
fixed sentinel byte (`0x00`) to prevent length-extension confusion between field boundaries:

```
field 1: instance_id bytes (raw 16 bytes)
field 2: triggering_event_seq (big-endian u64)
field 3: node_id (UTF-8 bytes)
field 4: emitted_event_type (UTF-8 bytes)
field 5: ordinal (big-endian u64)
```

The `ordinal` is the 0-based index of this emitted event within the `emitted_events` slice
returned by the single `transition()` call that produced it.

---

## 2. Where key computation happens

Key computation happens inside `transition.zig`, after all emitted events have been accumulated
in the internal `emitted_events: ArrayList(PendingEvent)` and before `toOwnedSlice` converts
that list into the final `[]PendingEvent` in `TransitionResult`.

**The pure-function rule remains inviolable.** Key computation is pure arithmetic on the inputs
already present in the function: `state.instance_id`, the caller-supplied
`triggering_event_seq`, the event's own `node_id` and type tag, and the loop index. No I/O,
no clock call, no randomness, no allocator beyond the one already accepted as a parameter.

The caller (orchestrator in `src/engine/instance.zig` or wherever `transition()` is invoked)
supplies `triggering_event_seq` as part of the call — this is the `sequence_number` of the
event that triggered this transition, read from the event store before calling `transition()`.

Because `transition.zig` does not read from or write to the DB, it cannot look up
`sequence_number` itself. The orchestrator reads the triggering event's `sequence_number` from
the `AppendResult` returned by the event store's `append()` and passes it into the transition
call site.

### Change to the `transition()` signature

A new parameter `triggering_event_seq: i64` is added to `transition()`:

```zig
pub fn transition(
    allocator:            std.mem.Allocator,
    snapshot:             graph_mod.DefinitionGraph,
    state:                InstanceState,
    event:                TransitionEvent,
    triggering_event_seq: i64,
) TransitionError!TransitionResult
```

All existing callers are updated to pass the sequence number. For the initial `instance_started`
event this value is `1` (the first sequence number assigned by the event store).

---

## 3. The `Event` struct field that carries the key

`PendingEvent` is currently a tagged union. To carry the computed key, a wrapper struct is
introduced:

```zig
pub const EmittedEvent = struct {
    /// The engine-computed deterministic key.
    /// Format: "engine:<16-hex-digits>"
    /// Never null for events produced by transition(); always null for trigger events
    /// whose key is supplied by the client.
    idempotency_key: []const u8,
    /// The payload of the emitted effect.
    payload: PendingEvent,
};
```

`TransitionResult.emitted_events` changes type from `[]PendingEvent` to `[]EmittedEvent`:

```zig
pub const TransitionResult = struct {
    state:          InstanceState,
    emitted_events: []EmittedEvent,
};
```

The `idempotency_key` string is allocated from the arena/allocator passed to `transition()` and
lives for the same lifetime as the rest of the `TransitionResult`. The orchestrator must not
free it independently; freeing the arena that backed the `transition()` call is sufficient.

The key string format is `"engine:" ++ hex_string_of_fnv1a_u64`, e.g.:
`"engine:3b8a4f291c7de802"`.

---

## 4. The INSERT path in `event_store/store.zig`

No change is required to the SQL in the existing `append()` path. The `events` table already
has `ON CONFLICT (idempotency_key) DO NOTHING` in the INSERT statement, and the `idempotency_key`
column already carries a UNIQUE constraint (enforced by the migration at `migrations/001_event_store.sql`).

The orchestrator calls `store.append()` for each element of `emitted_events`, passing
`EmittedEvent.idempotency_key` as `AppendParams.idempotency_key`.

Behaviour on conflict:

- The INSERT returns zero rows (RETURNING yields nothing).
- The store detects this and returns `AppendResult{ .record = ..., .is_duplicate = true }`.
- The orchestrator treats `is_duplicate = true` as a no-op and continues to the next emitted
  event — it does not abort the transaction or return an error to the API caller.

This means re-running the same orchestrator step (e.g., after a crash between the event commit
and the ACK) will silently skip already-persisted emitted events and complete cleanly.

The archive path (`events_archive`) already participates in duplicate detection via Invariant #5
of the event store design: if `ON CONFLICT` returns no rows, the store checks both `events`
and `events_archive` before returning `is_duplicate`. Engine-keyed events are covered by this
invariant with no additional changes.

---

## 5. Client-supplied trigger keys: pass-through unchanged

Client-supplied keys arrive on the triggering event (the `POST /events` or `POST /instances/:id/trigger`
API call). The trigger event is persisted by the orchestrator **before** calling `transition()`.
The key on the trigger event is set by the HTTP handler from the `idempotency_key` field in the
request body or header; it is never derived by the engine.

`transition()` receives the triggering event via the `TransitionEvent` union, which carries
content but not the storage-layer `idempotency_key`. The engine never sees, touches, or
re-derives the trigger key. There is no path in `transition.zig` that could overwrite or
inspect a client-supplied key.

The computed `idempotency_key` on `EmittedEvent` is populated only for entries in
`TransitionResult.emitted_events`. These are always cascade events (not the trigger). The
trigger's key is already committed before `transition()` is called. Therefore, client-supplied
command keys are structurally excluded from the key-computation path.

---

## 6. Replay determinism invariant

**Invariant R-1 (Replay Idempotency):** Given the same `(instance_id, triggering_event_seq,
graph snapshot, instance state)` inputs, two calls to `transition()` produce identical
`emitted_events` slices with identical `idempotency_key` values in identical order.

This invariant holds because:

1. FNV-1a is a pure deterministic function.
2. The five hash inputs (`instance_id`, `triggering_event_seq`, `node_id`, event type tag,
   `ordinal`) are all derived from the fixed inputs to `transition()`. None depends on wall
   clock, randomness, or DB reads.
3. The `ordinal` for each event is its stable 0-based index in the `emitted_events` ArrayList
   as constructed by `processNodeEntry`. Event ordering within a single `transition()` call is
   deterministic because it is driven by the graph definition and the token set — both of which
   are fixed inputs.
4. The hash is computed after the full event list is assembled, iterating over it in index
   order, so ordinals are stable even if internal processing appended events non-monotonically.

**Consequence for the event store:** If the orchestrator persists the trigger event and then
crashes before persisting all emitted events, it can re-call `transition()` with the same
inputs, produce the same `EmittedEvent` list, and call `store.append()` for each. Events
already in the store will return `is_duplicate = true` and be silently skipped. Events not yet
persisted will be inserted. The final state of the store is identical regardless of how many
times the step is retried.

---

## 7. Error taxonomy

These error variants are additive to the existing `TransitionError` set in `transition.zig`.
No existing variants are removed.

```zig
pub const TransitionError = error{
    // ... existing variants ...
    UnknownEventType,
    TokenOnMissingNode,
    NoMatchingEdge,
    CelEvaluationError,
    TransformResultNonObject,
    InvalidState,
    OutOfMemory,
    // New variant added by ISS-203:
    /// The triggering_event_seq parameter is <= 0, which would produce a
    /// non-unique key for the degenerate sequence. Callers must supply the
    /// actual sequence number assigned by the event store.
    InvalidTriggeringSeq,
};
```

`InvalidTriggeringSeq` is returned if `triggering_event_seq <= 0`. This prevents a caller from
accidentally passing an uninitialised integer (`0`) and generating keys that collide across
different transitions that happened to all receive sequence `0`.

No new error variants are required in `StoreError`. The existing `IdempotencyKeyMissing` and
`IdempotencyKeyTooLong` errors already cover malformed keys, but engine-generated keys are
always well-formed (23 characters, non-empty).

---

## 8. Public function signatures affected

### `src/engine/transition.zig`

**`transition()`** — one new parameter added:

```zig
pub fn transition(
    allocator:            std.mem.Allocator,
    snapshot:             graph_mod.DefinitionGraph,
    state:                InstanceState,
    event:                TransitionEvent,
    triggering_event_seq: i64,
) TransitionError!TransitionResult
```

**`TransitionResult`** — `emitted_events` field type changes:

```zig
pub const TransitionResult = struct {
    state:          InstanceState,
    emitted_events: []EmittedEvent,   // was []PendingEvent
};
```

**New type `EmittedEvent`**:

```zig
pub const EmittedEvent = struct {
    idempotency_key: []const u8,
    payload:         PendingEvent,
};
```

**New error variant in `TransitionError`**:

```zig
InvalidTriggeringSeq,
```

**New internal helper** (private, not exported):

```zig
fn computeEmittedEventKey(
    allocator:            std.mem.Allocator,
    instance_id:          Uuid,
    triggering_event_seq: i64,
    node_id:              []const u8,
    event_type_tag:       []const u8,
    ordinal:              usize,
) error{OutOfMemory}![]u8
```

Returns a heap-allocated string of the form `"engine:<16-hex-digits>"`. The string is owned by
the caller (allocated from the `allocator` parameter).

### `src/event_store/store.zig`

No signature changes. `AppendParams.idempotency_key` continues to accept any string that
satisfies the existing 1..255-char constraint. The orchestrator's call site sets this field to
`EmittedEvent.idempotency_key` when appending cascade events.

### Orchestrator call sites (`src/engine/instance.zig` or equivalent)

Wherever `transition()` is called, the caller must:

1. Before calling `transition()`: call `store.append()` with the trigger event and capture the
   resulting `AppendResult.record.sequence_number`.
2. Pass that `sequence_number` as `triggering_event_seq` to `transition()`.
3. For each `EmittedEvent e` in `result.emitted_events`: call `store.append()` with
   `params.idempotency_key = e.idempotency_key`.

The orchestrator function signature itself does not change in a publicly visible way; the
changes are internal to the call body.

---

## Key invariants

| # | Invariant |
|---|---|
| K-1 | `EmittedEvent.idempotency_key` is always non-empty and at most 23 characters. |
| K-2 | The key is derived solely from `(instance_id, triggering_event_seq, node_id, event_type_tag, ordinal)` — no wall clock, no randomness, no DB reads inside `transition()`. |
| K-3 | Two calls to `transition()` with identical inputs produce byte-equal `idempotency_key` values for every emitted event at every ordinal. |
| K-4 | Client-supplied idempotency keys on trigger events are never overwritten, inspected, or re-derived by the engine. |
| K-5 | `triggering_event_seq <= 0` is rejected immediately with `TransitionError.InvalidTriggeringSeq`. |
| K-6 | `ON CONFLICT (idempotency_key) DO NOTHING` in the event store silently deduplicates replay — no error is surfaced to the API caller. |

---

## External dependencies

| Dependency | Kind |
|---|---|
| `src/engine/transition.zig` | Modified — new parameter, new return type field |
| `src/event_store/store.zig` | Read-only at design time; `append()` called by orchestrator |
| `migrations/001_event_store.sql` | Existing UNIQUE on `events(idempotency_key)` — no migration needed |
| `src/engine/instance.zig` (or equivalent orchestrator) | Call sites updated |

No new DB columns, no new migrations, no new tables.

---

## Open questions

None. All design choices are resolved above.
