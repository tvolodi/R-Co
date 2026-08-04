# Design: ISS-102 — `tasks.claimed_by` and Real Claim Path

**Module:** `src/tasks/` · `src/api/routes/tasks.zig`  
**Migration:** `migrations/082_iss102_tasks_claimed_by.sql`  
**Requirement:** ISS-102 (EPIC-1, P0)  
**Design artefact type:** Type E (novel column + new endpoint + completion guard change)

---

## 1. Module purpose

The current claim path is broken: `POST /tasks/:id/claim` uses `assignee_ref IS NULL` as the
optimistic lock guard, but `assignee_ref` holds the GROUP/ROLE pool name set at activation and
is never null for pool tasks. Consequently no claim can ever succeed, and there is no column to
record which individual worker took the task.

This module adds:

1. A `claimed_by UUID NULL` column to `tasks` — the individual who atomically acquired the task.
2. A real `POST /tasks/:id/claim` endpoint backed by a conditional `UPDATE` on `claimed_by`.
3. Updated completion-guard logic in `handleComplete` that checks `claimed_by` (or a
   USER-assigned `assignee_ref`) rather than the broken group-membership look-up on pool tasks.
4. Two partial indexes from §5.2 covering the unclaimed work queue and "my tasks" view.

No other modules are touched. `src/engine/transition.zig` is unchanged.

---

## 2. Migration DDL shape

**File:** `migrations/082_iss102_tasks_claimed_by.sql`

The migration must be idempotent (`IF NOT EXISTS` / `IF NOT EXISTS` guards on every statement).

### 2.1 Column addition

```
ALTER TABLE tasks
    ADD COLUMN IF NOT EXISTS claimed_by UUID NULL;
```

`claimed_by` starts NULL for all existing rows and for newly activated tasks. No backfill is
required.

### 2.2 Partial index: unclaimed work pool

**Index name:** `idx_tasks_unclaimed_pool`

```
CREATE INDEX IF NOT EXISTS idx_tasks_unclaimed_pool
    ON tasks (assignee_type, assignee_ref, created_at)
    WHERE status = 'PENDING' AND claimed_by IS NULL;
```

**Purpose:** Supports the worker-queue scan — "show me all PENDING tasks for this
group/role/user that have not yet been claimed". The `WHERE` predicate excludes already-claimed
and non-pending rows, keeping the index small.

### 2.3 Partial index: "my tasks" (claimed by worker)

**Index name:** `idx_tasks_my_tasks`

```
CREATE INDEX IF NOT EXISTS idx_tasks_my_tasks
    ON tasks (claimed_by, created_at)
    WHERE status = 'PENDING' AND claimed_by IS NOT NULL;
```

**Purpose:** Supports `GET /tasks?claimed_by=<worker>` — "show me the PENDING tasks I have
already claimed". The `WHERE` predicate excludes NULL `claimed_by` and non-pending rows.

---

## 3. Claim endpoint

### 3.1 Endpoint summary

```
POST /api/v1/tasks/:id/claim
```

No request body required. The actor identity comes from the bearer token (populated into
`Actor.user_id` by auth middleware).

### 3.2 Exact UPDATE guard clause

```sql
UPDATE tasks
SET
    claimed_by = $2::uuid,
    updated_at = NOW()
WHERE id        = $1::uuid
  AND claimed_by IS NULL
  AND status     = 'PENDING'
RETURNING
    id, instance_id, token_id, node_id, node_name, status,
    assignee_type, assignee_ref, claimed_by,
    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint,
    form_schema::text
```

Parameters: `$1` = `task_id` hex UUID; `$2` = `actor.user_id` UUID.

### 3.3 Zero-rows branch — 409 condition

When the `UPDATE` returns 0 rows the task could be in one of three states:

| Diagnostic SELECT result | Return |
|---|---|
| Row not found | `ClaimError.NotFound` → HTTP 404 |
| `status != 'PENDING'` | `ClaimError.NotPending` → HTTP 409 |
| `claimed_by IS NOT NULL` | `ClaimError.AlreadyClaimed` → HTTP 409 |

The diagnostic SELECT is:

```sql
SELECT status, claimed_by IS NOT NULL AS is_claimed
FROM tasks
WHERE id = $1::uuid
```

Run only when the UPDATE returns 0 rows, using the same connection (no extra round-trip on
the happy path).

### 3.4 Concurrency correctness argument

The `UPDATE … WHERE id = $1 AND claimed_by IS NULL AND status = 'PENDING'` is executed
inside a single PostgreSQL statement. PostgreSQL serialises concurrent `UPDATE` statements
targeting the same row; the second concurrent claim will see `claimed_by` already set and
return 0 rows. No application-level lock is needed. The partial index
`idx_tasks_unclaimed_pool` makes the row lookup efficient without affecting the correctness
argument.

---

## 4. Completion guard

### 4.1 Where the check lives

The completion-authorization check remains in `handleComplete` (routes/tasks.zig) — **before**
delegating to `instance_store.completeTask`. This is consistent with the existing pattern for
`handleAssign` / `handleReassign`. The inner `completeInTx` function in `store.zig` does
**not** receive a `claimer_id` parameter; it only enforces `status = 'PENDING'`.

### 4.2 Updated check logic (TASK_WORKER path)

When `authorization.isTaskWorkerOnly(roles)` is true, `handleComplete` applies the following
guard in order:

```
1. If task.claimed_by IS NOT NULL:
       allow iff task.claimed_by == actor.user_id
       deny  → HTTP 403 UNAUTHORIZED_COMPLETE

2. Else if task.assignee_type == "USER":
       allow iff task.assignee_ref == actor.user_id
       deny  → HTTP 403 UNAUTHORIZED_COMPLETE

3. Else (GROUP/ROLE pool task, not yet claimed):
       deny always → HTTP 403 UNAUTHORIZED_COMPLETE
       (worker must claim before completing)
```

`PROCESS_OPERATOR` and above bypass this check entirely (no change from current behaviour).

### 4.3 Transaction safety note

Between `getById` and `completeInTx`, another concurrent request could change `claimed_by`.
However, the `AND status = 'PENDING'` guard in `completeInTx` is still atomic: if the task
was concurrently completed (status transitions to `COMPLETED`), the UPDATE returns 0 rows and
`completeInTx` returns `TaskError.AlreadyTerminated`. No double-completion is possible.
The TOCTOU window for a `claimed_by` change does not affect authorization soundness: if task
was unclaimed at check time and the actor was a USER assignee, the actor is legitimately
authorized. If another worker claims it in the window, the actor still completes, which is an
acceptable outcome (operators can reassign afterwards if needed).

---

## 5. Error taxonomy

### 5.1 New `ClaimError` error set (added to `src/tasks/store.zig`)

```
pub const ClaimError = error {
    /// task_id not found in tasks table.  HTTP 404.
    NotFound,
    /// Task is already claimed (claimed_by IS NOT NULL).  HTTP 409.
    AlreadyClaimed,
    /// Task status ≠ PENDING (already COMPLETED or CANCELLED).  HTTP 409.
    NotPending,
    /// db.Pool.acquire() failed.  HTTP 503.
    PoolExhausted,
    /// Malformed parameter (invalid UUID format) or unexpected DB error.  HTTP 422.
    InvalidInput,
};
```

### 5.2 Addition to existing `TaskError` error set

No new variants are added to `TaskError`. The completion-guard failure (unauthorized actor) is
returned directly from `handleComplete` as HTTP 403 with error code `UNAUTHORIZED_COMPLETE`,
using the existing `errorResult` helper — it does not propagate through the store layer.

### 5.3 HTTP mapping summary

| Scenario | Source | HTTP |
|---|---|---|
| `ClaimError.NotFound` | `claimTask` | 404 |
| `ClaimError.AlreadyClaimed` | `claimTask` | 409 |
| `ClaimError.NotPending` | `claimTask` | 409 |
| `ClaimError.PoolExhausted` | `claimTask` | 503 |
| Unauthorized completion (not claimer / not USER assignee) | `handleComplete` | 403 |
| `TaskError.AlreadyTerminated` | `completeInTx` | 409 |
| `TaskError.NotFound` | `getById` / `completeInTx` | 404 |

---

## 6. Public function signatures

### 6.1 `src/tasks/store.zig`

#### `Task` struct — new field

```zig
pub const Task = struct {
    task_id:         Uuid,
    instance_id:     Uuid,
    token_id:        Uuid,
    node_id:         []const u8,
    node_name:       []const u8,
    status:          TaskStatus,
    assignee_type:   ?[]const u8,
    assignee_ref:    ?[]const u8,
    /// The individual worker who claimed this task. NULL when unclaimed.
    claimed_by:      ?Uuid,          // ← NEW
    form_schema:     ?[]const u8,
    correlation_key: ?[]const u8,
    created_at:      i64,
    updated_at:      i64,
};
```

All existing callers that use `Task` fields are unaffected; the new field is additive.
`rowToTask` must be updated to parse the additional column returned by every SELECT/RETURNING.

#### New error set

```zig
pub const ClaimError = error {
    NotFound,
    AlreadyClaimed,
    NotPending,
    PoolExhausted,
    InvalidInput,
};
```

#### New function: `claimTask`

```zig
/// Atomically claim a PENDING, unclaimed task for a worker.
///
/// Executes the single-statement conditional UPDATE and returns the updated Task
/// on success.  On 0 rows, issues a diagnostic SELECT and maps the result to
/// the appropriate ClaimError variant.
///
/// Acquires its own connection from self.pool.
///
/// Security: task_id and worker_id are bound as $1::uuid and $2::uuid — no
/// SQL string interpolation of caller-supplied values.
pub fn claimTask(
    self: *TaskStore,
    allocator: std.mem.Allocator,
    task_id:   Uuid,
    worker_id: []const u8,   // actor.user_id from bearer token
) ClaimError!Task
```

#### Modified function: `completeInTx`

Signature is **unchanged**. The only implementation change is that the `RETURNING` clause must
include `claimed_by` so that the returned `Task` carries the correct field value.

```zig
pub fn completeInTx(
    self:                  *TaskStore,
    allocator:             std.mem.Allocator,
    conn:                  *db.Conn,
    task_id:               Uuid,
    output_variables_json: []const u8,
) TaskError!Task   // unchanged
```

#### Modified functions (RETURNING clause update only)

The following functions already exist and require only their SQL `RETURNING` or `SELECT`
clause to be extended with `claimed_by`. Signatures are unchanged:

- `getById` — add `t.claimed_by` to the `SELECT` column list
- `createInTx` — add `claimed_by` to `RETURNING` (will be `NULL` for all new rows)

### 6.2 `src/api/routes/tasks.zig`

#### New function: `handleClaim`

```zig
/// POST /api/v1/tasks/:id/claim
///
/// Atomically claims a PENDING, unclaimed task for the authenticated actor.
///
/// Authorisation: any authenticated role (TASK_WORKER or above).
///
/// Success:              HTTP 200 + JSON TaskDetailResponse (with claimed_by populated).
/// Task not found:       HTTP 404 + Problem Details.
/// Task already claimed: HTTP 409 + Problem Details (code: TASK_ALREADY_CLAIMED).
/// Task not PENDING:     HTTP 409 + Problem Details (code: TASK_NOT_PENDING).
/// Invalid UUID:         HTTP 422 + Problem Details.
/// Pool exhausted:       HTTP 503 + Problem Details.
/// Server error:         HTTP 500 + Problem Details.
pub fn handleClaim(
    store:       *task_mod.TaskStore,
    allocator:   std.mem.Allocator,
    actor:       Actor,
    task_id_str: []const u8,
) HandlerResult
```

#### Modified function: `handleComplete`

Signature is **unchanged**. The Step 3 role/ownership check block is replaced with the new
three-branch logic described in §4.2. No new parameters are added.

```zig
pub fn handleComplete(
    store:          *task_mod.TaskStore,
    instance_store: *instance_mod.InstanceStore,
    identity:       *identity_service.Service,
    allocator:      std.mem.Allocator,
    actor:          Actor,
    task_id_str:    []const u8,
    body:           []const u8,
) HandlerResult   // unchanged
```

---

## 7. Data flow

```
POST /api/v1/tasks/:id/claim
        │
        ▼
[auth middleware] → Actor{user_id, roles}
        │
        ▼
handleClaim(store, allocator, actor, task_id_str)
        │
        ├─ parseUuid(task_id_str)        — 422 if malformed
        │
        └─ store.claimTask(allocator, task_id, actor.user_id)
                │
                ├─ pool.acquire()         — 503 on PoolExhausted
                │
                ├─ UPDATE tasks SET claimed_by=$2 WHERE id=$1
                │    AND claimed_by IS NULL AND status='PENDING'
                │
                ├─ RETURNING rows > 0 → return Task (200)
                │
                └─ RETURNING rows == 0
                        │
                        └─ SELECT status, claimed_by IS NOT NULL
                                │
                                ├─ not found  → NotFound  (404)
                                ├─ claimed    → AlreadyClaimed (409)
                                └─ !PENDING   → NotPending (409)
```

```
POST /api/v1/tasks/:id/complete
        │
        ▼
handleComplete (updated Step 3 only)
        │
        ├─ store.getById() → Task{claimed_by, assignee_type, assignee_ref, ...}
        │
        ├─ [if isTaskWorkerOnly(roles)]
        │      ├─ claimed_by != null AND claimed_by == actor.user_id  → allow
        │      ├─ claimed_by == null AND type=='USER' AND ref==actor   → allow
        │      └─ else                                                 → 403
        │
        └─ instance_store.completeTask(…)   [unchanged call]
```

---

## 8. Dependencies

| Module | Dependency direction | Note |
|---|---|---|
| `src/tasks/store.zig` | Depends on `db` (pool) | No change |
| `src/api/routes/tasks.zig` | Depends on `tasks/store.zig`, `engine/instance.zig`, `identity/service.zig` | No change to import list |
| `src/engine/transition.zig` | **Must not be touched** | Pure function, no I/O |
| `src/engine/instance.zig` | Not touched — `completeTask` signature unchanged | |

---

## 9. Open questions

None. All design elements map directly to the ISS-102 acceptance criteria.
