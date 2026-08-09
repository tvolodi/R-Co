-- 1138_iss0635_webhook_secret_ref_corrective.sql
-- ISS-0635 / GH-616: corrective — missing secret_ref/secret_key_id columns
-- in tenant webhook_subscriptions tables provisioned after migration 1134.
-- Scope header intentionally absent: runs for every schema (all_schemas mode).
DO $$
DECLARE
    v_schema TEXT := current_schema();
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = v_schema
          AND table_name = 'webhook_subscriptions'
    ) THEN
        RAISE NOTICE 'ISS-0635: webhook_subscriptions absent in schema % — no-op', v_schema;
    ELSE
        ALTER TABLE webhook_subscriptions
            ADD COLUMN IF NOT EXISTS secret_ref TEXT,
            ADD COLUMN IF NOT EXISTS secret_key_id TEXT;
        UPDATE webhook_subscriptions ws
        SET
            secret_ref    = COALESCE(ws.secret_ref,
                'sec://tenant/' || COALESCE(
                    (SELECT t.slug FROM public.tenant t
                     WHERE (v_schema = 'tenant_default'
                            AND t.id = '00000000-0000-0000-0000-000000000000'::uuid)
                        OR ('tenant_' || replace(t.id::text, '-', '') = v_schema)
                     LIMIT 1),
                    v_schema
                ) || '/webhook/subscription-' || ws.id::text),
            secret_key_id = COALESCE(ws.secret_key_id, 'legacy')
        WHERE ws.secret_ref IS NULL OR ws.secret_key_id IS NULL;
        RAISE NOTICE 'ISS-0635: Confirmed secret_ref/secret_key_id in %.webhook_subscriptions', v_schema;
    END IF;
END $$;
