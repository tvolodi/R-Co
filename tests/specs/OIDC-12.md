# Test Spec: OIDC-12 — Realm-tenant binding

**Requirement:** OIDC-12 — Each BPM tenant MUST be associated with exactly one realm at the provider. The `tenant` table MUST have an `idp_realm_id` column referencing the provider's realm identifier.

**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-OIDC-12-01: Tenant with realm binding can be looked up by realm ID
**Given:** A tenant exists with `idp_realm_id = 'kc-realm-oidc12-01'`
**When:** `resolveTenantByRealm` is called with `idp_realm_id = 'kc-realm-oidc12-01'`
**Then:** The correct `TenantRealmBinding` record is returned
**Layer:** integration
**Acceptance criterion mapped:** Lookup by realm ID returns the tenant

### TC-OIDC-12-02: Default tenant has idp_realm_id = 'bpm-default'
**Given:** The default tenant (UUID `00000000-0000-0000-0000-000000000000`)
**When:** Its `idp_realm_id` is queried
**Then:** It equals `'bpm-default'`
**Layer:** integration
**Acceptance criterion mapped:** The default tenant has idp_realm_id = 'bpm-default'

### TC-OIDC-12-03: Lookup by unknown realm returns NotFound
**Given:** No tenant exists with `idp_realm_id = 'unknown-realm'`
**When:** `resolveTenantByRealm` is called
**Then:** `error.NotFound` is returned
**Layer:** integration
**Acceptance criterion mapped:** Lookup by realm ID returns the tenant

### TC-OIDC-12-04: Tenant-to-realm reverse lookup returns realm ID
**Given:** A tenant exists with `idp_realm_id = 'kc-realm-oidc12-04'`
**When:** `resolveRealmByTenant` is called with the tenant's UUID
**Then:** It returns `'kc-realm-oidc12-04'`
**Layer:** integration
**Acceptance criterion mapped:** Tenant creation API requires an idp_realm_id

### TC-OIDC-12-05: Reverse lookup by unknown tenant returns NotFound
**Given:** A tenant UUID that does not exist (or has no binding)
**When:** `resolveRealmByTenant` is called
**Then:** `error.NotFound` is returned
**Layer:** integration
**Acceptance criterion mapped:** Lookup by realm ID returns the tenant
