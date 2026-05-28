# Test Spec: OIDC-31 — End-to-end authentication test suite

**Requirement:** OIDC-31 — CI MUST run real-environment OIDC end-to-end suite that starts IDP and platform, exercises Stage 1-6 API surface with OIDC tokens, and confirms behavior equivalence with pre-OIDC expectations.

**Priority:** MUST
**Test layer:** integration, e2e

## Test Cases

### TC-OIDC-31-01: E2E auth suite preflight validates backend, DB, and IDP connectivity
**Given:** CI/dev environment with BPM_TEST_DB_URL, BPM_TEST_URL, BPM_IDP_BASE_URL
**When:** OIDC E2E preflight test runs
**Then:** DB ping succeeds, IDP discovery endpoint responds 200, backend health endpoint responds 200
**Layer:** integration
**Acceptance criterion mapped:** Real backend + DB + IDP setup path is active

### TC-OIDC-31-02: Role matrix execution covers Stage 5 roles on authenticated routes
**Given:** Role tokens for PLATFORM_ADMIN, PROCESS_DESIGNER, TASK_WORKER
**When:** Stage 1-6 endpoint matrix runs under each role
**Then:** Expected allow/deny outcomes per permission matrix are matched
**Layer:** e2e
**Acceptance criterion mapped:** Suite covers all Stage 5 role definitions

### TC-OIDC-31-03: OIDC outcomes match pre-OIDC baseline semantics
**Given:** Stored pre-OIDC baseline outcomes for representative routes
**When:** OIDC-authenticated suite replays equivalent scenarios
**Then:** Observed status/result semantics match baseline expectations
**Layer:** integration, e2e
**Acceptance criterion mapped:** OIDC integration does not regress Stage 1-6 behavior

## Planned test source and execution
- tests/integration/oidc31_end_to_end_auth_suite_test.zig
- tests/integration/adp12_default_tenant_regression_test.zig
- Command: zig build test-integration-oidc31
- Command: npx playwright test web/tests/e2e
