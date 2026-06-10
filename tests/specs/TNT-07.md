# TNT-07 — RLS cleanup migration test specification

**Requirement:** TNT-07 — Remove RLS policies and tenant_id columns from public business tables
**Priority:** MUST
**Stage:** 12
**Test file:** `tests/integration/tnt_backfill_export_cleanup_test.zig`

## Test Cases

### TC-TNT-07-01 — Pre-flight abort on unready tenant
- **Given:** A tenant exists in `public.tenant` with no COMPLETED row in `tnt05_progress`
- **When:** GBL-077 pre-flight check runs
- **Then:** `RAISE EXCEPTION` is raised listing the unready tenant; no DDL changes are made

### TC-TNT-07-02 — Pre-flight pass with all tenants ready
- **Given:** All tenants have `tenant_schemas.migrations_applied_at IS NOT NULL` and at least one COMPLETED row in `tnt05_progress`
- **When:** GBL-077 pre-flight check runs
- **Then:** Migration proceeds (already applied in test environment — skip status)

### TC-TNT-07-03 — Business tables absent from public
- **Given:** GBL-073 (drop legacy public tables) and GBL-077 (RLS cleanup) have been applied
- **When:** Query `information_schema.tables` for public business tables (events, instance_projections, etc.)
- **Then:** No business data tables exist in public — they were dropped by GBL-073

### TC-TNT-07-04 — bpm_effective_tenant_id() function dropped
- **Given:** GBL-077 has been applied
- **When:** Query `information_schema.routines` for `public.bpm_effective_tenant_id`
- **Then:** Function does not exist (dropped by GBL-077)

### TC-TNT-07-05 — Migration is idempotent
- **Given:** GBL-077 has already been applied
- **When:** Migration runner attempts to re-apply GBL-077
- **Then:** Migration is skipped (already recorded in schema_migrations); no errors
