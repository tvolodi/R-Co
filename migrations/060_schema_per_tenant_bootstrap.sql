-- scope: public
-- ISS-0604 / GH-470: creates public.tenant_schemas and alters public.schema_migrations.
-- Entirely public-schema infrastructure; must not run in per-tenant passes.
-- Migration 060: Schema-per-tenant provisioning infrastructure (SPT-01)
-- Idempotent throughout: all DDL uses IF NOT EXISTS / IF EXISTS guards.

-- ---------------------------------------------------------------------------
-- Table: public.tenant_schemas
-- Registry of provisioned tenant schemas.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tenant_schemas (
    id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             UUID        NOT NULL,
    schema_name           TEXT        NOT NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    migrations_applied_at TIMESTAMPTZ,
    CONSTRAINT tenant_schemas_tenant_id_uq   UNIQUE (tenant_id),
    CONSTRAINT tenant_schemas_schema_name_uq UNIQUE (schema_name)
);

CREATE INDEX IF NOT EXISTS tenant_schemas_tenant_id_idx
    ON public.tenant_schemas (tenant_id);

-- ---------------------------------------------------------------------------
-- Alter: public.schema_migrations
-- Add schema_name column so the same migration version can be tracked per
-- tenant schema independently.
-- ---------------------------------------------------------------------------
ALTER TABLE public.schema_migrations
    ADD COLUMN IF NOT EXISTS schema_name TEXT NOT NULL DEFAULT 'public';

-- Drop the old single-column unique constraint on version alone (if present).
-- Wrapped in a DO block for idempotency — no error if the constraint is absent.
DO $$ BEGIN
    ALTER TABLE public.schema_migrations
        DROP CONSTRAINT IF EXISTS schema_migrations_version_key;
EXCEPTION WHEN others THEN NULL;
END $$;

-- Drop old primary key on version alone (if it exists).
DO $$ BEGIN
    ALTER TABLE public.schema_migrations
        DROP CONSTRAINT IF EXISTS schema_migrations_pkey;
EXCEPTION WHEN others THEN NULL;
END $$;

-- Add composite primary key (schema_name, version) if not already present.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_schema    = 'public'
          AND table_name      = 'schema_migrations'
          AND constraint_type = 'PRIMARY KEY'
    ) THEN
        ALTER TABLE public.schema_migrations
            ADD PRIMARY KEY (schema_name, version);
    END IF;
END;
$$;

-- Composite unique index as a belt-and-suspenders guard (no-op if PK already enforces it).
CREATE UNIQUE INDEX IF NOT EXISTS schema_migrations_schema_version_uq
    ON public.schema_migrations (schema_name, version);

-- ---------------------------------------------------------------------------
-- Function: public.bpm_provision_tenant_schema(p_tenant_id UUID)
--
-- Creates the tenant's PostgreSQL schema and registers it in tenant_schemas.
-- Idempotent: safe to call multiple times for the same tenant_id.
-- Concurrent calls are serialised via pg_advisory_xact_lock.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bpm_provision_tenant_schema(p_tenant_id UUID)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_schema_name TEXT;
    v_default_uuid UUID := '00000000-0000-0000-0000-000000000000';
BEGIN
    -- Derive schema name from UUID (same convention as schemaNameForTenant in Zig).
    IF p_tenant_id = v_default_uuid THEN
        v_schema_name := 'tenant_default';
    ELSE
        v_schema_name := 'tenant_' || replace(p_tenant_id::text, '-', '');
    END IF;

    -- Serialise concurrent provisioning attempts for the same schema.
    PERFORM pg_advisory_xact_lock(hashtext(v_schema_name));

    -- Create schema idempotently.
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema_name);

    -- Register in tenant_schemas; silently skip if already present.
    INSERT INTO public.tenant_schemas (tenant_id, schema_name)
    VALUES (p_tenant_id, v_schema_name)
    ON CONFLICT DO NOTHING;
END;
$$;
