# Test Design Report: OIDC-35 — Company Onboarding Orchestration

**Run ID:** WF02-oidc35-20260528
**Agent:** TEST-DESIGNER
**Date:** 2026-05-28T13:35:45Z
**Status:** PASS

---

## Summary

Test spec and integration tests designed for OIDC-35 (Company onboarding orchestration). All MUST acceptance criteria are covered by runnable integration tests.

## Test Cases

| TC ID | Description | Layer | AC mapped |
|---|---|---|---|
| TC-OIDC-35-01 | Fresh idempotency key creates pending record | integration | AC #5 — Idempotency |
| TC-OIDC-35-02 | Same key + same hash returns existing (replay) | integration | AC #5 — Idempotency |
| TC-OIDC-35-03 | Same key + different hash triggers conflict | integration | AC #5 — Idempotency |
| TC-OIDC-35-04 | Select onboarding by onboarding_id | integration | AC #2 — Retrieve result |
| TC-OIDC-35-05 | Select onboarding by hostname | integration | AC #4 — Hostname bindings |
| TC-OIDC-35-10 | Hostname binding enforces uniqueness | integration | AC #4 — Unique hostnames |
| TC-OIDC-35-11 | Tenant slug enforces uniqueness | integration | AC #2 — Unique slugs |
| TC-OIDC-35-12 | Non-existent onboarding_id returns null | integration | AC #2 — NotFound case |
| TC-OIDC-35-13 | Non-existent hostname returns null | integration | AC #4 — NotFound case |

## Artifacts

- `tests/specs/OIDC-35.md` — Test specification (13 test cases defined)
- `tests/integration/oidc35_onboarding_test.zig` — Integration test source (9 runnable tests)
- `src/bpm.zig` — Added `onboarding_mod` and `identity_provider` exports
- `src/main.zig` — Added `onboarding_mod` public export
- `build.zig` — Wired `test-integration-oidc35` step and added to `test-integration` step

## Quality Checks

- [x] All MUST requirements have runnable integration tests
- [x] No mocks, stubs, or in-memory fakes
- [x] All fixtures use per-test UUIDs (hex UUIDs generated per test)
- [x] Tests clean up after themselves (transaction rollback via TestHarness)
- [x] Fail clearly if BPM_TEST_DB_URL is absent (TestHarness returns SkipZigTest)
- [x] No error.SkipZigTest on any MUST test that can run with DB only
- [x] zig build exits 0
- [x] No error-set violations
- [x] All queries use parameterised SQL ($1, $2 placeholders)
