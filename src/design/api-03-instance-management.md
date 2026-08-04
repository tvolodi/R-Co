# Module: api-03-instance-management

**Covers:** API-03 (GET /instances/:id, GET /instances list), API-06 (pagination)
**Files:** `src/api/routes/instances.zig` (extend existing)
**Depends on:** `src/design/engine.md`, `src/engine/instance.zig`, `src/tasks/store.zig`

---

## Module purpose

This module designs the two read endpoints for process instance management: `GET /instances/:id` (single instance state with current tasks) and `GET /instances` (paginated list filterable by status and definition_id). The write endpoints for this route — `POST /instances` (EE-01) and `POST /instances/:id/cancel` (EE-08) — are already implemented in `src/api/routes/instances.zig`. This design extends that file with the two remaining GET handlers to complete full API-03 coverage. All business data is fetched from `instance_projections` and `tasks` tables via `InstanceStore` and `TaskStore`. No new domain modules are required.

---

## Public interface

All handler functions follow the existing pattern in `instances.zig`: they accept store pointers, an `std.mem.Allocator`, and parsed inputs from the HTTP layer. They return `HandlerResult` (the existing `{status_code, body}` struct defined in that file).

### New request parameter types

```zig
/// Query parameters for GET /api/v1/instances/:id
/// No query params; only the path param instance_id is needed.

/// Query parameters for GET /api/v1/instances (list)
pub const ListInstancesParams = struct {
    /// Optional filter: one of "ACTIVE", "COMPLETED", "CANCELLED", "ERROR".
    /// Null means no status filter (return all statuses).
    status: ?[]const u8,
    /// Optional filter: UUID string. Only instances of this definition are returned.
    definition_id: ?[]const u8,
    /// Cursor for continuation pagination (opaque base64url string).
    /// Null means start from the beginning (most recent first).
    cursor: ?[]const u8,
    /// Page size; default 50, max 200.
    page_size: u16,
};
```

### New response types

```zig
/// Response body for GET /api/v1/instances/:id (API-03 AC).
///
/// Includes full instance state: status, current_tasks, variables, started_at.
/// Also includes completed_at when status is COMPLETED or CANCELLED (terminal).
pub const InstanceDetailResponse = struct {
    /// Primary key — UUID formatted as lowercase hex with hyphens.
    instance_id: []const u8,
    /// FK to process_definitions.id.
    definition_id: []const u8,
    /// Optional caller-supplied correlation key.
    correlation_key: ?[]const u8,
    /// One of: "ACTIVE", "COMPLETED", "CANCELLED", "ERROR".
    status: []const u8,
    /// Active HUMAN_TASK records for this instance (EE-03).
    /// Includes all tasks in PENDING status; may be empty for non-ACTIVE instances.
    current_tasks: []TaskSummary,
    /// Current instance variable map as a JSON object.
    variables: []const u8, // pre-serialised JSON string
    /// UTC epoch microseconds (i64). When the instance was started.
    started_at: i64,
    /// UTC epoch microseconds (i64) or null. Set when status is COMPLETED.
    completed_at: ?i64,
    /// UTC epoch microseconds (i64) or null. Set when status is CANCELLED.
    cancelled_at: ?i64,
    /// Present only when status is ERROR. Contains error_type, affected_node,
    /// reason, and variable_state at time of error.
    error_detail: ?[]const u8, // pre-serialised JSON string or null
};

/// Compact task record embedded in InstanceDetailResponse.current_tasks.
pub const TaskSummary = struct {
    /// UUID of the task record.
    task_id: []const u8,
    /// HUMAN_TASK node_id in the definition graph.
    node_id: []const u8,
    /// Display name of the HUMAN_TASK node.
    node_name: []const u8,
    /// Task status: always "PENDING" for current_tasks list.
    status: []const u8,
    /// Assignee type: "USER", "GROUP", "ROLE", or null.
    assignee_type: ?[]const u8,
    /// Assignee reference: user_id / group_name / role_name, or null.
    assignee_ref: ?[]const u8,
    /// UTC epoch microseconds (i64).
    created_at: i64,
};

/// Single item in the GET /api/v1/instances list response.
/// Intentionally smaller than InstanceDetailResponse — no variables, no tasks.
pub const InstanceListItem = struct {
    /// UUID formatted as lowercase hex with hyphens.
    instance_id: []const u8,
    /// FK to process_definitions.id.
    definition_id: []const u8,
    /// Optional correlation key.
    correlation_key: ?[]const u8,
    /// One of: "ACTIVE", "COMPLETED", "CANCELLED", "ERROR".
    status: []const u8,
    /// UTC epoch microseconds (i64).
    started_at: i64,
};

/// Paginated list response for GET /api/v1/instances.
pub const InstanceListResponse = struct {
    /// Items on this page; may be empty.
    items: []InstanceListItem,
    /// Opaque cursor for the next page; null if this is the last page.
    /// Format: base64url_no_pad(started_at_us_decimal || ":" || instance_id_hex)
    next_cursor: ?[]const u8,
    /// Total item count on this page.
    count: usize,
};
```

### New handler signatures

```zig
/// GET /api/v1/instances/:id
///
/// Returns the full instance state including current_tasks (PENDING tasks only),
/// variables (the current merged JSON object), started_at, completed_at (if terminal).
///
/// Authorisation: any authenticated role (API-03 AC).
///
/// Success:            HTTP 200 + JSON InstanceDetailResponse.
/// Not found:          HTTP 404 + Problem Details.
/// Invalid UUID:       HTTP 422 + Problem Details.
/// Pool exhausted:     HTTP 503 + Problem Details.
/// Server error:       HTTP 500 + Problem Details.
pub fn handleGetById(
    instance_store: *instance_mod.InstanceStore,
    task_store: *task_mod.TaskStore,
    allocator: std.mem.Allocator,
    instance_id_str: []const u8,
) HandlerResult;

/// GET /api/v1/instances
///
/// Returns a paginated, optionally-filtered list of instances.
/// Results are sorted by started_at DESC (most recently started first).
///
/// Query parameters (parsed before this handler is called):
///   status        — optional filter string
///   definition_id — optional filter string
///   cursor        — optional opaque continuation cursor
///   page_size     — validated integer, default 50, max 200
///
/// Authorisation: any authenticated role (API-03 AC).
///
/// Success:              HTTP 200 + JSON InstanceListResponse.
/// Invalid status value: HTTP 422 + Problem Details.
/// Invalid definition_id UUID: HTTP 422 + Problem Details.
/// Invalid cursor:       HTTP 422 + Problem Details.
/// Expired cursor:       HTTP 410 + Problem Details.
/// Invalid page_size:    HTTP 422 + Problem Details.
/// Pool exhausted:       HTTP 503 + Problem Details.
/// Server error:         HTTP 500 + Problem Details.
pub fn handleList(
    instance_store: *instance_mod.InstanceStore,
    allocator: std.mem.Allocator,
    params: ListInstancesParams,
) HandlerResult;
```

### New InstanceStore methods required (to be added by BACKEND-DEV)

The existing `InstanceStore` in `src/engine/instance.zig` does not yet expose query methods for GET operations. The following additions are needed:

```zig
/// Parameters for InstanceStore.getById().
/// instance_id is passed as [16]u8 (Uuid), already parsed from the path param.

/// Fetch a single instance projection plus all PENDING tasks for that instance.
///
/// Errors:
///   GetByIdError.InstanceNotFound   → HTTP 404
///   GetByIdError.PoolExhausted      → HTTP 503
///   GetByIdError.PersistenceFailed  → HTTP 500
pub fn getById(
    self: *InstanceStore,
    allocator: std.mem.Allocator,
    instance_id: Uuid,
) GetByIdError!InstanceWithTasks;

/// Lightweight projection row returned by InstanceStore.getById().
pub const InstanceWithTasks = struct {
    /// All fields from instance_projections row.
    instance_id:     Uuid,
    definition_id:   Uuid,
    correlation_key: ?[]const u8,  // allocator-owned if non-null
    status:          InstanceStatus,
    variables:       []const u8,   // JSON string, allocator-owned
    error_detail:    ?[]const u8,  // JSON string or null, allocator-owned
    started_at:      i64,          // UTC epoch microseconds
    completed_at:    ?i64,
    cancelled_at:    ?i64,
    /// Slice of PENDING tasks for this instance. Caller-owned.
    tasks:           []task_mod.Task,
};

pub const GetByIdError = error{
    InstanceNotFound,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

/// Parameters for InstanceStore.list().
pub const ListParams = struct {
    /// SQL-safe status string: "ACTIVE" | "COMPLETED" | "CANCELLED" | "ERROR" | null.
    status: ?[]const u8,
    /// Already-parsed UUID, or null for no filter.
    definition_id: ?Uuid,
    /// Decoded cursor: (started_at_us, instance_id_hex). Null = start from top.
    cursor_started_at: ?i64,
    cursor_instance_id: ?[]const u8,
    /// Page size [1..200].
    page_size: u16,
};

/// Fetch a page of instances from instance_projections.
///
/// Results are ordered by (started_at DESC, instance_id DESC) for stable pagination.
/// Returns exactly page_size rows or fewer (fewer means last page).
///
/// Errors:
///   ListError.PoolExhausted     → HTTP 503
///   ListError.PersistenceFailed → HTTP 500
pub fn list(
    self: *InstanceStore,
    allocator: std.mem.Allocator,
    params: ListParams,
) ListError![]InstanceProjectionRow;

/// Projection-only row (no tasks) returned by InstanceStore.list().
pub const InstanceProjectionRow = struct {
    instance_id:     Uuid,
    definition_id:   Uuid,
    correlation_key: ?[]const u8,  // allocator-owned if non-null
    status:          InstanceStatus,
    started_at:      i64,          // UTC epoch microseconds
};

pub const ListError = error{
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};
```

---

## Route table (complete API-03 surface after this design)

| Method | Path                              | Handler               | Role required    | Req body |
|--------|-----------------------------------|-----------------------|------------------|----------|
| `POST` | `/api/v1/instances`               | `handleCreate` (existing) | PROCESS_OPERATOR or above | JSON |
| `GET`  | `/api/v1/instances`               | `handleList` (NEW)    | Any authenticated | none |
| `GET`  | `/api/v1/instances/:id`           | `handleGetById` (NEW) | Any authenticated | none |
| `POST` | `/api/v1/instances/:id/cancel`    | `handleCancel` (existing) | PROCESS_OPERATOR or above | none |
| `POST` | `/api/v1/instances/:id/reconstruct` | `handleReconstruct` (existing) | PROCESS_OPERATOR or above | none |

**Router registration note:** `/api/v1/instances` (list) MUST be registered before `/api/v1/instances/:id` (single) so that the literal path segment "instances" is not consumed as a UUID path parameter. Similarly `/:id/cancel` and `/:id/reconstruct` are registered before the plain `/:id` GET.

---

## Request and response JSON shapes

### GET /api/v1/instances/:id — success response (HTTP 200)

```json
{
  "instance_id":    "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "definition_id":  "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "correlation_key": "order-42",
  "status":         "ACTIVE",
  "current_tasks": [
    {
      "task_id":       "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "node_id":       "approve-step",
      "node_name":     "Loan Approval",
      "status":        "PENDING",
      "assignee_type": "USER",
      "assignee_ref":  "alice@example.com",
      "created_at":    1716220800000000
    }
  ],
  "variables":    "{\"amount\":5000,\"approved\":false}",
  "started_at":   1716220800000000,
  "completed_at": null,
  "cancelled_at": null,
  "error_detail": null
}
```

For a COMPLETED instance: `completed_at` is a non-null UTC epoch microseconds integer; `current_tasks` is an empty array `[]`.

For a CANCELLED instance: `cancelled_at` is non-null; `current_tasks` is an empty array.

For an ERROR instance: `error_detail` is a non-null JSON string (the EXECUTION_ERROR payload from `instance_projections.error_detail`); `current_tasks` may still contain the PENDING task that triggered the error.

### GET /api/v1/instances — success response (HTTP 200)

```json
{
  "items": [
    {
      "instance_id":    "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "definition_id":  "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "correlation_key": null,
      "status":         "ACTIVE",
      "started_at":     1716220800000000
    }
  ],
  "next_cursor": "MTcxNjIyMDgwMDAwMDAwMDp4eHh4eHh4eC14eHh4LXh4eHgteHh4eC14eHh4eHh4eHh4eHg",
  "count": 1
}
```

Empty result: `{ "items": [], "next_cursor": null, "count": 0 }` — HTTP 200.

---

## Pagination strategy (API-06 integration)

The `GET /instances` list follows the same cursor-based scheme as `GET /definitions`:

- **Sort order:** `(started_at DESC, instance_id DESC)` — stable across pages because `instance_id` (UUID) breaks ties in `started_at` ties.
- **Cursor encoding:** `base64url_no_pad(decimal_string(last_item.started_at_us) || ":" || last_item.instance_id_hex)`
  - Example raw: `1716220800000000:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
- **Cursor decoding:** Split on `":"`, parse the integer part as `i64` and the hex part as a UUID.
- **SQL WHERE clause with cursor (no cursor):**
  ```sql
  -- No cursor: start from the top
  SELECT ... FROM instance_projections
  WHERE (<status filter>) AND (<definition_id filter>)
  ORDER BY started_at DESC, instance_id DESC
  LIMIT $page_size + 1
  ```
- **SQL WHERE clause with cursor:**
  ```sql
  -- With cursor: seek past the last-seen item
  WHERE (<status filter>) AND (<definition_id filter>)
    AND (started_at, instance_id) < ($cursor_started_at::timestamptz, $cursor_instance_id::uuid)
  ORDER BY started_at DESC, instance_id DESC
  LIMIT $page_size + 1
  ```
  This keyset-pagination pattern avoids OFFSET and is stable under concurrent inserts.
- **Next cursor presence:** If `LIMIT page_size + 1` returns exactly `page_size + 1` rows, a next cursor exists (derived from the page_size-th row; the extra row is discarded from the response). If fewer rows are returned, `next_cursor` is null.
- **Default page size:** 50. Maximum: 200. Zero or negative: HTTP 422.
- **Cursor expiry:** 24 hours. An expired cursor returns HTTP 410. The cursor encodes `started_at_us` which is sufficient to detect staleness at the DB layer (the row at that position either exists or the data changed — no explicit expiry mechanism needed at DB level; expiry is enforced by checking cursor creation time embedded in a separate cookie or by timestamp freshness check). See Open Question 1.
- **Cross-endpoint isolation:** A cursor from `/instances` MUST NOT be accepted by `/definitions` or any other list endpoint.

---

## Filter parameter handling

### `status` filter

Allowed values: `"ACTIVE"`, `"COMPLETED"`, `"CANCELLED"`, `"ERROR"`. Any other string returns HTTP 422. Comparison is case-sensitive to match the DB column value exactly. Null/absent means no filter.

SQL: `AND status = $status_param` (bound as `$N` parameter).

### `definition_id` filter

Must be a valid UUID string (36 characters, hyphens, hex). Parse failure returns HTTP 422 with `INVALID_DEFINITION_ID`. Null/absent means no filter.

SQL: `AND definition_id = $definition_id_param::uuid` (bound as `$N` parameter).

Security: both filters are bound as `$N` positional parameters; no SQL string interpolation of user-supplied values.

---

## Data flow diagram

```
HTTP GET /api/v1/instances/:id
         │
         ▼
  api/middleware/auth.zig
         │  Parse + validate Bearer token → HTTP 401 if absent/invalid
         │  Set ctx.actor (user_id + roles)
         ▼
  api/middleware/rbac.zig
         │  Any authenticated role passes → HTTP 403 only if no valid token
         ▼
  api/routes/instances.zig :: handleGetById(instance_store, task_store, allocator, id_str)
         │
         │  1. Parse UUID from path param
         │     → HTTP 422 INVALID_INSTANCE_ID if not a valid UUID
         │
         ▼
  engine/instance.zig :: InstanceStore.getById(allocator, instance_id)
         │
         ├─ [A] pool.acquire() → HTTP 503 on PoolExhausted
         │
         ├─ [B] SELECT instance_projections WHERE instance_id=$1::uuid
         │       → 0 rows → InstanceNotFound → HTTP 404
         │
         ├─ [C] SELECT tasks WHERE instance_id=$1::uuid AND status='PENDING'
         │       → 0 rows → current_tasks = [] (valid; instance may be terminal)
         │
         └─ return InstanceWithTasks
                    │
                    ▼
  handleGetById: serialise to InstanceDetailResponse JSON
         │
         └─ HTTP 200 + JSON body


HTTP GET /api/v1/instances?status=ACTIVE&definition_id=...&cursor=...&page_size=50
         │
         ▼
  api/middleware/auth.zig  (same as above)
         ▼
  api/middleware/rbac.zig  (any authenticated role)
         ▼
  api/routes/instances.zig :: handleList(instance_store, allocator, params)
         │
         │  1. Validate params.status (if present) → HTTP 422 on unknown value
         │  2. Parse params.definition_id UUID (if present) → HTTP 422 on bad UUID
         │  3. Validate params.page_size in [1..200] → HTTP 422 on out of range
         │  4. Decode params.cursor → (started_at_us, instance_id_hex)
         │     → HTTP 422 on malformed base64 or invalid contents
         │     → HTTP 410 on expired cursor (age > 24h)
         │
         ▼
  engine/instance.zig :: InstanceStore.list(allocator, ListParams)
         │
         ├─ [A] pool.acquire() → HTTP 503 on PoolExhausted
         │
         ├─ [B] SELECT instance_projections
         │       WHERE (<status_filter>) AND (<definition_id_filter>)
         │         AND (<cursor_seek> if cursor present)
         │       ORDER BY started_at DESC, instance_id DESC
         │       LIMIT page_size + 1
         │       → all bound as $N params; no SQL string interpolation
         │
         └─ return []InstanceProjectionRow (length <= page_size + 1)
                    │
                    ▼
  handleList:
         │  - If len == page_size + 1: encode next_cursor from item[page_size - 1]
         │    and trim items to page_size entries
         │  - Else: next_cursor = null
         │  - Serialise to InstanceListResponse JSON
         │
         └─ HTTP 200 + JSON body
```

---

## Error taxonomy

All errors produced by the two new handlers, with HTTP mappings:

| Error / condition                        | Source                                    | HTTP status | Error code string           |
|------------------------------------------|-------------------------------------------|-------------|----------------------------|
| `GetByIdError.InstanceNotFound`          | 0 rows from SELECT on instance_projections | 404        | `INSTANCE_NOT_FOUND`        |
| `GetByIdError.PoolExhausted`             | pool.acquire() fails                      | 503         | `SERVICE_UNAVAILABLE`       |
| `GetByIdError.PersistenceFailed`         | DB query error                            | 500         | `INTERNAL_ERROR`            |
| Invalid UUID path param (get by id)      | parseUuid() fails in handler              | 422         | `INVALID_INSTANCE_ID`       |
| `ListError.PoolExhausted`               | pool.acquire() fails                      | 503         | `SERVICE_UNAVAILABLE`       |
| `ListError.PersistenceFailed`           | DB query error                            | 500         | `INTERNAL_ERROR`            |
| Unknown `status` query param value       | validation in handler                     | 422         | `INVALID_STATUS`            |
| Invalid `definition_id` UUID format      | parseUuid() fails in handler              | 422         | `INVALID_DEFINITION_ID`     |
| `page_size <= 0` or `page_size > 200`    | validation in handler                     | 422         | `INVALID_PAGE_SIZE`         |
| Malformed cursor (base64 decode error)   | cursor decode in handler                  | 422         | `INVALID_CURSOR`            |
| Expired cursor (age > 24h)               | cursor age check in handler               | 410         | `CURSOR_EXPIRED`            |
| Missing auth token (any endpoint)        | auth middleware                           | 401         | (RFC 9457 standard)         |

**Error response shape (RFC 9457 Problem Details — consistent with existing handlers):**

```json
{
  "error": "<ERROR_CODE>",
  "message": "<human-readable detail>"
}
```

Note: the existing `instances.zig` uses a simpler `{"error":"<code>","message":"<msg>"}` shape (not full RFC 9457 Problem Details) via its private `errorResult()` helper. The two new handlers MUST use the same existing `errorResult()` helper for consistency within this file. Full RFC 9457 adoption is deferred to the api_conventions module (API-01).

---

## HTTP status codes — complete table

| Route                    | Condition                                | HTTP status | Response body                         |
|--------------------------|------------------------------------------|-------------|---------------------------------------|
| `GET /instances/:id`     | Success                                  | 200         | InstanceDetailResponse JSON           |
| `GET /instances/:id`     | Instance not found                       | 404         | `{"error":"INSTANCE_NOT_FOUND",...}`  |
| `GET /instances/:id`     | Invalid UUID path param                  | 422         | `{"error":"INVALID_INSTANCE_ID",...}` |
| `GET /instances/:id`     | Pool exhausted                           | 503         | `{"error":"SERVICE_UNAVAILABLE",...}` |
| `GET /instances/:id`     | Server error                             | 500         | `{"error":"INTERNAL_ERROR",...}`      |
| `GET /instances`         | Success (any result count incl. 0)       | 200         | InstanceListResponse JSON             |
| `GET /instances`         | Unknown `status` value                   | 422         | `{"error":"INVALID_STATUS",...}`      |
| `GET /instances`         | Invalid `definition_id` UUID format      | 422         | `{"error":"INVALID_DEFINITION_ID",...}` |
| `GET /instances`         | `page_size` <= 0 or > 200               | 422         | `{"error":"INVALID_PAGE_SIZE",...}`   |
| `GET /instances`         | Malformed cursor                         | 422         | `{"error":"INVALID_CURSOR",...}`      |
| `GET /instances`         | Expired cursor (> 24h)                   | 410         | `{"error":"CURSOR_EXPIRED",...}`      |
| `GET /instances`         | Pool exhausted                           | 503         | `{"error":"SERVICE_UNAVAILABLE",...}` |
| `GET /instances`         | Server error                             | 500         | `{"error":"INTERNAL_ERROR",...}`      |

---

## State transitions (relevant to GET semantics)

No state changes occur in the two GET handlers. The handlers are read-only. Relevant instance statuses returned:

```
ACTIVE      — instance is running; current_tasks may be non-empty
COMPLETED   — terminal; completed_at is non-null; current_tasks is empty
CANCELLED   — terminal; cancelled_at is non-null; current_tasks is empty
ERROR       — halted; error_detail is non-null; current_tasks may contain the task
              that triggered the error
```

GET /instances/:id always returns the current persisted projection state. It does NOT trigger state reconstruction (EE-11). Reconstruction is already exposed separately via `POST /instances/:id/reconstruct`.

---

## Dependencies

| Dependency                             | Direction                                      | Notes                                                                       |
|----------------------------------------|------------------------------------------------|-----------------------------------------------------------------------------|
| `src/engine/instance.zig :: InstanceStore` | `instances.zig` → `InstanceStore`          | `getById()` and `list()` are new methods to be added by BACKEND-DEV        |
| `src/tasks/store.zig :: TaskStore`     | `InstanceStore.getById` → `TaskStore`          | Fetch PENDING tasks for the instance; two queries in the same connection or two separate pool acquires |
| `src/api/errors.zig`                   | existing `errorResult()` helper in instances.zig | Reuse existing pattern; no change to error helper needed                  |
| `src/api/middleware/auth.zig`          | upstream → provides authenticated caller ctx   | Handler trusts that auth middleware ran; role check: any authenticated role |
| `src/api/middleware/rbac.zig`          | upstream → enforces role                       | Both GET routes: any authenticated role passes                              |
| `src/api/pagination.zig`              | `handleList` → cursor encode/decode            | Reuse or extend existing cursor helpers from definitions.zig; same pattern  |

**MUST NOT depend on:**
- `src/engine/transition.zig` — GET routes do not trigger state transitions.
- `src/engine/reconstruction.zig` — reconstruction is `POST /:id/reconstruct`, not GET /:id.
- `src/definition/store.zig` — instance handlers do not need to query definition records.
- Any external HTTP service.

---

## SQL query sketches (for BACKEND-DEV reference, not implementation)

These are guidance outlines. Schema decisions (column names, types) belong to migration files.

**getById — instance projection:**
```sql
SELECT
    instance_id,
    definition_id,
    correlation_key,
    status,
    variables,
    error_detail,
    (EXTRACT(EPOCH FROM started_at) * 1000000)::bigint   AS started_at_us,
    (EXTRACT(EPOCH FROM completed_at) * 1000000)::bigint AS completed_at_us,
    (EXTRACT(EPOCH FROM cancelled_at) * 1000000)::bigint AS cancelled_at_us
FROM instance_projections
WHERE instance_id = $1::uuid
```

**getById — PENDING tasks:**
```sql
SELECT
    id,
    node_id,
    node_name,
    status,
    assignee_type,
    assignee_ref,
    token_id,
    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us
FROM tasks
WHERE instance_id = $1::uuid
  AND status = 'PENDING'
ORDER BY created_at ASC
```

Security: both queries use `$1::uuid` — no user string interpolation into SQL.

**list — without cursor:**
```sql
SELECT
    instance_id,
    definition_id,
    correlation_key,
    status,
    (EXTRACT(EPOCH FROM started_at) * 1000000)::bigint AS started_at_us
FROM instance_projections
WHERE ($2::text IS NULL OR status = $2)
  AND ($3::uuid IS NULL OR definition_id = $3::uuid)
ORDER BY started_at DESC, instance_id DESC
LIMIT $1
```

**list — with cursor (keyset pagination):**
```sql
SELECT
    instance_id,
    definition_id,
    correlation_key,
    status,
    (EXTRACT(EPOCH FROM started_at) * 1000000)::bigint AS started_at_us
FROM instance_projections
WHERE ($4::text IS NULL OR status = $4)
  AND ($5::uuid IS NULL OR definition_id = $5::uuid)
  AND (started_at, instance_id) < (
        to_timestamp($2::bigint / 1000000.0),
        $3::uuid
      )
ORDER BY started_at DESC, instance_id DESC
LIMIT $1
```

Security: all filter values bound as `$N` parameters. The `(started_at, instance_id) < (...)` row comparison is a SQL standard construct; neither value is interpolated.

---

## Open questions

**OQ-1 — Cursor expiry mechanism:**
API-06 requires cursors to expire after 24 hours and return HTTP 410. The cursor format proposed above encodes `started_at_us` of the last-seen item, not a cursor creation timestamp. This means the handler cannot determine cursor age from the cursor value alone.

Two options:
- (a) Embed a cursor creation timestamp in the cursor payload: `base64url_no_pad(started_at_us || ":" || instance_id_hex || ":" || cursor_created_at_us)`. Adds 20+ bytes but enables expiry check without external storage.
- (b) Check: if the row at `(started_at_us, instance_id_hex)` no longer exists (data was deleted or started_at changed) and the data is > 24h old, treat as expired. Expensive and fragile.

Option (a) is strongly recommended. BACKEND-DEV should use option (a) and add the same pattern to definitions list if not already done. Needs confirmation that the definitions list uses the same cursor shape before BACKEND-DEV standardises.

**OQ-2 — Two queries for getById (instance + tasks):**
`InstanceStore.getById()` needs data from two tables: `instance_projections` and `tasks`. Options:

- (a) Two separate SQL queries on two pool-acquired connections: simple, but two round-trips.
- (b) One pool acquire, two sequential queries on the same connection (no transaction needed for read-only).
- (c) JOIN in a single query: works but returns a Cartesian product (one row per task), requiring de-duplication in application code.

Option (b) is recommended: one pool acquire, two sequential SELECTs. BACKEND-DEV should choose the implementation detail; it does not affect the public handler interface.

**OQ-3 — `variables` field serialisation in GET /instances/:id response:**
The `variables` column in `instance_projections` is stored as JSONB. When fetched, `pg.zig` returns it as a JSON string. The handler will embed this string directly in the response body. This avoids double-parsing but means the `variables` field in the JSON response is a JSON-string-embedded-in-JSON. Two options:

- (a) Embed `variables` as a nested JSON object (re-parse and re-serialise): correct JSON nesting, but extra allocation.
- (b) Embed `variables` as a pre-escaped string in the JSON body (current approach in `handleReconstruct`): avoids re-parse, but the caller receives a JSON string, not a JSON object, for the `variables` field.

Option (a) is correct for API usability. The response should include `"variables": { ... }` (object), not `"variables": "{...}"` (string). BACKEND-DEV should use `std.json.Stringify` to embed the JSONB string as a parsed object.
