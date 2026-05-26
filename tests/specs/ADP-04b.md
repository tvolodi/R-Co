# Test Spec: ADP-04b — Realm binding on tenant

**Requirement:** ADP-04b — The tenant table MUST gain `idp_realm_id TEXT NULL` for the identity provider realm identifier. The default tenant value is set to `bpm-default` on migration. Future tenants require this field at creation time once OIDC is in use.
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-ADP-04b-01: migration backfills default tenant realm binding to bpm-default
**Given:** Migration `031_adp04b_tenant_realm_binding.sql` has been applied to the integration database.
**When:** The default tenant row (`00000000-0000-0000-0000-000000000000`) is queried.
**Then:** `tenant.idp_realm_id` is exactly `bpm-default`, and assertions are deterministic (single-row lookup by fixed tenant UUID).
**Layer:** integration
**Acceptance criterion mapped:** The default tenant has `idp_realm_id = 'bpm-default'`.
**Implemented by:** `tests/integration/adp04b_tenant_realm_binding_test.zig` test `TC-ADP-04b-01`.

### TC-ADP-04b-02: OIDC-enabled non-default tenant creation requires idp_realm_id
**Given:** A PLATFORM_ADMIN actor and OIDC mode enabled.
**When:** A non-default tenant create request is executed with `idp_realm_id = null`.
**Then:** Creation is rejected with `IdentityError.MissingRealmBinding` and no tenant row is inserted.
**Layer:** integration
**Acceptance criterion mapped:** New tenants cannot be created without `idp_realm_id` once OIDC is in use.
**Implemented by:** `tests/integration/adp04b_tenant_realm_binding_test.zig` test `TC-ADP-04b-02`.

### TC-ADP-04b-03: OIDC-disabled tenant creation remains compatible without realm binding
**Given:** A PLATFORM_ADMIN actor and OIDC mode disabled.
**When:** A non-default tenant create request is executed with `idp_realm_id = null`.
**Then:** Tenant creation succeeds and persisted `tenant.idp_realm_id` remains `NULL`.
**Layer:** integration
**Acceptance criterion mapped:** Compatibility for existing/default-compatibility flows while OIDC enforcement is disabled.
**Implemented by:** `tests/integration/adp04b_tenant_realm_binding_test.zig` test `TC-ADP-04b-03`.

### TC-ADP-04b-04: realm ownership and uniqueness invariants align with ADP-04a and OIDC-12
**Given:** A tenant is created with a concrete realm binding in OIDC-enabled mode.
**When:** A second tenant is created with the same realm, and external identity provisioning is attempted with matching and mismatched realms.
**Then:** Duplicate realm binding is rejected, matching realm provisioning succeeds, and mismatched realm provisioning fails with `IdentityError.RealmOwnershipMismatch`.
**Layer:** integration
**Acceptance criterion mapped:** OIDC-12 one-to-one realm binding and ADP-04a realm-ownership guard invariants.
**Implemented by:** `tests/integration/adp04b_tenant_realm_binding_test.zig` test `TC-ADP-04b-04`, with cross-check in `tests/integration/adp04a_external_identity_linkage_test.zig` tests `TC-ADP-04a-04` and `TC-ADP-04a-06`.

## Traceability Matrix

| Requirement acceptance criterion | Concrete integration test evidence |
|---|---|
| Default tenant gets `idp_realm_id = 'bpm-default'` | `TC-ADP-04b-01` in `tests/integration/adp04b_tenant_realm_binding_test.zig` |
| New tenants require `idp_realm_id` once OIDC is enabled | `TC-ADP-04b-02` (negative boundary) + `TC-ADP-04b-03` (compatibility boundary) in `tests/integration/adp04b_tenant_realm_binding_test.zig` |
| Realm-to-tenant ownership invariants (OIDC-12, ADP-04a alignment) | `TC-ADP-04b-04` in `tests/integration/adp04b_tenant_realm_binding_test.zig`; `TC-ADP-04a-04` and `TC-ADP-04a-06` in `tests/integration/adp04a_external_identity_linkage_test.zig` |

## Coverage Gaps Identified

- **MAJOR**: Missing explicit integration test for the default-tenant creation validation boundary under OIDC-enabled mode where supplied `idp_realm_id` is not `bpm-default` and service must return `IdentityError.DefaultTenantRealmMismatch`.
- **MINOR**: Missing explicit integration test proving default-tenant creation/bootstrap with OIDC-enabled mode and omitted realm is normalized to `bpm-default`.

## Execution Notes For TEST-RUNNER

- Required env: `BPM_TEST_DB_URL` pointing to PostgreSQL integration database.
- Re-run `zig build test-integration` to execute `TC-ADP-04b-*` and ADP-04a cross-invariant tests.
- Assertions rely on deterministic tenant UUIDs, fixed realms, and explicit cleanup in test fixtures.
