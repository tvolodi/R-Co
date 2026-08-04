# Module: iss-201-transition-result

**Requirement:** ISS-201 -- Make `transition()` return `{state, emitted_events}`
**Type:** E (novel/cross-cutting engine change)
**Source:** EPIC-2 -- Event-sourcing integrity
**Status:** DESIGNED
**Date:** 2026-06-11

---

## Purpose

Currently `transition()` returns `InstanceState`, and `InstanceState` carries the
`pending_events: []PendingEvent` slice. The orchestrator reads
`new_state.pending_events` after every transition call to discover what
side-effects the engine decided on (timer rows, sub-process starts, parallel-split
stored as events). This couples the pure engine output to the persistence schema.

ISS-201 extracts the engine-emitted events into a first-class return field.
`transition()` returns a `TransitionResult` struct that separates:

- `state: InstanceState` -- the new state to persist (tokens, status, variables,
  join_counters, pending_task_nodes, error_detail, cancelled_branch_ids)
- `emitted_events: []PendingEvent` -- the events the engine decided the world
  should see

`InstanceState` no longer carries `pending_events`. It becomes a pure mirror
of what is stored in the database row.

**Foundational role:** ISS-202 (two-phase merge), ISS-203 (deterministic
idempotency keys), ISS-206 (token multiset), and ISS-207 (convergent retry)
all layer onto this interface. The separation must be correct now.

---

## 2. Public Interface

### 2.1 TransitionResult struct

```zig
/// Returned by transition(). Separates the persisted state projection from
/// the side-effect events the engine decided to emit.
///   state          — new state to write to instance_projections (no pending_events)
///   emitted_events — events decided by the engine; the orchestrator persists these
///                    atomically with the trigger in a single transaction
pub const TransitionResult = struct {
    state: InstanceState,
    emitted_events: []PendingEvent,
};
```

### 2.2 InstanceState (revised)

```zig
/// InstanceState no longer carries pending_events.  It is a pure mirror of the
/// instance_projections row: tokens, status, variables, join_counters,
/// pending_task_nodes, error_detail, cancelled_branch_ids.
pub const InstanceState = struct {
    instance_id: Uuid,
    status: InstanceStatus,
    tokens: []Token,
    variables: std.json.ObjectMap,
    join_counters: std.json.ObjectMap,
    pending_task_nodes: [][]const u8,
    error_detail: ?[]const u8,
    // REMOVED: pending_events: []PendingEvent
    cancelled_branch_ids: [][]const u8 = &[_][]const u8{},
};
```

### 2.3 transition() signature

```zig
pub fn transition(
    allocator: std.mem.Allocator,
    snapshot: graph_mod.DefinitionGraph,
    state: InstanceState,         // no longer carries pending_events
    event: TransitionEvent,
) TransitionError!TransitionResult;
```

**Contract:**
- The function performs ZERO I/O (unchanged -- pure function property is
  inviolable).
- It does NOT re-append the trigger event to `emitted_events`. The trigger
  (`event` parameter) is a `TransitionEvent` (input), not a `PendingEvent`
  (output). The orchestrator inserts the trigger event row itself.
- The returned `emitted_events` slice contains only new engine-initiated
  events: `parallel_split`, `parallel_join`, `instance_cancelled`,
  `timer_created`, `sub_process_start`.
- Replay of the same trigger against the same state must produce identical
  `emitted_events`. This follows from the pure-function contract --
  same inputs, same outputs.

---

## 3. Internal Function Changes

### 3.1 transition() body

The function body currently starts by building `new_state` as a full
`InstanceState` (line 180-190), which includes cloning `pending_events` from
the input state. With ISS-201 this changes:

**Before (line 180-190):**
```zig
var new_state = InstanceState{
    .instance_id = state.instance_id,
    .status = state.status,
    .tokens = ...,
    .variables = ...,
    .join_counters = ...,
    .pending_task_nodes = ...,
    .error_detail = null,
    .pending_events = try allocator.dupe(PendingEvent, state.pending_events),
    .cancelled_branch_ids = ...,
};
```

**After:**
```zig
var new_state = InstanceState{
    .instance_id = state.instance_id,
    .status = state.status,
    .tokens = ...,
    .variables = ...,
    .join_counters = ...,
    .pending_task_nodes = ...,
    .error_detail = null,
    .cancelled_branch_ids = ...,
};
// pending_events field removed from InstanceState
```

A new local accumulator carries emitted_events through the function body:

```zig
var emitted_events = std.ArrayList(PendingEvent).empty;
defer emitted_events.deinit(allocator);
```

At the end of `transition()`, the function wraps and returns:

```zig
return TransitionResult{
    .state = new_state,
    .emitted_events = try emitted_events.toOwnedSlice(allocator),
};
```

### 3.2 processNodeEntry() internal helper

`processNodeEntry()` (line 436) currently returns `TransitionError!InstanceState`.
It must be changed to accept and accumulate an `emitted_events` list, or
alternatively return `TransitionResult` internally. The simplest design:

- Pass an `*std.ArrayList(PendingEvent)` accumulator to `processNodeEntry()`.
- `processNodeEntry()` appends new events to the accumulator and returns
  `InstanceState` (state only).
- The outer `transition()` body wraps the final state + accumulator into
  `TransitionResult`.

**Decision:** Keep `processNodeEntry()` returning `InstanceState` with an
accumulator parameter. This minimises internal diff noise.

### 3.3 Sites where pending_events are currently built

The following locations in `transition.zig` currently build `pending_events`
via ArrayList accumulation:

| Line range | Code path | Event appended |
|---|---|---|
| ~526-541 | TIMER node entry | `timer_created` |
| ~564-578 | SUB_PROCESS node entry | `sub_process_start` |
| ~676-688 | PARALLEL_GATEWAY split (outgoing_count > 1) | `parallel_split` |
| ~748-757 | PARALLEL_GATEWAY join -- all branches cancelled | `instance_cancelled` |
| ~826-834 | PARALLEL_GATEWAY join -- fire | `parallel_join` |

Each of these currently:
1. Copies existing `state.pending_events` into a new ArrayList.
2. Appends the new event.
3. Sets `new_state.pending_events = new_pending_events.toOwnedSlice(allocator)`.

With ISS-201, each site instead appends directly to the shared accumulator
passed from `transition()`, and `new_state` no longer has a `pending_events`
field.

### 3.4 Idempotent early-return paths

Some code paths return `state` (no changes) or a modified state with the
same pending_events. These are unchanged except that `InstanceState` no longer
carries the field, so no action is needed at those sites.

---

## 4. Persistence Contract (Orchestrator -- instance.zig)

### 4.1 Two-part result

After `transition()` returns a `TransitionResult`:

1. **TransitionResult.state** -- this is the definitive new state. The
   orchestrator serialises it to `instance_projections` (status, tokens,
   variables, join_counters). `pending_events` is NOT in the DB row because
   it has been moved to the `emitted_events` side.

2. **TransitionResult.emitted_events** -- the orchestrator iterates these to
   perform the appropriate side-effect persistence:
   - `timer_created` -> insert into `timers`
   - `sub_process_start` -> `POST` to create child instance (which appends
     its own `instance_started` event)
   - `parallel_split`, `parallel_join`, `instance_cancelled` -> insert
     event rows with deterministic idempotency keys (ISS-203)

### 4.2 Atomic transaction contract

The trigger event row + all `emitted_events` + state update are committed in
a single PostgreSQL transaction. No partial write is possible:

```
BEGIN
  1. INSERT trigger event (with idempotency_key)
  2. UPDATE instance_projections (status, tokens, variables, join_counters)
  3. FOR EACH emitted_event:
       INSERT into timers / create sub-process instance / INSERT cascade event
  4. INSERT audit row (ISS-204 -- in same transaction)
COMMIT
```

If the transaction fails (any step), the entire state change rolls back.
This is already the current pattern; ISS-201 makes the data flow explicit.

### 4.3 JSON serialization contract

`InstanceState` serialized to `instance_projections` uses these JSON shapes:

- **active_tokens** (JSONB column): `[{"token_id":"<uuid>","node_id":"<str>","branch_id":"<hex>"}]`
  For waiting tokens: includes `"waiting_child_instance_id":"<uuid_hex>"`.
- **status** (TEXT column): uppercase `ACTIVE` | `COMPLETED` | `CANCELLED` | `ERROR`.
- **variables** (JSONB column): arbitrary JSON object (the process variable map).
- **join_counters** (JSONB column): `{"<join_node_id>":{"received_count":<u32>,"expected_from_branches":<u32>}}`.
- **error_detail** (JSONB column): NULL or the error payload JSON.

`pending_events` is NOT serialized to any column. It never was stored in
`instance_projections` directly (it was derived from event rows on replay).
The `pending_events` field that lived on `InstanceState` was an in-memory
transient for the orchestrator; ISS-201 makes this explicit by moving it to
`TransitionResult.emitted_events`.

---

## 5. Call Site Impact

### 5.1 src/engine/transition.zig

| Change | Description |
|---|---|
| Add `TransitionResult` struct | New public type (see section 2.1) |
| Remove `pending_events` from `InstanceState` | Field deletion |
| Change `transition()` return type | `TransitionError!InstanceState` -> `TransitionError!TransitionResult` |
| Add `emitted_events` accumulator | `std.ArrayList(PendingEvent)` local in `transition()` body |
| Pass accumulator to `processNodeEntry()` | New parameter `events: *std.ArrayList(PendingEvent)` |
| Update all 5 event-building sites | Append to accumulator instead of setting `new_state.pending_events` (lines ~526-541, ~564-578, ~676-688, ~748-757, ~826-834) |
| Update all unit tests in the file | Tests at lines ~1090-1801 must destructure `TransitionResult` and reference `.state` + `.emitted_events` |
| Remove all `pending_events` field init in test state literals | ~40 occurrences of `pending_events: &[_]PendingEvent{}` in test blocks; these go away as `InstanceState` no longer carries the field |

### 5.2 src/engine/instance.zig

| Line(s) | Function | Change |
|---|---|---|
| 669-678 | `create()` -- initial state literal | Remove `pending_events: &.{}` from `InstanceState` literal |
| 689-694 | `create()` -- transition() call | Destructure: `const result = try transition(...);` then use `result.state`, `result.emitted_events` |
| 695 | `create()` -- defer free | `freeOwnedTransitionState(allocator, result)` instead of `freeOwnedTransitionState(allocator, new_state)` |
| 696-700+ | `create()` -- state serialization | References to `new_state.tokens`, `new_state.variables`, etc. become `result.state.tokens`, `result.state.variables`, etc. |
| 1023-1028 | `applyEvent()` -- persist timers | `persistTimersFromPendingEventsInTx(allocator, conn, instance_id, result.emitted_events)` instead of reading from `new_state.pending_events` |
| 888-889 | `applyEvent()` -- transition() call | Destructure `TransitionResult` |
| 1525 | `handleTaskCompleted()` -- transition() call | Destructure `TransitionResult` |
| 1747-1751 | `handleTaskCompleted()` -- persist timers | Reference `result.emitted_events` |
| 2984 | `completeTask()` -- inline transition | Destructure `TransitionResult` |
| 3091 | `completeTask()` -- inline transition | Destructure `TransitionResult` |
| 392-423 | `freeOwnedTransitionState()` | New signature: accepts `TransitionResult`, frees both state sub-fields AND `emitted_events` array (see section 6) |
| 3580-3617 | `persistTimersFromPendingEventsInTx()` | Parameter changes from `pending_events: []const transition_mod.PendingEvent` to receive the slice from `emitted_events` instead of from `state.pending_events` (no signature change if the parameter stays the same type -- it just reads from a different source) |
| 3661-3700+ | `startSubProcessesForPendingEventsInTx()` | Accepts `emitted_events` slice instead of reading `state.pending_events`. The `state` parameter is now clean (no pending_events field). |
| 3671 | `startSubProcessesForPendingEventsInTx()` loop | `for (state.pending_events)` becomes `for (emitted_events)` |
| 1371 | `handleTaskCompleted()` -- state literal | Remove `pending_events` field |
| 1512 | `handleTaskCompleted()` -- current_state copy | Remove `pending_events` reference |

### 5.3 src/engine/reconstruction.zig

| Line(s) | Function | Change |
|---|---|---|
| 174-183 | `reconstructInstance()` -- initial state literal | Remove `pending_events: &[_]PendingEvent{}` from `InstanceState` literal |
| 186-211 | `reconstructInstance()` -- replay loop | `state = (try transition_mod.transition(...)).state` -- destructure TransitionResult, discard `emitted_events` during replay (they were already persisted as event rows) |
| 217 | `reconstructInstance()` -- reset | `state.pending_events = ...` line deleted; `InstanceState` no longer has this field |
| 294-302 | `reconstructInstancePointInTime()` -- initial state | Remove `pending_events: &[_]PendingEvent{}` from literal |
| 322 | `reconstructInstancePointInTime()` -- replay loop | Destructure: `state = (try transition_mod.transition(...)).state` |
| 326 | `reconstructInstancePointInTime()` -- reset | `state.pending_events = ...` line deleted |

**Replay behaviour:** During replay, the emitted_events from each transition
are discarded. They were already persisted as event rows in the log. The
replay loop only needs to rebuild the state projection. Discarding
`emitted_events` during replay is correct and intentional.

### 5.4 Unit test files

| File | Change |
|---|---|
| `tests/unit/test_engine_ee05.zig` | 6 calls to `transition()` -- each must destructure `TransitionResult` and access `.state.tokens`, `.state.pending_task_nodes`, etc. Tests that check `pending_events` on the returned state must now check `.emitted_events` instead. All `InstanceState` literals remove `pending_events` field. |
| `tests/unit/test_engine_apply.zig` | 5 calls to `transition()` -- same pattern. |
| `tests/unit/test_ee07_parallel_join.zig` | 3 calls to `transition()` -- tests checking `result.pending_events` must change to `result.emitted_events`. |
| `tests/unit/service_task_test.zig` | 1 call to `transition()` -- destructure `TransitionResult`. |

All unit test files build their `InstanceState` literals without `pending_events`
(because the field no longer exists).

---

## 6. freeOwnedTransitionState()

### 6.1 New signature

```zig
fn freeOwnedTransitionState(
    allocator: std.mem.Allocator,
    result: transition_mod.TransitionResult,
) void {
    // Free state sub-fields (same as today's logic)
    for (result.state.tokens) |tok| {
        if (tok.token_id) |tid| allocator.free(tid);
        allocator.free(tok.node_id);
        allocator.free(tok.branch_id);
        if (tok.waiting_child_instance_id) |child_id| {
            allocator.free(child_id);
        }
    }
    allocator.free(result.state.tokens);

    var vars = result.state.variables;
    vars.deinit(allocator);

    var jc = result.state.join_counters;
    jc.deinit(allocator);

    for (result.state.pending_task_nodes) |node_id| {
        allocator.free(node_id);
    }
    allocator.free(result.state.pending_task_nodes);

    if (result.state.error_detail) |detail| {
        allocator.free(detail);
    }

    allocator.free(result.state.cancelled_branch_ids);

    // NEW: free emitted_events array
    allocator.free(result.emitted_events);
}
```

### 6.2 What changed

- Accepts `TransitionResult` instead of `InstanceState`.
- The old `allocator.free(state.pending_events)` line is replaced by
  `allocator.free(result.emitted_events)`.
- The old `allocator.free(state.cancelled_branch_ids)` line stays because
  `cancelled_branch_ids` remains on `InstanceState`.
- All sub-field access goes through `result.state.*`.

### 6.3 Callers

Only one file calls `freeOwnedTransitionState`: `instance.zig` at line 695
(in `create()`). The call becomes `freeOwnedTransitionState(allocator, result)`.

---

## 7. Test Implications

### 7.1 Existing tests -- destructuring

Every test that calls `transition()` must change from:

```zig
const new_state = try transition(allocator, snapshot, state, event);
try std.testing.expect(new_state.tokens.len == 2);
try std.testing.expect(new_state.pending_events.len == 1);
```

to:

```zig
const result = try transition(allocator, snapshot, state, event);
try std.testing.expect(result.state.tokens.len == 2);
try std.testing.expect(result.emitted_events.len == 1);
```

### 7.2 Existing tests -- InstanceState literals

Every test that builds an `InstanceState` literal must remove the
`pending_events` field. Approximate count: ~40 occurrences across
`transition.zig` test blocks and the four unit test files.

### 7.3 New tests required

| Test ID | Description |
|---|---|
| TC-ISS-201-01 | Timer entry emits exactly one `timer_created` event with correct `timer_node_id` and `duration_iso8601` |
| TC-ISS-201-02 | Parallel split emits exactly one `parallel_split` event with correct `token_ids` and `target_node_ids` |
| TC-ISS-201-03 | Parallel join (fire) emits exactly one `parallel_join` event with correct `branch_ids_arrived` |
| TC-ISS-201-04 | Parallel join (all cancelled) emits exactly one `instance_cancelled` event with reason `ALL_BRANCHES_CANCELLED` |
| TC-ISS-201-05 | Sub-process entry emits exactly one `sub_process_start` event with correct `child_definition_id` |
| TC-ISS-201-06 | HUMAN_TASK entry emits zero events (emitted_events is empty) |
| TC-ISS-201-07 | END node entry emits zero events (emitted_events is empty) |
| TC-ISS-201-08 | Simple sequential step (START -> HUMAN_TASK -> END) throughout: check emitted_events per transition step |
| TC-ISS-201-09 | Replay produces identical emitted_events for the same trigger/state (determinism) |

These tests are already partially covered by the embedded test cases in
`transition.zig` (lines ~1090-1801), which currently assert `result.pending_events.len`
and content. Those assertions map directly to `result.emitted_events`.

### 7.4 Integration test

| Test ID | Description |
|---|---|
| TC-ISS-201-IT-01 | Trigger event + emitted_events committed atomically in one transaction. Start an instance with a TIMER node; verify both the `instance_started` event row and the timer row appear (or neither does on rollback). |

---

## 8. Error Taxonomy

No new error types are introduced. The existing `TransitionError` set is
sufficient:

```zig
pub const TransitionError = error{
    UnknownEventType,          // Trigger event tag is .unknown
    TokenOnMissingNode,        // A token references a node_id not in the graph
    NoMatchingEdge,            // Gateway evaluation produced no matching edge
    CelEvaluationError,        // CEL condition evaluation failed
    TransformResultNonObject,  // Edge transform result is not a JSON object
    InvalidState,              // State invariant violated (e.g. tokens + terminal status)
    OutOfMemory,               // Allocation failed
};
```

None of these errors change behaviour or meaning. The only difference is
that the error is now returned alongside a `TransitionResult` concept rather
than an `InstanceState` alone.

---

## 9. Key Invariants

1. **Pure function** -- `transition()` performs zero I/O. No database calls,
   no logging, no clock reads, no randomness. This invariant is unchanged.

2. **Trigger not re-appended** -- The `event` parameter (TransitionEvent,
   e.g. `task_completed`) is the input command; it is NOT returned in
   `emitted_events`. The orchestrator persists the trigger event as an event
   row itself. `emitted_events` contains only new engine-initiated events
   (PendingEvent variants).

3. **Deterministic replay** -- Given the same inputs (snapshot, state, event),
   `transition()` produces identical `TransitionResult`. This follows from
   the existing pure-function guarantee. No new sources of nondeterminism
   are introduced.

4. **Atomic persistence** -- The trigger event row, all emitted_events, and
   the state update are committed in a single PostgreSQL transaction. No
   partial write can occur.

5. **Replay discards emitted_events** -- During reconstruction, emitted_events
   are discarded because they were already persisted as event rows. The replay
   loop only needs the state projection.

6. **Memory ownership** -- `TransitionResult.state` and `TransitionResult.emitted_events`
   are both owned by the caller (allocated with the allocator passed to
   `transition()`). `freeOwnedTransitionState()` frees both.

---

## 9. External Dependencies

| Dependency | Type | Notes |
|---|---|---|
| `graph_mod.DefinitionGraph` | Input parameter | Unchanged |
| `graph_mod.NodeType` | Type dependency | Unchanged |
| `std.mem.Allocator` | Memory | Unchanged -- all allocations via caller's allocator |
| `std.json.ObjectMap` | Type dependency | Unchanged -- stored in `InstanceState.variables` and `join_counters` |

No new external dependencies, no new DB tables or columns, no new migrations.

---

## 10. Migration Path

No database migration is required. This is a pure code refactoring:

1. The `instance_projections` table does not store `pending_events`.
2. The `events` table is unchanged.
3. The change is entirely in the in-memory data flow: `transition()` output
   shape and the orchestrator's consumption of it.

---

## 11. Open Questions

None. The design is complete and unambiguous. All acceptance criteria from
ISS-201 are covered:

- [x] Signature returns `TransitionResult{ state, emitted_events: []Event }`
- [x] Engine remains pure -- no I/O, trigger not re-appended
- [x] All call sites listed with file+line references
- [x] `freeOwnedTransitionState()` signature documented
- [x] Atomic persistence contract documented
- [x] Test implications covered -- existing tests update path + new test IDs
