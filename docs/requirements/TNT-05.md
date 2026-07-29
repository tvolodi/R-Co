---
id: TNT-05
title: Backfill migration moves existing tenant data out of public schema
stage: 12
status: RELEASED
priority: MUST
status: RELEASED
---

# TNT-05 — Backfill migration moves existing tenant data out of public schema `[MUST]`

> A one-time backfill migration SHALL copy all rows belonging to each tenant
> from the business tables in `public` into the corresponding tables in
> `tenant_<uuid>`, verify row counts, and then remove those rows from `public`.
> The migration SHALL be idempotent and safe to re-run. It SHALL not cause
> downtime: writes to `public` business tables continue during the migration
> window and are drained before the final cutover.

**Acceptance Criteria:**
- GIVEN the backfill migration runs for tenant T, WHEN it completes, THEN:
  - `SELECT count(*) FROM tenant_<T_uuid>.<table>` equals the count of rows
    that were in `public.<table> WHERE tenant_id = T_uuid` before the migration.
  - `SELECT count(*) FROM public.<table> WHERE tenant_id = T_uuid` equals 0.
  - The result is the same for every business table listed in TNT-01.
- GIVEN the backfill migration is interrupted mid-run, WHEN it is re-run, THEN
  it resumes without duplicating rows (idempotency via `ON CONFLICT DO NOTHING`
  on insert into the tenant schema).
- GIVEN a tenant has zero rows in `public` (newly provisioned tenant), WHEN the
  backfill runs for that tenant, THEN it completes successfully with no-ops.
- GIVEN the backfill completes for all tenants, THEN the business table
  `tenant_id` column constraints and RLS policies added by migrations 027/028
  are dropped in a subsequent cleanup migration.
- The migration is executed per-tenant sequentially; it does not lock the entire
  `public` table for the duration (uses row-level locks and batched copies).
- A migration-window flag is set in `public.onboarding_registry` (or a
  dedicated `public.migration_windows` table) at the start and cleared at
  completion; the TNT-04 schema audit uses this flag to downgrade ERROR to
  WARNING during the window.
- The backfill migration records per-tenant progress in a `public.tnt05_progress`
  table so that partial runs can be inspected and resumed.

**See:** TNT-01 (target state), TNT-02 (migration runner), TNT-03 (search_path),
TNT-04 (public schema audit), DB-03 (transactional integrity during copy)

**Edge cases:**
- A row in `public.<table>` with `tenant_id = 00000000-0000-0000-0000-000000000000`
  (default tenant): copied to `tenant_default.<table>`.
- A row with a `tenant_id` that does not exist in `public.tenant`: logged as
  an orphan; not migrated; written to a `public.tnt05_orphans` table for manual
  review.
- Foreign key relationships between business tables (e.g. `tasks` references
  `instance_projections`): migration copies tables in dependency order
  (instances before tasks, definitions before instances).
- Very large tenants (millions of rows): migration uses batched inserts of
  10,000 rows per transaction to limit lock duration and WAL pressure.
