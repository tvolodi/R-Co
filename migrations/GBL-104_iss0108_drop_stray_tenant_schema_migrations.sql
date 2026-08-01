-- GBL-104: One-time cleanup — drop stray per-tenant schema_migrations shadow
-- tables (GitHub #368 / ISS-0108).
--
-- Root cause: migrations 001_event_store.sql and 055_xc06_backwards_
-- compatibility.sql historically issued an unqualified
-- "CREATE TABLE IF NOT EXISTS schema_migrations (...)". Because these are
-- non-GBL migrations, Migrations.runForSchema() (src/db/migrations.zig)
-- replays them once per tenant schema under a "<schema>,public" search_path
-- — so on every fresh tenant provision, the unqualified reference created a
-- permanently-empty schema_migrations table physically inside the tenant
-- schema, shadowing the real tracker (always public.schema_migrations, per
-- ISS-504/ISS-0091). An unqualified SELECT against schema_migrations from a
-- connection whose search_path starts with the tenant schema (e.g.
-- TestHarness's tenant_default,public) then silently resolves to this
-- always-empty shadow copy instead of the real, populated tracker.
--
-- That unqualified CREATE TABLE was fixed (schema-qualified to
-- public.schema_migrations) in the same change as this migration. This
-- migration performs the one-time cleanup of shadow tables already created
-- by the old, unqualified DDL on any tenant schema provisioned before the
-- fix — including on long-lived shared test containers, which is how this
-- was discovered (see docs/issues/ISS-0108.json).
--
-- GBL-prefix: exempt from lint_migration_schema.py business-table check.
-- Iterates public.tenant / builds schema names the same way GBL-075 does.

DO $$
DECLARE
    v_tenant      RECORD;
    v_schema_name TEXT;
    v_exists      BOOLEAN;
BEGIN
    FOR v_tenant IN
        SELECT id FROM tenant ORDER BY created_at ASC
    LOOP
        IF v_tenant.id = '00000000-0000-0000-0000-000000000000' THEN
            v_schema_name := 'tenant_default';
        ELSE
            v_schema_name := 'tenant_' || replace(v_tenant.id::text, '-', '');
        END IF;

        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
             WHERE table_schema = v_schema_name
               AND table_name   = 'schema_migrations'
        ) INTO v_exists;

        IF v_exists THEN
            EXECUTE format('DROP TABLE %I.schema_migrations', v_schema_name);
            RAISE NOTICE 'GBL-104: dropped stray %.schema_migrations shadow table.', v_schema_name;
        END IF;
    END LOOP;

    RAISE NOTICE 'GBL-104: stray per-tenant schema_migrations cleanup complete.';
END $$;
