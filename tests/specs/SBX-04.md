# Test Spec: SBX-04 — Sandbox Ownership Binding at Claim

**Requirement:** SBX-04  
**Priority:** MUST  
**Stage:** 17  
**Run ID:** WF02-sbx04-06-20260819  
**Design artefact:** src/design/sbx04-06-design.md  
**Implementation:** src/api/routes/agent_sandboxes.zig (handleClaimSandbox)  
**Migration:** migrations/1172_sbx04_06_owner_binding.sql

---

## Acceptance Criteria

| AC | Description |
|---|---|
| AC1 | GIVEN unowned sandbox + valid task_spec_id → 201, binding written |
| AC2 | GIVEN nonexistent task_spec_id → 404 task_spec_not_found |
| AC3 | GIVEN second principal claims same sandbox → 409 sandbox_already_claimed, no owner in body |
| AC4 | GIVEN same principal claims second sandbox for same task_spec_id → 409 sandbox_already_claimed |
| AC5 | GIVEN second principal issues operation inside claimed sandbox → 403 sandbox_not_accessible |
| AC6 | GIVEN concurrent claim race → exactly one 201, other gets 409 |
| AC7 | GIVEN released sandbox re-claimed → new binding, prior owner has no access |

---

## Test Cases

| ID | AC | Name | Expected outcome |
|---|---|---|---|
| TC-SBX-04-01 | AC1 | Claim unowned sandbox with valid task_spec_id | HTTP 201, owner_principal set, task_spec_id bound, sandbox.claimed audit written |
| TC-SBX-04-02 | AC2 | Claim with nonexistent task_spec_id | HTTP 404 `task_spec_not_found` |
| TC-SBX-04-03 | AC3 | Second principal claims same sandbox | HTTP 409 `sandbox_already_claimed`, response body contains no owner name |
| TC-SBX-04-04 | AC4 | Same principal claims second sandbox for same task_spec_id | HTTP 409 `sandbox_already_claimed` |
| TC-SBX-04-05 | AC5 | Second principal issues operation (release) inside claimed sandbox | HTTP 403 `sandbox_not_accessible` |
| TC-SBX-04-06 | AC6 | Concurrent claim race: exactly one 201, other 409 | One result is 201, other is 409 `sandbox_already_claimed` |
| TC-SBX-04-07 | AC7 | Released sandbox re-claimed, prior owner has no access | 201 for new claimer, 403 sentinel for prior owner |

---

## Test Isolation

- All fixtures use per-test UUIDs
- Every test cleans up via `defer` (sandboxes, task_specs, audit_entries)
- Requires `BPM_TEST_DB_URL` — fails with clear error if absent
- No mocks; real PostgreSQL connection via `BPM_TEST_DB_URL`
