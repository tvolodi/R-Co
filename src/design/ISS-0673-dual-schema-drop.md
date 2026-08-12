# ISS-0673 — Dual-Schema Shadow Drop Design

**Type:** E (novel / cross-cutting cleanup + source-migration patch)
**Run:** WF03-GH714-20260812 (REWORK 1/3)
**GitHub issue:** https://github.com/tvolodi/R-Co/issues/714
**Status:** DESIGN — pending CODE-DESIGN-VALIDATOR (rework)

---

## 1. Module purpose

ISS-0673 is a BLOCKER recurrence of the ISS-0185/ISS-0641 shadow-table family: four
ORD/PAR batch migrations (1145, 1146, 1148, 1149) were written and applied after
GBL-141 closed the previous 14 instances, but replicated the same unguarded
`CREATE TABLE IF NOT EXISTS` pattern. The migration runner
(`migrations.zig migrationScope()`, default `.all_schemas`) replays every such
migration in every schema pass (public → tenant_default → per-tenant schemas),
creating duplicate tables in schemas where they do not belong. The linter
`tools/lint_dual_schema_table_names.py` reports 8 BLOCKER duplicates.

This design covers two changes:

1. **GBL-142**: a corrective DROP migration that removes the 8 stray shadow copies
   from `public`, following the GBL-141 Step 1 pattern (PER_TENANT tables accidentally
   created in public during the public schema pass).
2. **Source-migration patches** (1145, 1146, 1148, 1149): DO $$ early-return guards
   that permanently close the shadow-creation path on cold-start, matching the
   1147 (`PAR-01`) pattern exactly.

**Classification authority:** ORCH OQ-1 resolution (2026-08-12). All 8 tables are
PER_TENANT. Canonical home = tenant_default. Stray copies are in `public`. This is the
**opposite** direction from GBL-134/136 (which fixed GLOBAL_REGISTRY tables accidentally
in tenant schemas); GBL-142 fixes PER_TENANT tables accidentally in `public`.

---

## 2. Table classification

**All 8 tables: PER_TENANT** (ORCH OQ-1 resolution, 2026-08-12)

Canonical home = `tenant_default`. Stray shadow copies are in `public` (created during
the `public` schema pass by unguarded top-level DDL in each source migration).

| Table | Source migration | Stray copy location |
|---|---|---|
| `plat_effect_completion` | 1145 | `public` |
| `plat_correlation_cursor` | 1146 | `public` |
| `plat_partition_catalog` | 1148 | `public` |
| `plat_partition_maintenance_run_log` | 1148 | `public` |
| `events_ephemeral` | 1149 | `public` |
| `events_ephemeral_2026_08` | 1149 | `public` (range partition) |
| `events_ephemeral_2026_09` | 1149 | `public` (range partition) |
| `events_ephemeral_2026_10` | 1149 | `public` (range partition) |

**Action for GBL-142:** drop `public.<name>` for all 8. Pattern: GBL-141 Step 1.

**Classification note for plat_* tables:** The ORCH OQ-1 resolution overrides the
initial code-designer classification (which marked plat_* as GLOBAL_REGISTRY based on
absence of `tenant_id` columns). ORCH confirmed these are PER_TENANT in the platform's
schema-per-tenant model: each tenant's schema carries its own copy of these sidecar
tables. The unguarded source migrations created spurious copies in `public` that must
be removed, not the tenant-schema copies.

---

## 3. Public interface — none

GBL-142 is a one-shot corrective migration. No new Zig functions, TypeScript interfaces,
or API endpoints are added.

---

## 4. Data flow

```
lint_dual_schema_table_names.py
    ↓ detects 8 duplicates (BLOCKER)

GBL-142 (corrective cleanup, runs once in public schema)
    Single DO block — DROP public.<name> RESTRICT for all 8 tables
    (children events_ephemeral_2026_08/09/10 before parent events_ephemeral;
     plat_* tables in any order)
    Canonical-home guard: only drops if table ALSO exists in tenant_default
    ↓

Source-migration patches (1145/1146/1148/1149)
    DO $$ early-return guard: IF current_schema() = 'public' THEN RETURN; END IF;
    Closes the public-copy creation path on cold-start
    ↓

lint_dual_schema_table_names.py → 0 duplicates (PASS)
```

---

## 5. CHANGE 1 — New migration: `migrations/GBL-142_iss0673_drop_dual_schema_shadows.sql`

### Exact SQL

```sql
-- GBL-142: ISS-0673 / GH-714 — drop the 8 dual-schema shadow tables from
-- public, reported by tools/lint_dual_schema_table_names.py after the ORD/PAR
-- batch (1145/1146/1148/1149) was applied.
--
-- All 8 tables are PER_TENANT (canonical home = tenant_default). Their stray
-- copies in public were created by unguarded top-level CREATE TABLE DDL running
-- during the public schema pass. ORCH OQ-1 resolution, 2026-08-12.
--
-- This is the OPPOSITE direction from GBL-134/136 (which dropped GLOBAL_REGISTRY
-- tenant_schema shadows). GBL-142 drops PER_TENANT public shadows — same
-- direction and pattern as GBL-141 Step 1.
--
-- Partition ordering (events_ephemeral*): monthly partition tables are listed
-- before their parent so each RESTRICT drop succeeds sequentially (PostgreSQL
-- RESTRICT refuses to drop a partitioned parent while children are attached;
-- dropping each child first implicitly detaches it, then the parent drop
-- succeeds without CASCADE).
--
-- Safety properties (identical to GBL-141 Step 1):
--   1. Only drops if the table ALSO exists in tenant_default (its canonical
--      home). A public-only occurrence is not a shadow — leave it alone.
--   2. RESTRICT only, never CASCADE. Per-table EXCEPTION WHEN
--      dependent_objects_still_exist: unexpected FK dependents are logged and
--      skipped; the loop continues.
--   3. Not data-destructive on the canonical side: tenant_default copies are
--      never touched.
--   4. current_schema() guard: defensive belt-and-suspenders; since GBL-
--      migrations run in public by convention, this ensures a re-entry from
--      an unexpected schema context is a no-op.

DO $$
DECLARE
    v_table      TEXT;
    v_exists_pub BOOLEAN;
    v_exists_ten BOOLEAN;
    v_dropped    INT := 0;
    v_skipped    INT := 0;
    -- 8 PER_TENANT tables whose public copies are stray shadows.
    -- Partition children listed before their parent (see header).
    v_tables TEXT[] := ARRAY[
        'events_ephemeral_2026_08',
        'events_ephemeral_2026_09',
        'events_ephemeral_2026_10',
        'events_ephemeral',
        'plat_effect_completion',
        'plat_correlation_cursor',
        'plat_partition_catalog',
        'plat_partition_maintenance_run_log'
    ];
BEGIN
    IF current_schema() != 'public' THEN
        RAISE NOTICE 'GBL-142: not in public schema — skipping (defensive guard).';
        RETURN;
    END IF;

    FOREACH v_table IN ARRAY v_tables LOOP
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = v_table
        ) INTO v_exists_pub;
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'tenant_default' AND table_name = v_table
        ) INTO v_exists_ten;

        -- Defense: only drop if the table also exists in tenant_default
        -- (its canonical home) — a public-only occurrence is not a shadow.
        IF v_exists_pub AND v_exists_ten THEN
            BEGIN
                EXECUTE format('DROP TABLE public.%I RESTRICT', v_table);
                v_dropped := v_dropped + 1;
                RAISE NOTICE 'GBL-142: dropped public.% (stray per-tenant shadow).', v_table;
            EXCEPTION WHEN dependent_objects_still_exist THEN
                v_skipped := v_skipped + 1;
                RAISE NOTICE 'GBL-142: skipped public.% — unexpected FK dependent.', v_table;
            END;
        END IF;
    END LOOP;

    RAISE NOTICE 'GBL-142: dropped % and skipped % stray per-tenant shadow(s) from public.',
        v_dropped, v_skipped;
END $$;
```

### Notes on scope handling

GBL-142 uses no `-- scope: public` header; it relies on the DO block's own
`current_schema() != 'public'` guard (defensive) and the explicit `public.%I`
schema qualification in every EXECUTE. This is consistent with GBL-141, which
also uses no scope header and instead guards via explicit schema qualification.

GBL-142 does **not** need a `public.tenant` loop because all drops target
`public.<name>` directly, not per-tenant schemas.

---

## 6. CHANGE 2 — Source-migration patches (prevent recurrence on cold-start)

**Pattern for all patches:** match the DO $$ early-return guard used in
`1147_par01_events_partitioning.sql`:

```
DO $$
BEGIN
    IF current_schema() = 'public' THEN
        RAISE NOTICE '<context>: public schema pass — skipping <table> (PER_TENANT; see GBL-142).';
        RETURN;
    END IF;
    -- ... original DDL unchanged
END $$;
```

**Why DO $$ and NOT `-- scope: public`:** `-- scope: public` would restrict the migration
to run only during the public schema pass — correct for GLOBAL_REGISTRY tables (canonical
home = public) but WRONG for PER_TENANT tables (canonical home = tenant_default). Adding
`-- scope: public` to 1145/1146/1148 would prevent plat_* tables from being created in
any tenant schema, regressing every tenant that depends on them. The DO $$ early-return
guard is the correct primitive: it skips the public pass while allowing all tenant schema
passes to proceed.

### 6a. `migrations/1145_ord01_plat_effect_completion.sql`

**Problem:** bare `CREATE TABLE IF NOT EXISTS plat_effect_completion` runs in every schema
pass. `plat_effect_completion` is PER_TENANT (ORCH OQ-1 resolution); it must be created
in tenant schemas, not in public.

**Fix:** wrap all DDL in a DO $$ block with the early-return guard.

```sql
DO $$
BEGIN
    IF current_schema() = 'public' THEN
        RAISE NOTICE 'ORD-01: public schema pass — skipping plat_effect_completion (PER_TENANT; see GBL-142).';
        RETURN;
    END IF;

    CREATE TABLE IF NOT EXISTS plat_effect_completion (
        completion_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        correlation_id text NOT NULL,
        sequence_no bigint NOT NULL,
        status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPLIED','DEAD')),
        payload jsonb NOT NULL DEFAULT '{}'::jsonb,
        received_at timestamptz NOT NULL DEFAULT now(),
        applied_at timestamptz,
        created_at timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT plat_effect_completion_correlation_seq_uq UNIQUE (correlation_id, sequence_no)
    );

    CREATE INDEX IF NOT EXISTS idx_plat_effect_completion_claim
        ON plat_effect_completion (correlation_id, sequence_no) WHERE status = 'PENDING';

    CREATE INDEX IF NOT EXISTS idx_plat_effect_completion_correlation
        ON plat_effect_completion (correlation_id, sequence_no);
END $$;
```

The existing `-- @generated` boilerplate comment block is retained above the DO $$; only
the DDL body is wrapped.

### 6b. `migrations/1146_ord04_plat_correlation_cursor.sql`

Identical pattern. `plat_correlation_cursor` is PER_TENANT.

```sql
DO $$
BEGIN
    IF current_schema() = 'public' THEN
        RAISE NOTICE 'ORD-04: public schema pass — skipping plat_correlation_cursor (PER_TENANT; see GBL-142).';
        RETURN;
    END IF;

    CREATE TABLE IF NOT EXISTS plat_correlation_cursor (
        correlation_id text PRIMARY KEY,
        applied_seq bigint NOT NULL DEFAULT 0 CHECK (applied_seq >= 0),
        updated_at timestamptz NOT NULL DEFAULT now(),
        created_at timestamptz NOT NULL DEFAULT now()
    );

    CREATE INDEX IF NOT EXISTS idx_plat_correlation_cursor_updated
        ON plat_correlation_cursor (updated_at);
END $$;
```

### 6c. `migrations/1148_par02_partition_catalog.sql`

Identical pattern. Both `plat_partition_catalog` and `plat_partition_maintenance_run_log`
are PER_TENANT; wrap the entire DDL (both CREATE TABLE statements) in a single DO $$ block.

```sql
DO $$
BEGIN
    IF current_schema() = 'public' THEN
        RAISE NOTICE 'PAR-02: public schema pass — skipping plat_partition_catalog / plat_partition_maintenance_run_log (PER_TENANT; see GBL-142).';
        RETURN;
    END IF;

    CREATE TABLE IF NOT EXISTS plat_partition_catalog (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        table_name text NOT NULL,
        parent_table text NOT NULL,
        range_start timestamptz NOT NULL,
        range_end timestamptz NOT NULL,
        state text NOT NULL DEFAULT 'ATTACHED',
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT plat_partition_catalog_table_uq UNIQUE (table_name),
        CHECK (state IN ('ATTACHED', 'DETACHED', 'ORPHAN_PARTITION', 'DROPPED'))
    );

    CREATE INDEX IF NOT EXISTS idx_plat_partition_catalog_parent_state
        ON plat_partition_catalog (parent_table, state);

    CREATE TABLE IF NOT EXISTS plat_partition_maintenance_run_log (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        run_date date NOT NULL,
        ran_at timestamptz NOT NULL DEFAULT now(),
        future_partition_count integer NOT NULL DEFAULT 0,
        CONSTRAINT plat_partition_maintenance_run_log_date_uq UNIQUE (run_date)
    );
END $$;
```

**Downstream consequence for 1149 DO blocks 4/5:** since `plat_partition_catalog` is
PER_TENANT (canonical home = tenant_default), the unqualified `INSERT INTO
plat_partition_catalog` in DO blocks 4/5 correctly resolves via `search_path` to the
**current schema's own** `plat_partition_catalog` during each tenant pass. This is the
intended per-tenant catalog model — each tenant's partition catalog tracks that tenant's
own partitions. No change to DO blocks 4/5 is required.

### 6d. `migrations/1149_par03_retention_class.sql`

**DO block 1** (event_type_registry ALTERs): already effectively guarded by
`IF to_regclass('event_type_registry') IS NULL THEN RETURN;` — since GBL-112 dropped
`public.event_type_registry`, this block is a no-op during the public pass. No change
needed for DO block 1.

**Fix for DO block 2** (events_ephemeral CREATE) — add early-return guard immediately
after `BEGIN`:

```sql
DO $$
DECLARE
    v_is_partitioned BOOLEAN;
BEGIN
    IF current_schema() = 'public' THEN
        RAISE NOTICE 'PAR-03: public schema pass — skipping events_ephemeral rebuild (PER_TENANT; see GBL-112 / GBL-142).';
        RETURN;
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM pg_partitioned_table pt
        JOIN pg_class c ON c.oid = pt.partrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = 'events_ephemeral' AND n.nspname = current_schema()
    ) INTO v_is_partitioned;
    -- ... rest of block unchanged
```

**Fix for DO block 3** (partition seed loop) — add the same guard immediately after
`BEGIN`:

```sql
DO $$
DECLARE
    v_month_start DATE := date_trunc('month', now())::date;
    v_offset INT;
    v_partition_name TEXT;
    v_range_start TIMESTAMPTZ;
    v_range_end TIMESTAMPTZ;
BEGIN
    IF current_schema() = 'public' THEN
        RAISE NOTICE 'PAR-03: public schema pass — skipping events_ephemeral partition seed (PER_TENANT; see GBL-112 / GBL-142).';
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_partitioned_table pt
        -- ... rest of block unchanged
```

**DO blocks 4 and 5** (plat_partition_catalog inserts): the `IF EXISTS (... WHERE
n.nspname = current_schema())` partition-existence checks correctly return false during
the public pass (events_ephemeral and events/events_archive partitions do not exist in
public after the DO block 2/3 guards are applied and GBL-142 has cleaned up). The
unqualified INSERT resolves to the current schema's per-tenant plat_partition_catalog —
this is correct. No change required.

---

## 7. Error taxonomy

| Error | Cause | Migration response |
|---|---|---|
| `dependent_objects_still_exist` | Unexpected FK dependent on a shadow table in public | `EXCEPTION WHEN` block logs NOTICE, increments `v_skipped`, loop continues |
| `undefined_table` | Table not in `information_schema` | Guarded by `v_exists_pub`/`v_exists_ten` booleans; EXECUTE never called if false |
| `42501 insufficient_privilege` | Migration not run as migration user | Hard abort — propagates out of DO block; fix: check migration runner credentials |

No `dependent_objects_still_exist` exceptions are anticipated for any of the 8 public
shadow copies (zero FK dependents confirmed on the live db_test for all 8 — they were
all created by recent unguarded migrations). The per-table exception block is defensive,
matching GBL-141 style.

---

## 8. State transitions

Not applicable. This design makes no changes to application state machines or workflow
tables. It only removes stray database objects and adds migration scope guards.

---

## 9. Dependencies

### GBL-142 depends on:
- `information_schema.tables` and `pg_class` (standard catalog introspection) — always
  present. No `public.tenant` loop needed; all drops target `public.<name>` directly.
- No dependency on any of the 8 shadow tables being non-empty; the drops are idempotent.

### Source patches depend on:
- `migrations.zig migrationScope()` executing the DO $$ block during every schema pass
  (`.all_schemas` default). The early-return guard inside the block handles the public
  pass; no scope header change needed.
- 1149's DO blocks 4/5 depend on the current schema having plat_partition_catalog
  (created by 1148 per-tenant pass). Since 1148 is patched to skip public, and
  1149 DO blocks 2/3 are patched to skip public, DO blocks 4/5 are unreachable during
  the public pass (the partition-existence checks return false). No ordering issue.

### Must NOT depend on:
- Any state set by the application at runtime (no function calls, no sequence resets).
- Other currently-open corrective migrations (GBL-142 is additive and independent of
  GBL-135 through GBL-141).

---

## 10. Open questions

| # | Question | Severity | Status |
|---|---|---|---|
| OQ-1 | Drop direction for all 8 tables. | MAJOR | **RESOLVED** (ORCH, 2026-08-12): all 8 are PER_TENANT; stray copies are in public; GBL-142 drops from public. |
| OQ-2 | `event_payload_store` and `plat_event_idempotency` absent from linter's 8-table list. | MINOR | No action unless linter list changes. `event_payload_store`'s public shadow was already dropped by GBL-141; `plat_event_idempotency` is guarded in 1147. |
| OQ-3 | `plat_partition_catalog` insert direction in 1149 DO blocks 4/5. | MINOR | **RESOLVED** (ORCH OQ-1 reclassification): plat_partition_catalog is PER_TENANT; per-tenant catalog model is correct. Unqualified INSERT resolves to current schema's copy. No change needed. |
| OQ-4 | 1149 DO block 1 uses `to_regclass('event_type_registry') IS NULL` rather than explicit `current_schema() = 'public'` check. | MINOR | No action required; both produce identical outcome. Optional follow-up. |

---

## 11. lint_migration_schema.py — no change required

`tools/lint_migration_schema.py` validates column shapes and constraint names; it does
not scan for scope headers or dual-schema duplicates. The dual-schema linter is
`tools/lint_dual_schema_table_names.py`. No update to either linter is needed as part
of this fix. The linter will pass after GBL-142 runs and the source patches are applied.

---

## 12. docs/anti-patterns.md — update

Add the following entry under the existing "Database — Schema-per-Tenant Migrations"
section (or create the section if absent):

> **Anti-pattern: `-- @generated` codegen migration with unguarded top-level DDL for
> PER_TENANT tables (ISS-0185-class recurrence).** When `tools/codegen_migration.py`
> generates a migration for a PER_TENANT table, the generated file lacks a DO $$
> early-return guard for the public schema pass. The migration runner defaults to
> `.all_schemas` and creates the table in every schema pass, including public — where
> PER_TENANT tables must not exist. **Fix:** wrap the entire DDL body in
> `DO $$ BEGIN IF current_schema() = 'public' THEN RAISE NOTICE '...'; RETURN; END IF;
> ... END $$;`, matching the pattern in 1147 (`PAR-01`). Do NOT use `-- scope: public`
> for PER_TENANT tables; that scope primitive restricts execution to public-pass only,
> preventing creation in tenant schemas. Previous occurrences: ISS-0185/ISS-0641
> (GBL-135 through GBL-141; source-migration patches used `-- scope: public` where
> appropriate for GLOBAL_REGISTRY tables). This recurrence: ISS-0673 (GBL-142),
> migrations 1145/1146/1148/1149 — PER_TENANT tables accidentally created in public.
> The canonical guard is the DO $$ `IF current_schema() = 'public' THEN RETURN` pattern.
