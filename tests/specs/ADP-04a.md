# Test Spec: ADP-04a — External identity linkage on user

**Requirement:** ADP-04a — The user table MUST gain `external_id TEXT NULL`, `external_realm TEXT NULL`, and `auth_source TEXT NOT NULL DEFAULT 'internal'` with allowed values `internal` and `oidc`. A unique index over `(external_realm, external_id)` MUST enforce one local user per external identity, while preserving existing internal-user behavior.  
**Priority:** MUST  
**Test layer:** integration

## Test Cases

### TC-ADP-04a-01: migration adds external-linkage columns without rewriting legacy internal users
**Given:** The integration database contains pre-existing internal users before migration `030_adp04a_external_identity_linkage.sql` is applied.  
**When:** The migration is applied and the users table is inspected.  
**Then:** `external_id` and `external_realm` are nullable columns, `auth_source` exists with a `NOT NULL` default of `internal`, and the pre-existing user count is unchanged. Any legacy row still reads back as `auth_source = internal` with both external linkage fields `NULL`.  
**Layer:** integration  
**Acceptance criterion mapped:** Additive migration semantics and backward-compatible internal-user rows.

### TC-ADP-04a-02: internal users keep NULL external linkage and do not resolve through external-identity lookup
**Given:** A user row exists with `auth_source = internal` and both external linkage columns `NULL`.  
**When:** `resolveUserByExternalIdentity` or `selectUserByExternalIdentity` is queried with the row's tenant plus any realm/sub pair that is not explicitly linked.  
**Then:** The lookup returns `null`, and no fallback by username or email occurs. The internal user remains valid and unchanged.  
**Layer:** integration  
**Acceptance criterion mapped:** NULL handling for backward-compatible internal-user rows and no accidental external binding.

### TC-ADP-04a-03: JIT OIDC provisioning stores oidc linkage and resolves by tenant plus realm plus sub
**Given:** No user exists for a tenant/realm/sub combination.  
**When:** `createOrGetJitOidcUser` is called for that tenant with a preferred username, display name, email, realm, and sub.  
**Then:** A new user is created with `auth_source = oidc`, populated `external_realm`, and populated `external_id`, and a subsequent `resolveUserByExternalIdentity` call returns the same user id.  
**Layer:** integration  
**Acceptance criterion mapped:** Realm+sub lookup behavior and JIT provisioning linkage.

### TC-ADP-04a-04: repeated JIT provisioning for the same tenant plus realm plus sub is idempotent
**Given:** An oidc-linked user already exists for a specific tenant/realm/sub.  
**When:** `createOrGetJitOidcUser` is called again with the same tenant/realm/sub but different mutable profile claims.  
**Then:** The call returns the existing user with `created = false`, the same `user_id`, and no additional row is inserted.  
**Layer:** integration  
**Acceptance criterion mapped:** Uniqueness of `(external_realm, external_id)` and idempotent create-or-get behavior.

### TC-ADP-04a-05: tenant isolation blocks cross-tenant identity binding and collision reuse
**Given:** Tenant A already owns a linked external identity for a specific realm/sub pair.  
**When:** Tenant B attempts to resolve or provision the same realm/sub pair.  
**Then:** `resolveUserByExternalIdentity` returns `null`, and provisioning fails with a collision-style identity error instead of binding Tenant B to Tenant A's row. No second user row is created for that identity.  
**Layer:** integration  
**Acceptance criterion mapped:** Tenant-isolation boundaries for identity resolution and collision prevention.

### TC-ADP-04a-06: multiple internal NULL-linkage rows remain valid while duplicate external pairs are rejected
**Given:** Several internal users exist with `external_id = NULL` and `external_realm = NULL`, a legacy pre-migration internal user row is present, and one oidc-linked row already exists for a concrete realm/sub pair.  
**When:** A second row is attempted with the same non-NULL realm/sub pair, and the users table's index metadata is inspected for the external-identity uniqueness rule.  
**Then:** Multiple NULL-linkage internal rows coexist, the legacy row still reads as `auth_source = internal` with both external linkage fields `NULL`, the duplicate non-NULL realm/sub pair is rejected by the uniqueness rule, and the index is confirmed as the unique external-identity constraint used by the integration test.  
**Layer:** integration  
**Acceptance criterion mapped:** NULL-handling rules, duplicate non-NULL identity rejection, unique index shape, and backward-compatible migration/backfill behavior.

## Traceability

- ADP-04a acceptance criteria are covered by TC-ADP-04a-01 through TC-ADP-04a-06.
- Planned test source: `tests/integration/adp04a_external_identity_linkage_test.zig`.
- Automated coverage mapping: TC-ADP-04a-06 is expected to be represented in `tests/integration/adp04a_external_identity_linkage_test.zig` with assertions for NULL-linkage coexistence, duplicate non-NULL rejection, and index metadata or legacy-migration proof.

## Execution Notes For TEST-RUNNER

- Required env: `BPM_TEST_DB_URL` pointing to the integration PostgreSQL database.
- Tests must use deterministic tenant, realm, and sub fixtures and must not fall back to username/email matching for external identity resolution.