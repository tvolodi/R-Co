# Module: spt-02 — Data Migration: Copy Rows into Tenant Schemas and Remove RLS

**Requirement ID:** SPT-02  
**Run ID:** WF02-spt-02  
**Stage:** Schema-Per-Tenant Migration — Data Migration Phase  
**Depends on:** SPT-01 (tenant_schemas registry, bpm_provision_tenant_schema(), search_path checkout)  
**Must precede:** SPT-03 (Zig code cleanup of tenant_id predicates)

---

## 1. Module Purpose

SPT-02 bridges the old row-based tenancy model (tenant_id columns + RLS policies) and the
target schema-per-tenant architecture. It consists of three SQL migrations that together
move all tenant data from the public schema into per-tenant schemas and then remove the
legacy isolation infrastructure from the public schema.

The three migrations are sequenced so that each is independently idempotent and each leaves
the system in a consistent state if the previous succeeded. Rollback to row-based tenancy
is possible before SPT-03 by reverting migrations 062 and 063 (re-adding columns, re-creating
policies, and re-enabling RLS). After SPT-03 is applied the Zig code no longer issues
WHERE tenant_id = $N predicates, making rollback structurally impossible and intentionally
dropped.

---

## 2. Affected Tables

All tables carrying `tenant_id NOT NULL` as of migration 060 baseline:

| Table | Source migration | Has RLS policy | Tenant scope |
|---|---|---|---|
| events | 027 | No | Row-level |
| events_archive | 027 | No | Row-level |
| process_definitions | 028 | Yes | Row-level |
| instance_projections | 028 | Yes | Row-level |
| tasks | 028 | Yes | Row-level |
| tokens | 028 | Yes | Row-level |
| audit_entries | 028 | Yes | Row-level |
| audit_log | 028 | Yes | Row-level |
| users | 029 | No | Identity binding |
| groups | 029 | No | Identity binding |

**Note on requirement list:** The SPT-02 requirement document names `process_instances`, `timers`,
and `sessions` as affected tables. The actual database table name for process instances is
`instance_projections` (created in migration 005). Inspection of migrations 007 and 008 shows
that `timers` and `sessions` were not given a `tenant_id` column in any migration. The design
therefore uses the actual table names derived from the migration history. BACKEND-DEV should
verify at implementation time by running:

```sql
SELECT table_name FROM information_schema.columns
WHERE column_name = 'tenant_id'
  AND table_schema = 'public'
ORDER BY table_name;
```

and use the query result as the authoritative affected-table list.

**tenant_hostnames note:** This table has a `tenant_id` column declared as a FK to `tenant(id)`,
not as an RLS-based isolation column. It does not have an RLS policy. Whether its rows should be
copied into tenant schemas depends on whether the hostname belongs to one tenant and should be
visible only within that tenant's schema. BACKEND-DEV must confirm with product ownership whether
tenant_hostnames rows are copied to tenant schemas or left in public schema with the FK intact.
This is flagged as an open question.

---

## 3. Public Interface

Three SQL migrations, each executed by the migration runner (src/db/migrations.zig) against the
public schema:

### Migration 061 — Copy rows to tenant schemas

```
migrations/061_spt02_copy_rows_to_tenant_schemas.sql
tests/integration/spt02_copy_rows_to_tenant_schemas_test.zig  (generated scaffold)
```

Schema change: adds `status TEXT NOT NULL DEFAULT 'pending'` to `tenant_schemas`.

Logic (executed as a PL/pgSQL DO block):

```
FOR EACH distinct tenant_id in UNION of all affected tables:
  IF NOT EXISTS in tenant_schemas:
    CALL bpm_provision_tenant_schema(tenant_id)
  IF tenant_schemas.status != 'active':
    BEGIN TRANSACTION
      FOR EACH affected table:
        INSERT INTO tenant_<schema>.<table>
          SELECT <non-tenant_id columns> FROM public.<table> WHERE tenant_id = <this>
          ON CONFLICT DO NOTHING
    SET tenant_schemas.status = 'active'
    COMMIT
```

### Migration 062 — Drop tenant_id columns, function, RLS, and indexes

```
migrations/062_spt02_drop_tenant_id_rls.sql
tests/integration/spt02_drop_tenant_id_rls_test.zig  (generated scaffold)
```

Executed as sequential DDL statements, each guarded with IF EXISTS.

### Migration 063 — Belt-and-suspenders idempotency cleanup

```
migrations/063_spt02_idempotency_cleanup.sql
tests/integration/spt02_idempotency_cleanup_test.zig  (generated scaffold)
```

Only DROP POLICY IF EXISTS statements; no structural DDL.

---

## 4. State Transitions

### tenant_schemas.status state machine

```
(not in table) ──bpm_provision_tenant_schema()──> 'pending'
     'pending' ──migration 061 copy completes──>  'active'
     'pending' ──migration 061 retry (ON CONFLICT DO NOTHING)──> 'pending' (until full)
      'active' ──migration 061 re-run──>           'active' (no-op; skipped)
```

### Database tenancy state machine

```
State A: public schema tables have tenant_id + RLS policies (SPT-01 baseline)
  │
  ├─ migration 061 ──> State B: both public and tenant schemas have data
  │                              tenant_schemas.status = 'active' per tenant
  │
  ├─ migration 062 ──> State C: only tenant schemas have data
  │                              public tables have no tenant_id column, no RLS
  │
  └─ migration 063 ──> State D: State C confirmed clean (all stale policies dropped)

Rollback path (only possible from State B or C, before SPT-03):
  State C ──re-add columns, re-create policies, re-enable RLS──> State A
  State B ──truncate tenant schemas, drop status column──> State A
```

---

## 5. Error Taxonomy

### E-061-DUP — Duplicate rows during copy

**Cause:** A row in the public schema has the same PK as a row already present in the tenant
schema (e.g. from a partial previous run or an external insert).  
**Handling:** `ON CONFLICT DO NOTHING` on every INSERT-SELECT silently skips the conflicting row.
The copy continues for remaining rows. After the loop completes, row counts in the tenant schema
may be lower than in the public schema for that table only if rows were already present — which
is correct for retry semantics.  
**Invariant:** A PK collision implies the row was already copied; skipping it is correct.

### E-061-SCHEMA-MISSING — bpm_provision_tenant_schema fails

**Cause:** The PL/pgSQL function encounters a lock conflict, schema name collision, or
INSERT conflict in tenant_schemas beyond the ON CONFLICT DO NOTHING guard.  
**Handling:** The DO block should catch this error and re-raise with context. The migration
runner surfaces the failure and halts. No partial state is committed for the failing tenant
(per-tenant transaction wraps all table copies).  
**Recovery:** Investigate pg_catalog.pg_namespace and tenant_schemas; run the migration again
after clearing the conflict.

### E-061-INTERRUPTED — Migration killed mid-copy

**Cause:** Database restart, OOM kill, or client disconnect during a per-tenant transaction.  
**Handling:** The per-tenant transaction is atomic: if the migration runner was killed before
`COMMIT`, the entire tenant's copy is rolled back. The `tenant_schemas.status` remains
`'pending'` (the UPDATE to `'active'` is inside the same transaction).  
**Recovery:** Re-run migration 061. The status = 'pending' guard causes the copy to retry.
`ON CONFLICT DO NOTHING` ensures any rows copied in the failed attempt are not duplicated.

### E-062-COLUMN-IN-USE — tenant_id column referenced by remaining objects

**Cause:** A view, generated column, or index not covered by the DROP INDEX list still
references `tenant_id` on an affected table, causing `DROP COLUMN` to fail.  
**Handling:** `DROP COLUMN IF EXISTS tenant_id CASCADE` (CASCADE is recommended) drops
dependent objects automatically. If cascade is not used, the migration fails with a
dependency error. BACKEND-DEV must decide whether CASCADE is appropriate.  
**Risk:** CASCADE on DROP COLUMN removes all dependent views and constraints silently. The
migration should enumerate known dependencies explicitly before resorting to CASCADE.

### E-062-FUNCTION-IN-USE — bpm_effective_tenant_id referenced by active RLS policies

**Cause:** RLS policies on tables other than the 6 known affected tables still reference
`bpm_effective_tenant_id()`, preventing `DROP FUNCTION ... CASCADE` from completing cleanly
or silently dropping additional dependent policies.  
**Handling:** `DROP FUNCTION IF EXISTS bpm_effective_tenant_id() CASCADE` drops all
dependent policies. BACKEND-DEV must confirm via `SELECT * FROM pg_depend` that no
unexpected objects depend on the function before applying migration 062.

### E-062-RLS-STILL-ACTIVE — Query against public table returns empty after column drop

**Cause:** RLS is still enabled on a table after the policy is dropped but before
`DISABLE ROW LEVEL SECURITY` is executed.  
**Handling:** With no policy in place and RLS enabled, PostgreSQL applies a default-deny:
no rows are visible. Migration 062 must execute `DISABLE ROW LEVEL SECURITY` immediately
after dropping each policy, within the same transaction.

### E-063-POLICY-NOT-FOUND — DROP POLICY IF EXISTS on non-existent policy

**Cause:** The policy was already dropped by migration 062.  
**Handling:** `IF EXISTS` suppresses the error. This is the expected case and is a no-op.

---

## 6. Rollback Strategy

### Before SPT-03 (reversible)

Rollback from State C (migration 062 applied) to State A:

1. Re-add `tenant_id UUID NOT NULL DEFAULT bpm_effective_tenant_id()` to each affected table.
2. Backfill `tenant_id` from the tenant schema name decoded from `current_schema()`.
3. Re-create all composite indexes with `CREATE INDEX IF NOT EXISTS ... (tenant_id, ...)`.
4. Re-create `bpm_effective_tenant_id()` from migration 028 source.
5. Re-enable RLS on each table and re-create all tenant policies.

Rollback from State B (migration 061 applied, 062 not) to State A:

1. Truncate all tenant schema tables for each registered tenant.
2. Drop the `status` column from `tenant_schemas`.

Rollback is a manual emergency procedure. It is not scripted as a down-migration. The recommended
approach is to re-run the SPT-01 migration set on a restored backup.

### After SPT-03 (irreversible)

Once SPT-03 removes `WHERE tenant_id = $N` predicates from all Zig source files, rolling back
requires reverting the Zig code as well as the SQL. This is structurally possible but requires
a coordinated Zig build + migration reversal. SPT-03 is the one-way door; rollback before
SPT-03 is straightforward.

---

## 7. Data Integrity Invariants

1. **No data loss:** Every row in every affected public table must be present in the
   corresponding tenant schema after migration 061 completes.

2. **No cross-tenant contamination:** Rows for tenant A must not appear in tenant B's schema.
   Each INSERT-SELECT is filtered by `WHERE tenant_id = <this_tenant>`.

3. **PK uniqueness in tenant schemas:** All affected tables have UUID PKs generated with
   `gen_random_uuid()`. Copying rows from public preserves the original PKs. No PK collision
   between tenants is possible since PKs are globally unique.

4. **FK consistency within tenant schemas:** FKs between tables (e.g. tokens → instance_projections,
   timers → instance_projections) must be satisfied within the tenant schema copy. Tables must
   be copied in FK dependency order to avoid FK constraint violations during INSERT-SELECT.
   Recommended copy order: instance_projections → tokens → tasks → timers → events → audit_log
   → audit_entries → process_definitions → users → groups.

5. **Atomic per-tenant copy:** All tables for a single tenant are copied in one transaction.
   Either all succeed or none are visible. `tenant_schemas.status = 'active'` is committed only
   on full success.

6. **Idempotency:** Running all three migrations on an already-migrated database produces no
   error and no state change. Verified by the migration test suite.

---

## 8. Dependencies

### Depends on (must already be applied)
- Migration 060 (`public.tenant_schemas`, `bpm_provision_tenant_schema()`, `runForSchema()`)
- Migrations 001–059 (all public schema tables exist)

### Must not depend on
- Any Zig runtime code (migrations run as pure SQL via the migration runner)
- SPT-03 (SPT-02 must run before SPT-03)

### Required Zig modules (integration tests only)
- `src/db/migrations.zig` — `runForSchema()` and migration runner helpers
- `tests/integration/helpers.zig` — TestHarness, applyMigration helper

---

## 9. Acceptance Criteria Mapping

| SPT-02 Acceptance Criterion | Design Element |
|---|---|
| AC-1: N tenants in public → N rows in tenant_schemas + N schemas in pg_namespace | Migration 061 DO block: per-distinct-tenant_id provisioning + status tracking |
| AC-2: Each tenant schema's tables contain exactly the rows that belonged to that tenant in public | Migration 061 INSERT-SELECT with WHERE tenant_id = filter; PK preservation |
| AC-3: After migration 062, no tenant_id column, no bpm_effective_tenant_id(), no RLS policies, no tenant_id indexes on public tables | Migration 062 DROP COLUMN/DROP FUNCTION/DROP POLICY/DROP INDEX with IF EXISTS guards |
| AC-4: After migration 063, DROP POLICY IF EXISTS executes for every previously known policy | Migration 063 explicit DROP POLICY IF EXISTS list covering all 6 known policies |
| AC-5: Re-running 061–063 on already-applied DB raises no error and leaves state unchanged | Migration 061: status='active' guard; 062/063: IF EXISTS guards throughout |
| AC-6: Interrupted copy detected via tenant_schemas.status; retry copies missing rows without duplication | Migration 061: ON CONFLICT DO NOTHING semantics + per-tenant transaction atomic commit |

---

## 10. Open Questions

1. **tenant_hostnames scope:** Should `tenant_hostnames` rows be copied into each tenant's
   schema? The table has `tenant_id` as a FK to `tenant(id)`, not as an RLS isolation column.
   If hostnames are global configuration (one per tenant, visible to the platform) they stay
   in public. If they are per-tenant data they should be copied.
   — *Recommend: leave in public; tenant_hostnames is platform-level routing config, not
   tenant business data.*

2. **users / groups scope:** The `users` and `groups` tables have `tenant_id` (from migration 029)
   but no RLS policies and are not in the requirement's explicit list. Should they be copied to
   tenant schemas or should tenant_id be dropped from them without copying?
   — *Recommend: copy to tenant schemas — users and groups are per-tenant data (confirmed by
   ADP-04 tenant binding requirements). BACKEND-DEV should verify.*

3. **Copy order and FK constraints:** Tenant schema FK constraints may prevent copy if child
   rows are inserted before parent rows. BACKEND-DEV must enumerate FK graph and insert in
   topological order, OR temporarily DISABLE TRIGGER ALL during copy.

4. **Table name discrepancy:** The SPT-02 requirement document lists `process_instances`,
   `timers`, and `sessions` as affected tables. The actual DB table for instances is
   `instance_projections`. `timers` and `sessions` do not have tenant_id columns as of
   migration 060. BACKEND-DEV should confirm at implementation time via `information_schema.columns`
   and raise a WF-03 if the requirements doc needs updating.
