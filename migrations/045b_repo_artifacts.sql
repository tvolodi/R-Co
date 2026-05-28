CREATE TABLE IF NOT EXISTS repository_artifacts (
artifact_id UUID,
version_id UUID PRIMARY KEY,
artifact_kind VARCHAR(64),
artifact_name VARCHAR(255),
content_hash TEXT,
content_json JSONB,
parent_version_id UUID,
created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS tenant_artifact_activations (
tenant_id UUID NOT NULL,
artifact_kind VARCHAR(64) NOT NULL,
artifact_name VARCHAR(255) NOT NULL,
active_version_id UUID NOT NULL,
activated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
PRIMARY KEY (tenant_id, artifact_kind, artifact_name)
);
