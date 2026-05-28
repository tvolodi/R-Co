-- Migration 046: Repository artifact activation tables (REPO-08..10)
--
-- Per-tenant activation of artifact versions with atomic multi-artifact activation,
-- history audit trail, and activation groups.
-- Covers:
--   - REPO-08: Atomic multi-artifact activation
--   - REPO-09: Per-tenant activation scoping
--   - REPO-10: Activation history audit trail

CREATE TABLE IF NOT EXISTS artifact_activations (
    activation_id        UUID NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID NOT NULL,
    artifact_kind        VARCHAR(64) NOT NULL,
    artifact_name        VARCHAR(255) NOT NULL,
    active_version_id    UUID NOT NULL,
    activated_at         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    activator_user_id    UUID NOT NULL,

    -- Uniqueness: one active version per (tenant_id, artifact_kind, artifact_name)
    CONSTRAINT uq_artifact_active_per_tenant UNIQUE (tenant_id, artifact_kind, artifact_name),

    -- Foreign key
    CONSTRAINT fk_artifact_activation_version FOREIGN KEY (active_version_id) REFERENCES artifact_versions(version_id) ON DELETE RESTRICT
);

-- Indexes for efficient tenant-scoped queries
CREATE INDEX IF NOT EXISTS idx_artifact_activations_tenant_kind ON artifact_activations (tenant_id, artifact_kind);
CREATE INDEX IF NOT EXISTS idx_artifact_activations_tenant ON artifact_activations (tenant_id);
CREATE INDEX IF NOT EXISTS idx_artifact_activations_activated_at ON artifact_activations (activated_at DESC);

COMMENT ON TABLE artifact_activations IS 'Current active artifact versions per tenant. Enforces one active per (tenant, kind, name).';
COMMENT ON COLUMN artifact_activations.activation_id IS 'Unique identifier for this activation record.';
COMMENT ON COLUMN artifact_activations.tenant_id IS 'Tenant UUID; activations are tenant-scoped (REPO-09).';
COMMENT ON COLUMN artifact_activations.artifact_kind IS 'Type of artifact being activated.';
COMMENT ON COLUMN artifact_activations.artifact_name IS 'Name of artifact being activated.';
COMMENT ON COLUMN artifact_activations.active_version_id IS 'UUID of the currently active version.';
COMMENT ON COLUMN artifact_activations.activator_user_id IS 'UUID of user who initiated the activation.';

-- Indexes for efficient tenant-scoped queries (created separately)
CREATE INDEX IF NOT EXISTS idx_artifact_activations_tenant_kind ON artifact_activations (tenant_id, artifact_kind);
CREATE INDEX IF NOT EXISTS idx_artifact_activations_tenant ON artifact_activations (tenant_id);
CREATE INDEX IF NOT EXISTS idx_artifact_activations_activated_at ON artifact_activations (activated_at DESC);


CREATE TABLE IF NOT EXISTS artifact_activation_history (
    history_id           UUID NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID NOT NULL,
    artifact_kind        VARCHAR(64) NOT NULL,
    artifact_name        VARCHAR(255) NOT NULL,
    previous_version_id  UUID,                           -- Nullable; null if first activation
    new_version_id       UUID NOT NULL,
    new_version_number   BIGINT NOT NULL,
    activator_user_id    UUID NOT NULL,
    activated_at         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    rationale            TEXT NOT NULL,                  -- Free-text reason for activation

    -- Foreign key
    CONSTRAINT fk_activation_history_new_version FOREIGN KEY (new_version_id) REFERENCES artifact_versions(version_id) ON DELETE RESTRICT
);

-- Indexes for efficient history queries (reverse chronological order)
CREATE INDEX IF NOT EXISTS idx_activation_history_tenant_artifact_time ON artifact_activation_history (tenant_id, artifact_kind, artifact_name, activated_at DESC);
CREATE INDEX IF NOT EXISTS idx_activation_history_tenant ON artifact_activation_history (tenant_id);
CREATE INDEX IF NOT EXISTS idx_activation_history_activated_at ON artifact_activation_history (activated_at DESC);

COMMENT ON TABLE artifact_activation_history IS 'Audit trail of all artifact activations per tenant (REPO-10).';
COMMENT ON COLUMN artifact_activation_history.history_id IS 'Unique identifier for this history record.';
COMMENT ON COLUMN artifact_activation_history.tenant_id IS 'Tenant UUID; history is tenant-scoped.';
COMMENT ON COLUMN artifact_activation_history.artifact_kind IS 'Type of artifact activated.';
COMMENT ON COLUMN artifact_activation_history.artifact_name IS 'Name of artifact activated.';
COMMENT ON COLUMN artifact_activation_history.previous_version_id IS 'UUID of version that was active before; null if first activation.';
COMMENT ON COLUMN artifact_activation_history.new_version_id IS 'UUID of version that is now active.';
COMMENT ON COLUMN artifact_activation_history.activator_user_id IS 'UUID of user who initiated the activation.';
COMMENT ON COLUMN artifact_activation_history.rationale IS 'Free-text explanation of why this activation was performed.';

-- Indexes for efficient history queries (reverse chronological order)  (created separately)
CREATE INDEX IF NOT EXISTS idx_activation_history_tenant_artifact_time ON artifact_activation_history (tenant_id, artifact_kind, artifact_name, activated_at DESC);
CREATE INDEX IF NOT EXISTS idx_activation_history_tenant ON artifact_activation_history (tenant_id);
CREATE INDEX IF NOT EXISTS idx_activation_history_activated_at ON artifact_activation_history (activated_at DESC);


CREATE TABLE IF NOT EXISTS artifact_activation_groups (
    group_id             UUID NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID NOT NULL,
    activated_at         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    activator_user_id    UUID NOT NULL,
    rationale            TEXT NOT NULL,
    -- artifacts_json: JSON array of {artifact_kind, artifact_name, version_id} objects
    artifacts_json       JSONB NOT NULL
);

-- Index for tenant-scoped queries
CREATE INDEX IF NOT EXISTS idx_activation_groups_tenant ON artifact_activation_groups (tenant_id);
CREATE INDEX IF NOT EXISTS idx_activation_groups_activated_at ON artifact_activation_groups (activated_at DESC);

COMMENT ON TABLE artifact_activation_groups IS 'Records of atomic multi-artifact activation groups (REPO-08, REPO-14).';
COMMENT ON COLUMN artifact_activation_groups.group_id IS 'Unique identifier for this activation group.';
COMMENT ON COLUMN artifact_activation_groups.tenant_id IS 'Tenant UUID; activation groups are tenant-scoped.';
COMMENT ON COLUMN artifact_activation_groups.artifacts_json IS 'JSON array of artifacts in this group: [{artifact_kind, artifact_name, version_id}, ...]';

-- Indexes for tenant-scoped queries (created separately)
CREATE INDEX IF NOT EXISTS idx_activation_groups_tenant ON artifact_activation_groups (tenant_id);
CREATE INDEX IF NOT EXISTS idx_activation_groups_activated_at ON artifact_activation_groups (activated_at DESC);
