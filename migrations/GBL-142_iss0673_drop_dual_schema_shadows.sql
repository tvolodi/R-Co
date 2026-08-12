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
