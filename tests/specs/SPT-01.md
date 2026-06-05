# Test Spec: SPT-01 — Schema-Per-Tenant Provisioning Infrastructure

**Requirement:** SPT-01 — Schema-per-tenant provisioning infrastructure: `public.tenant_schemas` registry, `bpm_provision_tenant_schema()` SQL function, `runForSchema` migration runner extension, pool `search_path` management, and `provisionTenantSchema` Zig orchestrator.  
**Priority:** MUST  
**Test layer:** integration (all cases require real PostgreSQL via `BPM_TEST_DB_URL`)

---

## Test Cases

| TC ID | Name | Layer | Acceptance Criterion |
|---|---|---|---|
| TC-SPT-01-01 | `provisionTenantSchema` creates schema named `tenant_<uuid_no_hyphens>` | integration | Schema exists in `information_schema.schemata` after call |
| TC-SPT-01-02 | `provisionTenantSchema` is idempotent | integration | Second call produces no error; exactly one row in `public.tenant_schemas` |
| TC-SPT-01-03 | `runForSchema` applies migrations inside the new schema | integration | Key tables exist in `pg_tables` for the provisioned schema name |
| TC-SPT-01-04 | `public.schema_migrations` records `(schema_name, version)` per applied migration | integration | At least one row with correct `schema_name` in `public.schema_migrations` |
| TC-SPT-01-05 | Default UUID maps to schema name `tenant_default` | integration | `tenant_schemas` row has `schema_name = 'tenant_default'`; schema exists |
| TC-SPT-01-06 | Pool checkout sets `search_path` to `'<tenant_schema>,public'` for non-default tenant | integration | `SHOW search_path` on acquired connection contains the stripped UUID schema name |
| TC-SPT-01-07 | Pool checkout for default tenant sets `search_path` to `'tenant_default,public'` | integration | `SHOW search_path` on acquired connection contains `tenant_default` |
| TC-SPT-01-08 | Existing public-schema migrations are tracked with `schema_name='public'` after migration 060 | integration | `public.schema_migrations WHERE schema_name = 'public' AND version LIKE '001%'` returns at least one row |

---

### TC-SPT-01-01: `provisionTenantSchema` creates schema named `tenant_<uuid_no_hyphens>`

**Given:** A test UUID is generated; no schema with that name exists in the database.  
**When:** `provisionTenantSchema(alloc, pool, test_uuid_str, migrations_dir)` is called.  
**Then:** `SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'tenant_<stripped>'` returns 1.  
**Layer:** integration  
**Acceptance criterion mapped:** `bpm_provision_tenant_schema()` creates the PostgreSQL schema using the naming convention `tenant_` + UUID with hyphens stripped.

---

### TC-SPT-01-02: `provisionTenantSchema` is idempotent

**Given:** `provisionTenantSchema` is called once for a fresh UUID (schema and registry row created).  
**When:** `provisionTenantSchema` is called a second time with the same UUID.  
**Then:** No error is returned on the second call; `SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1` returns exactly 1.  
**Layer:** integration  
**Acceptance criterion mapped:** Idempotency guarantee — safe to call multiple times for the same tenant.

---

### TC-SPT-01-03: `runForSchema` applies migrations inside the new schema

**Given:** `provisionTenantSchema` completes for a test UUID.  
**When:** `pg_tables` is queried for `schemaname = '<provisioned_schema_name>'`.  
**Then:** Key tables (`events`, `process_definitions`, `tasks`) exist in that schema.  
**Layer:** integration  
**Acceptance criterion mapped:** `runForSchema` applies all pending SQL migrations with `search_path` set to the tenant schema, causing unqualified `CREATE TABLE` statements to resolve to the tenant schema.

---

### TC-SPT-01-04: `public.schema_migrations` records `(schema_name, version)` per migration

**Given:** `provisionTenantSchema` completes for a test UUID.  
**When:** `public.schema_migrations WHERE schema_name = '<provisioned_schema_name>'` is queried.  
**Then:** At least one row exists with the correct `schema_name`.  
**Layer:** integration  
**Acceptance criterion mapped:** Migration tracking table stores per-schema migration history; each tenant's migration state is independent.

---

### TC-SPT-01-05: Default UUID maps to schema name `tenant_default`

**Given:** The all-zeros UUID `00000000-0000-0000-0000-000000000000` is used as `tenant_id_str`.  
**When:** `provisionTenantSchema` is called with this UUID.  
**Then:** The `public.tenant_schemas` row has `schema_name = 'tenant_default'`; the schema `tenant_default` exists in `information_schema.schemata`.  
**Layer:** integration  
**Acceptance criterion mapped:** Special-case mapping of the default/system tenant UUID to the human-readable `tenant_default` schema name.

---

### TC-SPT-01-06: Pool checkout sets `search_path` for non-default tenant

**Given:** The pool-level tenant context (`api_tenant_context`) is set to a test UUID.  
**When:** A pool connection is acquired and `SHOW search_path` is executed.  
**Then:** The result contains `tenant_<stripped_uuid>`.  
**Layer:** integration  
**Acceptance criterion mapped:** `applyRequestTenantContext` sets `search_path TO <schema_name>,public` on every connection checkout for non-default tenants.

---

### TC-SPT-01-07: Pool checkout for default tenant sets `search_path` to `tenant_default`

**Given:** The pool-level tenant context is set to empty string (default tenant).  
**When:** A pool connection is acquired and `SHOW search_path` is executed.  
**Then:** The result contains `tenant_default`.  
**Layer:** integration  
**Acceptance criterion mapped:** `applyRequestTenantContext` uses `tenant_default` schema name when tenant is empty or the all-zeros UUID.

---

### TC-SPT-01-08: Existing migrations tracked with `schema_name='public'` after migration 060

**Given:** All public-schema migrations (001 through 060) have been applied by `TestHarness.init()`.  
**When:** `public.schema_migrations WHERE schema_name = 'public' AND version LIKE '001%'` is queried.  
**Then:** At least one row is returned (migration 001 was applied to the public schema and is tracked).  
**Layer:** integration  
**Acceptance criterion mapped:** Migration 060 adds the `schema_name` column with `DEFAULT 'public'`; existing migration history rows are back-filled with `'public'` so historical tracking is preserved.
