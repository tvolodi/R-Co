-- Migration 069: retroactive tenant schema provisioning and schema drop helper (ISS-0068)
-- Idempotent migration: safe to run multiple times.

CREATE OR REPLACE FUNCTION public.bpm_drop_tenant_schema(p_tenant_id UUID)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_schema_name TEXT;
    v_default_uuid UUID := '00000000-0000-0000-0000-000000000000';
BEGIN
    IF p_tenant_id = v_default_uuid THEN
        v_schema_name := 'tenant_default';
    ELSE
        v_schema_name := 'tenant_' || replace(p_tenant_id::text, '-', '');
    END IF;

    EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', v_schema_name);
    DELETE FROM public.tenant_schemas WHERE tenant_id = p_tenant_id;
END;
$$;

DO $$
DECLARE
    r RECORD;
    v_sp_name TEXT;
BEGIN
    FOR r IN
        SELECT t.id
        FROM public.tenant t
        WHERE t.id NOT IN (SELECT ts.tenant_id FROM public.tenant_schemas ts)
        ORDER BY t.created_at
    LOOP
        v_sp_name := 'sp_' || replace(r.id::text, '-', '');

        BEGIN
            EXECUTE format('SAVEPOINT %I', v_sp_name);
            PERFORM public.bpm_provision_tenant_schema(r.id);
            EXECUTE format('RELEASE SAVEPOINT %I', v_sp_name);
        EXCEPTION
            WHEN OTHERS THEN
                BEGIN
                    EXECUTE format('ROLLBACK TO SAVEPOINT %I', v_sp_name);
                EXCEPTION
                    WHEN OTHERS THEN
                        NULL;
                END;
                BEGIN
                    EXECUTE format('RELEASE SAVEPOINT %I', v_sp_name);
                EXCEPTION
                    WHEN OTHERS THEN
                        NULL;
                END;
                RAISE WARNING 'Failed to provision schema for tenant %: %', r.id::text, SQLERRM;
        END;
    END LOOP;
END;
$$;