-- Migration 048: Repository event type registry extension (REPO-06)
--
-- Registration of event types used by active definitions.
-- Links event types to their producing definitions.
-- Extends ES-05 (event store event type registry).
-- Covers:
--   - REPO-06: Event type registry extension

CREATE TABLE IF NOT EXISTS event_type_registry_producers (
    id                   UUID NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type_id        UUID NOT NULL,
    definition_version_id UUID NOT NULL,
    registered_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Uniqueness: one registration per (event_type_id, definition_version_id)
    CONSTRAINT uq_event_type_producer UNIQUE (event_type_id, definition_version_id),

    -- Foreign keys
    -- event_type_id references event_store.event_type_registry(id)
    -- definition_version_id references artifact_versions(version_id) where artifact_kind='definition'
    CONSTRAINT fk_event_type_registry_event_type FOREIGN KEY (event_type_id) REFERENCES event_type_registry(id) ON DELETE RESTRICT,
    CONSTRAINT fk_event_type_registry_definition FOREIGN KEY (definition_version_id) REFERENCES artifact_versions(version_id) ON DELETE CASCADE
);

-- Indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_event_type_registry_event_type ON event_type_registry_producers (event_type_id);
CREATE INDEX IF NOT EXISTS idx_event_type_registry_definition ON event_type_registry_producers (definition_version_id);

COMMENT ON TABLE event_type_registry_producers IS 'Extension of ES-05: links event types to definitions that produce them (REPO-06).';
COMMENT ON COLUMN event_type_registry_producers.id IS 'Unique identifier for this producer registration.';
COMMENT ON COLUMN event_type_registry_producers.event_type_id IS 'Reference to event_store.event_type_registry(id).';
COMMENT ON COLUMN event_type_registry_producers.definition_version_id IS 'Reference to artifact_versions where artifact_kind="definition".';
COMMENT ON COLUMN event_type_registry_producers.registered_at IS 'UTC timestamp when this event type was registered for this definition.';

-- Indexes for efficient queries (created separately)
CREATE INDEX IF NOT EXISTS idx_event_type_registry_event_type ON event_type_registry_producers (event_type_id);
CREATE INDEX IF NOT EXISTS idx_event_type_registry_definition ON event_type_registry_producers (definition_version_id);
