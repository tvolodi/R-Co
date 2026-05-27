# Test Spec: OIDC-09 — JIT user creation

**Requirement:** OIDC-09 — On first successful authentication of an external user, the platform MUST create a local user record (per IDN-01 schema) mirroring the OIDC identity, with `external_id` (the OIDC `sub`), `external_realm`, and `tenant_id` populated. The local user MUST be marked as externally authenticated (no local password).

**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-OIDC-09-01: First auth creates new user record with auth_source=oidc
**Given:** A realm with JIT provisioning enabled and a new OIDC identity context not yet seen by the platform
**When:** The JIT provisioning pipeline is invoked (loadJitConfig → createOrGetJitOidcUser → processProvisionResult)
**Then:** A new user record is created with `auth_source='oidc'`, `external_id` = the OIDC `sub`, `external_realm` populated, `created=true`, and the user status is `ACTIVE`
**Layer:** integration
**Acceptance criterion mapped:** First login of a new OIDC user creates exactly one local record

### TC-OIDC-09-02: Subsequent auth returns existing user (no duplicate)
**Given:** An OIDC user has already been JIT-provisioned in a previous auth
**When:** The same identity context is presented again to `createOrGetJitOidcUser`
**Then:** The existing user record is returned with `created=false`, and exactly one row exists for that `(tenant_id, external_realm, external_id)` tuple
**Layer:** integration
**Acceptance criterion mapped:** Subsequent logins for the same OIDC user do not create duplicates

### TC-OIDC-09-03: JIT disabled for realm returns JitDisabled
**Given:** The realm's JIT provisioning config has `enabled=false`
**When:** JIT provisioning is attempted for that realm
**Then:** `loadJitConfig` returns a config with `enabled=false`, and the auth pipeline should reject the request (equivalent to HTTP 401)
**Layer:** integration
**Acceptance criterion mapped:** JIT provisioning failure blocks auth (returns 401/500)

### TC-OIDC-09-04: Default config returned when no explicit row exists
**Given:** A realm with no row in `jit_provisioning_config`
**When:** `loadJitConfig` is called for that realm
**Then:** The default config is returned: `enabled=true`, `default_status=ACTIVE`, `default_roles=[]`
**Layer:** integration
**Acceptance criterion mapped:** First login of a new OIDC user creates exactly one local record

### TC-OIDC-09-05: Duplicate preferred_username with existing internal user
**Given:** An internal user exists with a given username
**When:** JIT provisioning is attempted with the same `preferred_username`
**Then:** `createOrGetJitOidcUser` returns `error.DuplicateUsername`
**Layer:** integration
**Acceptance criterion mapped:** JIT provisioning failure blocks auth (returns 401/500)

### TC-OIDC-09-06: JIT provisioning emits audit event on creation
**Given:** A new OIDC user is JIT-provisioned for the first time
**When:** `processProvisionResult` is called with `created=true`
**Then:** An audit entry is written to `audit_entries` with `action='user.jit_provision'` and `resource_type='user'`
**Layer:** integration
**Acceptance criterion mapped:** First login of a new OIDC user creates exactly one local record

### TC-OIDC-09-07: Attributes map correctly from IdentityContext to user record
**Given:** An IdentityContext with specific `preferred_username`, `display_name`, `email`, and `external_user_id` (sub)
**When:** JIT provisioning is invoked
**Then:** The created user record has matching `username`, `display_name`, `email`, and `external_id`
**Layer:** integration
**Acceptance criterion mapped:** First login of a new OIDC user creates exactly one local record

### TC-OIDC-09-08: Migration creates jit_provisioning_config table with bpm-default seed
**Given:** The migrations have been applied against the test database
**When:** Inspecting the schema and seed data
**Then:** The `jit_provisioning_config` table exists with a seed row for `bpm-default` realm with `enabled=true`, `default_status='ACTIVE'`, `default_roles='[]'`
**Layer:** integration
**Acceptance criterion mapped:** Migration: jit_provisioning_config table created and bpm-default seed row exists

### TC-OIDC-09-09: Config overrides take effect (INACTIVE default status)
**Given:** A `jit_provisioning_config` row with `default_status='INACTIVE'` for a realm
**When:** `loadJitConfig` is called for that realm
**Then:** The returned config has `default_status=INACTIVE`
**Layer:** integration
**Acceptance criterion mapped:** First login of a new OIDC user creates exactly one local record

### TC-OIDC-09-10: Config overrides take effect (custom default roles)
**Given:** A `jit_provisioning_config` row with `default_roles='["VIEWER"]'` for a realm
**When:** `loadJitConfig` is called for that realm
**Then:** The returned config has `default_roles` containing `"VIEWER"`
**Layer:** integration
**Acceptance criterion mapped:** First login of a new OIDC user creates exactly one local record
