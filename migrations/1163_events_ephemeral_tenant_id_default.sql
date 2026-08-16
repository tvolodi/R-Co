-- 1163_events_ephemeral_tenant_id_default.sql
-- SPT-03 completion (WF02-spt02-04-20260816, BACKEND-DEV rework after
-- TEST-RUNNER Step-4 FAIL): give events_ephemeral.tenant_id the same
-- deterministic DEFAULT as events (migration 027).
--
-- SPT-03 (commit 27ec5d6c) removed tenant_id from the events/events_ephemeral
-- INSERT column list per src/design/spt-02-03-04-schema-per-tenant-migration.md
-- §8.2 R3 ("tenant_id ... INSERT columns on Class B tables — Remove"). The
-- storage boundary no longer carries tenant_id; the column DEFAULT is the
-- deterministic fallback (see src/event_store/store.zig StoreError
-- MissingTenantContext comment: "tenant_id is absent at storage boundary;
-- deterministic fallback is required by caller").
--
-- events already had this default (027_adp01_event_store_tenant.sql), so its
-- INSERT path kept working. events_ephemeral (created by
-- 1149_par03_retention_class.sql with `tenant_id UUID NOT NULL` and NO
-- default) did not — so every delete-class append routed to events_ephemeral
-- by PAR-03's append-time retention-class routing inserted tenant_id NULL and
-- failed NOT NULL / the partitions' `CHECK (tenant_id IS NOT NULL)`
-- (sqlstate 23502 / 23514). Confirmed live: test-integration-event-store
-- TC-ADP-11-02 "non-protected families retain hard-delete configurability".
--
-- events_ephemeral is a PER_TENANT table (canonical home tenant_default;
-- GBL-112 permanently dropped public.events_ephemeral), so this migration
-- runs in each tenant schema pass and skips schemas where the table does not
-- exist. Because events_ephemeral is RANGE-partitioned and PostgreSQL does
-- NOT propagate an ALTER of a partitioned parent's column DEFAULT to already-
-- attached partitions, the parent is altered first (so future
-- `CREATE TABLE ... (LIKE events_ephemeral INCLUDING DEFAULTS)` partitions
-- inherit it) and every existing partition is altered explicitly.

DO $$
DECLARE
    v_partition_name TEXT;
BEGIN
    -- Guard: skip schemas where events_ephemeral does not exist (e.g. the
    -- public pass after GBL-112). Mirrors 1149_par03_retention_class.sql's
    -- per-tenant-table guard style.
    IF to_regclass('events_ephemeral') IS NULL THEN
        RAISE NOTICE 'SPT-03/1163: events_ephemeral absent in this schema pass — skipping tenant_id DEFAULT.';
        RETURN;
    END IF;

    -- Parent first: partitions created AFTER this migration (via
    -- LIKE ... INCLUDING DEFAULTS, the 1149 seed pattern) inherit the
    -- default at creation time.
    EXECUTE 'ALTER TABLE events_ephemeral ALTER COLUMN tenant_id SET DEFAULT ''00000000-0000-0000-0000-000000000000''';

    -- Existing partitions were created by 1149's seed loop with
    -- `LIKE events_ephemeral INCLUDING DEFAULTS` BEFORE the parent had the
    -- default, so each one still needs its own SET DEFAULT. Discover them via
    -- pg_inherits (schema-scoped to the current pass) and %I-interpolate the
    -- identifier (OQ-5 constraint, no static qualified names).
    FOR v_partition_name IN
        SELECT child.relname
        FROM pg_inherits i
        JOIN pg_class child ON child.oid = i.inhrelid
        JOIN pg_class parent ON parent.oid = i.inhparent
        JOIN pg_namespace n ON n.oid = child.relnamespace
        WHERE parent.relname = 'events_ephemeral'
          AND n.nspname = current_schema()
    LOOP
        EXECUTE format(
            'ALTER TABLE %I ALTER COLUMN tenant_id SET DEFAULT ''00000000-0000-0000-0000-000000000000''',
            v_partition_name
        );
    END LOOP;
END $$;
