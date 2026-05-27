# Test Spec: OIDC-16 — Full lifecycle API for agents

**Requirement:** OIDC-16 — The platform MUST expose REST endpoints for realm/user/role/client/federation lifecycle and secret rotation with PLATFORM_ADMIN or AGENT_RUNNER+scope authorization.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-16-01: OpenAPI includes full IDP lifecycle endpoint set
**Given:** The generated OpenAPI route descriptors
**When:** The IDP module endpoints are enumerated
**Then:** Realm, user, role assign/revoke, client lifecycle, secret rotate, federation lifecycle, and bundle routes are all present
**Layer:** unit
**Acceptance criterion mapped:** All provisioning endpoints are documented in OpenAPI

### TC-OIDC-16-02: Scope gate permits authorized agents and denies unauthorized principals
**Given:** Principals with PLATFORM_ADMIN, AGENT_RUNNER+scope, and AGENT_RUNNER without scope
**When:** Endpoint scope enforcement is evaluated
**Then:** Admin and scoped agents are allowed, missing-scope agents are rejected with Forbidden
**Layer:** unit
**Acceptance criterion mapped:** Endpoints require PLATFORM_ADMIN or AGENT_RUNNER with appropriate sub-scope

### TC-OIDC-16-03: Foundation schema supports complete provision bundle persistence path
**Given:** A real PostgreSQL test database with migration 042 applied
**When:** Ledger and transaction rows for a bundle operation are inserted
**Then:** Required persistence artifacts are accepted and queryable for bundle orchestration
**Layer:** integration
**Acceptance criterion mapped:** Agent can provision tenant lifecycle through platform orchestration surfaces
