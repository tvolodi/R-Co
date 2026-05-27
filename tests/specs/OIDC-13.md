# Test Spec: OIDC-13 — Tenant claim source

**Requirement:** OIDC-13 — The `tenant_id` claim required by ADP-03 MUST be populated by the identity provider, not constructed by the client.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-13-01: validateTenantClaimSource returns valid for well-formed UUID
**Given:** A token with a `tenant_id` claim containing a valid 36-character UUID
**When:** `validateTenantClaimSource` is called
**Then:** The result has `valid = true`
**Layer:** unit
**Acceptance criterion mapped:** Tokens issued contain the corresponding tenant_id claim

### TC-OIDC-13-02: validateTenantClaimSource returns invalid for missing claim
**Given:** A token with no `tenant_id` claim
**When:** `validateTenantClaimSource` is called with `null`
**Then:** The result has `valid = false` and a non-null `reason`
**Layer:** unit
**Acceptance criterion mapped:** Tokens issued contain the corresponding tenant_id claim

### TC-OIDC-13-03: validateTenantClaimSource returns invalid for short value
**Given:** A token with `tenant_id` claim value `"too-short"` (not a UUID)
**When:** `validateTenantClaimSource` is called
**Then:** The result has `valid = false`
**Layer:** unit
**Acceptance criterion mapped:** Tokens issued contain the corresponding tenant_id claim

### TC-OIDC-13-04: rejectClientTenantIdOverride passes when no client override present
**Given:** A request with no `X-Tenant-ID` header and no `tenant_id` query parameter
**When:** `rejectClientTenantIdOverride` is called with `(false, false)`
**Then:** It succeeds (returns void)
**Layer:** unit
**Acceptance criterion mapped:** Clients cannot override the tenant_id claim

### TC-OIDC-13-05: rejectClientTenantIdOverride rejects X-Tenant-ID header
**Given:** A request with an `X-Tenant-ID` header set by the client
**When:** `rejectClientTenantIdOverride` is called with `(true, false)`
**Then:** It returns `error.ClientOverridesTenantId`
**Layer:** unit
**Acceptance criterion mapped:** Clients cannot override the tenant_id claim

### TC-OIDC-13-06: rejectClientTenantIdOverride rejects tenant_id query parameter
**Given:** A request with a `tenant_id` query parameter set by the client
**When:** `rejectClientTenantIdOverride` is called with `(false, true)`
**Then:** It returns `error.ClientOverridesTenantId`
**Layer:** unit
**Acceptance criterion mapped:** Clients cannot override the tenant_id claim

### TC-OIDC-13-07: buildTenantIdMapperBody produces valid Keycloak-compatible JSON
**Given:** A `TenantClaimMapperConfig` with a valid tenant UUID
**When:** `buildTenantIdMapperBody` is called
**Then:** The produced JSON contains `"oidc-hardcoded-claim-mapper"` and the tenant UUID
**Layer:** unit
**Acceptance criterion mapped:** The tenant_id claim is populated by the identity provider
