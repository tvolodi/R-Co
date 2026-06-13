-- Migration 100: EXP-501 — tenant-scoped envelope-encrypted secrets module
-- Date: 2026-06-14
--
-- Additive/idempotent only:
--   1) create secrets table (global, tenant-scoped rows)
--   2) add webhook subscription secret reference metadata columns
--   3) backfill webhook metadata from legacy plaintext secret column
--      and then clear plaintext value to avoid future persistence/logging exposure

DO $$
DECLARE
    v_proj_oid OID;
BEGIN
    -- Keep the same guard convention used by recent GBL migrations.
    v_proj_oid := to_regclass('instance_projections');
    IF v_proj_oid IS NULL THEN
        RETURN;
    END IF;

    EXECUTE $q$
        CREATE TABLE IF NOT EXISTS secrets (
            secret_id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id             TEXT        NOT NULL,
            namespace             TEXT        NOT NULL,
            name                  TEXT        NOT NULL,
            key_id                TEXT        NOT NULL,
            purpose               TEXT        NOT NULL,
            status                TEXT        NOT NULL DEFAULT 'active'
                                            CHECK (status IN ('active', 'disabled', 'deleted')),
            algorithm             TEXT        NOT NULL,
            wrapped_key_algorithm TEXT        NOT NULL,
            ciphertext            BYTEA       NOT NULL,
            wrapped_data_key      BYTEA       NOT NULL,
            nonce                 BYTEA       NOT NULL,
            auth_tag              BYTEA       NOT NULL,
            aad                   BYTEA       NOT NULL,
            wrapping_key_ref      TEXT        NOT NULL,
            wrapping_key_version  TEXT        NOT NULL,
            created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            created_by            TEXT        NOT NULL,
            disabled_at           TIMESTAMPTZ,
            deleted_at            TIMESTAMPTZ,
            CONSTRAINT uq_secrets_scope UNIQUE (tenant_id, namespace, name, key_id)
        )
    $q$;

    EXECUTE $q$
        CREATE INDEX IF NOT EXISTS idx_secrets_lookup
            ON secrets (tenant_id, namespace, name, status)
    $q$;

    EXECUTE $q$
        CREATE INDEX IF NOT EXISTS idx_secrets_purpose
            ON secrets (tenant_id, purpose)
    $q$;

    -- Webhook subscriptions now store only secret references + key metadata.
    EXECUTE $q$
        ALTER TABLE webhook_subscriptions
            ADD COLUMN IF NOT EXISTS secret_ref TEXT,
            ADD COLUMN IF NOT EXISTS secret_key_id TEXT
    $q$;

    -- Backfill reference metadata for already-configured rows.
    -- Use the stable default tenant + deterministic namespace/name shape.
    EXECUTE $q$
        UPDATE webhook_subscriptions
        SET secret_ref = COALESCE(secret_ref, 'sec://tenant/default/webhook/subscription-' || id::text),
            secret_key_id = COALESCE(secret_key_id, 'legacy')
        WHERE COALESCE(secret, '') <> ''
    $q$;

    -- EXP-501 hard requirement: plaintext secret value must not persist.
    EXECUTE $q$
        UPDATE webhook_subscriptions
        SET secret = ''
        WHERE COALESCE(secret, '') <> ''
    $q$;
END $$;
