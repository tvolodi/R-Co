# Test Spec: OIDC-F-05 — GET /api/tenant-config with ?realm= hint

**Requirement:** OIDC-F-05 — `GET /api/tenant-config` returns `oidc_authority` and `client_id`
for the tenant associated with the given query parameter. When `?realm=<slug>` is present,
the backend bypasses hostname lookup and resolves config directly by tenant slug.
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-OIDC-F05-01: ?realm=<slug> returns oidc_authority containing the tenant's idp_realm_id
**Given:** A tenant row exists in `public.tenant` with `slug='iss0072-<uuid>'` and `idp_realm_id='iss0072-<uuid>'`
**When:** `handleTenantConfig(alloc, &pool, "realm=iss0072-<uuid>")` is called
**Then:** Response has `status_code=200` and `body` contains `iss0072-<uuid>` in the `oidc_authority` field
**Layer:** integration
**Acceptance criterion mapped:** ?realm= param resolves config by slug, bypassing hostname lookup

### TC-OIDC-F05-02: ?realm= with non-existent slug falls back to bpm-default realm
**Given:** No tenant row exists for slug `no-such-realm-iss0072-xyz`
**When:** `handleTenantConfig(alloc, &pool, "realm=no-such-realm-iss0072-xyz")` is called
**Then:** Response has `status_code=200` and `body` contains `bpm-default` in the `oidc_authority` field
**Layer:** integration
**Acceptance criterion mapped:** Missing ?realm= slug falls through to default, never returns 4xx

### TC-OIDC-F05-03: ?host=127.0.0.1 still returns 200 (non-regression)
**Given:** No `tenant_hostnames` row for `127.0.0.1` exists in the test database
**When:** `handleTenantConfig(alloc, &pool, "host=127.0.0.1")` is called
**Then:** Response has `status_code=200` and `body` contains `bpm-default` in the `oidc_authority` field
**Layer:** integration
**Acceptance criterion mapped:** Existing ?host= path is not broken by the ?realm= addition
