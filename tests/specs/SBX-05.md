# Test Spec: SBX-05 — Single Sentinel for Inaccessible Sandboxes

**Requirement:** SBX-05  
**Priority:** MUST  
**Stage:** 17  
**Run ID:** WF02-sbx04-06-20260819  
**Design artefact:** src/design/sbx04-06-design.md  
**Implementation:** src/api/routes/sandbox_access.zig (checkPrincipalBound, checkProbeRate)

---

## Acceptance Criteria

| AC | Description |
|---|---|
| AC1 | GIVEN nonexistent sandbox_id → 403 sandbox_not_accessible |
| AC2 | GIVEN sandbox from another tenant (same ID) → 403, body byte-identical to AC1 |
| AC3 | GIVEN sandbox in caller's tenant bound to another principal → 403, body byte-identical |
| AC4 | GIVEN all three cases → headers identical |
| AC5 | GIVEN 20 sentinel responses in 60 s from same principal → 21st returns 429 probe_rate_exceeded |
| AC6 | GIVEN SBX-04 409 does not disclose cross-tenant sandbox existence |

---

## Test Cases

| ID | AC | Name | Expected outcome |
|---|---|---|---|
| TC-SBX-05-01 | AC1 | Nonexistent sandbox_id returns sentinel | HTTP 403 `sandbox_not_accessible` |
| TC-SBX-05-02 | AC2/AC4 | Cross-tenant sandbox (other tenant's sandbox via same search_path schema) | HTTP 403, byte-identical body and headers as TC-SBX-05-01 |
| TC-SBX-05-03 | AC3/AC4 | Sandbox in caller's tenant bound to another principal | HTTP 403, byte-identical body and headers |
| TC-SBX-05-04 | AC5 | 21st sentinel probe in 60 s returns 429 | HTTP 429 `probe_rate_exceeded` after 20 sentinels |
| TC-SBX-05-05 | AC6 | SBX-04 409 does not disclose cross-tenant existence | 409 only for sandboxes visible to caller's tenant; unknown UUID → 403 sentinel |

---

## Test Isolation

- All fixtures use per-test UUIDs
- probe_counters cleaned up after probe-rate test
- Requires `BPM_TEST_DB_URL` — fails with clear error if absent
- No mocks; real PostgreSQL connection
