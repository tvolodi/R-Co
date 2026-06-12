# Module: ISS-503 RLS Removal

## Module purpose

This module defines the migration (GBL-084) and code changes to remove legacy Row-Level Security predicates from the public schema after all tenants have been cut over to SCHEMA mode. It enforces a hard pre-flight guard: the migration MUST NOT proceed if any tenant still has `storage_mode = 'LEGACY_RLS'`. Once the guard passes, the migration drops all RLS policies, removes `tenant_id` columns from business tables, drops the `bpm_effective_tenant_id()` function, and removes `set_config('bpm.tenant_id', ...)` calls from the connection routing path. The migration is idempotent (`IF EXISTS` everywhere).

## Scope and non-goals

- In scope: GBL-084 migration SQL with DO-block pre-flight guard.
- In scope: removal of `set_config('bpm.tenant_id', ...)` from `pool.zig:applyRequestStorageRouting()` (LEGACY_RLS branch).
- In scope: removal of `bpm.tenant_id` references from unit/integration tests that relied on the RLS session variable.
- Out of scope: dropping the orphaned rows from public schema (these are the rows that were copied to tenant schemas during ISS-502 cutover; they remain in public until an archival step).
- Out of scope: removing `tenant_id` from the `tenant` table or other global/SaaS tables that are NOT per-tenant business tables.

## Prerequisites

- ISS-502: all tenants have been cut over to SCHEMA mode (storage_mode = 'SCHEMA').
- ISS-501: storage-mode-aware routing is active (SCHEMA path no longer calls set_config).
- ISS-107: storage_mode column exists and is indexed.

## Comparison with GBL-077

GBL-077 (TNT-07) performed a similar RLS cleanup but used a different pre-flight guard (checking `tnt05_progress` for COMPLETED status). ISS-503 replaces GBL-077's logic with a simpler, more direct guard: zero tenants in LEGACY_RLS mode. The DDL operations are the same (DROP POLICY, DROP COLUMN, DROP FUNCTION) but the guard is different and the migration number is new (GBL-084).

GBL-077 already exists in the migrations directory. GBL-084 is a NEW migration that should be applied AFTER GBL-077. Since GBL-077 uses `IF EXISTS` throughout, applying GBL-084 after it is safe (the policies and columns may already be dropped, and IF EXISTS makes that a no-op).

**Critical note:** GBL-084 and GBL-077 must not conflict. GBL-084 will be numbered higher than GBL-077 (084 > 077), so the migration runner applies GBL-077 first, then GBL-084. GBL-084's guard (zero LEGACY_RLS tenants) is stricter than GBL-077's guard (tnt05_progress COMPLETED), so GBL-084 may fail the pre-flight even after GBL-077 succeeded. This is intentional: GBL-084 is the definitive RLS teardown gated on the storage_mode flag.

## Migration: GBL-084_rls_removal.sql

### Pre-flight guard

```sql
DO $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Guard: must be zero tenants in LEGACY_RLS mode.
    SELECT count(*) INTO v_count
    FROM public.tenant
    WHERE storage_mode = 'LEGACY_RLS';

    IF v_count > 0 THEN
        RAISE EXCEPTION 'ISS-503 pre-flight failed: % tenant(s) still in LEGACY_RLS mode. All tenants must be cut over to SCHEMA before RLS removal.', v_count;
    END IF;

    RAISE NOTICE 'GBL-084: Pre-flight check PASSED — zero LEGACY_RLS tenants. Proceeding with RLS removal.';
END $$;
```

### DDL operations (idempotent, IF EXISTS)

Same tables as GBL-077, with the addition of `webhook_deliveries`. Three groups of operations:

**Group 1: RLS-protected tables** — disable RLS, drop policy, drop `tenant_id` column.
Tables: `process_definitions`, `instance_projections`, `tasks`, `tokens`, `audit_entries`, `audit_log`.

```sql
ALTER TABLE IF EXISTS process_definitions   DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS process_definitions_tenant_policy   ON process_definitions;
ALTER TABLE IF EXISTS process_definitions   DROP COLUMN IF EXISTS tenant_id;
-- ... (same pattern for all 6 RLS-protected tables)
```

**Group 2: Non-RLS tables with tenant_id** — drop `tenant_id` column only.
Tables: `events`, `events_archive`, `instance_sequence`, `event_type_registry`, `event_retention_policies`, `timers`, `users`, `groups`, `group_members`, `roles`, `user_roles`, `api_tokens`, `webhook_subscriptions`, `webhook_deliveries`, `dead_letter_items`, `repository_form_schemas`.

```sql
ALTER TABLE IF EXISTS events DROP COLUMN IF EXISTS tenant_id;
-- ... (same pattern for all 16 tables)
```

**Group 3: Drop helper function.**

```sql
DROP FUNCTION IF EXISTS bpm_effective_tenant_id();
```

The full DDL is in the migration file `migrations/GBL-084_rls_removal.sql`.

## Code changes: pool.zig

### Remove set_config calls from LEGACY_RLS branch

After GBL-084 is applied, the LEGACY_RLS branch in `applyRequestStorageRouting()` no longer needs to call `set_config('bpm.tenant_id', ...)` because RLS policies have been dropped. However, during the transition period (between ISS-501 deployment and ISS-503 completion), some tenants may still be LEGACY_RLS and need the set_config call. The code must handle both cases:

**Approach A (recommended):** Keep the `set_config` call in the LEGACY_RLS branch unconditionally. After GBL-084, there are zero LEGACY_RLS tenants, so the LEGACY_RLS branch is never taken. The code is dead but harmless. Remove it in a follow-up cleanup.

**Approach B:** Remove the `set_config` call immediately after GBL-084 is applied. This is cleaner but requires coordination between migration and deploy.

Recommendation: **Approach A** for this issue. The LEGACY_RLS branch's `set_config` call is harmless after RLS removal (it sets a session variable that no policy reads). A follow-up cleanup can remove the dead branch entirely.

### No changes to SCHEMA branch

The SCHEMA branch already does not call `set_config('bpm.tenant_id', ...)`. No changes needed.

## Code changes: tenant_context.zig

No changes required. The `tenant_id` is still resolved and stored; it is simply no longer propagated as a PostgreSQL session variable for LEGACY_RLS tenants (because there are none).

## Error taxonomy

```zig
// No new Zig-level errors. The migration pre-flight guard raises a
// PostgreSQL-level EXCEPTION if LEGACY_RLS tenants remain.
```

## Integration points

- `migrations/GBL-084_rls_removal.sql` -- new migration file.
- `src/db/pool.zig` -- `applyRequestStorageRouting()` may remove `set_config('bpm.tenant_id', ...)` from LEGACY_RLS branch (or defer to cleanup).
- `src/db/migrations.zig` -- no changes; the migration runner handles GBL-prefixed files via the existing `runForSchema` logic.

## Dependencies

- ISS-107: `storage_mode` column (RELEASED).
- ISS-501: storage-mode-aware routing (for the SCHEMA path to work).
- ISS-502: SPT cutover must have been executed for all tenants.

## Teardown completeness checklist

After GBL-084 is applied:

- [ ] `SELECT count(*) FROM tenant WHERE storage_mode = 'LEGACY_RLS'` returns 0.
- [ ] `SELECT count(*) FROM pg_policies WHERE schemaname = 'public'` returns 0 (or only non-BPM policies).
- [ ] `SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND column_name = 'tenant_id'` returns 0 for business tables.
- [ ] `SELECT count(*) FROM pg_proc WHERE proname = 'bpm_effective_tenant_id'` returns 0.
- [ ] Full regression suite passes on a schema-only database.
