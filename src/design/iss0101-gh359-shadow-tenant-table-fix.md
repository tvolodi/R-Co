# ISS-0101 / GH-359 — Shadow Tenant Table Fix Design

**Type:** E (remediation migration + existing-file scope header patch)
**Issue:** ISS-0101 (shadow `tenant_default.tenant` + `tenant_default.tenant_hostnames`)
**GitHub:** https://github.com/tvolodi/R-Co/issues/359
**Migration:** GBL-140 (next after GBL-139)
**Scope of changes:**
- `migrations/GBL-140_iss0101_drop_shadow_tenant_tables.sql` (new)
- `migrations/031_adp04b_tenant_realm_binding.sql` (add `-- scope: public` header)

---

## Module purpose

`migrations/031_adp04b_tenant_realm_binding.sql` has no `-- scope: public` header.
The migration runner's `migrationScope()` function (src/db/migrations.zig line 611)
defaults to `all_schemas` when no scope header is found, so 031's
`CREATE TABLE IF NOT EXISTS tenant (...)` runs once for the `public` pass and once
for the `tenant_default` pass (and once for every per-tenant pass). The result is a
shadow `tenant_default.tenant` table that:
- lacks the `tenant_type` and `production_tenant_id` columns added by later GBL-only
  migrations (GBL-080 and descendants), causing schema drift;
- has a dependent `tenant_default.tenant_hostnames` table (FK:
  `tenant_hostnames.tenant_id → tenant_default.tenant.id`) created by 050_tenant_hostnames.sql
  for the same reason.

GBL-134 through GBL-139 have incrementally cleaned up these and other shadow tables.
The shadow `tenant` and `tenant_hostnames` pair in `tenant_default` were correctly
removed by GBL-139 (which looped all tenant schemas and dropped them). However, an
accidental `DROP SCHEMA tenant_default CASCADE` + replay during WF03-GH566-20260808
(2026-08-08 08:19Z) re-ran all 75 migrations including 031 against `tenant_default`,
resurrecting both shadows. GBL-140 removes them again; adding `-- scope: public` to 031
prevents every future reprovision from recreating them.

---

## Public interface

No new public Zig functions, types, or HTTP endpoints. This is a pure database
remediation and scope-header patch.

**Migration runner interaction (read-only — no API changes):**

```
migrationScope("031_adp04b_tenant_realm_binding.sql", header) → .public_only
                                                                  (after scope header added)
```

The `migrations.zig` `apply()` function's tenant-schema loop reads the first 4096 bytes
of each migration file and calls `migrationScope()`. When the result is `.public_only`,
the file is skipped with `continue` for that tenant-schema iteration. Adding
`-- scope: public` at line 1 of 031 is sufficient and requires no Zig changes.

---

## Data flow diagram

```
BEFORE GBL-140
  tenant_default schema
    ├─ tenant_hostnames  (FK → tenant_default.tenant.id)   ← shadow
    └─ tenant            (missing tenant_type, production_tenant_id) ← shadow

GBL-140 DROP sequence
  Step 1: check tenant_default.tenant_hostnames EXISTS → true
          DROP TABLE tenant_default.tenant_hostnames RESTRICT  ← FK child first
  Step 2: check tenant_default.tenant EXISTS → true
          DROP TABLE tenant_default.tenant RESTRICT           ← FK parent safe now

AFTER GBL-140
  tenant_default schema
    (no tenant_hostnames shadow)
    (no tenant shadow)

031 scope header addition
  migrationScope("031...", header) → .all_schemas   (BEFORE)
  migrationScope("031...", header) → .public_only   (AFTER)

Future tenant reprovision (DROP+replay 001..Nnn)
  031 runs:  public pass → creates/upserts public.tenant   ✓
             tenant_default pass → scope=public_only → SKIP ✓
```

---

## Migration GBL-140 — exact SQL design

**Filename:** `migrations/GBL-140_iss0101_drop_shadow_tenant_tables.sql`

The migration uses a targeted PL/pgSQL `DO $$ ... $$` block. Unlike GBL-134..139
which looped all tenant schemas, GBL-140 targets only `tenant_default` because:
1. All other tenant schemas have already had `tenant` and `tenant_hostnames` cleaned up
   by GBL-134/135/136/139.
2. The shadow re-appeared ONLY in `tenant_default` via the accidental replay event.
3. Narrowing the scope reduces blast radius if run against a database where a real tenant
   schema has a legitimate `tenant` or `tenant_hostnames` table (none known; this is
   defensive).

**Ordering requirement (FK safety):**

```
tenant_default.tenant_hostnames  →  tenant_default.tenant   (FK child → FK parent)
```

`tenant_hostnames.tenant_id` has a FK to `tenant_default.tenant.id`. Therefore:
- DROP `tenant_hostnames` FIRST (removes the FK reference).
- DROP `tenant` SECOND (no remaining FK dependents).

Reversing the order causes `DROP TABLE tenant_default.tenant RESTRICT` to fail with
`ERROR: cannot drop table tenant because other objects depend on it`.

**Idempotency guards:**

Both DROPs are wrapped in existence checks against `information_schema.tables`. A
second run (or run against a database where shadows are already gone) is a no-op.
Additionally, each DROP uses `RESTRICT` (not `CASCADE`) so an unexpected FK dependent
causes an exception that is caught and reported rather than silently wiping dependents.

**GBL convention:** The file carries `-- scope: public` because GBL- migrations always
run public-only (the GBL prefix alone is sufficient per `migrationScope()`, but the
explicit header is added for clarity per the established GBL-138/139 convention).

```sql
-- scope: public
-- GBL-140: ISS-0101 / GH-359 — drop tenant_default shadow tenant tables.
-- FK ordering: tenant_hostnames (FK child) first, then tenant (FK parent).
-- All DROPs use RESTRICT + existence guard; scoped to tenant_default only.
DO $$
DECLARE
    v_hostnames_exists BOOLEAN;
    v_tenant_exists    BOOLEAN;
    v_dropped          INT := 0;
BEGIN
    -- Step 1: DROP tenant_default.tenant_hostnames (FK child — must go first).
    SELECT EXISTS (SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'tenant_default' AND table_name = 'tenant_hostnames'
    ) INTO v_hostnames_exists;
    IF v_hostnames_exists THEN
        BEGIN
            DROP TABLE tenant_default.tenant_hostnames RESTRICT;
            v_dropped := v_dropped + 1;
        EXCEPTION WHEN dependent_objects_still_exist THEN
            RAISE NOTICE 'GBL-140: SKIP tenant_default.tenant_hostnames — unexpected FK dependent.';
        END;
    END IF;
    -- Step 2: DROP tenant_default.tenant (FK parent — safe after step 1).
    SELECT EXISTS (SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'tenant_default' AND table_name = 'tenant'
    ) INTO v_tenant_exists;
    IF v_tenant_exists THEN
        BEGIN
            DROP TABLE tenant_default.tenant RESTRICT;
            v_dropped := v_dropped + 1;
        EXCEPTION WHEN dependent_objects_still_exist THEN
            RAISE NOTICE 'GBL-140: SKIP tenant_default.tenant — unexpected FK dependent.';
        END;
    END IF;
    RAISE NOTICE 'GBL-140: % shadow(s) dropped from tenant_default.', v_dropped;
END $$;
```

---

## Scope header patch for 031

**File:** `migrations/031_adp04b_tenant_realm_binding.sql`
**Change:** Insert `-- scope: public` as the first non-empty line (before line 1 comment).

**Before (current lines 1–3):**
```sql
-- 031_adp04b_tenant_realm_binding.sql
-- ADP-04b: tenant realm binding for OIDC tenant isolation.

CREATE TABLE IF NOT EXISTS tenant (
```

**After:**
```sql
-- scope: public
-- 031_adp04b_tenant_realm_binding.sql
-- ADP-04b: tenant realm binding for OIDC tenant isolation.

CREATE TABLE IF NOT EXISTS tenant (
```

The `migrations.zig` scope reader probes the first 4096 bytes. Inserting `-- scope: public`
at position 0 satisfies `std.mem.indexOf(u8, header, "-- scope: public") != null` at line 628
of `src/db/migrations.zig`.

**Why 031 specifically:** 031 contains:
```sql
CREATE TABLE IF NOT EXISTS tenant (...)   -- creates shadow in every tenant pass
...
CREATE TABLE IF NOT EXISTS tenant_hostnames (...)   -- NOT in 031 — this is in 050
```

Actually 031 only creates `tenant`. The `tenant_hostnames` shadow arises because
`050_tenant_hostnames.sql` also lacks a `-- scope: public` header. However:
- The primary D1 defect documented in ISS-0101 focuses on 031 as the root-cause file.
- `050_tenant_hostnames.sql` scope fix is a separate concern (ISS-0101 D1 mentions
  `tenant_hostnames` as a FK-dependent shadow of `tenant`, not as an independent root cause).
- BACKEND-DEV should verify whether `050_tenant_hostnames.sql` also lacks a scope header
  and, if so, add `-- scope: public` there as well in the same commit (defensive fix).

---

## Error taxonomy

| Error condition | Source | Handling |
|---|---|---|
| `dependent_objects_still_exist` | DROP TABLE ... RESTRICT with live FK dependent | Caught per-table; RAISE NOTICE; migration continues; manual review flagged |
| `tenant_hostnames` already absent | `v_hostnames_exists = false` | No-op path with NOTICE; not an error |
| `tenant` already absent | `v_tenant_exists = false` | No-op path with NOTICE; not an error |
| `tenant_hostnames` DROP fails but `tenant` DROP succeeds | Can't happen: hostnames is the FK child; if it stays, tenant's DROP will also fail | Both catch blocks handle independently |
| `tenant` DROP fails while `tenant_hostnames` was dropped | Unexpected FK dependent on `tenant` other than `tenant_hostnames` | Caught; NOTICE; manual review |

**No migration error type is returned from this migration.** `zig build migrate`
exit code is 0 in all designed cases; RESTRICT failures are caught and logged as
NOTICE, not re-raised, consistent with the GBL-136/138/139 pattern.

---

## Dependencies

| Module | Relationship | Constraint |
|---|---|---|
| `src/db/migrations.zig` | Applies GBL-140 to public schema only (GBL prefix + scope header) | No Zig changes needed |
| `migrations/031_adp04b_tenant_realm_binding.sql` | Patched: `-- scope: public` header added | Existing SQL is unchanged except the new first line |
| `migrations/050_tenant_hostnames.sql` | May need same `-- scope: public` patch (BACKEND-DEV to verify) | No schema changes |
| GBL-134..139 | Establish the shadow-cleanup lineage; GBL-140 extends it | GBL-134..139 are immutable per convention |

---

## Acceptance criteria

1. After `zig build migrate` with GBL-140 applied: `SELECT table_schema, table_name FROM information_schema.tables WHERE table_name IN ('tenant','tenant_hostnames') AND table_schema = 'tenant_default'` returns zero rows.
2. `SELECT table_schema, table_name FROM information_schema.tables WHERE table_name IN ('tenant','tenant_hostnames') AND table_schema = 'public'` still returns two rows (public copies untouched).
3. `zig build migrate` exits 0 on a warm db_test (GBL-140 already applied).
4. A fresh `DROP SCHEMA tenant_default CASCADE` + `zig build migrate` replay does NOT recreate `tenant_default.tenant` or `tenant_default.tenant_hostnames` (scope header in 031 prevents it).
5. `zig build test` exits 0 (unit tests unaffected).

---

## Open questions

None. Root cause, FK ordering, and idempotency are fully characterized by ISS-0101 Step 1 diagnosis.

---

## As-implemented addendum (2026-08-09, Step 5 verification)

Implementation matched this design with two additions discovered during BACKEND-DEV/Step 5:

1. **`public.`-qualification was required, not optional.** Adding `-- scope: public`
   alone would have tripped `src/db/migrations.zig`'s ISS-0604/GH-470
   `MigrationScopeMismatch` guard: `declaresUnqualifiedTableWork()` scans the file body
   for unqualified `CREATE TABLE`/`ALTER TABLE`/`INSERT INTO` heads, and both 031 and
   050 contain several (031: `CREATE TABLE`, 6x `ALTER TABLE`, 1x `INSERT INTO`; 050:
   `CREATE TABLE`). Every one was schema-qualified as `public.tenant` /
   `public.tenant_hostnames` in the same commit as the header. This is a **mandatory**
   companion change whenever `-- scope: public` is added to a file with unqualified DDL,
   not a style preference — omitting it makes `zig build migrate` fail outright on the
   very next apply with `MigrationError.MigrationScopeMismatch`.
2. **`050_tenant_hostnames.sql` also received the scope header + qualification** (the
   design's open question at the time was resolved: yes, it needed the same fix, for the
   same reason — its FK to `tenant(id)` only makes sense if it lives in `public` too).
3. **`tools/clean_test_db.py` required an independent fix** to make the live cold-start
   reproduction (Step 5's D2 re-verification) possible at all: `drop_orphaned_tenant_
   schemas()` unconditionally queried `public.tenant_schemas`, which does not exist on a
   genuinely empty database. Not part of the original design (D2 was believed resolved
   via ISS-0603 alone) — discovered live while reproducing the destructive cold-start
   scenario per the issue's own Step 5 requirement. See CHANGELOG.md and
   `docs/issues/ISS-0101.json` `resolution` field for full detail.
4. **`tests/integration/iss0185_dual_schema_test.zig` required updating** — it hard-coded
   `tenant`/`tenant_hostnames` as HYBRID (present in both schemas) and asserted an exact
   dual-schema duplicate count of 9. Both are now stale given this fix; updated to
   GLOBAL_REGISTRY classification and a floor-based count assertion (see the test file's
   own header comment and CHANGELOG.md for why an exact count is no longer appropriate —
   unrelated to the ISS-0641 finding filed alongside this fix).
