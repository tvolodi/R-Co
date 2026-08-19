# Test Spec: SBX-06 — Sandbox Release, Reclaim, and Claim Audit

**Requirement:** SBX-06  
**Priority:** MUST  
**Stage:** 17  
**Run ID:** WF02-sbx04-06-20260819  
**Design artefact:** src/design/sbx04-06-design.md  
**Implementation:** src/api/routes/agent_sandboxes.zig (handleReleaseSandbox), src/definition/sandbox_pool.zig (reclaimIdleSandboxes)

---

## Acceptance Criteria

| AC | Description |
|---|---|
| AC1 | GIVEN second principal attempts release → 403 sandbox_not_accessible, binding unchanged |
| AC2 | GIVEN orchestrator principal attempts release → 403 sandbox_not_accessible |
| AC3 | GIVEN owner releases → 204, state=released, sandbox.released audit entry |
| AC4 | GIVEN idle sandbox 61 min → pool manager marks released, sandbox.reclaimed audit names prior owner |
| AC5 | GIVEN 30 sentinel responses → 30 SandboxClaimRejected audit entries name principal + sandbox_id |

---

## Test Cases

| ID | AC | Name | Expected outcome |
|---|---|---|---|
| TC-SBX-06-01 | AC1 | Second principal release attempt → 403, binding unchanged | HTTP 403 `sandbox_not_accessible`, owner_principal unchanged in DB |
| TC-SBX-06-02 | AC2 | Orchestrator release attempt → 403 sentinel | HTTP 403 `sandbox_not_accessible` |
| TC-SBX-06-03 | AC3 | Owner releases successfully → 204, released state, audit | HTTP 204, status='released', owner_principal=NULL, `sandbox.released` audit written |
| TC-SBX-06-04 | AC4 | Idle reclaim: last_active_at set to 61 min ago → reclaim sweep marks released | status='released', `sandbox.reclaimed` audit names prior_principal |
| TC-SBX-06-05 | AC5 | Sentinel audit trail: 5 sentinel calls create audit entries | audit_entries carries sandbox_id and principal for each sentinel |

---

## Test Isolation

- All fixtures use per-test UUIDs
- Idle reclaim test directly manipulates last_active_at to simulate 61 min elapsed
- sandbox_pool.reclaimIdleSandboxes invoked directly (no wall-clock wait)
- Requires `BPM_TEST_DB_URL` — fails with clear error if absent
- No mocks; real PostgreSQL connection
