-- Migration 134: ISS-0112 - Add secret_ref and secret_key_id to SCHEMA-mode tenant webhook_subscriptions
-- Issue: https://github.com/R-Co/bpm-platform/issues/375 (ISS-0112)
-- Date: 2026-08-04
-- Author: BACKEND-DEV (WF03-gh375-20260804)
--
-- Problem: Migration GBL-128_exp501_secrets.sql attempted to add webhook_subscriptions.secret_ref
-- but its guard condition `IF to_regclass('webhook_subscriptions') IS NOT NULL` evaluated against
-- the public schema where the table was already dropped by GBL-073. GBL migrations only run against
-- the public schema, so the columns were never added to SCHEMA-mode tenant schemas.
--
-- Solution: Iterate over all SCHEMA-mode tenants and add both columns using dynamic SQL.
-- This is a NON-GBL migration so it can execute DDL against multiple tenant schemas.
--
-- Idempotency: Uses ADD COLUMN IF NOT EXISTS. Safe to re-run.

DO $$
DECLARE
    v_tenant         RECORD;
    v_tenant_schema  TEXT;
    v_schemas_processed INTEGER := 0;
BEGIN
    -- Iterate over all SCHEMA-mode tenants
    FOR v_tenant IN
        SELECT id, slug FROM public.tenant WHERE storage_mode = 'SCHEMA'
    LOOP
        -- Construct tenant schema name
        IF v_tenant.id = '00000000-0000-0000-0000-000000000000'::uuid THEN
            v_tenant_schema := 'tenant_default';
        ELSE
            v_tenant_schema := 'tenant_' || replace(v_tenant.id::text, '-', '');
        END IF;

        -- Verify schema exists before attempting DDL
        IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = v_tenant_schema) THEN
            -- Check if webhook_subscriptions table exists in this schema
            IF EXISTS (
                SELECT 1 FROM information_schema.tables
                WHERE table_schema = v_tenant_schema
                  AND table_name = 'webhook_subscriptions'
            ) THEN
                -- Add both columns using IF NOT EXISTS (idempotent)
                EXECUTE format(
                    'ALTER TABLE %I.webhook_subscriptions
                     ADD COLUMN IF NOT EXISTS secret_ref TEXT,
                     ADD COLUMN IF NOT EXISTS secret_key_id TEXT',
                    v_tenant_schema
                );

                -- Backfill secret_ref for existing rows using tenant slug pattern
                -- Pattern: sec://tenant/{tenant_slug}/webhook/subscription-{id}
                EXECUTE format(
                    'UPDATE %I.webhook_subscriptions
                     SET secret_ref = COALESCE(secret_ref, $1 || id::text),
                         secret_key_id = COALESCE(secret_key_id, $2)
                     WHERE secret_ref IS NULL OR secret_key_id IS NULL',
                    v_tenant_schema
                ) USING 'sec://tenant/' || v_tenant.slug || '/webhook/subscription-', 'legacy';

                v_schemas_processed := v_schemas_processed + 1;
                RAISE NOTICE 'ISS-0112: Added secret_ref/secret_key_id to %.webhook_subscriptions ✓', v_tenant_schema;
            ELSE
                RAISE NOTICE 'ISS-0112: Skipping tenant % (schema %) — webhook_subscriptions table does not exist', v_tenant.id, v_tenant_schema;
            END IF;
        ELSE
            RAISE NOTICE 'ISS-0112: Skipping tenant % — schema % does not exist', v_tenant.id, v_tenant_schema;
        END IF;
    END LOOP;

    RAISE NOTICE 'ISS-0112 corrective migration completed: processed % SCHEMA-mode tenant schema(s)', v_schemas_processed;
END $$;
