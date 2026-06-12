# Module: ISS-207 — Convergent EXECUTION_ERROR Retry

**Requirement:** ISS-207 · EPIC-2  
**Design date:** 2026-06-11  
**Touchpoints:** `src/engine/instance.zig`, `src/dlq/store.zig`, `src/api/routes/dlq.zig`

---

## Module Purpose

Provide convergent resolution paths for process instances in `ERROR` status. Re-presenting the
identical triggering event to a deterministic engine reproduces the identical error with no
progress. This module guards bare retries (requiring a changed cause) and provides
retry-with-input and discard as the other two resolution paths.

---

## Error Taxonomy

| Error | HTTP | Cause |
|---|---|---|
| `ItemNotFound` | 404 | DLQ row absent |
| `InstanceNotFound` | 404 | `instance_id` FK missing from projections |
| `InstanceNotInError` | 409 | Instance status is not `ERROR` |
| `RetryWithoutChange` | 409 | Definition version and correction events unchanged since error |
| `InvalidInput` | 422 | `corrected_payload_json` not a valid JSON object |
| `PoolExhausted` | 503 | `pool.acquire()` failed |
| `PersistenceFailed` | 500 | Any DB write failure |
| `OutOfMemory` | 500 | Allocator returned `OutOfMemory` |

---

## Background

When a process instance reaches status `ERROR`, the engine has recorded an `EXECUTION_ERROR`
event whose root cause is deterministic: re-presenting the identical triggering event to the
same definition version will reproduce the identical error with no progress. Three resolution
paths are therefore defined:

1. **retry** — allowed only when the cause has changed (new definition version promoted after
   the error, or an authorised correction event recorded). Bare no-op retry rejected with 409
   + descriptive hint.
2. **retry-with-input** — operator supplies a corrected payload; the original trigger is
   re-presented with the new input so the engine can re-evaluate.
3. **discard** — operator accepts the error; instance is moved to `CANCELLED` and the DLQ item
   is marked `DISCARDED`.

---

## Public interface

```
// DLQ store additions
pub fn retryConvergent(
    allocator: std.mem.Allocator,
    pool: *Pool,
    instance_store: *InstanceStore,
    actor_id: []const u8,
    dlq_id: []const u8,
) DlqRetryError!RetryConvergentResult

pub fn retryWithInput(
    allocator: std.mem.Allocator,
    pool: *Pool,
    instance_store: *InstanceStore,
    actor_id: []const u8,
    dlq_id: []const u8,
    corrected_payload_json: []const u8,
) DlqRetryError!RetryConvergentResult

pub fn discardItem(
    allocator: std.mem.Allocator,
    pool: *Pool,
    actor_id: []const u8,
    dlq_id: []const u8,
) DlqDiscardError!void

// HTTP routes (POST)
// POST /api/v1/dlq/:item_id/retry
// POST /api/v1/dlq/:item_id/retry-with-input   body: { "payload": {...} }
// POST /api/v1/dlq/:item_id/discard
```

---

## Data types

```
pub const DlqRetryError = error{
    ItemNotFound,           // DLQ row absent → 404
    InstanceNotFound,       // instance_id FK missing → 404
    InstanceNotInError,     // instance status is not ERROR → 409
    RetryWithoutChange,     // cause unchanged (same def version, no correction event) → 409
    InvalidInput,           // corrected_payload_json not a JSON object → 422
    PoolExhausted,          // pool.acquire() failed → 503
    PersistenceFailed,      // any DB write failure → 500
    OutOfMemory,
};

pub const DlqDiscardError = error{
    ItemNotFound,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

pub const RetryConvergentResult = struct {
    dlq_id: []u8,             // allocator-owned
    instance_id: []u8,        // allocator-owned
    new_status: []u8,         // "ACTIVE" on success, allocator-owned
};
```

---

## Key invariants

1. **Changed-cause requirement for bare retry:** Before allowing retry, the handler MUST check
   whether the definition version recorded on the instance (`instance_projections.definition_artifact_hash`)
   differs from the currently-promoted version of that definition, OR whether an event of type
   `EXECUTION_CORRECTION` exists in the instance event log authored by an authorised operator.
   If neither condition holds, return `RetryWithoutChange` (HTTP 409) with a hint message such
   as: `"Instance has not changed since the error; promote a new definition version or submit a
   correction event before retrying."`.

2. **retry-with-input input validation:** `corrected_payload_json` MUST be a valid JSON object
   (not null, not array, not scalar). If invalid, return `InvalidInput` (HTTP 422) before
   touching the database.

3. **retry-with-input engine call:** Load the instance projection and snapshot. Build a
   `TransitionEvent.instance_started` or the appropriate trigger event with the corrected
   payload substituted for the original `original_payload` field from the DLQ item. Call
   `instance_store.applyTransition()` with the corrected event. If transition succeeds, update
   the instance status to `ACTIVE`, delete the DLQ row, and return success.

4. **discard atomicity:** The discard operation MUST execute in a single DB transaction:
   a) `UPDATE instances SET status='CANCELLED', cancelled_at=NOW() WHERE instance_id=$1`;
   b) `INSERT INTO dead_letter_items (dlq_id, instance_id, resolution='DISCARDED', discarded_at=NOW())`;
   c) `DELETE FROM dead_letter_queue WHERE id=$1`.
   If any step fails, ROLLBACK.

5. **No I/O inside transition():** All engine calls happen in the handler layer. The pure
   function receives data; it never reads from or writes to the DB.

6. **Security:** All SQL values bound as `$N` positional parameters. No string interpolation
   of user-supplied data (corrected_payload_json, dlq_id, actor_id).

---

## Algorithm — bare retry (`POST /api/v1/dlq/:item_id/retry`)

1. Load DLQ item by `item_id` — `ItemNotFound` if absent.
2. Load instance projection for `instance_id` from the DLQ row — `InstanceNotFound` if absent.
3. Verify `instance_projections.status = 'ERROR'` — `InstanceNotInError` if not.
4. **Changed-cause check:**
   a. Query `process_definitions` for the currently-promoted artifact hash for the instance's
      `definition_id`.
   b. If the promoted hash differs from `instance_projections.definition_artifact_hash`: cause
      has changed via new version → allow retry.
   c. Otherwise query `events WHERE instance_id=$1 AND event_type='EXECUTION_CORRECTION'
      AND created_at > (SELECT created_at FROM events WHERE event_type='EXECUTION_ERROR'
      ORDER BY sequence_number DESC LIMIT 1)` — if any row: correction event present → allow retry.
   d. If neither a nor c: return `RetryWithoutChange` (HTTP 409) with hint message.
5. Update DLQ item: `status='retrying'`, `retry_count=0`.
6. The service-task / timer infrastructure picks up the item on the next poll and re-executes
   the original trigger. The DLQ row is deleted on success.
7. Return HTTP 200 with `{ "status": "RETRYING", "dlq_id": "...", "instance_id": "..." }`.

---

## Algorithm — retry-with-input (`POST /api/v1/dlq/:item_id/retry-with-input`)

1. Parse and validate `corrected_payload_json` — `InvalidInput` if not a JSON object.
2. Load DLQ item — `ItemNotFound` if absent.
3. Load instance projection — `InstanceNotFound` if absent.
4. Verify `status = 'ERROR'` — `InstanceNotInError` if not.
5. Load definition snapshot for the instance.
6. Build the corrected `TransitionEvent` by substituting `corrected_payload_json` for the
   original trigger payload stored in `dead_letter_queue.original_payload`.
7. Call `instance_store.applyTransition()` with the corrected event. If this succeeds, the
   instance status transitions away from ERROR.
8. In the same transaction as the transition:
   a. Delete the DLQ row.
   b. Update the instance status if `applyTransition` did not already do so.
9. Return HTTP 200 with the new instance state.

---

## Algorithm — discard (`POST /api/v1/dlq/:item_id/discard`)

1. Load DLQ item — `ItemNotFound` if absent.
2. BEGIN TRANSACTION:
   a. `UPDATE instance_projections SET status='CANCELLED', cancelled_at=NOW(), updated_at=NOW()
       WHERE instance_id=$1 AND status='ERROR'`
   b. `INSERT INTO dead_letter_items (id=gen_uuid, dlq_id=$1, instance_id=$2,
       resolution='DISCARDED', discarded_at=NOW(), actor_id=$3)`
   c. `DELETE FROM dead_letter_queue WHERE id=$1`
3. COMMIT.
4. Return HTTP 200 with `{ "status": "DISCARDED", "dlq_id": "..." }`.

---

## External dependencies

- `dead_letter_queue` table (migration 010_dlq.sql)
- `dead_letter_items` table (must contain `resolution TEXT`, `discarded_at TIMESTAMPTZ`, `actor_id TEXT` columns — add via migration if absent)
- `instance_projections` table — reads `status`, `definition_artifact_hash`, `definition_id`
- `process_definitions` table — reads promoted artifact hash
- `events` table — reads `EXECUTION_ERROR` and `EXECUTION_CORRECTION` events

---

## Open questions

- None. All edge cases covered by acceptance criteria.
