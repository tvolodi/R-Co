-- 056_xc03_configuration_repository_fix.sql
-- XC-03 follow-up: restore the repository_artifacts compatibility columns
-- on databases where 052 was recorded but the XC-03 ALTER TABLE shape is
-- still missing.

ALTER TABLE repository_artifacts
    ADD COLUMN IF NOT EXISTS artifact_id UUID;

ALTER TABLE repository_artifacts
    ADD COLUMN IF NOT EXISTS version_id UUID;

ALTER TABLE repository_artifacts
    ADD COLUMN IF NOT EXISTS artifact_kind TEXT;

ALTER TABLE repository_artifacts
    ADD COLUMN IF NOT EXISTS artifact_name TEXT;

ALTER TABLE repository_artifacts
    ADD COLUMN IF NOT EXISTS content_json JSONB;

ALTER TABLE repository_artifacts
    ADD COLUMN IF NOT EXISTS parent_version_id UUID;

ALTER TABLE repository_artifacts
    ADD COLUMN IF NOT EXISTS tenant_id UUID;
    ALTER TABLE repository_artifacts
        ALTER COLUMN content_json TYPE TEXT USING content_json::text;
