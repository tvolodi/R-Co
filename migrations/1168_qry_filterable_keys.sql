-- 1168_qry_filterable_keys.sql
-- QRY-02: per-entity declared JSONB key allowlist for filter/sort surfaces.
-- scope: tenant_only
--
-- entity_filterable_keys stores JSONB key declarations that may appear in
-- filter and sort nodes for the entity query endpoint (QRY-01/QRY-02).
-- Typed projection columns (from entity_definitions.definition_json.fields
-- where queried=true) are NOT stored here; they are merged at allowlist-load
-- time and shadow same-name JSONB keys (QRY-02 AC: "typed columns shadow").
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS.
-- No tenant_id column: schema search_path (SPT-03) provides tenant isolation.

CREATE TABLE IF NOT EXISTS entity_filterable_keys (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_key      TEXT        NOT NULL,
    key_name        TEXT        NOT NULL,
    storage_type    TEXT        NOT NULL
                                CHECK (storage_type IN ('text','numeric','boolean','timestamptz')),
    is_sortable     BOOLEAN     NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_efk_entity_key_name UNIQUE (entity_key, key_name)
);

CREATE INDEX IF NOT EXISTS idx_efk_entity_key
    ON entity_filterable_keys (entity_key);
