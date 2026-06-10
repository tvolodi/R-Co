---
id: TNT-07
title: Remove RLS policies and tenant_id columns from public business tables
stage: 12
status: RELEASED
priority: MUST
status: DRAFT
---

# TNT-07 — Remove RLS policies and tenant_id columns from public business tables `[MUST]`

> Once TNT-05 backfill is confirmed complete for all tenants, the Row Level
> Security policies, RLS enablement, and `tenant_id` columns added by
> migrations 027 and 028 to business tables in `public` SHALL be removed.
> Schema isolation (TNT-01 through TNT-03) replaces RLS as the tenant
> separation mechanism. The `bpm_effective_tenant_id()` function SHALL also
> be dropped.

**Acceptance Criteria:**
- GIVEN TNT-05 is complete and all tenant data is confirmed in tenant schemas,
  WHEN this migration runs, THEN:
  - `ALTER TABLE public.<table> DISABLE ROW LEVEL SECURITY` succeeds for each
    business table that had RLS enabled.
  - `DROP POLICY <policy> ON public.<table>` succeeds for each policy created
    by migration 028.
  - `ALTER TABLE public.<table> DROP COLUMN IF EXISTS tenant_id` succeeds for
    each business table that had the column.
  - `DROP FUNCTION IF EXISTS public.bpm_effective_tenant_id()` succeeds.
- GIVEN this migration is applied and a query is issued directly against
  `public.events` without a `tenant_id` filter, THEN it returns zero rows
  (because no business data remains in `public` after TNT-05).
- GIVEN this migration is applied, WHEN `zig build test` is run, THEN all
  integration tests pass (no test relies on RLS filtering in `public`).
- This migration is gated: it MUST NOT run until a pre-flight check confirms
  that every known `tenant_id` in `public.tenant` has a corresponding row in
  `public.tenant_schemas` with `migrations_applied_at IS NOT NULL`, and
  `public.tnt05_progress` shows all tenants at status `COMPLETED`.
- The migration is idempotent: running it twice produces no error.

**See:** TNT-05 (backfill must complete first), TNT-01 (target architecture),
TNT-04 (public schema permitted table list enforced after this migration)

**Edge cases:**
- A business table in `public` that never had RLS enabled (added after migration
  028): the `DISABLE ROW LEVEL SECURITY` and `DROP POLICY` steps are no-ops;
  `DROP COLUMN tenant_id` still applies if the column exists.
- Pre-flight check fails for one tenant (e.g. provisioning failed): migration
  aborts with an error listing the unready tenants; no DDL changes are made.
- `bpm_effective_tenant_id()` referenced by a trigger or view that was not
  cleaned up: `DROP FUNCTION` fails with a dependency error; the migration
  aborts and lists the dependent objects for manual cleanup.
