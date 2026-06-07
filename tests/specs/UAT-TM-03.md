# Test Spec: UAT-TM-03 - Tenant Context Pre-Resolution Before Execution

**Requirement:** UAT-TM-03 - UAT flow supports pre-resolving unique scenario company_id values into TenantContext before step execution.
**Priority:** MUST
**Test layer:** e2e helper integration

## Test Cases

### TC-UAT-TM-03-01: Pre-resolve unique company_id values to TenantContext map before execution
**Given:** Backend and IdP are ready and a default-realm admin token can be issued.
**When:** Unique company_id values are collected and resolved through resolveTenantContext(request, slug, adminToken) before any scenario-step action.
**Then:** Resolution produces deterministic TenantContext entries keyed by slug, with valid tenantId and slug fields.
**Layer:** e2e helper integration
**Acceptance criterion mapped:** tenant-context pre-resolution is runnable and executable, not documentation-only
**Implemented in:** web/tests/e2e/uat-tenant-url.e2e.spec.ts (TC-UAT-TM-03-01)

## Notes

- This requirement is covered through executable helper behavior used by UAT execution orchestration.
- No mocked services are used; calls go to real backend and real IdP endpoints.
