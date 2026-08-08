-- scope: public
-- GBL-138: ISS-0623 / GH-580 — reconcile bpm_test's tenant_default schema
-- after an out-of-band accidental full drop-and-reprovision.
--
-- Root cause (see docs/issues/ISS-0623.json and docs/anti-patterns.md
-- "Ad-hoc, unlogged psql DROP against a shared long-lived database during
-- live diagnosis (ISS-0623 / GH-580)" for full forensic detail):
--   During WF03-GH566-20260808's own BACKEND-DEV step (07:13:29-07:33:05Z),
--   GBL-136 was verified via DIRECT ad-hoc `psql` application against the
--   live bpm_test database (not `zig build migrate`), after first
--   discovering and correcting an env-var mixup (BPM_DB_URL vs
--   BPM_TEST_DB_URL). TEST-RUNNER's own step-04 handoff for the SAME run
--   self-reports "an accidental full DB drop mid-run while investigating"
--   during this manual diagnosis window. public.schema_migrations confirms
--   tenant_default's entire 75-row ledger was replayed from
--   001_event_store.sql through 1137_...backfill.sql in a 2.5-second burst
--   at 2026-08-08 08:19:53.236205 to 08:19:55.782928 UTC — consistent with
--   an ad-hoc `DROP SCHEMA tenant_default CASCADE` (or equivalent) run by
--   hand outside any committed script, immediately followed by the next
--   TestHarness.init()/zig build migrate call reprovisioning it from
--   scratch. This resurrected the 18 GLOBAL_REGISTRY/PER_TENANT shadow
--   tables that GBL-134 and GBL-135 had already correctly dropped from this
--   database at 2026-08-08 05:44:11Z and 05:44:16Z respectively.
--
--   No in-repo code defect was found: every call site that can reach
--   public.bpm_drop_tenant_schema() (src/identity/onboarding.zig's saga
--   compensate() path, tests/integration/spt01_iss0068_onboarding_schema_
--   test.zig's cleanupTenantSchema) only ever does so with a tenant_id
--   freshly generated moments earlier from either gen_random_uuid() (SQL
--   INSERT ... RETURNING) or std.testing.io.random() (Zig test helper) --
--   never nil, never empty, and the `defer`/`errdefer` that invokes the
--   drop is registered strictly AFTER that value is bound, so a failure
--   before assignment can never reach the drop call with a stale/empty
--   value. tools/clean_test_db.py's orphan-schema sweep explicitly excludes
--   'tenant_default' by name in every WHERE clause and additionally
--   requires the dropped name to match ^tenant_[0-9a-f]{32}$, which
--   'tenant_default' never does. This workspace's bpm_test (port 5453,
--   COMPOSE_PROJECT_NAME=r-co-2) was also confirmed NOT shared with the
--   sibling checkout (COMPOSE_PROJECT_NAME=r-co, port 5443) -- ruling out
--   ISS-0623's original "stale cross-workspace binary" theory. The cause is
--   therefore classified as an undocumented manual/ad-hoc DB action taken
--   during live debugging, not a reproducible code path.
--
-- This migration is GBL-134/GBL-135's reconciliation follow-up, not a
-- replacement -- it re-applies their exact DROP logic (same table lists,
-- same RESTRICT-only safety posture, same existence guards) now that
-- tenant_default has been reprovisioned and the 18 shadow tables are back
-- in both databases. GBL-134/GBL-135 themselves are immutable per this
-- lineage's established convention (see GBL-136/GBL-137's identical
-- treatment) and are left unmodified.
--
-- Safety properties (identical to GBL-134/GBL-135):
--   1. Each drop is scoped to tables that exist in BOTH the source and
--      target schema for that direction -- a table that exists only in one
--      schema is never touched.
--   2. The table lists below are the exact GBL-134 (11 names present in
--      this reprovisioning) and GBL-135 (7 names) allow-lists -- no new
--      classification decisions are made here.
--   3. RESTRICT (default): a live FK dependent aborts that table's drop,
--      not the whole migration (matches GBL-136's per-table exception
--      handling, not GBL-134's bare EXECUTE).
--   4. Idempotent: safe to re-run on a database where the duplicates are
--      already gone (both existence checks simply find nothing to drop).

DO $$
DECLARE
    v_schema_name TEXT := 'tenant_default';
    v_public_has  BOOLEAN;
    v_exists      BOOLEAN;
    v_dropped     INT := 0;
    v_skipped     INT := 0;
    -- GBL-134's 11 GLOBAL_REGISTRY names that are present as duplicates in
    -- this reprovisioning event (subset of GBL-134's full 24-name array --
    -- the others were never resurrected because their public.<name> row
    -- did not exist at reprovision time, or they are HYBRID/excluded).
    v_tenant_shadow_tables TEXT[] := ARRAY[
        'agent_bootstrap_audit',
        'agent_bootstrap_state',
        'agent_identity_binding',
        'agent_secret_rotation',
        'federation_attribute_mapping',
        'idp_adapter_audit',
        'idp_federation_binding',
        'idp_operation_ledger',
        'idp_transaction_log',
        'subsystem_health_probe',
        'tenant_artifact_activations'
    ];
    v_table TEXT;
BEGIN
    -- Direction 1 (GBL-134 logic): drop the tenant_default shadow of each
    -- GLOBAL_REGISTRY table whose canonical home is public.
    FOREACH v_table IN ARRAY v_tenant_shadow_tables LOOP
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = v_table
        ) INTO v_public_has;
        IF NOT v_public_has THEN
            CONTINUE;
        END IF;

        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
             WHERE table_schema = v_schema_name AND table_name = v_table
        ) INTO v_exists;

        IF v_exists THEN
            BEGIN
                EXECUTE format('DROP TABLE %I.%I RESTRICT', v_schema_name, v_table);
                v_dropped := v_dropped + 1;
                RAISE NOTICE 'GBL-138: dropped %.% (re-resurrected global shadow).',
                    v_schema_name, v_table;
            EXCEPTION WHEN dependent_objects_still_exist THEN
                v_skipped := v_skipped + 1;
                RAISE NOTICE 'GBL-138: skipped %.% -- live FK dependent still references it.',
                    v_schema_name, v_table;
            END;
        END IF;
    END LOOP;

    RAISE NOTICE 'GBL-138: direction 1 (tenant shadow of GLOBAL_REGISTRY) -- dropped %, skipped %.',
        v_dropped, v_skipped;
END $$;

DO $$
DECLARE
    v_exists_pub BOOLEAN;
    v_exists_ten BOOLEAN;
    v_dropped    INT := 0;
    v_skipped    INT := 0;
    -- GBL-135's 7 PER_TENANT names present as duplicates in this
    -- reprovisioning. GBL-135 itself no-opped on all of these against
    -- bpm_test at 2026-08-08 05:44:16Z because tenant_default did not yet
    -- exist (0 ledger rows) at that point in this database's history --
    -- confirmed via public.schema_migrations -- so the public shadow was
    -- never actually dropped and both copies are visible now that
    -- tenant_default has been (re)provisioned.
    v_public_shadow_tables TEXT[] := ARRAY[
        'group_roles',
        'instance_definition_snapshots',
        'role_permissions',
        'sessions',
        'sla_records',
        'user_groups',
        'webhook_deliveries'
    ];
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY v_public_shadow_tables LOOP
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = v_table
        ) INTO v_exists_pub;
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'tenant_default' AND table_name = v_table
        ) INTO v_exists_ten;

        IF v_exists_pub AND v_exists_ten THEN
            BEGIN
                EXECUTE format('DROP TABLE public.%I RESTRICT', v_table);
                v_dropped := v_dropped + 1;
                RAISE NOTICE 'GBL-138: dropped public.% (stray per-tenant shadow, GBL-135 follow-up).',
                    v_table;
            EXCEPTION WHEN dependent_objects_still_exist THEN
                v_skipped := v_skipped + 1;
                RAISE NOTICE 'GBL-138: skipped public.% -- live FK dependent still references it.',
                    v_table;
            END;
        END IF;
    END LOOP;

    RAISE NOTICE 'GBL-138: direction 2 (public shadow of PER_TENANT) -- dropped %, skipped %.',
        v_dropped, v_skipped;
END $$;
