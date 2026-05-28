# Test Spec: OIDC-33 — Coexistence period

**Requirement:** OIDC-33 — Internal legacy tokens and OIDC tokens remain valid simultaneously and produce equivalent internal contexts for the same principal.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-33-01: Equivalent subject, tenant, and normalized roles pass equivalence assertion
**Given:** Legacy and OIDC auth contexts for same principal
**When:** Context equivalence assertion runs
**Then:** No error is returned
**Layer:** unit
**Acceptance criterion mapped:** Both token types produce equivalent internal context

### TC-OIDC-33-02: Tenant mismatch fails equivalence assertion
**Given:** Legacy and OIDC contexts with different tenant IDs
**When:** Context equivalence assertion runs
**Then:** TenantContextMismatch error is returned
**Layer:** unit
**Acceptance criterion mapped:** Context mismatch is detectable and blocked

### TC-OIDC-33-03: Legacy-issued pre-cutover token still authenticates during coexistence
**Given:** Token pair issued across legacy and OIDC paths
**When:** Same protected route is called through both paths
**Then:** Authorization outcome and principal mapping are equivalent
**Layer:** integration
**Acceptance criterion mapped:** No forced migration and dual-path validity

## Planned test source and execution
- tests/unit/test_oidc33_coexistence_auth.zig
- tests/integration/oidc31_end_to_end_auth_suite_test.zig
- Command: zig build test
- Command: zig build test-integration-oidc31
