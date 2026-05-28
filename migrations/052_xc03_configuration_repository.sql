-- 052_xc03_configuration_repository.sql
-- XC-03: Configuration in repository
-- Enables storing configuration as artifacts alongside process definitions.
-- Uses existing repository_artifacts and repository_activations tables.

-- The configuration repository feature uses:
-- 1. repository_artifacts table (already created in migrations 045+)
--    - artifact_kind = 'config' for configuration artifacts
--    - artifact_name identifies the configuration (e.g., 'capabilities', 'monitoring_config')
--    - content_json stores the configuration JSONB
--
-- 2. tenant_artifact_activations table (already created in migration 046)
--    - Maps tenant -> active configuration version
--    - Supports per-tenant activation following REPO-09 pattern
--
-- 3. audit_entries table (already created in migration 020)
--    - Records configuration activation events for auditability

-- Add index for configuration artifact lookups
CREATE INDEX IF NOT EXISTS idx_artifact_versions_config
    ON artifact_versions (artifact_kind, artifact_name)
    WHERE artifact_kind = 'config';

-- Add index for tenant configuration activations
CREATE INDEX IF NOT EXISTS idx_artifact_activations_config
    ON artifact_activations (tenant_id, artifact_kind, artifact_name)
    WHERE artifact_kind = 'config';

-- Optional: Create a view for easy configuration lookup
DROP VIEW IF EXISTS v_active_configs;
CREATE VIEW v_active_configs AS
SELECT
    aa.tenant_id,
    aa.artifact_kind,
    aa.artifact_name,
    aa.active_version_id,
    av.description,
    aa.activated_at
FROM artifact_activations aa
JOIN artifact_versions av
    ON aa.active_version_id = av.version_id
WHERE aa.artifact_kind = 'config';
