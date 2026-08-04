# Module: api-04-task-operations

**Covers:** API-04 (GET /tasks, GET /tasks/:id, POST /tasks/:id/complete, POST /tasks/:id/assign, POST /tasks/:id/reassign), API-06 (pagination for task list)
**Files:** `src/api/routes/tasks.zig` (extend existing)
**Depends on:** `src/tasks/store.zig`, `src/engine/instance.zig`, `src/design/api_conventions.md`, `src/design/engine.md` (EE-04 completeTask)

---

## Module purpose

This module designs the five task operation endpoints required by API-04. Three endpoints extend the existing `tasks.zig` handler file (`handleList` replacement, `handleGetById` new, `handleComplete` already implemented). Two new endpoints (`handleAssign`, `handleReassign`) add task assignment management. All five endpoints follow the existing `HandlerResult` pattern from `tasks.zig` and use the error helpers from `src/api/errors.zig`.

Key differences from the existing EE-03 `handleList`:
- Replaces offset/limit pagination with cursor-based pagination (API-06 compliance).
- Adds role-based row filtering: TASK_WORKER sees only tasks assigned to them; PROCESS_OPERATOR and above see all tasks.
- Renames filter parameter `assignee_ref` → `assignee_id` to match API-04 AC naming (maps to `tasks.assignee_ref` column with `assignee_type = 'USER'`).
- Adds `instance_id` as an explicit filter parameter (was already supported in the EE-03 handler but not in the API-04 spec naming).

---

## Role model

Roles referenced in this module (from IDN-03):

| Role | Abbreviation | GET /tasks visibility | write operations |
|---|---|---|---|
| `TASK_WORKER` | TW | Own tasks only (row-level filter) | complete own task only |
| `PROCESS_OPERATOR` | PO | All tasks | complete any task, assign, reassign |
| `PROCESS_DESIGNER` | PD | All tasks | same as PO |
| `PLATFORM_ADMIN` | PA | All tasks | all operations |

Roles are additive. Effective permissions = union of all roles held by the caller. The caller's `user_id` and role set are extracted from the bearer token by `api/middleware/auth.zig` and passed to handlers as an `Actor` struct (defined in Section 1 below).

---

## Section 1: Shared types

### Actor struct (auth context)

The auth middleware populates an `Actor` value that is passed to every handler needing role checks. BACKEND-DEV should define this in `src/api/auth.zig` (or reuse an existing location if one exists).

```zig
/// Authenticated caller context, extracted from the bearer token.
pub const Actor = struct {
    /// Caller's user identifier (from token subject).
    user_id: []const u8,
    /// True if caller holds PROCESS_OPERATOR, PROCESS_DESIGNER, or PLATFORM_ADMIN.
    is_operator_or_above: bool,
    /// True if caller holds PLATFORM_ADMIN.
    is_platform_admin: bool,
};
```

### AssignError (new error set for assign/reassign)

```zig
pub const AssignError = error{
    /// task_id not found. HTTP 404.
    NotFound,
    /// Task is already assigned (for assign) or not assigned (for reassign). HTTP 409.
    AssignmentConflict,
    /// Task status ≠ PENDING (cannot reassign a completed/cancelled task). HTTP 409.
    AlreadyTerminated,
    /// DB pool exhausted. HTTP 503.
    PoolExhausted,
    /// Malformed parameter or DB error. HTTP 500.
    PersistenceFailed,
    OutOfMemory,
};
```

---

## Section 2: GET /tasks (list with cursor pagination)

### 2.1 Query parameters

```zig
/// Parsed query parameters for GET /api/v1/tasks.
pub const ListTasksParams = struct {
    /// Optional: filter to tasks assigned to this user_id.
    /// Maps to: tasks.assignee_ref = $assignee_id AND tasks.assignee_type = 'USER'.
    /// Null means no assignee filter (subject to role-based row filtering below).
    assignee_id: ?[]const u8,
    /// Optional: filter by task status.
    /// Allowed values: "PENDING", "COMPLETED", "CANCELLED". Null = no filter.
    status: ?TaskStatus,
    /// Optional: filter to tasks belonging to this process instance UUID.
    instance_id: ?Uuid,
    /// Cursor for continuation pagination (opaque base64url string).
    /// Null means start from the beginning (most recently created first).
    cursor: ?[]const u8,
    /// Page size; default 50, max 200. Zero or negative → HTTP 422.
    page_size: u16,
};
```

### 2.2 Response types

```zig
/// Single task item in the list response.
pub const TaskListItem = struct {
    /// UUID formatted as lowercase hex with hyphens.
    task_id: []const u8,
    /// UUID of the owning process instance.
    instance_id: []const u8,
    /// HUMAN_TASK node_id in the definition graph.
    node_id: []const u8,
    /// Display name of the HUMAN_TASK node.
    node_name: []const u8,
    /// "PENDING", "COMPLETED", or "CANCELLED".
    status: []const u8,
    /// "USER", "GROUP", "ROLE", or null.
    assignee_type: ?[]const u8,
    /// user_id / group_name / role_name, or null.
    assignee_ref: ?[]const u8,
    /// UTC epoch microseconds (i64).
    created_at: i64,
};

/// Paginated list response for GET /api/v1/tasks.
pub const TaskListResponse = struct {
    /// Items on this page; may be empty.
    items: []TaskListItem,
    /// Opaque cursor for the next page; null if this is the last page.
    /// Format: base64url_no_pad(decimal_string(last_item.created_at_us) || ":" || last_item.task_id_hex)
    next_cursor: ?[]const u8,
    /// Item count on this page.
    count: usize,
};
```

### 2.3 Handler signature

```zig
/// GET /api/v1/tasks
///
/// Returns a paginated, optionally-filtered list of tasks.
/// Results sorted by created_at DESC, task_id DESC (stable cursor pagination).
///
/// Role-based row filtering:
///   TASK_WORKER: only tasks where assignee_ref = actor.user_id AND assignee_type = 'USER'.
///   PROCESS_OPERATOR or above: all tasks (no extra row filter).
///
/// Query parameters (parsed before this handler is called):
///   assignee_id — optional user_id filter
///   status      — optional status filter
///   instance_id — optional instance UUID filter
///   cursor      — optional continuation cursor
///   page_size   — validated integer, default 50, max 200
///
/// Authorisation: any authenticated role.
///
/// Success:              HTTP 200 + JSON TaskListResponse.
/// Invalid status:       HTTP 422 + Problem Details.
/// Invalid instance_id:  HTTP 422 + Problem Details.
/// Invalid cursor:       HTTP 422 + Problem Details.
/// Expired cursor:       HTTP 410 + Problem Details.
/// Invalid page_size:    HTTP 422 + Problem Details.
/// Pool exhausted:       HTTP 503 + Problem Details.
/// Server error:         HTTP 500 + Problem Details.
pub fn handleList(
    store: *task_mod.TaskStore,
    allocator: std.mem.Allocator,
    actor: Actor,
    params: ListTasksParams,
) HandlerResult;
```

### 2.4 Role-based SQL filter injection

When `actor.is_operator_or_above` is `false` (i.e. caller is TASK_WORKER only), the handler MUST inject two additional SQL conditions before calling the store:

```
AND assignee_ref = $N        -- bound as actor.user_id
AND assignee_type = 'USER'   -- literal fixed string, not user-supplied
```

These conditions are combined with any explicit `assignee_id` filter. If the caller is TASK_WORKER AND supplies `assignee_id`, both conditions must match; if `assignee_id ≠ actor.user_id`, the handler MAY short-circuit to an empty result set (HTTP 200 with empty `items`) since a TASK_WORKER can never see another user's tasks.

### 2.5 TaskStore additions required

The existing `TaskStore.list()` uses offset/limit. A new method is required:

```zig
/// Parameters for TaskStore.listCursor().
pub const ListCursorParams = struct {
    /// Filter by assignee user_id (maps to assignee_ref where assignee_type='USER').
    /// Null = no filter. For TASK_WORKER: always set to actor.user_id.
    assignee_id: ?[]const u8,
    /// If true AND assignee_id is set: add AND assignee_type = 'USER'.
    /// Always true when filtering for role-based row restriction.
    assignee_type_user_only: bool,
    /// Optional status filter.
    status: ?TaskStatus,
    /// Optional instance_id filter.
    instance_id: ?Uuid,
    /// Decoded cursor values. Null = start from the top.
    cursor_created_at: ?i64,
    cursor_task_id: ?[]const u8,
    /// Page size [1..200].
    page_size: u16,
};

/// Fetch a page of tasks using cursor-based (keyset) pagination.
///
/// Results are ordered by (created_at DESC, task_id DESC).
/// Returns exactly page_size rows or fewer (fewer means last page).
/// Fetches page_size + 1 rows internally; returns at most page_size.
///
/// Security: all filter values bound as $N positional parameters.
///
/// Errors:
///   TaskError.PoolExhausted  → HTTP 503
///   TaskError.InvalidInput   → HTTP 500
pub fn listCursor(
    self: *TaskStore,
    allocator: std.mem.Allocator,
    params: ListCursorParams,
) TaskError![]Task;
```

**SQL pattern (with cursor):**
```sql
SELECT id, instance_id, token_id, node_id, node_name, status,
       assignee_type, assignee_ref,
       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
FROM tasks
WHERE (<status_filter>)
  AND (<instance_id_filter>)
  AND (<assignee_id_filter>)
  AND (<role_row_filter>)
  AND (created_at, id) < ($cursor_created_at::timestamptz, $cursor_task_id::uuid)
ORDER BY created_at DESC, id DESC
LIMIT $page_size + 1
```

**Without cursor:** omit the `(created_at, id) < (...)` clause.

All filter values bound as `$N` positional parameters. `assignee_type = 'USER'` is a fixed SQL literal, not user-supplied.

### 2.6 Cursor encoding/decoding

Same strategy as API-03 instances:

- **Encoding:** `base64url_no_pad(decimal_string(created_at_us) || ":" || task_id_hex)`
  - Example raw: `1716220800123456:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
- **Decoding:** split on `":"`, parse the integer part as `i64` (created_at_us) and the hex part as a UUID.
- **Expiry:** 24 hours. Detect by comparing cursor's `created_at_us` against current time:
  - If `now_us - cursor_created_at_us > 86_400_000_000` (24 hours in µs), return HTTP 410.
- **Cross-endpoint isolation:** cursors from `/tasks` MUST NOT be accepted by `/instances` or other list endpoints. The cursor contains a task creation timestamp, which is structurally identical to an instance timestamp — BACKEND-DEV MUST add a 1-byte endpoint discriminator prefix before base64 encoding:
  - `/tasks` cursors: raw = `"T:" || decimal_string(created_at_us) || ":" || task_id_hex`
  - Decoding: reject if raw does not start with `"T:"`.

### 2.7 Success response JSON shape

```json
{
  "items": [
    {
      "task_id":       "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "instance_id":   "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "node_id":       "approve-step",
      "node_name":     "Loan Approval",
      "status":        "PENDING",
      "assignee_type": "USER",
      "assignee_ref":  "alice@example.com",
      "created_at":    1716220800000000
    }
  ],
  "next_cursor": "VDoxNzE2MjIwODAwMDAwMDAwOnhjsHh4eHh4eC14eHh4LXh4eHgteHh4eC14eHh4eHh4eHh4eHg",
  "count": 1
}
```

Empty result: `{ "items": [], "next_cursor": null, "count": 0 }` — HTTP 200.

---

## Section 3: GET /tasks/:id

### 3.1 Response type

```zig
/// Response body for GET /api/v1/tasks/:id.
pub const TaskDetailResponse = struct {
    /// UUID formatted as lowercase hex with hyphens.
    task_id: []const u8,
    /// UUID of the owning process instance.
    instance_id: []const u8,
    /// HUMAN_TASK node_id in the definition graph.
    node_id: []const u8,
    /// Display name of the HUMAN_TASK node.
    node_name: []const u8,
    /// "PENDING", "COMPLETED", or "CANCELLED".
    status: []const u8,
    /// "USER", "GROUP", "ROLE", or null.
    assignee_type: ?[]const u8,
    /// user_id / group_name / role_name, or null.
    assignee_ref: ?[]const u8,
    /// UTC epoch microseconds (i64). When the task was created.
    created_at: i64,
    /// UTC epoch microseconds (i64). When the task was last updated.
    updated_at: i64,
};
```

### 3.2 Handler signature

```zig
/// GET /api/v1/tasks/:id
///
/// Returns the full task record.
///
/// Authorisation: any authenticated role. TASK_WORKER may retrieve any task by ID
/// (no row-level restriction here — the restriction applies to the list endpoint only).
///
/// Success:          HTTP 200 + JSON TaskDetailResponse.
/// Not found:        HTTP 404 + Problem Details.
/// Invalid UUID:     HTTP 422 + Problem Details.
/// Pool exhausted:   HTTP 503 + Problem Details.
/// Server error:     HTTP 500 + Problem Details.
pub fn handleGetById(
    store: *task_mod.TaskStore,
    allocator: std.mem.Allocator,
    task_id_str: []const u8,
) HandlerResult;
```

### 3.3 Implementation notes

Uses the existing `TaskStore.getById()`. Parse `task_id_str` as UUID → HTTP 422 on parse failure. Serialise the returned `Task` to `TaskDetailResponse` JSON. No role restriction beyond authentication.

### 3.4 Success response JSON shape

```json
{
  "task_id":       "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "instance_id":   "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "node_id":       "approve-step",
  "node_name":     "Loan Approval",
  "status":        "PENDING",
  "assignee_type": "USER",
  "assignee_ref":  "alice@example.com",
  "created_at":    1716220800000000,
  "updated_at":    1716220900000000
}
```

---

## Section 4: POST /tasks/:id/complete

### 4.1 Request type

```zig
/// Request body for POST /api/v1/tasks/:id/complete.
pub const CompleteTaskRequest = struct {
    /// Output variables to merge into the instance variable map (EE-09).
    /// Must be a JSON object. Empty object `{}` is valid.
    /// Null is rejected with HTTP 422 — callers must supply `{}` for no output.
    output_variables: []const u8, // pre-parsed JSON object string
};
```

### 4.2 Handler signature

```zig
/// POST /api/v1/tasks/:id/complete
///
/// Completes the task per EE-04:
///   1. Fetch task by ID (HTTP 404 if not found).
///   2. Role check: TASK_WORKER may only complete a task where
///      assignee_ref = actor.user_id (HTTP 403 if mismatch).
///      PROCESS_OPERATOR or above may complete any task.
///   3. Validate output_variables is a JSON object (not null, not array).
///   4. Call InstanceStore.completeTask(task_id, output_variables_json)
///      which atomically: merges variables (EE-09), transitions state (EE-02),
///      marks task COMPLETED, appends TASK_COMPLETED event (DB-03).
///   5. Return HTTP 200 with { "status": "ok", "task_id": "..." }.
///
/// Authorisation:
///   TASK_WORKER — may complete tasks assigned to them only.
///   PROCESS_OPERATOR or above — may complete any task.
///
/// Success:                     HTTP 200 + { "status": "ok", "task_id": "..." }
/// Task not found:              HTTP 404 + Problem Details.
/// Caller not assignee (TW):    HTTP 403 + Problem Details.
/// Already completed/cancelled: HTTP 409 + Problem Details.
/// Task for CANCELLED instance: HTTP 409 + Problem Details (task is already CANCELLED).
/// output_variables = null:     HTTP 422 + Problem Details.
/// output_variables not object: HTTP 422 + Problem Details.
/// Pool exhausted:              HTTP 503 + Problem Details.
/// Server error:                HTTP 500 + Problem Details.
pub fn handleComplete(
    store: *task_mod.TaskStore,
    instance_store: *instance_mod.InstanceStore,
    allocator: std.mem.Allocator,
    actor: Actor,
    task_id_str: []const u8,
    body: []const u8,
) HandlerResult;
```

### 4.3 Role check algorithm

```
1. Parse task_id_str → Uuid (HTTP 422 on failure)
2. Call TaskStore.getById(task_id) → task (HTTP 404 on NotFound)
3. If actor.is_operator_or_above == false:
     If task.assignee_type != "USER" OR task.assignee_ref != actor.user_id:
       return HTTP 403 "Caller is not the assigned user for this task"
4. Parse body JSON → extract output_variables (HTTP 422 if missing or not object)
5. Call InstanceStore.completeTask(task_id, output_variables_json)
     → HTTP 409 on AlreadyTerminated
     → HTTP 503 on PoolExhausted
     → HTTP 500 on PersistenceFailed / TransitionFailed
6. Return HTTP 200 { "status": "ok", "task_id": "<task_id_hex>" }
```

### 4.4 EE-04 invocation

`handleComplete` delegates to the existing `InstanceStore.completeTask()` method (already implemented for EE-04). The handler does NOT re-implement transition logic. See `src/engine/instance.zig` for the signature:

```zig
// Already defined in instance.zig (EE-04):
pub fn completeTask(
    self: *InstanceStore,
    allocator: std.mem.Allocator,
    task_id: Uuid,
    output_variables_json: []const u8,
) CompleteTaskError!void;
```

The `handleComplete` implementation in `tasks.zig` (already partially implemented for EE-04) MUST be updated to:
1. Accept an `Actor` parameter for role checking.
2. Perform the TASK_WORKER ownership check before calling `completeTask`.

---

## Section 5: POST /tasks/:id/assign

### 5.1 Request type

```zig
/// Request body for POST /api/v1/tasks/:id/assign.
pub const AssignTaskRequest = struct {
    /// user_id to assign the task to.
    /// Must be a non-empty string. UUID or other opaque ID format is accepted.
    user_id: []const u8,
};
```

### 5.2 Handler signature

```zig
/// POST /api/v1/tasks/:id/assign
///
/// Assigns an unassigned PENDING task to a specific user.
///
/// Authorisation: PROCESS_OPERATOR or above.
///
/// Success:                        HTTP 200 + JSON TaskDetailResponse (updated task).
/// Task not found:                 HTTP 404 + Problem Details.
/// Task already assigned:          HTTP 409 + Problem Details.
/// Task already completed/cancelled: HTTP 409 + Problem Details.
/// Caller is not PROCESS_OPERATOR: HTTP 403 + Problem Details.
/// user_id missing/empty:          HTTP 422 + Problem Details.
/// Pool exhausted:                 HTTP 503 + Problem Details.
/// Server error:                   HTTP 500 + Problem Details.
pub fn handleAssign(
    store: *task_mod.TaskStore,
    allocator: std.mem.Allocator,
    actor: Actor,
    task_id_str: []const u8,
    body: []const u8,
) HandlerResult;
```

### 5.3 Algorithm

```
1. Role check: if !actor.is_operator_or_above → HTTP 403
2. Parse task_id_str → Uuid (HTTP 422 on failure)
3. Parse body JSON → extract user_id (HTTP 422 if missing or empty)
4. Call TaskStore.assign(task_id, user_id)
     → NotFound        → HTTP 404
     → AssignmentConflict (already assigned or not PENDING) → HTTP 409
     → PoolExhausted   → HTTP 503
     → PersistenceFailed → HTTP 500
5. Return HTTP 200 + JSON TaskDetailResponse of the updated task
```

### 5.4 TaskStore.assign method required

```zig
/// Assign an unassigned PENDING task to a user.
///
/// Preconditions enforced atomically by the UPDATE WHERE clause:
///   - status = 'PENDING'
///   - assignee_ref IS NULL (unassigned)
///
/// Returns AssignError.AssignmentConflict if 0 rows updated
/// (task already assigned, not PENDING, or not found after pre-check).
///
/// Security: user_id is bound as $2 — no SQL string interpolation.
pub fn assign(
    self: *TaskStore,
    allocator: std.mem.Allocator,
    task_id: Uuid,
    user_id: []const u8,
) AssignError!Task;
```

**SQL:**
```sql
UPDATE tasks
SET
    assignee_type = 'USER',
    assignee_ref  = $2,
    updated_at    = NOW()
WHERE id = $1::uuid
  AND status = 'PENDING'
  AND assignee_ref IS NULL
RETURNING id, instance_id, token_id, node_id, node_name, status,
          assignee_type, assignee_ref,
          (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
          (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
```

0 RETURNING rows → `AssignError.AssignmentConflict` (callers SHOULD do a `getById` first to distinguish 404 from 409).

### 5.5 Success response

HTTP 200 with the updated task serialised as `TaskDetailResponse` (same JSON shape as GET /tasks/:id).

---

## Section 6: POST /tasks/:id/reassign

### 6.1 Request type

```zig
/// Request body for POST /api/v1/tasks/:id/reassign.
pub const ReassignTaskRequest = struct {
    /// New user_id to assign the task to.
    /// Must be a non-empty string.
    user_id: []const u8,
};
```

### 6.2 Handler signature

```zig
/// POST /api/v1/tasks/:id/reassign
///
/// Changes the assignee of an already-assigned PENDING task.
/// Requires PROCESS_OPERATOR or above.
///
/// Authorisation: PROCESS_OPERATOR or above.
///
/// Success:                          HTTP 200 + JSON TaskDetailResponse (updated task).
/// Task not found:                   HTTP 404 + Problem Details.
/// Task not currently assigned:      HTTP 409 + Problem Details.
/// Task already completed/cancelled: HTTP 409 + Problem Details.
/// Caller is not PROCESS_OPERATOR:   HTTP 403 + Problem Details.
/// user_id missing/empty:            HTTP 422 + Problem Details.
/// Pool exhausted:                   HTTP 503 + Problem Details.
/// Server error:                     HTTP 500 + Problem Details.
pub fn handleReassign(
    store: *task_mod.TaskStore,
    allocator: std.mem.Allocator,
    actor: Actor,
    task_id_str: []const u8,
    body: []const u8,
) HandlerResult;
```

### 6.3 Algorithm

```
1. Role check: if !actor.is_operator_or_above → HTTP 403
2. Parse task_id_str → Uuid (HTTP 422 on failure)
3. Parse body JSON → extract user_id (HTTP 422 if missing or empty)
4. Call TaskStore.reassign(task_id, user_id)
     → NotFound           → HTTP 404
     → AssignmentConflict → HTTP 409 (task not assigned or not PENDING)
     → PoolExhausted      → HTTP 503
     → PersistenceFailed  → HTTP 500
5. Return HTTP 200 + JSON TaskDetailResponse of the updated task
```

### 6.4 TaskStore.reassign method required

```zig
/// Change the assignee of an already-assigned PENDING task.
///
/// Preconditions enforced atomically:
///   - status = 'PENDING'
///   - assignee_ref IS NOT NULL (must already be assigned)
///
/// Returns AssignError.AssignmentConflict if 0 rows updated.
///
/// Security: both parameters bound as $N — no SQL string interpolation.
pub fn reassign(
    self: *TaskStore,
    allocator: std.mem.Allocator,
    task_id: Uuid,
    new_user_id: []const u8,
) AssignError!Task;
```

**SQL:**
```sql
UPDATE tasks
SET
    assignee_type = 'USER',
    assignee_ref  = $2,
    updated_at    = NOW()
WHERE id = $1::uuid
  AND status = 'PENDING'
  AND assignee_ref IS NOT NULL
RETURNING id, instance_id, token_id, node_id, node_name, status,
          assignee_type, assignee_ref,
          (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
          (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
```

0 RETURNING rows → `AssignError.AssignmentConflict`. Use `getById` pre-check to distinguish 404 from 409 in the handler.

---

## Section 7: Route table

| Method | Path | Handler | Role required | Request body |
|---|---|---|---|---|
| `GET` | `/api/v1/tasks` | `handleList` (replace existing) | Any authenticated | none |
| `GET` | `/api/v1/tasks/:id` | `handleGetById` (NEW) | Any authenticated | none |
| `POST` | `/api/v1/tasks/:id/complete` | `handleComplete` (update existing) | Any authenticated + ownership check | JSON |
| `POST` | `/api/v1/tasks/:id/assign` | `handleAssign` (NEW) | PROCESS_OPERATOR or above | JSON |
| `POST` | `/api/v1/tasks/:id/reassign` | `handleReassign` (NEW) | PROCESS_OPERATOR or above | JSON |

**Router registration order:** `/api/v1/tasks/:id/complete`, `/api/v1/tasks/:id/assign`, `/api/v1/tasks/:id/reassign` MUST be registered before `/api/v1/tasks/:id` (GET) so the sub-path literal segments are not consumed as UUIDs.

---

## Section 8: Error code summary

| Endpoint | Condition | HTTP | error_code |
|---|---|---|---|
| All | Unauthenticated | 401 | (from auth middleware) |
| GET /tasks | Invalid status filter | 422 | INVALID_STATUS |
| GET /tasks | Invalid instance_id format | 422 | INVALID_INSTANCE_ID |
| GET /tasks | Invalid page_size (≤0 or >200) | 422 | INVALID_PAGE_SIZE |
| GET /tasks | Malformed cursor | 422 | INVALID_CURSOR |
| GET /tasks | Expired cursor | 410 | CURSOR_EXPIRED |
| GET /tasks | Pool exhausted | 503 | SERVICE_UNAVAILABLE |
| GET /tasks/:id | task_id not a valid UUID | 422 | INVALID_TASK_ID |
| GET /tasks/:id | Task not found | 404 | TASK_NOT_FOUND |
| GET /tasks/:id | Pool exhausted | 503 | SERVICE_UNAVAILABLE |
| POST .../complete | task_id not a valid UUID | 422 | INVALID_TASK_ID |
| POST .../complete | Task not found | 404 | TASK_NOT_FOUND |
| POST .../complete | Caller is TASK_WORKER and not assignee | 403 | FORBIDDEN |
| POST .../complete | Task already completed/cancelled | 409 | TASK_ALREADY_TERMINATED |
| POST .../complete | output_variables is null | 422 | INVALID_INPUT |
| POST .../complete | output_variables is not a JSON object | 422 | INVALID_INPUT |
| POST .../complete | Pool exhausted | 503 | SERVICE_UNAVAILABLE |
| POST .../assign | Caller not PROCESS_OPERATOR | 403 | FORBIDDEN |
| POST .../assign | task_id not a valid UUID | 422 | INVALID_TASK_ID |
| POST .../assign | Task not found | 404 | TASK_NOT_FOUND |
| POST .../assign | Task already assigned | 409 | TASK_ALREADY_ASSIGNED |
| POST .../assign | Task not PENDING | 409 | TASK_ALREADY_TERMINATED |
| POST .../assign | user_id missing or empty | 422 | INVALID_INPUT |
| POST .../assign | Pool exhausted | 503 | SERVICE_UNAVAILABLE |
| POST .../reassign | Caller not PROCESS_OPERATOR | 403 | FORBIDDEN |
| POST .../reassign | task_id not a valid UUID | 422 | INVALID_TASK_ID |
| POST .../reassign | Task not found | 404 | TASK_NOT_FOUND |
| POST .../reassign | Task not currently assigned | 409 | TASK_NOT_ASSIGNED |
| POST .../reassign | Task not PENDING | 409 | TASK_ALREADY_TERMINATED |
| POST .../reassign | user_id missing or empty | 422 | INVALID_INPUT |
| POST .../reassign | Pool exhausted | 503 | SERVICE_UNAVAILABLE |

All error responses use RFC 9457 Problem Details format per `src/design/api_conventions.md` Section 1.

---

## Section 9: Edge cases

### 9.1 TASK_WORKER completing another user's task

A caller with only TASK_WORKER role who calls `POST /tasks/:id/complete` where the task's `assignee_ref ≠ actor.user_id` (or `assignee_type ≠ 'USER'`) receives HTTP 403. The check happens AFTER the task is fetched (HTTP 404 takes priority) but BEFORE `output_variables` is validated or `completeTask` is called.

Exception per IDN-03: if a task is assigned to a GROUP (`assignee_type = 'GROUP'`) and the caller is a member of that group, the call is permitted. Since the identity module (IDN-01, IDN-02) is not yet implemented, BACKEND-DEV SHOULD add a `TODO IDN-02` comment and for now restrict TASK_WORKER to USER-assigned tasks only.

### 9.2 Task for a CANCELLED instance

When an instance is cancelled (EE-08), all its PENDING tasks are set to CANCELLED via `TaskStore.cancelInTx`. A subsequent `POST /tasks/:id/complete` on such a task will:
1. `TaskStore.getById` returns the task with `status = CANCELLED`.
2. Role check (TASK_WORKER): proceeds (task was assigned to them).
3. `InstanceStore.completeTask` returns `AlreadyTerminated`.
4. Handler returns HTTP 409.

This is correct. The HTTP 409 response detail SHOULD say "Task is not in PENDING status" (not reveal why it was cancelled).

### 9.3 Cursor cross-endpoint isolation

Cursors from `/tasks` include a `"T:"` prefix discriminator. If a cursor from `/instances` (which starts with `"I:"`) is supplied to `GET /tasks`, the base64-decoded string will not start with `"T:"` and the handler returns HTTP 422 INVALID_CURSOR.

### 9.4 TASK_WORKER with assignee_id filter

If a TASK_WORKER supplies `?assignee_id=other_user_id`, the handler MUST ignore the filter (or silently override it with `actor.user_id`). Returning HTTP 403 for this case is not correct per IDN-03 ("only tasks assigned to them are returned — not HTTP 403"). Silently returning empty results is also acceptable. Recommended: override `params.assignee_id = actor.user_id` before calling the store.

### 9.5 assign/reassign on a GROUP-assigned task

`POST /tasks/:id/reassign` changes the assignee to a USER regardless of the current `assignee_type`. After a successful reassign, `assignee_type` becomes `'USER'` and `assignee_ref` becomes the new `user_id`. This is intentional: reassign always sets a specific USER as the new assignee.

### 9.6 Empty output_variables

`output_variables = {}` is valid and results in a no-op variable merge (EE-09 collision policy: no keys to merge). The task is still completed and the transition proceeds.

---

## Section 10: Data flow diagram

```
HTTP GET /api/v1/tasks?status=PENDING&assignee_id=alice&cursor=...&page_size=50
         │
         ▼
  api/middleware/auth.zig
         │  Parse Bearer token → actor (user_id, roles) → HTTP 401 if invalid
         ▼
  api/middleware/rbac.zig
         │  Any authenticated role → proceed
         ▼
  api/routes/tasks.zig :: handleList(store, allocator, actor, params)
         │
         │  1. Validate params.status → HTTP 422 on unknown value
         │  2. Parse params.instance_id UUID → HTTP 422 on bad UUID
         │  3. Validate params.page_size ∈ [1..200] → HTTP 422 on out of range
         │  4. Decode params.cursor → (created_at_us, task_id_hex)
         │     → HTTP 422 on malformed; HTTP 410 on expired
         │  5. If !actor.is_operator_or_above:
         │       override assignee_id = actor.user_id, assignee_type_user_only = true
         │
         ▼
  tasks/store.zig :: TaskStore.listCursor(allocator, ListCursorParams)
         │
         ├─ [A] pool.acquire() → HTTP 503 on PoolExhausted
         ├─ [B] SELECT tasks WHERE (<filters>) AND (<cursor_seek>)
         │       ORDER BY created_at DESC, id DESC  LIMIT page_size + 1
         └─ return []Task (length <= page_size + 1)
                    │
                    ▼
  handleList:
         │  - If len == page_size + 1: encode next_cursor from item[page_size - 1]
         │  - Serialise to TaskListResponse JSON
         └─ HTTP 200 + JSON body


HTTP POST /api/v1/tasks/:id/complete
         │
         ▼
  api/middleware/auth.zig  → actor
         ▼
  api/routes/tasks.zig :: handleComplete(store, instance_store, allocator, actor, id_str, body)
         │
         │  1. Parse task_id UUID → HTTP 422 on failure
         │  2. TaskStore.getById(task_id) → task → HTTP 404 on NotFound
         │  3. Role check (TASK_WORKER): verify assignee ownership → HTTP 403
         │  4. Parse body JSON → output_variables → HTTP 422 on null/non-object
         │
         ▼
  engine/instance.zig :: InstanceStore.completeTask(task_id, output_variables_json)
         │
         │  (atomic transaction: EE-09 merge + EE-02 transition + TASK_COMPLETED event)
         │
         ├─ AlreadyTerminated → HTTP 409
         ├─ PoolExhausted     → HTTP 503
         └─ success
                    │
                    ▼
         HTTP 200 + { "status": "ok", "task_id": "..." }


HTTP POST /api/v1/tasks/:id/assign   (similar for /reassign)
         │
         ▼
  api/middleware/auth.zig  → actor
         ▼
  api/routes/tasks.zig :: handleAssign(store, allocator, actor, id_str, body)
         │
         │  1. Role check: !is_operator_or_above → HTTP 403
         │  2. Parse task_id UUID → HTTP 422
         │  3. Parse body JSON → user_id → HTTP 422 on missing/empty
         │  4. TaskStore.getById(task_id) → HTTP 404 on NotFound
         │  5. TaskStore.assign(task_id, user_id)
         │     → AssignmentConflict → HTTP 409
         │     → PoolExhausted     → HTTP 503
         │
         └─ HTTP 200 + TaskDetailResponse JSON
```
