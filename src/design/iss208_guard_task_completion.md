# Module: ISS-208 — Guard Task Completion Against Terminal Instances

**Requirement:** ISS-208 · EPIC-2  
**Design date:** 2026-06-11  
**Touchpoints:** `src/tasks/store.zig`, `src/api/routes/tasks.zig`

---

## Module Purpose

Guard the `completeTask` path against concurrent or post-hoc completion attempts on instances
that are no longer `ACTIVE`. The guard is enforced inside the DB transaction to prevent a race
between task completion and instance cancellation/error.

---

## Error Taxonomy

| Error | HTTP | Cause |
|---|---|---|
| `TaskNotFound` | 404 | `task_id` not found in `tasks` |
| `TaskAlreadyTerminated` | 409 | Task status ≠ `PENDING` |
| `InstanceNotActive` | 409 | Parent instance status is not `ACTIVE` (locked inside tx) |
| `InstanceInError` | 409 | Parent instance is in `ERROR` status |
| `ConcurrentModification` | 409 | Row lock contention (NOWAIT fired SQLSTATE 55P03) |
| `InvalidInput` | 422 | `output_variables_json` not a JSON object |
| `PoolExhausted` | 503 | `pool.acquire()` failed |
| `PersistenceFailed` | 500 | Any DB write failure |
| `OutOfMemory` | 500 | Allocator returned `OutOfMemory` |

---

## Background

A task completion (`POST /tasks/:id/complete`) could currently succeed even when the parent
instance is in a terminal state (`ERROR`, `CANCELLED`, or `COMPLETED`). This design adds a
race-safe guard inside the `completeTask` transaction so that no state changes are persisted
when the instance is not `ACTIVE`.

---

## Public interface

```
// Existing function; new error variant added
pub fn completeTask(
    self: *InstanceStore,
    allocator: std.mem.Allocator,
    task_store: *task_mod.TaskStore,
    task_id: task_mod.Uuid,
    output_variables_json: []const u8,
) CompleteTaskError!transition_mod.InstanceState

// New error variant added to CompleteTaskError:
//   InstanceNotActive  — instance status is not ACTIVE; HTTP 409
```

---

## Data types

```
// Addition to the existing CompleteTaskError set in src/engine/instance.zig:
pub const CompleteTaskError = error{
    // ... existing variants ...
    /// Parent instance is not ACTIVE (CANCELLED / COMPLETED / ERROR).
    /// Enforced inside the transaction via SELECT FOR UPDATE. HTTP 409.
    InstanceNotActive,
};
```

---

## Key invariants

1. **Transactional enforcement:** The instance status check is performed INSIDE the open DB
   transaction using `SELECT instance_id, status FROM instance_projections WHERE instance_id=$1
   FOR UPDATE`. The `FOR UPDATE` row lock prevents a concurrent `cancelInstance` from
   changing the status between the read and the subsequent event write. A pre-check outside the
   transaction is insufficient because the window between the read and the first write is a
   race.

2. **Placement in the write path:** The `SELECT ... FOR UPDATE` check MUST occur before any
   event is appended, before `completeInTx` updates the task row, and before any
   `instance_projections` update. If the locked status is not `ACTIVE`, the function MUST
   ROLLBACK (via `errdefer`) and return `InstanceNotActive` (HTTP 409) with no side effects.

3. **Existing guard preserved:** The existing `FOR UPDATE NOWAIT` lock that catches
   `ConcurrentModification` is a separate concern and MUST remain. The new guard replaces the
   pre-transaction status read that was already present (Step c in the existing algorithm) with
   an in-transaction version.

4. **No events on rejection:** When `InstanceNotActive` is returned, the event log MUST
   contain zero new rows for this instance. The task row MUST remain in its previous status.
   The instance projection MUST be unchanged.

5. **HTTP mapping:** `InstanceNotActive` → HTTP 409 Conflict with body:
   `{ "type": "urn:bpm:error:instance-not-active",
     "title": "Instance is not active",
     "detail": "Task completion is not allowed: the parent instance is not in ACTIVE status." }`.

---

## Algorithm

The existing `completeTask` algorithm (Steps a–n in `src/engine/instance.zig`) is unchanged
except for **Step f**:

**Modified Step f — BEGIN transaction; SELECT FOR UPDATE; status guard:**

1. Acquire connection, `BEGIN`.
2. `SELECT instance_id, status FROM instance_projections WHERE instance_id = $1 FOR UPDATE`
   (uses the regular blocking lock, not NOWAIT — this is the guard lock, not the concurrency
   detection lock; NOWAIT is retained on the separate lock already present).
3. If the locked row status is not `ACTIVE`:
   - `ROLLBACK` (via `errdefer`).
   - Return `InstanceNotActive` (HTTP 409).
4. Proceed with the existing merge, transition, and write steps.

The change is minimal: one additional SQL query inside the existing transaction, a status
check, and a new error path. All other steps remain identical.

---

## External dependencies

- `instance_projections` table — `SELECT ... FOR UPDATE` on `(instance_id, status)`
- `tasks` table — `completeInTx` still updates it in the same transaction
- `events` table — event INSERT still happens in the same transaction, after the guard passes

---

## Open questions

- None. Design is straightforward; all edge cases covered by acceptance criteria.
