# Test Spec: UAT-TM-04 - company_id to Realm/Token URL Resolution Chain

**Requirement:** UAT-TM-04 - Scenario execution can derive tenant realm and token URL from company_id without requiring manual realm input.
**Priority:** MUST
**Test layer:** e2e helper integration

## Test Cases

### TC-UAT-TM-04-01: company_id alone resolves realm and derived token URL
**Given:** Backend and IdP are ready and a default-realm admin token can be issued.
**When:** resolveTenantContext(request, 'swiftroute', adminToken) is called using company_id only.
**Then:** Returned TenantContext includes slug, non-empty realm, and tokenUrl equal to keycloakTokenUrl(realm), proving automatic company_id -> tenant API -> realm -> token URL resolution.
**Layer:** e2e helper integration
**Acceptance criterion mapped:** company_id is sufficient for tenant-aware token endpoint derivation
**Implemented in:** web/tests/e2e/uat-tenant-url.e2e.spec.ts (TC-UAT-TM-04-01)

## Notes

- This requirement is validated through executable helper behavior rather than prose-only traceability.
- No mocked services are used; coverage exercises live tenant API and IdP readiness paths.
