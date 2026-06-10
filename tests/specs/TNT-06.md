# TNT-06 — Tenant schema export/import and db_host routing test specification

**Requirement:** TNT-06 — Tenant schema export and import for server migration
**Priority:** MUST
**Stage:** 12
**Test file:** `tests/integration/tnt_backfill_export_cleanup_test.zig`

## Test Cases

### TC-TNT-06-01 — db_host column exists on tenant_schemas
- **Given:** GBL-076 migration applied
- **When:** Query `information_schema.columns` for `public.tenant_schemas.db_host`
- **Then:** Column exists with type TEXT and default NULL

### TC-TNT-06-02 — MIGRATING status column exists on tenant
- **Given:** GBL-076 migration applied
- **When:** Query `public.tenant` CHECK constraint for `status`
- **Then:** `status` column accepts values 'ACTIVE', 'INACTIVE', 'MIGRATING'

### TC-TNT-06-03 — MIGRATING status check rejects writes
- **Given:** A tenant with `status = 'MIGRATING'`
- **When:** middleware `checkTenantWritePause` is called with method POST and that tenant_id
- **Then:** Returns 503 HandlerResult with appropriate body

### TC-TNT-06-04 — MIGRATING status allows reads
- **Given:** A tenant with `status = 'MIGRATING'`
- **When:** middleware `checkTenantWritePause` is called with method GET and that tenant_id
- **Then:** Returns null (request proceeds normally)

### TC-TNT-06-05 — Export endpoint handler exists and compiles
- **Given:** `handleExportTenant` function is callable
- **When:** Called with valid tenant_id and body
- **Then:** Function compiles and returns a HandlerResult (HTTP 202 or 404/409/500 as appropriate)
