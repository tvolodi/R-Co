# Test Spec: PRM-02 — Conflict preflight rejection

**Requirement:** PRM-02 — When a promotion targets a tenant whose active version of a process definition is ahead of the base_version (i.e., target_active_version > base_version), the promotion pipeline MUST reject with HTTP 409 and append a DEFINITION_PROMOTION_REJECTED event before any version pointer moves.
**Priority:** MUST
**Test layer:** integration

## Test Tier Derivation

| Dimension | Points | Notes |
|---|---|---|
| DB schema | 1 | Reads `process_definitions` in target tenant schema |
| Tenant isolation | 1 | Cross-tenant conflict check |
| Transactional boundary | 1 | Separate transaction for rejection event |
| **Total** | **3** | **Unit + integration** |

## Test Cases

### TC-PRM-02-01: No conflict when target has no ACTIVE version

**Given:** Target tenant has no ACTIVE definition for `process_key` (zero rows in `process_definitions WHERE name=$1 AND status='ACTIVE'`).

**When:** `rejectIfConflicts(target_tenant_id, process_key, base_version=1)` is called.

**Then:** Returns `null` — no conflict detected. Pipeline continues.

**Layer:** integration  
**Acceptance criterion:** PRM-02 AC — "If the target has no ACTIVE version of process_key (zero rows), MAX returns NULL → no conflict."

---

### TC-PRM-02-02: No conflict when target_version == base_version

**Given:** Target tenant has ACTIVE definition at version 3, and base_version is 3.

**When:** `rejectIfConflicts(target_tenant_id, process_key, base_version=3)` is called.

**Then:** Returns `null` — `target_version (3) <= base_version (3)` is NOT a conflict.

**Layer:** integration  
**Acceptance criterion:** PRM-02 AC — conflict condition is strictly `target_version > base_version`.

---

### TC-PRM-02-03: Conflict detected when target_version > base_version

**Given:** Target tenant has ACTIVE definition at version 5, and base_version is 3.

**When:** `rejectIfConflicts(target_tenant_id, process_key, base_version=3)` is called.

**Then:** Returns `ConflictRejection` with `target_version=5`. A separate transaction appends `DEFINITION_PROMOTION_REJECTED` to the event store.

**Layer:** integration  
**Acceptance criterion:** PRM-02 AC — "conflict = (target_active_version > base_version)."

---

### TC-PRM-02-04: Conflict when target has advanced by one version

**Given:** Target tenant has ACTIVE definition at version 2, and base_version is 1.

**When:** `rejectIfConflicts(target_tenant_id, process_key, base_version=1)` is called.

**Then:** Returns `ConflictRejection` with `target_version=2`. The event is appended in an independent transaction.

**Layer:** integration  
**Acceptance criterion:** PRM-02 AC — even a single-version gap triggers rejection.

---

### TC-PRM-02-05: HTTP 409 body shape on conflict

**Given:** A conflict exists as in TC-PRM-02-03.

**When:** The HTTP handler processes the rejection.

**Then:** The response body is:
```json
{
  "error": "PROMOTION_CONFLICT",
  "message": "Target tenant has advanced past base_version",
  "conflicts": [{
    "process_key": "<process_key>",
    "target_definition_id": "<uuid>",
    "target_version": 5,
    "source_change": "branched from version <base_version>",
    "target_change": "target is now at version <target_version>"
  }]
}
```
HTTP status is **409 Conflict**.

**Layer:** integration  
**Acceptance criterion:** PRM-02 AC — HTTP 409 with typed ConflictRejection body.

---

### TC-PRM-02-06: Rejection event written in independent transaction

**Given:** Conflict detected as in TC-PRM-02-03.

**When:** The rejection event is appended.

**Then:** The `DEFINITION_PROMOTION_REJECTED` event is committed in its own transaction, separate from any main-promotion-pipeline transaction. No version pointer on the target tenant is modified.

**Layer:** integration  
**Acceptance criterion:** PRM-02 design — "no lock on target at conflict-check time, independent transaction for rejection event."

---

### TC-PRM-02-07: PoolExhausted surfaces as HTTP 503

**Given:** DB connection pool is exhausted.

**When:** `rejectIfConflicts(...)` is called.

**Then:** Returns `ConflictCheckError.PoolExhausted`, surfaced as HTTP 503 `SERVICE_UNAVAILABLE`.

**Layer:** integration  
**Acceptance criterion:** PRM-02 error taxonomy — `PoolExhausted → HTTP 503`.
