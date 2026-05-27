# Test Spec: OIDC-08 — Standard Claim Mapping

**Requirement:** OIDC-08 — On successful verification, the platform MUST extract: `sub` → external user ID; configurable claim (default `tenant_id`) → tenant; configurable claim (default `realm_access.roles` for Keycloak, falling back to `roles`) → role list; standard claims `email`, `preferred_username`, `name` → user attributes. Mapping rules MUST be configurable per realm to accommodate other providers.

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-08-U01: Basic mapping with all standard claims present
**Given:** A JWT payload containing `sub`, `email`, `preferred_username`, `name`, and `tenant_id` claims.
**When:** `mapVerifiedClaims` is called with the default config.
**Then:** All fields of the returned `IdentityContext` are populated from the corresponding claims.
**Layer:** unit
**Acceptance criterion mapped:** Standard claims `email`, `preferred_username`, `name` → user attributes.

### TC-OIDC-08-U02: Sub claim missing returns error
**Given:** An empty `subject` argument.
**When:** `mapVerifiedClaims` is called.
**Then:** `MappingError.SubClaimMissing` is returned.
**Layer:** unit
**Acceptance criterion mapped:** `sub` → external user ID (required; missing → error).

### TC-OIDC-08-U03: Missing email defaults to empty string
**Given:** A JWT payload without an `email` claim.
**When:** `mapVerifiedClaims` is called.
**Then:** `IdentityContext.email` is `""`.
**Layer:** unit
**Acceptance criterion mapped:** Missing optional claims produce concrete defaults, not errors — missing `email` defaults to empty string.

### TC-OIDC-08-U04: Missing preferred_username defaults to sub value
**Given:** A JWT payload without a `preferred_username` claim.
**When:** `mapVerifiedClaims` is called.
**Then:** `IdentityContext.preferred_username` equals `external_user_id`.
**Layer:** unit
**Acceptance criterion mapped:** Missing optional claims produce concrete defaults — missing `preferred_username` defaults to the `sub` value.

### TC-OIDC-08-U05: Missing roles defaults to empty list
**Given:** A JWT payload with no roles claims at any configured path.
**When:** `mapVerifiedClaims` is called with default config.
**Then:** `IdentityContext.roles` is an empty slice.
**Layer:** unit
**Acceptance criterion mapped:** Missing optional claims produce concrete defaults — missing `roles` defaults to empty list.

### TC-OIDC-08-U06: Missing display_name defaults to null
**Given:** A JWT payload without a `name` claim.
**When:** `mapVerifiedClaims` is called.
**Then:** `IdentityContext.display_name` is `null`.
**Layer:** unit
**Acceptance criterion mapped:** Missing optional claims produce concrete defaults.

### TC-OIDC-08-U07: Missing tenant_id defaults to null
**Given:** A JWT payload without a `tenant_id` claim.
**When:** `mapVerifiedClaims` is called.
**Then:** `IdentityContext.tenant_id` is `null`.
**Layer:** unit
**Acceptance criterion mapped:** Missing optional claims produce concrete defaults.

### TC-OIDC-08-U08: Nested role path resolved from realm_access.roles
**Given:** A JWT payload with `{"realm_access": {"roles": ["admin", "user"]}}`.
**When:** `mapVerifiedClaims` is called with default config.
**Then:** `IdentityContext.roles` contains `["admin", "user"]`.
**Layer:** unit
**Acceptance criterion mapped:** Configurable claim (default `realm_access.roles` for Keycloak, falling back to `roles`) → role list.

### TC-OIDC-08-U09: Role path fallback — first path missing, second path used
**Given:** A JWT payload with top-level `roles` but no `realm_access.roles`.
**When:** `mapVerifiedClaims` is called with default config `["realm_access.roles", "roles"]`.
**Then:** Roles are extracted from `roles` (the fallback path).
**Layer:** unit
**Acceptance criterion mapped:** Configurable claim falling back to `roles`.

### TC-OIDC-08-U10: Claim not a string — email non-string defaults to empty
**Given:** A JWT payload where the `email` claim is a number rather than a string.
**When:** `mapVerifiedClaims` is called.
**Then:** `IdentityContext.email` is `""`.
**Layer:** unit
**Acceptance criterion mapped:** Missing optional claims produce concrete defaults (type mismatch treated as missing).

### TC-OIDC-08-U11: Claim not a string — preferred_username non-string defaults to sub
**Given:** A JWT payload where the `preferred_username` claim is a number rather than a string.
**When:** `mapVerifiedClaims` is called.
**Then:** `IdentityContext.preferred_username` equals `external_user_id`.
**Layer:** unit
**Acceptance criterion mapped:** Missing optional claims produce concrete defaults (type mismatch treated as missing).

### TC-OIDC-08-U12: Claim not a string — display_name non-string defaults to null
**Given:** A JWT payload where the `name` claim is an array rather than a string.
**When:** `mapVerifiedClaims` is called.
**Then:** `IdentityContext.display_name` is `null`.
**Layer:** unit
**Acceptance criterion mapped:** Missing optional claims produce concrete defaults (type mismatch treated as missing).

### TC-OIDC-08-U13: identityContextsEquivalent returns true for same (external_user_id, realm)
**Given:** Two `IdentityContext` values with the same `external_user_id` and `realm` but different `email`, `roles`, `display_name`, and `tenant_id`.
**When:** `identityContextsEquivalent` is called.
**Then:** It returns `true`.
**Layer:** unit
**Acceptance criterion mapped:** Tokens from different configured providers produce equivalent internal user contexts.

### TC-OIDC-08-U14: identityContextsEquivalent returns false for different external_user_id
**Given:** Two `IdentityContext` values with different `external_user_id`.
**When:** `identityContextsEquivalent` is called.
**Then:** It returns `false`.
**Layer:** unit
**Acceptance criterion mapped:** Tokens from different configured providers produce equivalent internal user contexts (negative case).

### TC-OIDC-08-U15: identityContextsEquivalent returns false for different realm
**Given:** Two `IdentityContext` values with different `realm`.
**When:** `identityContextsEquivalent` is called.
**Then:** It returns `false`.
**Layer:** unit
**Acceptance criterion mapped:** Tokens from different configured providers produce equivalent internal user contexts (negative case).

### TC-OIDC-08-U16: resolveJsonPath resolves nested dot-separated paths
**Given:** A parsed JSON document with nested objects.
**When:** `resolveJsonPath` is called with path `["realm_access", "roles"]`.
**Then:** It returns the JSON array at that path.
**Layer:** unit
**Acceptance criterion mapped:** Nested claim paths resolved.

### TC-OIDC-08-U17: resolveJsonPath returns null for nonexistent path
**Given:** A parsed JSON document without the requested path.
**When:** `resolveJsonPath` is called.
**Then:** It returns `null`.
**Layer:** unit
**Acceptance criterion mapped:** Missing optional claims produce concrete defaults (null paths handled gracefully).

### TC-OIDC-08-U18: Non-JSON input returns ClaimPathMalformed error
**Given:** A `raw_claims_json` that is not valid JSON.
**When:** `mapVerifiedClaims` is called.
**Then:** `MappingError.ClaimPathMalformed` is returned.
**Layer:** unit
**Acceptance criterion mapped:** Robust error handling for malformed input.

### TC-OIDC-08-U19: Tenant_id claim from configured path
**Given:** A JWT payload with `tenant_id` at the default path.
**When:** `mapVerifiedClaims` is called.
**Then:** `IdentityContext.tenant_id` contains the tenant value.
**Layer:** unit
**Acceptance criterion mapped:** Configurable claim (default `tenant_id`) → tenant.

### TC-OIDC-08-I01: Config loaded from DB when row exists
**Given:** A row exists in `realm_claim_mapping_config` for realm `test-realm`.
**When:** `loadClaimMappingConfig` is called with that realm.
**Then:** A `ClaimMappingConfig` is returned with the stored values.
**Layer:** integration
**Acceptance criterion mapped:** Claim mapping rules are configurable per realm and stored in platform configuration.

### TC-OIDC-08-I02: Config returns null when no row exists
**Given:** No row exists in `realm_claim_mapping_config` for realm `unknown-realm`.
**When:** `loadClaimMappingConfig` is called with that realm.
**Then:** `null` is returned, and callers fall back to `DEFAULT_CLAIM_MAPPING_CONFIG`.
**Layer:** integration
**Acceptance criterion mapped:** Claim mapping rules are configurable per realm and stored in platform configuration (null = defaults apply).

### TC-OIDC-08-I03: Config loading with custom non-default paths
**Given:** A row exists in `realm_claim_mapping_config` with custom non-default claim paths.
**When:** `loadClaimMappingConfig` is called.
**Then:** The returned config has the custom paths, not defaults.
**Layer:** integration
**Acceptance criterion mapped:** Claim mapping rules are configurable per realm.

## Acceptance-to-Test Traceability

| OIDC-08 acceptance criterion | Test cases | Files |
|---|---|---|
| Tokens from different configured providers produce equivalent internal user contexts | TC-OIDC-08-U13, U14, U15 | `tests/unit/test_oidc08_claim_mapping.zig` |
| Claim mapping rules are configurable per realm and stored in platform configuration | TC-OIDC-08-I01, I02, I03 | `tests/integration/oidc08_claim_mapping_config_test.zig` |
| Missing `email` defaults to empty string | TC-OIDC-08-U03, U10 | `tests/unit/test_oidc08_claim_mapping.zig` |
| Missing `preferred_username` defaults to `sub` value | TC-OIDC-08-U04, U11 | `tests/unit/test_oidc08_claim_mapping.zig` |
| Missing `roles` defaults to empty list | TC-OIDC-08-U05 | `tests/unit/test_oidc08_claim_mapping.zig` |
| `sub` → external user ID (required) | TC-OIDC-08-U01, U02 | `tests/unit/test_oidc08_claim_mapping.zig` |
| Configurable `tenant_id` claim path | TC-OIDC-08-U07, U19 | `tests/unit/test_oidc08_claim_mapping.zig` |
| Nested role resolution + fallback | TC-OIDC-08-U08, U09, U16 | `tests/unit/test_oidc08_claim_mapping.zig` |

## Directive Alignment

- This spec does not introduce mocks or stubs for backend code.
- Integration tests connect to real PostgreSQL via `BPM_TEST_DB_URL`.
- Pure function unit tests run without any database dependency.
- Every MUST acceptance criterion has ≥1 test case that would fail if the requirement were violated.
