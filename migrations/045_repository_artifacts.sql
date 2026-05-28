-- Migration 045: Repository artifacts and versioning tables (REPO-01..03)
--
-- Content-addressed immutable artifact store with versioning and parent linkage.
-- Covers:
--   - REPO-01: Content addressing via SHA-256 hash
--   - REPO-02: Immutability enforcement (PRIMARY KEY on content_hash)
--   - REPO-03: Versioning with parent linkage for lineage tracking

CREATE TABLE IF NOT EXISTS repository_artifacts (
    content_hash         BYTEA NOT NULL PRIMARY KEY,
    content_type         VARCHAR(64) NOT NULL,           -- "application/json", "application/wasm", etc.
    byte_size            BIGINT NOT NULL,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Indexes for type-filtered and time-filtered queries
    INDEX idx_repo_artifacts_type_created (content_type, created_at),
    INDEX idx_repo_artifacts_created (created_at)
);

COMMENT ON TABLE repository_artifacts IS 'Content-addressed immutable artifact storage. Deduplication via content_hash PRIMARY KEY.';
COMMENT ON COLUMN repository_artifacts.content_hash IS 'SHA-256 digest of canonical artifact content; PRIMARY KEY enforces immutability.';
COMMENT ON COLUMN repository_artifacts.content_type IS 'MIME type: application/json (definitions, forms, schemas) or application/wasm (compiled modules).';
COMMENT ON COLUMN repository_artifacts.byte_size IS 'Stored content length in bytes.';


CREATE TABLE IF NOT EXISTS artifact_versions (
    version_id           UUID NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    artifact_id          UUID NOT NULL,
    artifact_kind        VARCHAR(64) NOT NULL,           -- "definition", "form", "schema", "service_catalog", "script", "module", "scenario"
    artifact_name        VARCHAR(255) NOT NULL,
    version_number       BIGINT NOT NULL,
    content_hash         BYTEA NOT NULL,
    parent_version_id    UUID,                           -- Optional: for lineage tracking (REPO-03)
    created_by           UUID NOT NULL,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    description          TEXT,                           -- Optional free-text description

    -- Uniqueness: one (kind, name, version_number) tuple per artifact
    CONSTRAINT uq_artifact_version_number UNIQUE (artifact_kind, artifact_name, version_number),

    -- Foreign keys
    CONSTRAINT fk_artifact_versions_content FOREIGN KEY (content_hash) REFERENCES repository_artifacts(content_hash) ON DELETE RESTRICT,
    CONSTRAINT fk_artifact_versions_parent FOREIGN KEY (parent_version_id) REFERENCES artifact_versions(version_id) ON DELETE SET NULL,

    -- Indexes for efficient queries
    INDEX idx_artifact_versions_kind_name_created (artifact_kind, artifact_name, created_at),
    INDEX idx_artifact_versions_content_hash (content_hash),
    INDEX idx_artifact_versions_kind_name (artifact_kind, artifact_name),
    INDEX idx_artifact_versions_parent (parent_version_id)
);

COMMENT ON TABLE artifact_versions IS 'Versioned artifact records with optional parent linkage for lineage.';
COMMENT ON COLUMN artifact_versions.version_id IS 'Unique identifier for this version record.';
COMMENT ON COLUMN artifact_versions.artifact_id IS 'Stable identifier for the logical artifact across all versions.';
COMMENT ON COLUMN artifact_versions.artifact_kind IS 'Type of artifact: definition, form, schema, service_catalog, script, module, scenario.';
COMMENT ON COLUMN artifact_versions.artifact_name IS 'Semantic name of the artifact (e.g., "order_process", "customer_form").';
COMMENT ON COLUMN artifact_versions.version_number IS 'Monotonically increasing per (kind, name) pair; starts at 1.';
COMMENT ON COLUMN artifact_versions.content_hash IS 'SHA-256 hash of canonical artifact content; enables deduplication.';
COMMENT ON COLUMN artifact_versions.parent_version_id IS 'Optional reference to the parent version for provenance tracking.';
COMMENT ON COLUMN artifact_versions.created_by IS 'UUID of user who created this version.';
COMMENT ON COLUMN artifact_versions.description IS 'Optional free-text description of what changed in this version.';
