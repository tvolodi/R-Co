-- Migration 047: Repository form schema registry (REPO-05)
--
-- Form schema indexing for agent-driven discovery by field type, name, and label.
-- Covers:
--   - REPO-05: Form schema indexing and queryability

CREATE TABLE IF NOT EXISTS form_schema_registry (
    registry_id          UUID NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    version_id           UUID NOT NULL,
    artifact_name        VARCHAR(255) NOT NULL,
    field_name           VARCHAR(255) NOT NULL,
    field_type           VARCHAR(128) NOT NULL,          -- "string", "number", "date", "enum", "currency", etc.
    field_label          VARCHAR(4096),                  -- User-visible label
    required             BOOLEAN DEFAULT FALSE,
    pattern              TEXT,                           -- Optional regex validation pattern

    -- Uniqueness per version and field name
    CONSTRAINT uq_form_schema_field UNIQUE (version_id, field_name),

    -- Foreign key
    CONSTRAINT fk_form_schema_version FOREIGN KEY (version_id) REFERENCES artifact_versions(version_id) ON DELETE CASCADE,

    -- Indexes for searchability
    INDEX idx_form_schema_version (version_id),
    INDEX idx_form_schema_field_type (field_type),
    INDEX idx_form_schema_field_name (field_name),
    -- Full-text search on labels (GIN index for LIKE queries)
    INDEX idx_form_schema_field_label USING GIN (to_tsvector('english', field_label))
);

COMMENT ON TABLE form_schema_registry IS 'Index of form schema fields for agent-driven discovery (REPO-05).';
COMMENT ON COLUMN form_schema_registry.registry_id IS 'Unique identifier for this schema field entry.';
COMMENT ON COLUMN form_schema_registry.version_id IS 'Reference to artifact_versions; form this index entry belongs to.';
COMMENT ON COLUMN form_schema_registry.artifact_name IS 'Name of the form artifact.';
COMMENT ON COLUMN form_schema_registry.field_name IS 'Name of the field in the form schema.';
COMMENT ON COLUMN form_schema_registry.field_type IS 'Type classification: string, number, date, enum, currency, boolean, file, etc.';
COMMENT ON COLUMN form_schema_registry.field_label IS 'User-visible label displayed in the form.';
COMMENT ON COLUMN form_schema_registry.required IS 'Whether the field is mandatory.';
COMMENT ON COLUMN form_schema_registry.pattern IS 'Optional regex pattern for field validation.';
