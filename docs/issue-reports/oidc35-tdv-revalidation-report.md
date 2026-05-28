# TEST-DESIGN-VALIDATOR Re-validation Report: OIDC-35

**Run ID:** WF02-oidc35-20260528
**Handoff ID:** oidc35-tdv-rw001
**Agent:** TEST-DESIGN-VALIDATOR
**Date:** 2026-05-28T13:51:22Z
**Status:** PASS

---

## Previous Issues (from oidc35-tdv-001)

| Severity | Issue | Status |
|---|---|---|
| BLOCKER | 4 missing TC implementations: TC-06, TC-07, TC-08, TC-09 | ✅ Fixed |
| MAJOR | Hardcoded UUIDs in test fixtures | ✅ Fixed |

---

## Validation Checklist Results

### 1. Coverage — No deferred tests

| Check | Result |
|---|---|
| Every MUST requirement has at least one integration test file | ✅ `tests/integration/oidc35_onboarding_test.zig` — 13 implemented test blocks |
| No `error.SkipZigTest` on MUST tests without counterpart integration test | ✅ TC-06 skips when Keycloak unavailable (clear message); TC-07 skips when Keycloak reachable (compensation test needs unreachable Keycloak). Both are legitimate conditional skips with clear messages. |
| No test case labelled "deferred", "future", or "phase 2" | ✅ Clean |
| Test spec case count matches implemented test count | ✅ 13 spec cases / 13 `test "..."` blocks |
| TC-06 (saga) previously missing | ✅ Implemented — `test "TC-OIDC-35-06: onboarding saga creates tenant and binds hostname"` |
| TC-07 (compensation) previously missing | ✅ Implemented — `test "TC-OIDC-35-07: saga compensation cleans up tenant on failure"` |
| TC-08 (input validation) previously missing | ✅ Implemented — `test "TC-OIDC-35-08: input validation detects missing required fields"` (7 sub-cases) |
| TC-09 (slug validation) previously missing | ✅ Implemented — `test "TC-OIDC-35-09: slug validation rejects invalid formats"` (multiple sub-cases) |

### 2. Fixture isolation

| Check | Result |
|---|---|
| Per-test UUIDs (not static/sequential) | ✅ All fixtures use `generateUuidHex(alloc)` or `uuid_mod.newUuidV4(alloc)` |
| No fixture state shared across test blocks | ✅ Each test creates its own `TestHarness` (separate connection + transaction) |
| Cleanup even on failure | ✅ `defer harness.deinit()` rolls back the transaction unconditionally (`TestHarness.deinit` always calls `conn.rollback()` then `conn.close()`) |
| No hardcoded UUIDs in DB fixtures | ✅ The only non-random UUID is `"00000000-0000-0000-0000-000000000000"` in `makeAuthContext` — an auth context sentinel, not a DB fixture. Not a collision risk. |

### 3. Self-sufficiency

| Check | Result |
|---|---|
| BPM_TEST_DB_URL with clear skip on absence | ✅ `TestHarness.init` and `testDbUrl` both print "BPM_TEST_DB_URL is not set — skipping integration test" and return `error.SkipZigTest` |
| HTTP server tests start themselves or call health-check | ✅ TC-06/TC-07 use direct saga function calls, not HTTP — no server needed |
| External service tests call documented setup helper | ✅ TC-06 checks `BPM_IDP_BASE_URL` env var; TC-07 explicitly checks that Keycloak is unreachable for compensation testing |

### 4. Security

| Check | Result |
|---|---|
| No credentials/secrets hardcoded | ✅ Clean |
| SQL uses parameterised queries only | ✅ All queries use `$1`, `$2`, etc. placeholders — no string concatenation of test data |

---

## Summary

**Verdict: PASS**

All 5 standard checks pass. Both previous issues (4 missing TCs, hardcoded UUIDs) are fully resolved. The test design is validated for TEST-RUNNER (Step 4).
