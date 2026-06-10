# TNT-05 — Backfill migration test specification

**Requirement:** TNT-05 — Backfill migration moves existing tenant data out of public schema
**Priority:** MUST
**Stage:** 12
**Test file:** `tests/integration/tnt_backfill_export_cleanup_test.zig`

## Test Cases

### TC-TNT-05-01 — Backfill tracking tables exist
- **Given:** GBL-074 migration has been applied
- **When:** Query `information_schema.tables` for `public.tnt05_progress` and `public.tnt05_orphans`
- **Then:** Both tables exist with correct columns (tenant_id, table_name, rows_copied, status for progress; row_id, table_name, tenant_id, reason for orphans)

### TC-TNT-05-02 — Migration window flag propagation
- **Given:** GBL-075 backfill runs
- **When:** Query `onboarding_registry.migration_window_active`
- **Then:** Flag exists as a BOOLEAN column (added by migration 071); GBL-075 sets it TRUE at start and FALSE at end

### TC-TNT-05-03 — Backfill idempotency
- **Given:** GBL-075 has already completed for all tenants
- **When:** GBL-075 is re-run (triggered via migration runner skip — it's already applied)
- **Then:** No duplicate rows in tnt05_progress; COMPLETED status preserved

### TC-TNT-05-04 — Orphan table structure
- **Given:** GBL-074 applied
- **When:** Query `public.tnt05_orphans` columns
- **Then:** Table has columns: row_id (TEXT), table_name (TEXT), tenant_id (UUID), reason (TEXT), logged_at (TIMESTAMPTZ)

### TC-TNT-05-05 — Default tenant mapping
- **Given:** Default tenant `00000000-0000-0000-0000-000000000000` exists
- **When:** Check `tenant_schemas` for the default tenant
- **Then:** Schema name is `tenant_default` (not `tenant_00000000000000000000000000000000`)
