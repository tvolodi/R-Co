# Design: SBX-04 / SBX-05 / SBX-06 — Sandbox ownership binding, inaccessible-sandbox sentinel, and claim/release/reclaim audit

**Requirements:** SBX-04, SBX-05, SBX-06  
**Stage:** 17  
**Run:** WF02-sbx04-06-20260819  
**Artefact type:** Type C (migration 1172) + Type E (cross-cutting logic)

---

## 1. Module purpose

This design covers three tightly coupled requirements that together close the sandbox ownership surface:

- **SBX-04** — At claim, bind the sandbox row to the triple `(tenant_schema, agent_principal, task_spec_id)` under a partial unique index. Concurrent or cross-principal claims return HTTP 409 `sandbox_already_claimed` without disclosing the existing owner.
- **SBX-05** — Every "inaccessible" outcome (nonexistent sandbox, cross-tenant sandbox, wrong-principal sandbox) returns the single byte-identical sentinel HTTP 403 `sandbox_not_accessible`. Probe bursts of 20 sentinels in 60 seconds trigger HTTP 429 `probe_rate_exceeded`.
- **SBX-06** — Only the bound `agent_principal` may release; pool manager reclaims idle sandboxes after 60 minutes. Four audit event types record every ownership transition so probe patterns are observable in the audit log even though no response leaks ownership information.

Affected files: `migrations/1172_sbx04_06_owner_binding.sql`, `src/api/routes/agent_sandboxes.zig`, `src/definition/sandbox_pool.zig`.

---

## 2. Type classification

| Requirement group | Type | Output artefact |
|---|---|---|
| Migration + constraint fix + probe counters table | **C** | `templates/specs/sbx04-06-migration.yaml` (see §3) |
| Sentinel enforcement, rate limiting, release endpoint, reclaim sweep, audit events | **E** | this file |

---

## 3. Database schema changes (migration 1172)

**Migration spec:** `templates/specs/sbx04-06-migration.yaml` (Type C — see §2)  
**Generated file:** `migrations/1172_sbx04_06_owner_binding.sql`  
**Scope:** `tenant_only` (all changes apply per-tenant schema; no `tenant_id` columns needed)

The full table/column/constraint/index shape is specified in the Type C parameter file. Key design decisions recorded here for BACKEND-DEV:

- **`last_active_at`** (added to `agent_sandboxes`): nullable `TIMESTAMPTZ`; backfilled to `COALESCE(claimed_at, updated_at)` for existing rows. Updated on every in-sandbox operation and by the claim itself; cleared to NULL on release/reclaim. Used by the 60-minute idle-reclaim sweep (§7).

- **`ux_sandbox_owner` constraint replacement**: the column-level `UNIQUE (owner_principal, task_spec_id)` from migration 1170 is dropped and replaced by a partial unique index `ON agent_sandboxes (task_spec_id) WHERE status = 'claimed'`. The original constraint allowed cross-principal double-claims for the same `task_spec_id`; the partial index enforces exactly one claimed row per `task_spec_id` within the tenant schema while leaving unclaimed rows unrestricted.

- **`sandbox_probe_counters`** table: per-principal sliding-window counter separate from `rate_limit_buckets` (GBL-122). `window_start` is `EXTRACT(EPOCH FROM NOW())::bigint / 60 * 60`; rows older than the current window are purged opportunistically. Threshold constants (20 / 60 s) are compile-time constants, not env-configured.

**Probe rate limit parameters (constants in source, not env-configured):**
- Window length: 60 seconds
- Threshold: 20 sentinel responses per window per principal

---

## 4. New audit event types

Audit events use the existing `writeAuditInTx` call with the `action` string set as follows. `resource_type` is always `"agent_sandbox"`. The `after_state` JSON carries the fields required by SBX-06 for forensic audit trail.

| Logical name | `action` string | Trigger | `after_state` JSON fields |
|---|---|---|---|
| SandboxClaimed | `"sandbox.claimed"` | Successful claim | `principal`, `sandbox_id`, `task_spec_id`, `claimed_at` |
| SandboxClaimRejected | `"sandbox.claim_rejected"` | 409 or 403 on claim path | `principal`, `sandbox_id`, `rejection_code`, `task_spec_id` (if known) |
| SandboxReleased | `"sandbox.released"` | Successful voluntary release | `principal`, `sandbox_id`, `task_spec_id` |
| SandboxReclaimed | `"sandbox.reclaimed"` | Pool manager idle reclaim | `prior_principal`, `sandbox_id`, `task_spec_id`, `idle_minutes` |

> **SBX-06 invariant:** `SandboxClaimRejected` is appended **for every** sentinel response including those triggered by probe-rate enforcement — this means the audit trail always records the attempted `sandbox_id` and `principal` even though the HTTP response reveals nothing.

The existing `"sandbox.claim_rejected"` string already written by `handleClaimSandbox` (role gate path) is reused unchanged; the existing call site is extended to also populate `task_spec_id` in the `after_state` when the sandbox_id is parseable.

---

## 5. API endpoint changes

### 5.1 Endpoint inventory

| Method | Path | Handler | Change | SBX |
|---|---|---|---|---|
| `GET` | `/api/v1/agent/sandboxes` | `handleListSandboxes` | No change | — |
| `POST` | `/api/v1/agent/sandboxes/{id}/claim` | `handleClaimSandbox` | Extend: set `last_active_at`, write `sandbox.claimed` audit, fix ux_sandbox_owner alignment | SBX-04 |
| `DELETE` | `/api/v1/agent/sandboxes/{id}/claim` | `handleReleaseSandbox` | **New** | SBX-06 |
| `*` | All operation endpoints inside a claimed sandbox | various (future SBX-07+) | Must call `checkPrincipalBound` before servicing, update `last_active_at` | SBX-04/05 |

> **Note on PATCH vs POST for claim:** The existing SBX-03 implementation uses `POST /sandboxes/{id}/claim`. SBX-04 extends the same handler. BACKEND-DEV must keep the method as `POST` (changing to PATCH would break the already-released SBX-03 integration tests). The word "PATCH" in the task description is aspirational REST style, not a breaking route change.

### 5.2 `handleClaimSandbox` changes (SBX-04)

The existing handler in `agent_sandboxes.zig` performs:
1. Role gate (implementer only)
2. `UPDATE agent_sandboxes SET status='claimed', owner_principal=$1, claimed_at=NOW() WHERE sandbox_id=$2 AND status='unclaimed'`
3. On unique constraint violation: return 409 `sandbox_already_claimed`

Changes required for SBX-04:
- Parse `task_spec_id` from request body JSON (`{"task_spec_id": "uuid-string"}`).
- **DB pre-validation of `task_spec_id`** (V-01 fix — INV-2 compliance): before binding, execute a tenant-scoped existence check:
  ```sql
  SELECT 1 FROM task_specs
  WHERE tenant_id = current_setting('app.current_tenant_id')::uuid
    AND task_spec_id = $1::uuid
  ```
  - If 0 rows: return HTTP 404 `task_spec_not_found`. This is a precondition failure — the spec does not exist in this tenant. Do **not** emit the SBX-05 sentinel (404 vs 403 signals a missing prerequisite, not a sandbox access denial).
  - If 1 row: proceed to the UPDATE below.
  - This prevents an authenticated implementer from claiming a sandbox under an arbitrary forged UUID: only `task_spec_id` values that exist in the tenant's `task_specs` table are accepted. Tenant isolation is enforced by the `tenant_id = current_setting(...)::uuid` predicate in the same query (SPT-03 compliant).
  - Note: this check confirms the task spec exists in the tenant but does **not** enforce that the caller was dispatched for it; dispatch authorization is a future stage 17 extension (see §13 OQ-SBX-03).
- Include `task_spec_id` in the UPDATE: `SET ..., task_spec_id = $3::uuid, last_active_at = NOW()`.
- On success (1 row updated): write `sandbox.claimed` audit entry.
- On unique constraint violation (`ux_sandbox_owner`): write `sandbox.claim_rejected` audit entry, return 409.
- On 0 rows updated (sandbox not unclaimed, or sandbox doesn't belong to tenant): **do not** return a distinct "not found" — run the SBX-05 sentinel path (see §6).

### 5.3 `handleReleaseSandbox` (SBX-06) — new handler

- Method: `DELETE /api/v1/agent/sandboxes/{id}/claim`
- Role gate: implementer only (orchestrator receives `sandbox_not_accessible`).
- Load sandbox via `checkPrincipalBound` (see §6.1). Mismatch or not-found → sentinel.
- If bound principal matches caller: `UPDATE agent_sandboxes SET status='released', owner_principal=NULL, task_spec_id=NULL, claimed_at=NULL, last_active_at=NULL, updated_at=NOW() WHERE sandbox_id=$1 AND status='claimed' AND owner_principal=$2`.
- Write `sandbox.released` audit entry.
- Return HTTP 204.

---

## 6. SBX-05 sentinel enforcement

### 6.1 `checkPrincipalBound` — shared row-loading function

All handlers that operate on a claimed sandbox call one shared function that loads the row and validates both tenant scope and principal binding in a **single query**. This satisfies SBX-05's "tenant predicate in same query as row load" requirement, eliminating the timing difference between the "sandbox not found" and "sandbox exists but wrong tenant" code paths.

```zig
pub const SandboxAccessResult = union(enum) {
    ok: SandboxRow,
    inaccessible: void,
};

pub fn checkPrincipalBound(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    sandbox_id: []const u8,
    caller_principal: []const u8,
) db.QueryError!SandboxAccessResult;
```

Query shape:
```sql
SELECT sandbox_id::text, status, owner_principal, task_spec_id::text, claimed_at
FROM agent_sandboxes
WHERE sandbox_id = $1::uuid
  AND status = 'claimed'
  AND owner_principal = $2
```

All three negative cases (nonexistent, wrong tenant via search_path isolation, wrong principal) return zero rows — the caller receives `inaccessible` and must emit the sentinel. The query is parameterised by `(sandbox_id, caller_principal)`; the tenant scope is implicit in the schema search-path (SPT-03).

### 6.2 Sentinel response — byte-identical body and header set

The sentinel response must be byte-identical across all inaccessible cases. A single `sendSentinel403` helper produces it:

```zig
pub fn sendSentinel403(allocator: std.mem.Allocator) HandlerResult;
```

Fixed body: `{"detail":"sandbox_not_accessible","status":403}` (no trailing newline, no whitespace variation).  
Fixed headers: `Content-Type: application/json` only (no `X-Sandbox-*` headers, no timestamp headers that vary by call).

### 6.3 Probe rate-limiting (SBX-05)

Every invocation of `sendSentinel403` is preceded by a call to `checkProbeRate`. If the rate limit is exceeded, the handler emits HTTP 429 instead of 403 — and still writes the `sandbox.claim_rejected` audit entry.

```zig
pub const ProbeRateResult = union(enum) {
    allowed: void,
    exceeded: u32, // seconds until window resets (Retry-After value)
};

pub fn checkProbeRate(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    principal: []const u8,
) db.QueryError!ProbeRateResult;
```

Algorithm (mirrors `rate_limit.zig` but with separate table and tighter threshold):
1. Compute `window_start = EXTRACT(EPOCH FROM NOW())::bigint / 60 * 60`.
2. `INSERT INTO sandbox_probe_counters (principal, window_start, count) VALUES ($1, $2, 1) ON CONFLICT (principal, window_start) DO UPDATE SET count = sandbox_probe_counters.count + 1 RETURNING count`.
3. If returned `count > 20`: transaction commits (count is recorded), return `exceeded` with `retry_after = window_start + 60 - NOW()::bigint`.
4. Opportunistic cleanup: `DELETE FROM sandbox_probe_counters WHERE window_start < $window_start`.

The 429 response body: `{"detail":"probe_rate_exceeded","status":429}`.  
The 429 response includes `Retry-After: <seconds>` header.

### 6.4 Audit write on sentinel

Both the 403 and 429 paths write a `sandbox.claim_rejected` entry. The audit entry carries `principal`, `sandbox_id` (as-supplied by the caller — not validated to exist, so it may be any string the caller sent), and `rejection_code` (`"sandbox_not_accessible"` or `"probe_rate_exceeded"`). The `after_state` JSON always includes the `tenant_id` (read from `auth.tenant_id`) so the owning tenant is recorded even though no response body carries it.

---

## 7. Pool manager idle-reclaim logic (SBX-06)

### 7.1 Sweep function

A new exported function on `SandboxPool` performs the idle-reclaim sweep. It is called by the main background timer (or by a dedicated goroutine/thread — exact wiring is BACKEND-DEV's decision) at a configurable interval (default 5 minutes; the 60-minute idle threshold is applied inside the query, not the sweep interval).

```zig
pub fn reclaimIdleSandboxes(
    self: *SandboxPool,
    allocator: std.mem.Allocator,
    io: std.Io,
) SandboxPoolError!u32; // returns count of sandboxes reclaimed this sweep
```

### 7.2 Sweep query

Within a single transaction:
1. Select all idle sandboxes: `SELECT sandbox_id::text, owner_principal, task_spec_id::text FROM agent_sandboxes WHERE status = 'claimed' AND last_active_at < NOW() - INTERVAL '60 minutes' FOR UPDATE SKIP LOCKED`.
2. For each row: `UPDATE agent_sandboxes SET status = 'released', owner_principal = NULL, task_spec_id = NULL, claimed_at = NULL, last_active_at = NULL, updated_at = NOW() WHERE sandbox_id = $1`.
3. Write `sandbox.reclaimed` audit entry (within the same transaction via `writeAuditInTx`).

`FOR UPDATE SKIP LOCKED` prevents double-reclaim when multiple backend nodes run the sweep concurrently.

### 7.3 `last_active_at` update discipline

Every handler that operates inside a claimed sandbox must update `last_active_at = NOW()` on the `agent_sandboxes` row as part of the operation's transaction. The update must be **within the same transaction** as the main state change (not a separate UPDATE after the fact), so a rolled-back operation does not advance the idle timer.

The claim handler sets `last_active_at = NOW()` alongside `claimed_at`. The release handler clears it to NULL. The reclaim sweep matches on `last_active_at < NOW() - INTERVAL '60 minutes'`.

---

## 8. Data flow diagram

```
Caller
  │
  ▼
[Auth middleware]  →  auth.tenant_id, auth.user_id (agent principal)
  │
  ▼
[Role gate: requireImplementerClaim]
  │ fail → 403 + sandbox.claim_rejected audit
  │ pass
  ▼
[checkProbeRate(principal, conn)]
  │ exceeded → 429 + sandbox.claim_rejected audit
  │ allowed
  ▼
[CLAIM path]                              [RELEASE path]
  │                                           │
  ▼                                           ▼
UPDATE agent_sandboxes                  checkPrincipalBound(sandbox_id, principal)
  WHERE sandbox_id = $1 AND               │ inaccessible → 403 sentinel + claim_rejected audit
    status = 'unclaimed'                  │ ok
  SET status='claimed',                   ▼
      owner_principal=$2,           UPDATE agent_sandboxes SET status='released' ...
      task_spec_id=$3,              writeAuditInTx("sandbox.released", ...)
      last_active_at=NOW()          → HTTP 204
  │
  ├─ 0 rows → checkPrincipalBound() → sentinel path (§6.2/6.3)
  ├─ unique constraint violation → 409 + sandbox.claim_rejected audit
  └─ 1 row → writeAuditInTx("sandbox.claimed", ...) → HTTP 201


[Pool manager sweep — background]
  │
  ▼
SELECT claimed sandboxes WHERE last_active_at < NOW() - 60min FOR UPDATE SKIP LOCKED
  │
  for each row:
    UPDATE → status='released', owner_principal=NULL ...
    writeAuditInTx("sandbox.reclaimed", prior_principal, ...)
```

---

## 9. Error taxonomy

| Error case | Path | HTTP status | Error code | Audit written? |
|---|---|---|---|---|
| `task_spec_id` not found in tenant's `task_specs` | CLAIM | 404 | `task_spec_not_found` | No — precondition failure before sandbox access |
| Caller lacks implementer role | CLAIM | 403 | `implementer_role_required` | Yes — `sandbox.claim_rejected` |
| Caller is orchestrator | CLAIM | 403 | `orchestrator_may_not_claim` | Yes — `sandbox.claim_rejected` |
| Caller is orchestrator | RELEASE | 403 | `sandbox_not_accessible` | Yes — `sandbox.claim_rejected` |
| Sandbox does not exist | CLAIM, RELEASE | 403 | `sandbox_not_accessible` | Yes — `sandbox.claim_rejected` |
| Sandbox exists in another tenant (implicit via schema isolation) | CLAIM, RELEASE | 403 | `sandbox_not_accessible` | Yes — `sandbox.claim_rejected` |
| Sandbox claimed by different principal | RELEASE | 403 | `sandbox_not_accessible` | Yes — `sandbox.claim_rejected` |
| Sandbox already claimed (unique index on task_spec_id) | CLAIM | 409 | `sandbox_already_claimed` | Yes — `sandbox.claim_rejected` |
| Probe rate exceeded (20 sentinels / 60 s) | CLAIM, RELEASE | 429 | `probe_rate_exceeded` | Yes — `sandbox.claim_rejected` with code `probe_rate_exceeded` |
| Non-owner calling release | RELEASE | 403 | `sandbox_not_accessible` | Yes — `sandbox.claim_rejected` |
| DB pool exhausted | CLAIM, RELEASE | 503 | `pool_exhausted` | No |
| Out of memory | CLAIM, RELEASE | 503 | `out_of_memory` | No |

> **Path notes:** `implementer_role_required` and `orchestrator_may_not_claim` are CLAIM-path only. On the RELEASE path, an orchestrator caller receives `sandbox_not_accessible` (same sentinel as all other unauthorized callers), per SBX-06 AC.

---

## 10. Zig type signatures

No function bodies are specified here. These signatures define the public interface for BACKEND-DEV.

### 10.1 `src/api/routes/agent_sandboxes.zig` — additions and changes

```zig
// Existing handler — extended for SBX-04 (task_spec_id + last_active_at + audit)
// Pre-validates task_spec_id against task_specs (tenant-scoped) before the claim UPDATE; returns 404 if not found.
pub fn handleClaimSandbox(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    auth: auth_mod.AuthContext,
    sandbox_id: []const u8,
    body_json: []const u8,     // must contain {"task_spec_id": "..."}; validated against task_specs before binding
) HandlerResult;

// New handler — SBX-06 release
pub fn handleReleaseSandbox(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    auth: auth_mod.AuthContext,
    sandbox_id: []const u8,
) HandlerResult;

// Shared sentinel helper — byte-identical 403 body
fn sendSentinel403(allocator: std.mem.Allocator) HandlerResult;

// Shared 429 helper
fn sendProbeRateExceeded(allocator: std.mem.Allocator, retry_after: u32) HandlerResult;
```

### 10.2 `src/api/routes/sandbox_access.zig` — new file for shared access helpers

Extracted into a separate file to keep `agent_sandboxes.zig` focused on HTTP routing and to allow future operation handlers to import the sentinel and probe-rate functions without importing the route module.

```zig
pub const SandboxRow = struct {
    sandbox_id: []const u8,
    status: []const u8,
    owner_principal: ?[]const u8,
    task_spec_id: ?[]const u8,
    claimed_at: ?[]const u8,
    last_active_at: ?[]const u8,
};

pub const SandboxAccessResult = union(enum) {
    ok: SandboxRow,
    inaccessible: void,
};

pub const ProbeRateResult = union(enum) {
    allowed: void,
    exceeded: u32,
};

/// Load sandbox row and validate principal binding in one query.
/// Returns inaccessible for all three SBX-05 negative cases.
pub fn checkPrincipalBound(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    sandbox_id: []const u8,
    caller_principal: []const u8,
) db.QueryError!SandboxAccessResult;

/// Increment probe counter and check threshold (20 / 60 s).
pub fn checkProbeRate(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    principal: []const u8,
) db.QueryError!ProbeRateResult;
```

### 10.3 `src/definition/sandbox_pool.zig` — new function

```zig
/// Reclaim all sandboxes idle for > 60 minutes.
/// Returns the count of sandboxes reclaimed in this sweep.
/// Writes sandbox.reclaimed audit entries within the reclaim transaction.
pub fn reclaimIdleSandboxes(
    self: *SandboxPool,
    allocator: std.mem.Allocator,
    io: std.Io,
) SandboxPoolError!u32;
```

---

## 11. Dependencies

| Module | Depends on | Must not depend on |
|---|---|---|
| `sandbox_access.zig` | `pool` (db conn), `obs/audit.zig` | `agent_sandboxes.zig` (routing layer) |
| `agent_sandboxes.zig` (handlers) | `sandbox_access.zig`, `obs/audit.zig`, `api/middleware/agent_auth.zig` | `sandbox_pool.zig` (pool manager is a separate concern) |
| `sandbox_pool.zig` (reclaimIdleSandboxes) | `pool`, `obs/audit.zig` | `agent_sandboxes.zig` |
| Migration 1172 | Migration 1170 (agent_sandboxes table must exist) | — |

---

## 12. State transitions

```
unclaimed ──[claim POST, implementer, task_spec_id supplied]──► claimed
    │                                                               │
    │                                                 [release DELETE, bound principal]
    │                                                 [reclaim sweep, 60-min idle]
    │                                                               │
    └───────────────────────────────────────────────────────► released
```

`claimed → released` is the only valid transition for SBX-04/05/06. A released sandbox becomes `unclaimed`-equivalent for re-claim purposes (the existing `status IN ('unclaimed','claimed','released','failed')` check-constraint permits this).

---

## 13. Open questions

None. Requirements SBX-04/05/06 are unambiguous. Two design decisions are recorded here for CODE-DESIGN-VALIDATOR review:

- **OQ-SBX-01 (RESOLVED in design):** The partial unique index `ux_sandbox_owner (task_spec_id) WHERE status = 'claimed'` replaces the column-level constraint `UNIQUE (owner_principal, task_spec_id)` from migration 1170. The original constraint allowed cross-principal double-claims for the same task_spec, which violates SBX-04. BACKEND-DEV must not reinstate the old constraint shape.

- **OQ-SBX-02 (RESOLVED in design):** Probe counters use a separate `sandbox_probe_counters` table, not the global `rate_limit_buckets`. Rationale: the sentinel threshold (20/60 s) is not env-configurable and must not interfere with the global API rate limit used for all other endpoints.

- **OQ-SBX-03 (FUTURE REQUIREMENT — stage 17 limitation):** Stage 17 does not enforce that the implementer was dispatched for the task_spec; full dispatch authorization is out of scope for this stage and tracked as a future requirement. The DB pre-validation in §5.2 confirms the task_spec exists in the tenant, but does not verify that this caller principal was assigned to work on it. When dispatch tables are available in a future stage, an additional check will bind `task_spec_id` to the dispatched principal before the claim proceeds.

---

## 14. Migration file name

`migrations/1172_sbx04_06_owner_binding.sql`

> Follows the numeric sequence: last migration is `1171_agt01_03_agent_artifacts.sql`.
