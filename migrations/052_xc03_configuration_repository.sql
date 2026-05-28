-- 052_xc03_configuration_repository.sql
-- XC-03: Configuration in repository
-- Enables storing configuration as artifacts alongside process definitions.

-- Create repository_artifacts table if it doesn't exist
CREATE TABLE IF NOT EXISTS repository_artifacts (
    artifact_id UUID NOT NULL PRIMARY KEY,
    version_id UUID NOT NULL,
    artifact_kind TEXT NOT NULL,
    artifact_name TEXT NOT NULL,
    content_hash TEXT NULL,
    content_json JSONB NULL,
    parent_version_id UUID NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    tenant_id UUID NULL
);

-- Create artifact_activations table for per-tenant activation tracking
CREATE TABLE IF NOT EXISTS artifact_activations (
    activation_id UUID NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    artifact_kind TEXT NOT NULL,
    artifact_name TEXT NOT NULL,
    active_version_id UUID NOT NULL REFERENCES repository_artifacts(version_id),
    activated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    activated_by UUID NULL
);

-- Create indexes for configuration artifact lookups
CREATE INDEX IF NOT EXISTS idx_repository_artifacts_config
    ON repository_artifacts (artifact_kind, artifact_name)
    WHERE artifact_kind = 'config';

CREATE INDEX IF NOT EXISTS idx_artifact_activations_config
    ON artifact_activations (tenant_id, artifact_kind, artifact_name)
    WHERE artifact_kind = 'config';

-- Create a view for easy configuration lookup
DROP VIEW IF EXISTS v_active_configs;
CREATE VIEW v_active_configs AS
SELECT
    aa.tenant_id,
    aa.artifact_kind,
    aa.artifact_name,
    aa.active_version_id,
    ra.content_json,
    aa.activated_at
FROM artifact_activations aa
JOIN repository_artifacts ra
    ON aa.active_version_id = ra.version_id
WHERE aa.artifact_kind = 'config';
