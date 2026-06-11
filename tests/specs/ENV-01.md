# Test Spec: ENV-01 — Tenant carries a type field distinguishing production from test

**Requirement:** ENV-01 — `public.tenant` gains `tenant_type` and `production_tenant_id` columns enforced by DB constraint and onboarding API.  
**Priority:** MUST  
**Test layer:** integration

## Test Cases

### TC-ENV-01-01: Migration applied — tenant_type column present with correct constraint
**Given:** The database migration GBL-080 has been applied  
**When:** Querying `information_schema.columns` for `public.tenant`  
**Then:** Column `tenant_type` exists with `NOT NULL` constraint and default `'production'`; check constraint `ck_tenant_type_fk_coherence` exists  
**Layer:** integration  
**Acceptance criterion mapped:** `public.tenant` has `tenant_type TEXT NOT NULL DEFAULT 'production' CHECK (tenant_type IN ('production', 'test'))`

### TC-ENV-01-02: Migration applied — production_tenant_id FK column present
**Given:** The database migration GBL-080 has been applied  
**When:** Querying `information_schema.columns` for `public.tenant`  
**Then:** Column `production_tenant_id` exists, is nullable, and has a FK reference to `tenant(id) ON DELETE RESTRICT`  
**Layer:** integration  
**Acceptance criterion mapped:** `production_tenant_id UUID NULL REFERENCES public.tenant(id) ON DELETE RESTRICT`

### TC-ENV-01-03: Existing rows backfilled to tenant_type='production'
**Given:** The migration is applied and the default tenant row exists  
**When:** Querying `SELECT tenant_type, production_tenant_id FROM public.tenant`  
**Then:** Every existing row has `tenant_type = 'production'` and `production_tenant_id IS NULL`  
**Layer:** integration  
**Acceptance criterion mapped:** Existing rows backfilled to `tenant_type='production'`, `production_tenant_id=NULL`

### TC-ENV-01-04: DB constraint — test tenant with valid production_tenant_id succeeds
**Given:** A production tenant row exists in `public.tenant`  
**When:** A test tenant row is inserted with `tenant_type='test'` and `production_tenant_id=<valid_production_id>`  
**Then:** The INSERT succeeds; the row is present with correct values  
**Layer:** integration  
**Acceptance criterion mapped:** Test tenant can be created with a valid `production_tenant_id`

### TC-ENV-01-05: DB constraint — test tenant without production_tenant_id fails
**Given:** The migration is applied  
**When:** An INSERT of a row with `tenant_type='test'` and `production_tenant_id=NULL` is attempted  
**Then:** PostgreSQL raises a constraint violation error  
**Layer:** integration  
**Acceptance criterion mapped:** Constraint `ck_tenant_type_fk_coherence` enforces test tenants must have a non-null FK

### TC-ENV-01-06: DB constraint — production tenant with production_tenant_id fails
**Given:** The migration is applied  
**When:** An INSERT of a row with `tenant_type='production'` and a non-null `production_tenant_id` is attempted  
**Then:** PostgreSQL raises a constraint violation error  
**Layer:** integration  
**Acceptance criterion mapped:** Constraint `ck_tenant_type_fk_coherence` enforces production tenants must have null FK

### TC-ENV-01-07: Onboarding validation — test tenant missing production_tenant_id
**Given:** The onboarding module is available  
**When:** `executeSaga` is called with `tenant_type=.testing` and `production_tenant_id=null`  
**Then:** Returns `error.TestTenantMissingProductionRef`  
**Layer:** integration  
**Acceptance criterion mapped:** `POST /api/v1/tenants/onboard` with `tenant_type='test'` and no `production_tenant_id` → HTTP 422

### TC-ENV-01-08: Onboarding validation — production tenant with production_tenant_id
**Given:** The onboarding module is available  
**When:** `executeSaga` is called with `tenant_type=.production` and a non-null `production_tenant_id`  
**Then:** Returns `error.ProductionTenantMustNotHaveRef`  
**Layer:** integration  
**Acceptance criterion mapped:** `POST /api/v1/tenants/onboard` with `tenant_type='production'` and a `production_tenant_id` → HTTP 422

### TC-ENV-01-09: GET /admin/tenants includes tenant_type and production_tenant_id
**Given:** A test tenant and a production tenant exist in the database  
**When:** `handleListTenants` is called by a PLATFORM_ADMIN  
**Then:** Response JSON contains `tenant_type` and `production_tenant_id` fields for every entry  
**Layer:** integration  
**Acceptance criterion mapped:** `GET /api/v1/admin/tenants` response includes both new fields

### TC-ENV-01-10: PATCH with tenant_type key returns HTTP 422
**Given:** A tenant exists  
**When:** `handlePatchTenant` is called with a body containing the `tenant_type` key  
**Then:** HTTP 422 with `error: "immutable_field"`  
**Layer:** integration  
**Acceptance criterion mapped:** `PATCH /api/v1/tenants/:id` must reject `tenant_type` with HTTP 422 (immutable)

### TC-ENV-01-11: PATCH with production_tenant_id key returns HTTP 422
**Given:** A tenant exists  
**When:** `handlePatchTenant` is called with a body containing the `production_tenant_id` key  
**Then:** HTTP 422 with `error: "immutable_field"`  
**Layer:** integration  
**Acceptance criterion mapped:** `PATCH /api/v1/tenants/:id` must reject `production_tenant_id` with HTTP 422 (immutable)

### TC-ENV-01-12: ON DELETE RESTRICT — deleting production tenant blocked by test tenant FK
**Given:** A production tenant and a linked test tenant exist  
**When:** `DELETE FROM public.tenant WHERE id = <production_tenant_id>` is executed  
**Then:** PostgreSQL raises a foreign key violation (test tenant references production tenant)  
**Layer:** integration  
**Acceptance criterion mapped:** `ON DELETE RESTRICT` prevents production tenant deletion while test tenants reference it
