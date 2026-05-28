-- 052_xc03_configuration_repository.sql
-- XC-03: Configuration in repository
-- Enables storing configuration as artifacts alongside process definitions.
--
-- NOTE: repository_artifacts is created by migration 045 with schema:
--   content_hash BYTEA PK, content_type VARCHAR(64), byte_size BIGINT, created_at
-- artifact_activations is created by migration 046 with schema:
--   activation_id UUID PK, tenant_id UUID, artifact_kind VARCHAR(64),
--   artifact_name VARCHAR(255), active_version_id UUID, activated_at, activator_user_id
--
-- This migration adds columns needed for config support and creates
-- a convenience view that traverses the version chain.

-- Add columns to repository_artifacts for config metadata (045 schema has only raw content)
ALTER TABLE repository_artifacts
    ADD COLUMN IF NOT EXISTS artifact_id UUID,
    ADD COLUMN IF NOT EXISTS version_id UUID,
    ADD COLUMN IF NOT EXISTS artifact_kind VARCHAR(64),
    ADD COLUMN IF NOT EXISTS artifact_name VARCHAR(255),
    ADD COLUMN IF NOT EXISTS content_hash_text TEXT,
    ADD COLUMN IF NOT EXISTS content_json JSONB,
    ADD COLUMN IF NOT EXISTS parent_version_id UUID,
    ADD COLUMN IF NOT EXISTS tenant_id UUID;

-- Create indexes for configuration artifact lookups
CREATE INDEX IF NOT EXISTS idx_repository_artifacts_config
    ON repository_artifacts (artifact_kind, artifact_name)
    WHERE artifact_kind IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_artifact_activations_config
    ON artifact_activations (tenant_id, artifact_kind, artifact_name)
    WHERE artifact_kind = 'config';

-- Create a view for easy configuration lookup
-- Traverses: artifact_activations -> artifact_versions -> repository_artifacts
-- to resolve content through the version chain (045/046 schema).
DROP VIEW IF EXISTS v_active_configs;
CREATE VIEW v_active_configs AS
SELECT
    aa.tenant_id,
    aa.artifact_kind,
    aa.artifact_name,
    aa.active_version_id,
    encode(ra.content_hash, 'hex') AS content_hash_hex,
    aa.activated_at
FROM artifact_activations aa
JOIN artifact_versions av
    ON aa.active_version_id = av.version_id
JOIN repository_artifacts ra
    ON av.content_hash = ra.content_hash
WHERE aa.artifact_kind = 'config';
