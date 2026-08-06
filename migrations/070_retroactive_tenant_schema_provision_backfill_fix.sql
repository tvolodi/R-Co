-- scope: public
-- ISS-0604 / GH-470: corrective backfill over public.tenant / public.tenant_schemas.
-- Runs once from the public pass only.
-- Migration 070: corrective backfill for tenant schema provisioning (ISS-0068)
-- Applies provisioning for any tenants still missing tenant_schemas rows.

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT t.id
        FROM public.tenant t
        WHERE t.id NOT IN (SELECT ts.tenant_id FROM public.tenant_schemas ts)
        ORDER BY t.created_at
    LOOP
        BEGIN
            PERFORM public.bpm_provision_tenant_schema(r.id);
        EXCEPTION
            WHEN OTHERS THEN
                RAISE WARNING 'Failed to provision schema for tenant %: %', r.id::text, SQLERRM;
        END;
    END LOOP;
END;
$$;
