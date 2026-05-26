# WF-02 Step 4 — ADP-04a Integration Test Report

**Run ID:** WF02-adp04a-20260526  
**Handoff ID:** 20260526-038  
**Step:** 4c — TEST-RUNNER rework 2  
**Agent:** TEST-RUNNER  
**Timestamp:** 2026-05-26T04:46:29Z  
**Database:** `postgres://bpm:bpm@localhost:5433/bpm_test`  
**Target:** `zig build test-integration`  

---

## Summary

The ADP-04a integration suite was re-run after adding the concrete TC-ADP-04a-06 automated case. The suite completed successfully against the real PostgreSQL test database, and all six ADP-04a spec cases now have explicit automated coverage.

| Metric | Count |
|---|---:|
| Spec cases total | 6 |
| Passed | 6 |
| Failed | 0 |

**Overall verdict: PASS** — the suite exits 0 and TC-ADP-04a-06 now explicitly verifies NULL-linkage coexistence, duplicate non-NULL realm/sub rejection, and unique-index proof.

## Execution

- `zig build test-integration` completed with exit code 0.
- Console output contained only the normal cleanup lines:
  - `Cleaning test database...`
  - `Test database cleaned.`
- Captured log: [tests/reports/WF02-adp04a-20260526-step-04c-test-runner-rework2.log](WF02-adp04a-20260526-step-04c-test-runner-rework2.log)
- Test source under evaluation: [tests/integration/adp04a_external_identity_linkage_test.zig](../integration/adp04a_external_identity_linkage_test.zig)
- Updated spec: [tests/specs/ADP-04a.md](../specs/ADP-04a.md)

## Case Matrix

| Case | Status | Automated coverage used | Notes |
|---|---|---|---|
| TC-ADP-04a-01 | PASS | `TC-ADP-04a-01` in [tests/integration/adp04a_external_identity_linkage_test.zig](../integration/adp04a_external_identity_linkage_test.zig) | Confirms internal user defaults remain `auth_source=internal` with `external_realm` and `external_id` as `NULL`. |
| TC-ADP-04a-02 | PASS | `TC-ADP-04a-02` in [tests/integration/adp04a_external_identity_linkage_test.zig](../integration/adp04a_external_identity_linkage_test.zig) | Confirms OIDC linkage is persisted and resolved by tenant+realm+sub. |
| TC-ADP-04a-03 | PASS | `TC-ADP-04a-03` in [tests/integration/adp04a_external_identity_linkage_test.zig](../integration/adp04a_external_identity_linkage_test.zig) | Confirms create-or-get behavior is idempotent for identical tenant+realm+sub. |
| TC-ADP-04a-04 | PASS | `TC-ADP-04a-04` in [tests/integration/adp04a_external_identity_linkage_test.zig](../integration/adp04a_external_identity_linkage_test.zig) | Confirms tenant-scoped lookup and collision handling prevent cross-tenant binding. |
| TC-ADP-04a-05 | PASS | `TC-ADP-04a-04` cross-tenant collision assertions | Confirms tenant isolation blocks collision reuse of the same realm/sub in another tenant. |
| TC-ADP-04a-06 | PASS | `TC-ADP-04a-06` in [tests/integration/adp04a_external_identity_linkage_test.zig](../integration/adp04a_external_identity_linkage_test.zig) | Confirms multiple internal `NULL` linkage rows coexist, duplicate non-NULL realm/sub insertion is rejected, and `idx_users_external_identity_unique` unique index metadata is asserted. |

## Issues

- None.

## Next Action

Route to **RELEASE-VALIDATOR** for WF-02 Step 5.