-- Migration 101: EXP-501 corrective — actually create the secrets table
-- Date: 2026-07-30
--
-- GBL-100_exp501_secrets.sql originally guarded its entire body (including
-- CREATE TABLE secrets) on `to_regclass('instance_projections') IS NOT NULL`.
-- Because GBL-prefixed migrations run only against the public schema, and
-- instance_projections was permanently dropped from public by
-- GBL-073_tnt01_drop_legacy_public_business_tables.sql, that guard always
-- evaluated false: the secrets table was never created in any environment.
-- See docs/anti-patterns.md ("Guarding a migration's DO block with
-- to_regclass(...)") and GitHub #335 (ISS-0076).
--
-- schema_migrations already records GBL-100_exp501_secrets.sql as applied,
-- so editing that file in place does not cause it to re-run. This corrective
-- migration performs the same CREATE TABLE / CREATE INDEX DDL, unconditionally
-- and idempotently (IF NOT EXISTS throughout), so it is a no-op if GBL-100 is
-- ever fixed forward and re-applied from scratch in a new environment.

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
);

CREATE INDEX IF NOT EXISTS idx_secrets_lookup
    ON secrets (tenant_id, namespace, name, status);

CREATE INDEX IF NOT EXISTS idx_secrets_purpose
    ON secrets (tenant_id, purpose);
