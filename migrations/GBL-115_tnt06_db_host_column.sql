-- GBL-076: TNT-06 — add db_host routing column to tenant_schemas and
-- add MIGRATING status value to tenant.status_check constraint.
--
-- db_host: NULL means use the default BPM_DB_URL host (single-server
-- deployments are unaffected). Non-null directs the connection pool to
-- establish a connection to the named PostgreSQL host for this tenant.
--
-- MIGRATING status: used by the tenant export/import procedure to pause
-- write requests (HTTP 503) while reads continue.
--
-- GBL-prefix: operates on public routing tables; exempt from
-- lint_migration_schema.py business-table check.

-- Add db_host column to tenant_schemas (idempotent)
ALTER TABLE public.tenant_schemas
    ADD COLUMN IF NOT EXISTS db_host TEXT DEFAULT NULL;

COMMENT ON COLUMN public.tenant_schemas.db_host IS
    'Override PostgreSQL host for this tenant. NULL = use BPM_DB_URL host.';

-- Update the tenant_status_check constraint to include MIGRATING.
-- Strategy: drop the old constraint (if present) and re-add with MIGRATING.
-- Both operations are wrapped in DO blocks for idempotency.
DO $$
BEGIN
    -- Drop the existing constraint (may be named tenant_status_check from mig 031)
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints
         WHERE table_schema    = 'public'
           AND table_name      = 'tenant'
           AND constraint_name = 'tenant_status_check'
           AND constraint_type = 'CHECK'
    ) THEN
        ALTER TABLE public.tenant DROP CONSTRAINT tenant_status_check;
    END IF;
END $$;

-- Add the updated constraint that includes MIGRATING
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
         WHERE table_schema    = 'public'
           AND table_name      = 'tenant'
           AND constraint_name = 'tenant_status_check'
           AND constraint_type = 'CHECK'
    ) THEN
        ALTER TABLE public.tenant
            ADD CONSTRAINT tenant_status_check
            CHECK (status IN ('ACTIVE', 'INACTIVE', 'MIGRATING'));
    END IF;
END $$;
