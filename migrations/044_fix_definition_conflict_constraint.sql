-- Migration 044: Convert uq_definition_tenant_version from unique index to named constraint
--
-- Background: Migration 028 originally created a unique index named
-- uq_definition_tenant_version. DSL-13 retroactively changed migration 028 to
-- use ALTER TABLE ... ADD CONSTRAINT instead. Databases that had migration 028
-- applied before DSL-13 still carry only the unique index, not a named
-- constraint. store.zig now uses ON CONFLICT ON CONSTRAINT which requires a
-- named constraint. This migration upgrades such databases idempotently.
--
-- Idempotent: safe to re-run on databases that already have the constraint.

DO $$
BEGIN
    -- Drop the unique index if it exists as an index (not a constraint).
    -- pg_constraint will have an entry if it is a named constraint; if only
    -- pg_class has the index then it is the old unique-index form.
    IF EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = 'uq_definition_tenant_version'
          AND c.relkind = 'i'
          AND NOT EXISTS (
              SELECT 1 FROM pg_constraint pc
              WHERE pc.conname = 'uq_definition_tenant_version'
          )
    ) THEN
        DROP INDEX uq_definition_tenant_version;
    END IF;

    -- Add the named constraint if it does not already exist.
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_definition_tenant_version'
    ) THEN
        ALTER TABLE process_definitions
            ADD CONSTRAINT uq_definition_tenant_version
            UNIQUE (tenant_id, name, version);
    END IF;
END;
$$;
