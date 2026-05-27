# Test Spec: OIDC-14 — Realm provisioning via adapter

**Requirement:** OIDC-14 — The `IdentityProvider` interface MUST support programmatic realm creation, including: realm name, display name, default token lifetimes, default password policy, default MFA policy, signing key generation, protocol mapper for `tenant_id` claim.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-14-01: buildRealmCreateBody produces valid JSON with all config fields
**Given:** A `ProvisionRealmInput` with tenant_id, slug, display_name and defaults
**When:** `buildRealmCreateBody` is called
**Then:** The produced JSON contains the tenant slug, `"accessTokenLifespan"`, and default value `900`
**Layer:** unit
**Acceptance criterion mapped:** Creating a tenant via platform API results in a fully configured realm at the provider

### TC-OIDC-14-02: ProvisionRealmInput defaults are correct
**Given:** A `ProvisionRealmInput` with only required fields
**When:** Defaults are inspected
**Then:** `default_token_lifetime_seconds` is 900, `min_password_length` is 8, `signing_key_algorithm` is RS256
**Layer:** unit
**Acceptance criterion mapped:** Creating a tenant via platform API results in a fully configured realm at the provider

### TC-OIDC-14-03: DEFAULT_REALM_CONFIG constants are accessible
**Given:** The `DEFAULT_REALM_CONFIG` namespace
**When:** Constants are accessed
**Then:** `access_token_seconds` is 900, `min_length` is 8, `algorithm` is RS256
**Layer:** unit
**Acceptance criterion mapped:** Creating a tenant via platform API results in a fully configured realm at the provider

### TC-OIDC-14-04: ProvisionRealmResult deinit frees all allocated memory
**Given:** A `ProvisionRealmResult` with allocated realm_id and keyset
**When:** `deinit` is called
**Then:** Memory is freed without double-free
**Layer:** unit
**Acceptance criterion mapped:** Creating a tenant via platform API results in a fully configured realm at the provider

### TC-OIDC-14-05: Realm creation body includes otp and password policy fields
**Given:** A `ProvisionRealmInput` with custom OTP and password policy
**When:** `buildRealmCreateBody` is called
**Then:** The JSON includes `otpPolicyAlgorithm`, `otpPolicyDigits`, and `passwordPolicy` fields with the configured values
**Layer:** unit
**Acceptance criterion mapped:** Realm is immediately ready to issue tokens after provisioning
