# Module: idn05-role-registry

**Covers:** IDN-05 (Named role registry and ROLE assignee resolution)
**Classification:** Type C (migration `1154_idn05_tenant_role_registry.sql`) + Type A (GET /roles, POST /roles in `templates/specs/idn05-roles.crud-endpoint.yaml`) + Type E (EE-03 ROLE resolution logic — this document)
**Files (new):** `src/identity/role_registry.zig`, `migrations/1154_idn05_tenant_role_registry.sql`
**Files (modified):** `src/engine/instance.zig` (ROLE resolution injected into `applyTransition`), `src/api/routes/identity.zig` (new GET/POST /roles handlers)
**Depends on:**
- `src/identity/registry.zig` — existing `groups` table queries (read-only; existence check)
- `src/engine/instance.zig` — `applyTransition`; `TaskStore.createInTx`
- `src/tasks/store.zig` — `createInTx` receives resolved `assignee_type` + `assignee_ref`
- `src/api/middleware/rbac.zig` — PROCESS_DESIGNER and PLATFORM_ADMIN checks
- `src/db/pool.zig` — `db.Pool`, `db.Conn`

**Distinct from IDN-03:** IDN-03 defines the fixed 3-tier platform RBAC (`PLATFORM_ADMIN`, `PROCESS_DESIGNER`, `PROCESS_OPERATOR`, `TASK_WORKER`). IDN-05 defines an open-ended, tenant-controlled registry of *business-domain* role names (e.g. "Finance Approver", "IT Reviewer") that process designers embed in HUMAN_TASK nodes. The two systems share the word "role" but are entirely separate concepts with separate tables.

---

## Module purpose

IDN-05 adds a per-tenant named-role registry — the `tenant_role` table — that decouples how process designers name participants from how the platform resolves them to concrete groups of users. When a HUMAN_TASK node carries `assignee_type = ROLE` and `assignee_ref = "Finance Approver"`, the execution engine (EE-03) looks up that name in the calling tenant's `tenant_role` table and, if a binding exists, creates the task with `assignee_type = 'GROUP'` and `assignee_ref = <resolved_group_id>`. If no binding exists the task is still created (PENDING, unresolved), so the instance never transitions to ERROR solely because a role name is not yet registered.

Tenant isolation is provided by the per-tenant schema (SPT architecture). The `tenant_role` table is provisioned in each tenant's schema; no `tenant_id` column is needed. The same role name string may independently map to different group UUIDs in different tenants — this is the mechanism that solution-pack manifests (SOL-01) rely on.

---

## 1. Database schema (Type C — see `templates/specs/idn05-tenant-role.migration.yaml`)

### `tenant_role` table (new — migration `1154_idn05_tenant_role_registry.sql`)

```
tenant_role
────────────────────────────────────────────────────────────────────────
id          UUID        PRIMARY KEY DEFAULT gen_random_uuid()
name        TEXT        NOT NULL
group_id    UUID        NOT NULL REFERENCES groups(id) ON DELETE RESTRICT
created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()

UNIQUE (name)
```

**Schema-scoped (no `tenant_id` column).** Like `groups` and `users`, `tenant_role` lives in the per-tenant schema; the schema search path set by the request context provides tenant isolation.

**`UNIQUE (name)`** — each tenant may register a role name exactly once. An `ON CONFLICT (name) DO UPDATE SET group_id = EXCLUDED.group_id` upsert implements re-binding.

**`REFERENCES groups(id) ON DELETE RESTRICT`** — a group that has active role bindings cannot be deleted. Group deletion is out of scope for IDN-02 and IDN-05; this FK enforces referential integrity defensively.

**Indexes:**
- `idx_tenant_role_name ON tenant_role(name)` — fast lookup by name at task activation
- `idx_tenant_role_group ON tenant_role(group_id)` — fast lookup for cascading effects if group management grows

---

## 2. Domain types

**File:** `src/identity/role_registry.zig`

### `TenantRole` struct

```
TenantRole {
    id:         Uuid        -- platform-assigned UUID PK
    name:       []const u8  -- role name string (caller-owned slice)
    group_id:   Uuid        -- bound group UUID
    created_at: i64         -- UTC epoch microseconds (from role_registry.created_at)
}
```

All `[]const u8` fields are allocated with the caller-supplied `std.mem.Allocator` and owned by the caller.

### `TenantRoleError` error set

```
TenantRoleError {
    GroupNotFound      -- group_id supplied to upsertRole does not exist; HTTP 404
    RoleNameInvalid    -- name is empty, exceeds 128 codepoints, or contains control chars; HTTP 422
    GroupIdInvalid     -- group_id is not a valid UUID v4 string; HTTP 422
    PoolExhausted      -- db.Pool.acquire() failed; HTTP 503
    PersistenceFailed  -- unexpected DB error; HTTP 500
    OutOfMemory        -- std.mem.Allocator returned OutOfMemory
}
```

**Note:** `resolveRoleInTx` (used inside `applyTransition`) does **not** return `TenantRoleError`. It returns `?Uuid` — null when the role is unbound. Role resolution failure is never surfaced as an error to the activation path; it silently produces a PENDING unresolved task.

---

## 3. Public interface — `TenantRoleStore`

**File:** `src/identity/role_registry.zig`

### Struct definition

```
pub const TenantRoleStore = struct {
    pool: *db.Pool,
    pub fn init(pool: *db.Pool) TenantRoleStore;
};
```

`pool` must outlive `TenantRoleStore`.

### 3a. `upsertRole`

```
pub fn upsertRole(
    self: *TenantRoleStore,
    allocator: std.mem.Allocator,
    name: []const u8,
    group_id: []const u8,   -- UUID v4 hex string
) TenantRoleError!TenantRole
```

**Algorithm:**

1. Validate `name`: must be non-empty and ≤ 128 UTF-8 codepoints, must not contain ASCII control characters (0x00–0x1F, 0x7F). If invalid → `TenantRoleError.RoleNameInvalid`.
2. Parse `group_id` as a UUID v4 hex string. If malformed → `TenantRoleError.GroupIdInvalid`.
3. Acquire a connection from `self.pool` (→ `TenantRoleError.PoolExhausted` on failure).
4. Execute within a transaction:

   **Step a — existence check:**
   ```sql
   SELECT id FROM groups WHERE id = $1::uuid
   ```
   Parameter: `$1` = `group_id` hex string.
   - 0 rows → rollback, return `TenantRoleError.GroupNotFound`.

   **Step b — upsert:**
   ```sql
   INSERT INTO tenant_role (name, group_id)
   VALUES ($1, $2::uuid)
   ON CONFLICT (name) DO UPDATE SET group_id = EXCLUDED.group_id
   RETURNING id, name, group_id,
       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint
   ```
   Parameters: `$1` = `name` (TEXT), `$2` = `group_id` (UUID hex).

5. Build and return `TenantRole` from the RETURNING row. All slice fields duplicated into `allocator`.

**Security invariants:** All user-supplied values bound via `$N` positional parameters. No SQL string interpolation of `name` or `group_id`.

**Response semantics:** HTTP 200 if an existing binding was updated (role name already existed); HTTP 201 if a new binding was created. The handler distinguishes these by checking whether the returned `created_at` matches `NOW()` vs a historical timestamp — or more simply by returning HTTP 200 unconditionally (the requirement does not mandate a 201 vs 200 distinction).

### 3b. `listRoles`

```
pub fn listRoles(
    self: *TenantRoleStore,
    allocator: std.mem.Allocator,
) TenantRoleError![]TenantRole
```

**Algorithm:**

1. Acquire a connection from `self.pool` (→ `TenantRoleError.PoolExhausted`).
2. Execute:
   ```sql
   SELECT id, name, group_id,
       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint
   FROM tenant_role
   ORDER BY name ASC
   ```
   No parameters (scoped via schema search path).
3. Return a caller-owned slice of `TenantRole` structs. An empty table returns `&[0]TenantRole{}` (not an error).

**Pagination:** Not required by IDN-05. The role registry is expected to be small (tens of entries per tenant). If volume requirements change, pagination can be added in a later requirement without breaking callers.

### 3c. `resolveRoleInTx`

```
pub fn resolveRoleInTx(
    conn: *db.Conn,
    name: []const u8,
) ?Uuid
```

**Called from inside an existing DB transaction** (the `applyTransition` transaction). Does NOT acquire a new connection. Does NOT error — returns `null` if the role is not bound.

**Algorithm:**

Execute on `conn`:
```sql
SELECT group_id FROM tenant_role WHERE name = $1
```
Parameter: `$1` = `name` (TEXT).

- 1 row returned → parse `group_id` as `Uuid` and return it (`.some`).
- 0 rows returned → return `null`.
- Any DB error → return `null` and log at WARN level. Do NOT propagate the error; role resolution failure is treated as "unbound" and must not abort the activation transaction.

**Rationale for null-on-error:** The EE-03 activation transaction must not fail due to a transient DB error on the role lookup. If the lookup fails, the task is created in the unbound-ROLE state; a PROCESS_OPERATOR can manually reassign. This is strictly safer than ERROR-transitioning the instance.

---

## 4. EE-03 integration — ROLE resolution at task activation

**File modified:** `src/engine/instance.zig`, inside `applyTransition`

### Where to inject

`applyTransition` already computes `new_task_node_ids` (the set difference of `new_state.pending_task_nodes` minus `old_state.pending_task_nodes`) and calls `task_store.createInTx` for each new task node. The ROLE resolution step is inserted **between** computing the `assignee_type`/`assignee_ref` from the definition snapshot node and calling `createInTx`.

`applyTransition` must receive a `*TenantRoleStore` (or a `*db.Pool` from which `role_registry.TenantRoleStore` is constructed). Because `applyTransition` already holds an open `*db.Conn` for its transaction, it should call `resolveRoleInTx(conn, assignee_ref)` directly rather than acquiring a second connection.

### Modified `applyTransition` signature

```
pub fn applyTransition(
    self: *InstanceStore,
    allocator: std.mem.Allocator,
    task_store: *task_mod.TaskStore,
    role_store: *role_registry_mod.TenantRoleStore,  -- NEW parameter
    instance_id: Uuid,
    old_state: transition.InstanceState,
    event: transition.TransitionEvent,
    snapshot: definition_graph.DefinitionGraph,
) ApplyError!transition.InstanceState
```

`role_store` is added as a dependency. BACKEND-DEV must wire it at the call site in `src/api/routes/instances.zig` (or wherever `applyTransition` is called).

### ROLE resolution algorithm (prose, no Zig)

For each new task node in the set difference:

1. Look up the `GraphNode` for `node_id` in `snapshot.nodes`.
2. Read `node.assignee_type` and `node.assignee_ref` from the node definition.
3. If `node.assignee_type` equals `"ROLE"`:
   a. Call `role_registry_mod.resolveRoleInTx(conn, node.assignee_ref)`.
   b. If result is non-null (`group_id` was found):
      - Call `task_store.createInTx(conn, instance_id, token_id, node_id, node_name, "GROUP", group_id_as_hex_string)`.
      - The task is created with GROUP semantics; any ACTIVE member of the resolved group may claim and complete it (IDN-02 rules apply unchanged).
   c. If result is null (role is unbound):
      - Call `task_store.createInTx(conn, instance_id, token_id, node_id, node_name, "ROLE", node.assignee_ref)`.
      - The task is created with `assignee_type='ROLE'` and `assignee_ref=<original_role_name>`.
      - Task status defaults to `'PENDING'` (the DB default). The instance does NOT transition to ERROR.
      - No error is returned; execution continues normally for all other task nodes in the same activation.
4. If `node.assignee_type` is not `"ROLE"` (i.e. `"USER"`, `"GROUP"`, or null): pass through to `createInTx` unchanged (existing behaviour, no modification).

### Claim-eligibility for unbound-ROLE tasks

The existing claim-eligibility check in `src/tasks/manager.zig` (or `src/api/routes/tasks.zig`) evaluates:
- `assignee_type = 'USER'` → only the named user may claim
- `assignee_type = 'GROUP'` → any ACTIVE member of the named group may claim
- `assignee_type = 'ROLE'` → **no automated eligibility** (the role is unresolved; no group is bound)
- `assignee_type = null` → platform-level assignment (PROCESS_OPERATOR or PLATFORM_ADMIN may assign)

A task with `assignee_type = 'ROLE'` must be treated as non-claimable by regular TASK_WORKERs until a PROCESS_OPERATOR or PLATFORM_ADMIN manually reassigns it (using the existing task reassignment API). No new case is needed in the claim logic — `'ROLE'` is already not handled (it falls through to "not eligible").

---

## 5. API surface (Type A — see `templates/specs/idn05-roles.crud-endpoint.yaml`)

### Authorization

Both endpoints require the caller to hold `PROCESS_DESIGNER` or `PLATFORM_ADMIN`. `TASK_WORKER` and `PROCESS_OPERATOR` are not authorised (this is a registry-management operation, not a task operation).

### GET /api/v1/roles

**Purpose:** List all role bindings for the calling tenant.

**Request:** No body. No query parameters required by IDN-05.

**Success response — HTTP 200:**
```json
{
  "roles": [
    {
      "id":         "<UUID>",
      "name":       "<string>",
      "group_id":   "<UUID>",
      "created_at": "<ISO 8601 UTC>"
    }
  ]
}
```
Array is sorted by `name ASC`. Empty tenant returns `{ "roles": [] }`.

**Error responses:**

| HTTP | Condition | `code` |
|------|-----------|--------|
| 503  | Pool exhausted | `SERVICE_UNAVAILABLE` |
| 500  | Unexpected DB error | `INTERNAL_ERROR` |

### POST /api/v1/roles

**Purpose:** Create or update (re-bind) a role name → group_id mapping.

**Request body:**
```json
{
  "name":     "<string>",
  "group_id": "<UUID>"
}
```

Field rules:
- `name`: required; non-empty string; max 128 UTF-8 codepoints; no control characters.
- `group_id`: required; must be a valid UUID v4 hex string; the group must exist in the tenant's `groups` table.

**Success response — HTTP 200:**
```json
{
  "id":         "<UUID>",
  "name":       "<string>",
  "group_id":   "<UUID>",
  "created_at": "<ISO 8601 UTC>"
}
```
HTTP 200 is returned for both create and update (upsert; no 201/200 distinction required).

**Error responses:**

| HTTP | Condition | `code` |
|------|-----------|--------|
| 400  | Malformed JSON | `MALFORMED_JSON` |
| 404  | `group_id` does not exist in the tenant | `GROUP_NOT_FOUND` |
| 422  | `name` empty / too long / control chars | `INVALID_ROLE_NAME` |
| 422  | `group_id` not a valid UUID | `INVALID_GROUP_ID` |
| 503  | Pool exhausted | `SERVICE_UNAVAILABLE` |
| 500  | Unexpected DB error | `INTERNAL_ERROR` |

---

## 6. Data flow diagram

**API endpoints:**

```
POST /api/v1/roles
  → auth middleware: require PROCESS_DESIGNER or PLATFORM_ADMIN (→ 403 otherwise)
  → parse body; validate name (→ 422 INVALID_ROLE_NAME) and group_id (→ 422 INVALID_GROUP_ID)
  → TenantRoleStore.upsertRole(name, group_id)
        → BEGIN
        → SELECT id FROM groups WHERE id = $1  (existence check)
              └─ 0 rows → ROLLBACK; return GroupNotFound → HTTP 404
        → INSERT INTO tenant_role (name, group_id)
          ON CONFLICT (name) DO UPDATE SET group_id = EXCLUDED.group_id
          RETURNING id, name, group_id, created_at
        → COMMIT
  → HTTP 200 TenantRole JSON

GET /api/v1/roles
  → auth middleware: require PROCESS_DESIGNER or PLATFORM_ADMIN (→ 403 otherwise)
  → TenantRoleStore.listRoles()
        → SELECT id, name, group_id, created_at FROM tenant_role ORDER BY name
  → HTTP 200 { "roles": [...] }
```

**EE-03 ROLE resolution (inside `applyTransition`):**

```
applyTransition begins — acquire conn, BEGIN
  │
  ├─ call transition() → new_state (pure; no I/O)
  ├─ write updated instance_projections
  ├─ append event to event_store
  │
  └─ for each node_id in (new pending_task_nodes − old pending_task_nodes):
        read GraphNode → assignee_type, assignee_ref

        if assignee_type == "ROLE":
          call resolveRoleInTx(conn, assignee_ref)
            → SELECT group_id FROM tenant_role WHERE name = $1
            → returns ?Uuid (null if not bound or transient error)

          if resolved (group_id found):
            createInTx(conn, ..., "GROUP", group_id_hex)
            Task: assignee_type='GROUP'; any ACTIVE group member may claim (IDN-02)

          if unresolved (null):
            createInTx(conn, ..., "ROLE", original_assignee_ref)
            Task: assignee_type='ROLE'; status='PENDING'; instance stays ACTIVE

        else (USER / GROUP / null):
          createInTx(conn, ..., original assignee_type, original assignee_ref)
  │
  COMMIT
```

---

## 7. Error taxonomy

| Error | Produced by | HTTP code | Meaning |
|---|---|---|---|
| `TenantRoleError.GroupNotFound` | `upsertRole` | 404 | `group_id` does not exist in `groups` table for this tenant |
| `TenantRoleError.RoleNameInvalid` | `upsertRole` handler (pre-validation) | 422 | `name` empty, > 128 codepoints, or contains control chars |
| `TenantRoleError.GroupIdInvalid` | `upsertRole` handler (pre-validation) | 422 | `group_id` is not a valid UUID hex string |
| `TenantRoleError.PoolExhausted` | `upsertRole`, `listRoles` | 503 | DB pool exhausted |
| `TenantRoleError.PersistenceFailed` | `upsertRole`, `listRoles` | 500 | Unexpected DB error |
| `null` (no error) | `resolveRoleInTx` | — | Role unbound; task created with ROLE assignee type; no HTTP error |

---

## 8. State transitions

### Role registry lifecycle

```
(no binding)
    │
    │  POST /roles { name, group_id }
    ▼
(name → group_id)              ← tenant_role row exists
    │
    │  POST /roles { name, group_id2 }    (re-binding)
    ▼
(name → group_id2)             ← ON CONFLICT DO UPDATE; old group_id replaced
```

### Task assignee state (EE-03 ROLE resolution)

```
HUMAN_TASK activates (assignee_type=ROLE, assignee_ref="Role Name")
    │
    ├── [tenant_role has binding for "Role Name"]
    │       │
    │       ▼
    │   Task row: assignee_type='GROUP', assignee_ref=<group_uuid>
    │       │
    │       └─ any ACTIVE group member may claim (IDN-02)
    │
    └── [tenant_role has NO binding for "Role Name"]
            │
            ▼
        Task row: assignee_type='ROLE', assignee_ref="Role Name"
            │                                        ↑ kept for audit visibility
            └─ task stays PENDING; no claim eligible
               until PROCESS_OPERATOR manually reassigns
```

**Re-binding does NOT affect existing tasks.** Tasks already created with `assignee_type='ROLE'` or resolved to a prior group are not updated when `POST /roles` is called with a new `group_id`. Only future task activations use the new binding.

---

## 9. Dependencies

| Import | Symbol(s) used | Why |
|---|---|---|
| `src/db/pool.zig` | `db.Pool`, `db.Conn` | Connection management |
| `src/identity/registry.zig` | `groups` table queries | Read-only group existence check in `upsertRole` |
| `src/engine/instance.zig` | `InstanceStore`, `applyTransition` | ROLE resolution injected into activation path |
| `src/tasks/store.zig` | `TaskStore.createInTx` | Task row creation with resolved assignee |
| `src/api/middleware/rbac.zig` | `PROCESS_DESIGNER`, `PLATFORM_ADMIN` checks | Authorization on GET/POST /roles |
| `src/api/errors.zig` | `errorResult`, `HandlerResult` | Error response construction |

**Must NOT depend on:** `src/engine/transition.zig` (the role registry is a persistence concern, not a pure transition concern), any module that performs HTTP calls, or any scheduler/timer module.

---

## 10. Security invariants

1. **No SQL interpolation.** All user-supplied values (`name`, `group_id`) are bound via `$N` positional parameters. SQL literal strings contain only fixed schema identifiers.
2. **Tenant isolation via schema.** `tenant_role` lives in the per-tenant schema. The schema search path must be set (by the auth middleware, per SPT architecture) before any query executes. The route handler must not accept a caller-supplied `tenant_id` query/body parameter — tenant scope is derived from the authenticated session.
3. **Authorization enforced before store calls.** RBAC middleware must reject non-PROCESS_DESIGNER, non-PLATFORM_ADMIN callers with HTTP 403 before `upsertRole` or `listRoles` is invoked. The store itself does not re-check authorization.
4. **Role resolution in EE-03 is read-only and non-fatal.** `resolveRoleInTx` never writes to `tenant_role`. A lookup error (transient DB issue) silently produces an unbound-ROLE task rather than aborting the activation transaction — this prevents a transient DB hiccup from ERROR-transitioning a running instance.

---

## 11. Open questions

| # | Question | Impact | Recommended resolution |
|---|---|---|---|
| OQ-1 | Should unbound-ROLE tasks retain `assignee_type='ROLE'` (preserving original intent for audit display) or be created with `assignee_type=NULL` (simpler for claim logic)? | Medium — affects claim-eligibility check and observability | **Recommended: retain `assignee_type='ROLE'`** so process operators can identify which role was expected. The claim-eligibility check already treats any unhandled `assignee_type` as not eligible. |
| OQ-2 | Route file placement: extend `src/api/routes/identity.zig` or create new `src/api/routes/roles.zig`? | Low — only affects file organisation | **Recommended: extend `identity.zig`** since role registry is identity-adjacent. BACKEND-DEV may decide otherwise if `identity.zig` has grown too large. |
| OQ-3 | Role name constraints: max length and forbidden characters not specified by IDN-05. | Low | **Recommended: max 128 UTF-8 codepoints; no ASCII control characters (0x00–0x1F, 0x7F)**. Reuse the existing name-validation helper from IDN-02 group creation if it covers these rules. |
| OQ-4 | Should `DELETE /roles/:name` be added to allow un-registering a role? IDN-05 does not require it, but SOL-01 un-install scenarios may need it. | Low (out of scope for IDN-05) | Defer to a future requirement. The `tenant_role` table FK ON DELETE RESTRICT on `groups` prevents orphaned bindings. |
| OQ-5 | The `applyTransition` signature adds a new `role_store` parameter. If `applyTransition` is called from multiple call sites, all must be updated simultaneously. | Medium — wiring impact | BACKEND-DEV: audit all callers of `applyTransition` before implementing; the parameter addition is breaking. |

---

## 12. Traceability table

| IDN-05 Acceptance Criterion | Design element |
|---|---|
| Per-tenant named role registry distinct from IDN-03 platform RBAC | `tenant_role` table in per-tenant schema (§1); `TenantRoleStore` in `src/identity/role_registry.zig` (§3); explicit note at top of document distinguishing IDN-03 vs IDN-05 |
| GET /roles — list bindings for calling tenant; requires PROCESS_DESIGNER or PLATFORM_ADMIN | §5 GET /roles; §5 Authorization; Type A spec `idn05-roles.crud-endpoint.yaml` |
| POST /roles — create/update binding; HTTP 404 if group_id does not exist | §3a `upsertRole` step a (group existence check → `GroupNotFound` → 404); §5 POST /roles error table |
| EE-03 integration: ROLE resolution at task activation; if unbound → PENDING (not ERROR) | §4 ROLE resolution algorithm (steps 3a–3c); §6 data flow diagram; §8 state transitions |
| Migration adding `tenant_role` table | §1 schema; Type C spec `idn05-tenant-role.migration.yaml` (migration `1154_idn05_tenant_role_registry.sql`) |
| Tenant scoping: same role name may map to different groups in different tenants | §1 (no `tenant_id` column; per-tenant schema isolation); §10 security invariant 2 |
| Re-binding does not affect existing PENDING tasks | §8 state transitions "Re-binding does NOT affect existing tasks"; §4 algorithm (lookup happens at activation time only — past tasks are not retroactively re-resolved) |
