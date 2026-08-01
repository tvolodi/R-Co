-- 1106_iss0125_instance_definition_snapshots_cascade.sql
-- Requirements: ISS-0125 / GitHub tvolodi/R-Co#391
--
-- Root cause: migrations/004_definitions.sql:50-57 declared
--   definition_id UUID NOT NULL REFERENCES process_definitions(id)
-- with the default NO ACTION referential action. Any process_definitions
-- DELETE was therefore blocked while any referencing
-- instance_definition_snapshots row remained. The shared test harness
-- (tests/integration/helpers.zig resetTestData) was correctly ordered,
-- but bespoke per-test cleanup helpers that swallowed SQL errors could
-- silently proceed to DELETE FROM process_definitions after a failed
-- child delete, producing C23503. See docs/issue-reports/ISS-0125-root-cause.md.
--
-- Fix: replace the FK with an equivalent FK that uses ON DELETE CASCADE.
-- The snapshot is an immutable copy of the graph at instance start, so
-- the parent row's identity has no meaning without its children once the
-- parent is gone. Keeping the FK name preserves information_schema
-- lookups in pre-existing tools and tests.
--
-- Schema placement (corrected vs. the original design draft, which assumed
-- instance_definition_snapshots lived in public):
--   After migration 060 (schema-per-tenant bootstrap) and GBL-073
--   (drop legacy public business tables), the active FK constraint lives
--   in tenant_default and per-tenant schemas, NOT in public. A legacy
--   orphan copy of instance_definition_snapshots remains in public (the
--   table itself, no FK), because GBL-073 dropped public.process_definitions
--   with CASCADE - which also removed the FK constraint on the table -
--   leaving an empty public.instance_definition_snapshots behind. There
--   is no FK to alter in public; this migration therefore targets each
--   tenant schema where the FK actually exists.
--
-- Filename/numbering: this migration is NOT GBL-prefixed. The migrator
-- (src/db/migrations.zig) blanket-skips GBL-prefixed files for any
-- schema_name != 'public' (per the GBL-104 convention), so a GBL-prefixed
-- file would NOT reach tenant_default where the FK actually lives. The
-- migration is sequence-numbered 1106 (4-digit, beyond GBL-105's order
-- 1105) because src/db/migrations.zig migrationOrder() rejects any
-- out-of-order migration whose file_order < max_applied_order. With
-- GBL-105 already applied for every schema, the next per-tenant
-- migration must have order >= 1106, which forces a 4-digit prefix.
--
-- Per-schema execution: Migrations.runForSchema() sets search_path to
-- <schema_name>,public before applying each non-GBL migration file. The
-- unqualified table references below therefore resolve to the current
-- tenant schema's instance_definition_snapshots and process_definitions
-- tables. The to_regclass() guards make the DDL a no-op when the table
-- does not exist in the current schema (e.g. when this file is replayed
-- against public, where the legacy orphan table has no FK to alter).
--
-- Idempotency contract: DROP CONSTRAINT IF EXISTS is idempotent. The
-- ADD CONSTRAINT will fail with "constraint already exists" on a re-run
-- when the FK was already replaced; that is acceptable because
-- Migrations.runForSchema() records this file in schema_migrations after
-- successful application and skips subsequent runs.
--
-- reapply_on_drift: true

DO $$
DECLARE
    v_snapshots_oid OID;
    v_definitions_oid OID;
BEGIN
    -- Both tables must exist in the current search_path (i.e. the per-tenant
    -- schema). If either is missing, this is a no-op - runs against the
    -- public schema (where the FK no longer exists after GBL-073) are
    -- silently skipped.
    v_snapshots_oid := to_regclass('instance_definition_snapshots');
    v_definitions_oid := to_regclass('process_definitions');
    IF v_snapshots_oid IS NULL OR v_definitions_oid IS NULL THEN
        RAISE NOTICE '1106_iss0125: instance_definition_snapshots or process_definitions missing in current schema - skipping (no-op).';
        RETURN;
    END IF;

    -- Replace the existing FK (if any) with an equivalent FK that uses
    -- ON DELETE CASCADE. The constraint name is preserved so existing
    -- information_schema lookups in tests and external tools continue to
    -- find the same name.
    EXECUTE format(
        'ALTER TABLE instance_definition_snapshots '
        || 'DROP CONSTRAINT IF EXISTS instance_definition_snapshots_definition_id_fkey'
    );

    EXECUTE format(
        'ALTER TABLE instance_definition_snapshots '
        || 'ADD CONSTRAINT instance_definition_snapshots_definition_id_fkey '
        || 'FOREIGN KEY (definition_id) REFERENCES process_definitions(id) '
        || 'ON DELETE CASCADE'
    );
END
$$;
