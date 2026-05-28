# Test Spec: OIDC-11 — External user identity stability

**Requirement:** OIDC-11 — The `sub` claim MUST be treated as the stable identifier. Changes to email or username at the provider MUST NOT cause the platform to treat the user as a different person.

**Priority:** MUST
**Test layer:** integration, unit

## Test Cases

### TC-OIDC-11-01: User lookup by (external_realm, external_id) returns correct user
**Given:** A user exists with `external_realm`, `external_id`, and `tenant_id` populated
**When:** `resolveByExternalIdentity` is called with matching `external_realm`, `external_id`, and `tenant_id`
**Then:** The function returns the correct `User` record with `IdentityLookupResult`
**Layer:** integration
**Acceptance criterion mapped:** Lookup by (external_realm, sub) is the authoritative identity lookup path

### TC-OIDC-11-02: Lookup by (external_realm, external_id) returns UserNotFound for unknown identity
**Given:** No user exists with the given `(external_realm, external_id, tenant_id)` tuple
**When:** `resolveByExternalIdentity` is called
**Then:** `error.UserNotFound` is returned
**Layer:** integration
**Acceptance criterion mapped:** Lookup by (external_realm, sub) is the authoritative identity lookup path

### TC-OIDC-11-03: User renamed at provider retains same local user_id
**Given:** A user exists with `external_id = sub-abc` and was previously JIT-provisioned
**When:** The user is renamed at the provider (email/username changes) and `resolveByExternalIdentity` is called using the unchanged `sub` claim
**Then:** The same `user_id` is returned — the local identity is stable
**Layer:** integration
**Acceptance criterion mapped:** User renamed or re-emailed retains the same local user_id

### TC-OIDC-11-04: No fallback to email-based lookup
**Given:** A user exists with a given email but a different `(external_realm, external_id)` tuple
**When:** `resolveByExternalIdentity` is called with the correct realm but a non-matching external_id
**Then:** `error.UserNotFound` is returned — even if the email matches
**Layer:** integration
**Acceptance criterion mapped:** Lookup by (external_realm, sub) is the authoritative identity lookup path

### TC-OIDC-11-05: Tenant mismatch returns TenantMismatch
**Given:** A user exists with the given `(external_realm, external_id)` but a different `tenant_id`
**When:** `resolveByExternalIdentity` is called with a `tenant_id` that does not match the user's tenant
**Then:** `error.TenantMismatch` is returned
**Layer:** integration
**Acceptance criterion mapped:** Lookup by (external_realm, sub) is the authoritative identity lookup path

### TC-OIDC-11-06: assertStableIdentity matching ids returns ok
**Given:** A stored `external_id` and a token `sub` that are identical
**When:** `assertStableIdentity` is called
**Then:** It returns `void` successfully
**Layer:** unit
**Acceptance criterion mapped:** The sub claim is treated as the stable identifier

### TC-OIDC-11-07: assertStableIdentity mismatched ids returns IdentityDriftDetected
**Given:** A stored `external_id` ("user-123") and a token `sub` ("user-456") that differ
**When:** `assertStableIdentity` is called
**Then:** `error.IdentityDriftDetected` is returned
**Layer:** unit
**Acceptance criterion mapped:** The sub claim is treated as the stable identifier

### TC-OIDC-11-08: has_profile_drift detected when token external_id differs from stored
**Given:** A user record exists where `external_id` stored in DB differs from the `input.external_id`
**When:** `resolveByExternalIdentity` returns
**Then:** `has_profile_drift` is `true`
**Layer:** integration
**Acceptance criterion mapped:** User renamed at provider retains same local user_id
