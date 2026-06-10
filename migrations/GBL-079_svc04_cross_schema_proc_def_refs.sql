-- GBL-079: SVC-04 cross-schema process_definitions active-reference helper (Stage 13)
--
-- After Stage 12 (GBL-073), public.process_definitions was dropped; the table now
-- lives in per-tenant schemas (tenant_<uuid_no_dashes>).  The service catalog's
-- referential guards (deleteService, updateServiceScope) need to find ACTIVE
-- process definitions that reference a given service_id across ALL tenant schemas.
--
-- This function iterates public.tenant_schemas and queries each registered schema.
-- It is called by:
--   - src/repository/service_catalog.zig deleteService
--   - src/repository/service_catalog.zig updateServiceScope
--
-- GBL-prefix: operates across schemas; exempt from lint_migration_schema.py
-- business-table placement check.
--
-- Idempotent: CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION public.bpm_active_defs_for_service(p_service_id text)
RETURNS TABLE(tenant_id uuid, definition_id uuid)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    r   RECORD;
    sql text;
BEGIN
    FOR r IN
        SELECT schema_name
        FROM   public.tenant_schemas
        ORDER  BY schema_name
    LOOP
        BEGIN
            sql := format(
                $q$
                SELECT tenant_id::uuid, id::uuid
                FROM   %I.process_definitions
                WHERE  status = 'ACTIVE'
                  AND  graph::text LIKE '%%' || $1 || '%%'
                $q$,
                r.schema_name
            );
            RETURN QUERY EXECUTE sql USING p_service_id;
        EXCEPTION
            WHEN undefined_table  THEN NULL;   -- schema provisioned but not yet migrated
            WHEN undefined_column THEN NULL;   -- unusual schema shape; skip gracefully
        END;
    END LOOP;
END;
$$;
