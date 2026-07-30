# ISS-0076 Fix Design — `secrets` table never created (GBL-100 guard defect)

**Requirement:** EXP-501
**GitHub issue:** https://github.com/tvolodi/R-Co/issues/335
**Severity:** MAJOR

## Root cause (confirmed against running `bpm_dev` and `bpm_test` databases)

`migrations/GBL-100_exp501_secrets.sql` guards its body with:

```sql
v_proj_oid := to_regclass('instance_projections');
IF v_proj_oid IS NULL THEN
    RETURN;
END IF;
```

The migration runner (`src/db/migrations.zig`, ~line 197–207) applies every
`GBL-`-prefixed migration **only against the `public` schema** — it explicitly
skips `GBL-` files for all tenant schemas:

```zig
if (!std.mem.eql(u8, schema_name, "public") and
    std.mem.startsWith(u8, filename, "GBL-"))
{
    continue;
}
```

`GBL-073_tnt01_drop_legacy_public_business_tables.sql` permanently dropped
`instance_projections` (and `event_type_registry`, `webhook_subscriptions`,
etc.) from `public` as part of the TNT-01 schema-per-tenant migration. Those
tables now live only inside per-tenant schemas (`tenant_default`,
`tenant_<uuid>`, ...).

Consequence: when GBL-100 runs (against `public`, its only execution
context), `to_regclass('instance_projections')` **always** returns `NULL`,
the guard **always** fires, and the migration body — including
`CREATE TABLE secrets` — never executes, in any environment. This is not an
ambient-`search_path` edge case; the guard checks a table that structurally
cannot exist in the only schema this migration ever runs against.

Verified empirically: neither `bpm_dev` nor `bpm_test` has a `secrets` table
in any schema, while `schema_migrations` records `GBL-100_exp501_secrets.sql`
as applied.

## Fix

`secrets` is a **global table** per its own header comment ("tenant-scoped
rows" stored in one shared table, not "tenant-scoped table" — compare to how
`onboarding_registry` / `tenant_schemas` work). It has no dependency on
`instance_projections` and does not need a prerequisite guard at all — it is
new, self-contained DDL that only needs to run once against `public`.

1. **Remove the incorrect guard** in `migrations/GBL-100_exp501_secrets.sql`:
   drop the `to_regclass('instance_projections')` check entirely. The table
   creation (`CREATE TABLE IF NOT EXISTS secrets`, its indexes) is already
   idempotent and belongs unconditionally in `public`.

2. **Keep the `webhook_subscriptions` backfill guarded**, because
   `webhook_subscriptions` genuinely does not exist in `public` (dropped by
   GBL-073, lives only per-tenant) — that part of the file must remain
   conditional, but should guard on `webhook_subscriptions` directly (the
   table it actually touches), not on the unrelated `instance_projections`.
   Since GBL migrations never run against tenant schemas, this guard will
   also always no-op under the current runner — which is *correct*, because
   GBL-100 (public-only) is structurally the wrong place to backfill a
   per-tenant table. That backfill is dead code today and was never reached
   even before this fix (same defect, harmless because the table it backfills
   doesn't exist in `public` either — no error, just permanently skipped).
   Leave a comment explaining this so a future reader does not "fix" the
   guard again without noticing the GBL/public-only constraint.

3. **Corrective re-run:** because `schema_migrations` already marks
   `GBL-100_exp501_secrets.sql` as applied, editing the file in place will
   NOT cause it to re-run via `zig build migrate`. Add a new corrective
   migration `GBL-101_exp501_secrets_corrective.sql` that:
   - Creates `secrets` (identical DDL, `CREATE TABLE IF NOT EXISTS`, so it is
     harmless if GBL-100 is ever fixed forward and re-applied from scratch
     in a fresh environment)
   - Creates the same two indexes (`IF NOT EXISTS`)
   - No guard needed (unconditional, idempotent, public-only global table)

4. **Documentation cross-reference:** `docs/anti-patterns.md` already has an
   entry (line 48) referencing this issue and GitHub #335. Add a one-line
   comment at the top of `migrations/GBL-100_exp501_secrets.sql` and the new
   `GBL-101` file pointing back to that anti-patterns entry.

## Acceptance criteria mapping

| AC | Design element |
|---|---|
| Guard checks table existence against correct schema / doesn't rely on ambient search_path | GBL-100's guard is removed entirely (it was checking the wrong table for a public-only migration); GBL-101 is unconditional |
| Corrective migration actually creates `secrets` table | `GBL-101_exp501_secrets_corrective.sql` |
| Test/manual verification confirms `secrets` exists post-migration in multi-schema DB | BACKEND-DEV runs `zig build migrate` against `bpm_test` (which has `tenant_default` provisioned) and queries `pg_tables` |
| anti-patterns.md cross-referenced from the migration file | Comment added to both GBL-100 and GBL-101 |

## Files to change

- `migrations/GBL-100_exp501_secrets.sql` — remove incorrect guard, fix webhook guard, add anti-pattern comment reference
- `migrations/GBL-101_exp501_secrets_corrective.sql` — new corrective migration (create `secrets` table unconditionally)

No Zig source changes required — `src/secrets/*` already assumes the table exists per #289/ISS-0074.
