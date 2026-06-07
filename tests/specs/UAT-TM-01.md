# Test Spec: UAT-TM-01 - Resolve Tenant Context from company_id

**Requirement:** UAT-TM-01 - UAT helpers resolve a scenario company_id into tenant context (tenantId, realm, tokenUrl) via tenant API before execution.
**Priority:** MUST
**Test layer:** e2e helper test

## Test Cases

### TC-UAT-TM-01-01: Tenant context resolution succeeds and caches by slug
**Given:** Backend is reachable and default-realm admin credentials are valid.
**When:** resolveTenantContext(request, 'swiftroute', adminToken) is called twice in the same test process.
**Then:** The first call returns tenantId, slug, realm, tokenUrl and the second call returns the cached context for that slug.
**Layer:** e2e helper test
**Acceptance criterion mapped:** company_id -> tenant API lookup -> tenant context derivation with in-process cache
**Implemented in:** web/tests/e2e/uat-tenant-url.e2e.spec.ts (TC-UAT-TM-01-01)

### TC-UAT-TM-01-02: Unknown company_id fails with explicit not-found error
**Given:** Backend is reachable and admin token exists.
**When:** resolveTenantContext(request, 'tenant-missing-for-uat-tm', adminToken) is called.
**Then:** The call fails with an explicit "Tenant not found: <slug>" error.
**Layer:** e2e helper test
**Acceptance criterion mapped:** unresolved tenant slug is treated as failure with clear error semantics
**Implemented in:** web/tests/e2e/uat-tenant-url.e2e.spec.ts (TC-UAT-TM-01-02)

## Notes

- This requirement is test-infrastructure focused, so execution is validated through Playwright APIRequestContext helper tests rather than UI screens.
- No HTTP mocking is used; calls go to the real backend tenant API.
