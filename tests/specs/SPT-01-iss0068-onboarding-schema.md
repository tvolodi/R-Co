# Test Spec: SPT-01 — ISS-0068 onboarding schema provisioning

**Requirement:** SPT-01 — Schema-per-tenant provisioning infrastructure; onboarding flow must provision tenant schema and registry entry.
**Issue:** ISS-0068
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-SPT-01-ISS68-01: onboarding provisioning path creates tenant schema + registry row
**Given:** A fresh random tenant UUID is generated for this test run.
**When:** `provisionTenantSchema(allocator, pool, tenant_id, migrations_dir)` is called for that UUID.
**Then:** `public.tenant_schemas` contains exactly one row for `tenant_id`.
**Then:** `information_schema.schemata` contains the derived schema name.
**Layer:** integration
**Acceptance criterion mapped:** Onboarding schema provisioning wiring produces persisted schema + registry state.

### TC-SPT-01-ISS68-02: retroactive backfill leaves tenant and tenant_schemas counts aligned
**Given:** Migration backfill (069/070) has already been applied in the test database.
**When:** The test compares `SELECT count(*) FROM public.tenant` and `SELECT count(*) FROM public.tenant_schemas`.
**Then:** The counts are equal.
**Then:** `tenant_default` exists in `information_schema.schemata`.
**Layer:** integration
**Acceptance criterion mapped:** Existing tenants are fully backfilled with schema registry rows and default schema presence.

### TC-SPT-01-ISS68-03: provisionTenantSchema is idempotent for same tenant
**Given:** A fresh random tenant UUID is generated for this test run.
**When:** `provisionTenantSchema(...)` is called twice for the same UUID.
**Then:** Both calls succeed without error.
**Then:** `public.tenant_schemas` contains exactly one row for that `tenant_id`.
**Layer:** integration
**Acceptance criterion mapped:** Provisioning is idempotent and safe under retries.

## Isolation and cleanup

- All tests connect to real PostgreSQL via `BPM_TEST_DB_URL`; missing env var is a hard test error.
- Fixture tenants use per-test UUIDs; no hardcoded fixture IDs.
- Tests that create schemas clean up via `bpm_drop_tenant_schema($1::uuid)` in `defer` blocks.
- No `error.SkipZigTest` is used.
