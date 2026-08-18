-- Migration 1169: QRY-05 entity field grant tables
-- scope: tenant_only
-- Adds entity_field_restrictions and user_entity_grants for field-level read grants.

CREATE TABLE IF NOT EXISTS entity_field_restrictions (
    id              UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_key      TEXT    NOT NULL,
    field_name      TEXT    NOT NULL,
    required_grant  TEXT    NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_efr_entity_field UNIQUE (entity_key, field_name)
);
CREATE INDEX IF NOT EXISTS idx_efr_entity_key
    ON entity_field_restrictions (entity_key);

CREATE TABLE IF NOT EXISTS user_entity_grants (
    id              UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID    NOT NULL,
    entity_key      TEXT    NOT NULL,
    grant_name      TEXT    NOT NULL,
    granted_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_ueg_user_entity_grant UNIQUE (user_id, entity_key, grant_name)
);
CREATE INDEX IF NOT EXISTS idx_ueg_user_entity
    ON user_entity_grants (user_id, entity_key);
