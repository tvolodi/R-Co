# Test Spec: OIDC-03 -- Configuration source

**Requirement:** OIDC-03 -- The active identity provider MUST be selected via platform configuration (stored as an artifact per XC-03 once Stage 10 is operational; via environment variable until then). The configuration MUST include: provider type, base URL, admin credentials reference, default realm/tenant identifier.
**Priority:** MUST
**Test layer:** unit

## Test Cases

### TC-OIDC-03-01: Config loader accepts valid required fields and bounded timeouts
**Given:**
- Environment values provide `BPM_IDP_PROVIDER_TYPE=keycloak`, valid HTTPS `BPM_IDP_BASE_URL`, secret-reference `BPM_IDP_ADMIN_CREDENTIALS_REF`, and valid `BPM_IDP_DEFAULT_REALM_OR_TENANT`.
- Timeout fields are inside allowed bounds.

**When:**
- `loadIdentityProviderConfig` is called for production.

**Then:**
- Loader returns `IdentityProviderConfig` without error.
- Provider type resolves to `keycloak` and timeout values are preserved.

**Layer:** unit
**Acceptance criterion mapped:** Required OIDC-03 configuration shape is accepted for startup when valid.
**Implemented by:** `src/config/identity_provider.zig` test `TC-OIDC-03-01`.

---

### TC-OIDC-03-02: Config loader rejects invalid values for required fields
**Given:**
- One required field at a time is invalid: unsupported provider type, insecure/invalid base URL for production, plaintext admin credentials value, or reserved invalid default realm/tenant value.

**When:**
- `loadIdentityProviderConfig` is called with each invalid row.

**Then:**
- Loader returns the field-specific validation error (`UnsupportedProviderType`, `InvalidBaseUrl`, `InvalidAdminCredentialsRef`, `InvalidDefaultRealmOrTenant`).

**Layer:** unit
**Acceptance criterion mapped:** Misconfiguration is rejected at startup validation before server listeners open.
**Implemented by:** `src/config/identity_provider.zig` test `TC-OIDC-03-02`.

---

### TC-OIDC-03-04: Negative matrix covers missing required fields and timeout bounds
**Given:**
- Matrix rows omit each required field in turn (`provider_type`, `base_url`, `admin_credentials_ref`, `default_realm_or_tenant`).
- Matrix rows include out-of-range timeout values for request/connect timeouts.

**When:**
- `loadIdentityProviderConfig` is called for each row.

**Then:**
- Missing rows return explicit missing-field errors.
- Timeout rows return explicit invalid-timeout errors.

**Layer:** unit
**Acceptance criterion mapped:** Required-field validation and startup-fatal timeout bounds are exhaustively covered.
**Implemented by:** `src/config/identity_provider.zig` test `TC-OIDC-03-04`.

---

### TC-OIDC-03-03: Provider bootstrap selects configured provider type (stub path)
**Given:**
- A valid in-memory `IdentityProviderConfig` with `provider_type=stub`.

**When:**
- `initializeActiveProvider` is called.

**Then:**
- A non-null manager provider is wired and auth mode is set for dual-token acceptance.

**Layer:** unit
**Acceptance criterion mapped:** Switching configured provider type drives adapter selection via configuration path.
**Implemented by:** `src/identity/provider/bootstrap.zig` test `TC-OIDC-03-03`.

---

### TC-OIDC-03-05: Provider bootstrap selects configured provider type (keycloak path)
**Given:**
- A valid in-memory `IdentityProviderConfig` with `provider_type=keycloak` and required config fields.

**When:**
- `initializeActiveProvider` is called.

**Then:**
- Active runtime is Keycloak-backed and manager provider is non-null.

**Layer:** unit
**Acceptance criterion mapped:** Switching configured provider type triggers loading the corresponding adapter.
**Implemented by:** `src/identity/provider/bootstrap.zig` test `TC-OIDC-03-05`.

---

### TC-OIDC-03-06: Startup error mapping includes stable error_code and invalid field attribution
**Given:**
- Configuration and validation errors that represent each OIDC-03 required-field failure class and timeout-field failures.

**When:**
- `describeConfigError` maps each error.

**Then:**
- Returned detail includes deterministic `error_code` and exact field key for each mapped error.
- Non-config bootstrap failures are not misreported as config-field errors.

**Layer:** unit
**Acceptance criterion mapped:** Misconfiguration yields clear startup error identifying invalid field.
**Implemented by:** `src/identity/provider/bootstrap.zig` test `TC-OIDC-03-06`.

## Negative Misconfiguration Matrix

| Matrix ID | Misconfiguration | Expected error |
|---|---|---|
| MX-OIDC-03-01 | Missing `BPM_IDP_PROVIDER_TYPE` | `error.MissingProviderType` |
| MX-OIDC-03-02 | Missing `BPM_IDP_BASE_URL` | `error.MissingBaseUrl` |
| MX-OIDC-03-03 | Missing `BPM_IDP_ADMIN_CREDENTIALS_REF` | `error.MissingAdminCredentialsRef` |
| MX-OIDC-03-04 | Missing `BPM_IDP_DEFAULT_REALM_OR_TENANT` | `error.MissingDefaultRealmOrTenant` |
| MX-OIDC-03-05 | `BPM_IDP_PROVIDER_TYPE=unknown` | `error.UnsupportedProviderType` |
| MX-OIDC-03-06 | Insecure base URL in production (`http://...`) | `error.InvalidBaseUrl` |
| MX-OIDC-03-07 | Plaintext credentials value | `error.InvalidAdminCredentialsRef` |
| MX-OIDC-03-08 | Reserved realm/tenant value (`default`) | `error.InvalidDefaultRealmOrTenant` |
| MX-OIDC-03-09 | `BPM_IDP_REQUEST_TIMEOUT_MS` out of bounds | `error.InvalidRequestTimeoutMs` |
| MX-OIDC-03-10 | `BPM_IDP_CONNECT_TIMEOUT_MS` out of bounds | `error.InvalidConnectTimeoutMs` |

## Traceability Matrix

| OIDC-03 acceptance area | Concrete test evidence |
|---|---|
| Switching provider type loads corresponding adapter | `TC-OIDC-03-03`, `TC-OIDC-03-05` |
| Misconfiguration emits clear startup error with invalid field attribution | `TC-OIDC-03-06` + matrix rows `MX-OIDC-03-01..10` |
| Required config fields are enforced | `TC-OIDC-03-01`, `TC-OIDC-03-02`, `TC-OIDC-03-04` |
| TEST-RUNNER can execute coverage directly in current suite | `zig build test` executes module tests in `src/config/identity_provider.zig` and `src/identity/provider/bootstrap.zig` |

## Concrete Pass/Fail Signals

### Build-level checks
- **PASS:** `zig build test` exits 0 and executes OIDC-03 mapped unit tests.
- **FAIL:** compile errors in `identity_provider.zig` or `bootstrap.zig`, or any OIDC-03 test assertion failures.

### Runtime-level checks
- **PASS:** loader success path returns valid config for required fields.
- **PASS:** invalid/missing matrix rows fail with field-specific errors.
- **PASS:** bootstrap activates adapter matching configured provider type.
- **PASS:** startup config error mapping returns deterministic `error_code` and `field` values.
- **FAIL:** any mismatch in expected error variant, provider selection branch, or mapped field key.

## Execution Notes For TEST-RUNNER

- Primary command: `zig build test`
- Focused rerun commands (if isolating failures):
  - `zig test src/config/identity_provider.zig`
  - `zig test src/identity/provider/bootstrap.zig`
