-- 028_adp02_tenant_scope_persistence.sql
-- Stage 6.5: ADP-02 -- additive tenant scope for definition/instance/task/token/audit persistence.

CREATE OR REPLACE FUNCTION bpm_effective_tenant_id()
RETURNS UUID
LANGUAGE SQL
STABLE
AS $$
    SELECT COALESCE(
        NULLIF(current_setting('bpm.tenant_id', true), '')::uuid,
        '00000000-0000-0000-0000-000000000000'::uuid
    )
$$;

ALTER TABLE process_definitions
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL DEFAULT bpm_effective_tenant_id();

ALTER TABLE instance_projections
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL DEFAULT bpm_effective_tenant_id();

ALTER TABLE tasks
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL DEFAULT bpm_effective_tenant_id();

ALTER TABLE tokens
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL DEFAULT bpm_effective_tenant_id();

ALTER TABLE audit_entries
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL DEFAULT bpm_effective_tenant_id();

ALTER TABLE audit_log
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL DEFAULT bpm_effective_tenant_id();

ALTER TABLE process_definitions ALTER COLUMN tenant_id SET DEFAULT bpm_effective_tenant_id();
ALTER TABLE instance_projections ALTER COLUMN tenant_id SET DEFAULT bpm_effective_tenant_id();
ALTER TABLE tasks ALTER COLUMN tenant_id SET DEFAULT bpm_effective_tenant_id();
ALTER TABLE tokens ALTER COLUMN tenant_id SET DEFAULT bpm_effective_tenant_id();
ALTER TABLE audit_entries ALTER COLUMN tenant_id SET DEFAULT bpm_effective_tenant_id();
ALTER TABLE audit_log ALTER COLUMN tenant_id SET DEFAULT bpm_effective_tenant_id();

ALTER TABLE process_definitions DROP CONSTRAINT IF EXISTS uq_definition_version;
ALTER TABLE process_definitions DROP CONSTRAINT IF EXISTS uq_definition_tenant_version;
DROP INDEX IF EXISTS uq_active_definition;
DROP INDEX IF EXISTS uq_instance_correlation;

ALTER TABLE process_definitions ADD CONSTRAINT uq_definition_tenant_version
    UNIQUE (tenant_id, name, version);

CREATE UNIQUE INDEX IF NOT EXISTS uq_active_definition_tenant
    ON process_definitions (tenant_id, name)
    WHERE status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_def_tenant_name_status
    ON process_definitions (tenant_id, name, status);

CREATE INDEX IF NOT EXISTS idx_def_tenant_created
    ON process_definitions (tenant_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS uq_instance_tenant_correlation
    ON instance_projections (tenant_id, definition_id, correlation_key)
    WHERE correlation_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_proj_tenant_status
    ON instance_projections (tenant_id, status);

CREATE INDEX IF NOT EXISTS idx_proj_tenant_definition
    ON instance_projections (tenant_id, definition_id);

CREATE INDEX IF NOT EXISTS idx_proj_tenant_instance
    ON instance_projections (tenant_id, instance_id);

CREATE INDEX IF NOT EXISTS idx_task_tenant_instance
    ON tasks (tenant_id, instance_id);

CREATE INDEX IF NOT EXISTS idx_task_tenant_pending_assignee
    ON tasks (tenant_id, assignee_ref, status)
    WHERE status = 'PENDING';

CREATE INDEX IF NOT EXISTS idx_task_tenant_status
    ON tasks (tenant_id, status);

CREATE INDEX IF NOT EXISTS idx_token_tenant_instance
    ON tokens (tenant_id, instance_id);

CREATE INDEX IF NOT EXISTS idx_token_tenant_active
    ON tokens (tenant_id, instance_id, status)
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_token_tenant_waiting
    ON tokens (tenant_id, instance_id, gateway_id)
    WHERE status = 'waiting';

CREATE INDEX IF NOT EXISTS idx_audit_entries_tenant_time
    ON audit_entries (tenant_id, timestamp DESC, audit_id DESC);

CREATE INDEX IF NOT EXISTS idx_audit_entries_tenant_resource_time
    ON audit_entries (tenant_id, resource_type, resource_id, timestamp DESC, audit_id DESC);

CREATE INDEX IF NOT EXISTS idx_audit_log_tenant_time
    ON audit_log (tenant_id, occurred_at DESC);

ALTER TABLE process_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE process_definitions FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS process_definitions_tenant_policy ON process_definitions;
CREATE POLICY process_definitions_tenant_policy ON process_definitions
    USING (tenant_id = bpm_effective_tenant_id())
    WITH CHECK (tenant_id = bpm_effective_tenant_id());

ALTER TABLE instance_projections ENABLE ROW LEVEL SECURITY;
ALTER TABLE instance_projections FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS instance_projections_tenant_policy ON instance_projections;
CREATE POLICY instance_projections_tenant_policy ON instance_projections
    USING (tenant_id = bpm_effective_tenant_id())
    WITH CHECK (tenant_id = bpm_effective_tenant_id());

ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasks FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tasks_tenant_policy ON tasks;
CREATE POLICY tasks_tenant_policy ON tasks
    USING (tenant_id = bpm_effective_tenant_id())
    WITH CHECK (tenant_id = bpm_effective_tenant_id());

ALTER TABLE tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE tokens FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tokens_tenant_policy ON tokens;
CREATE POLICY tokens_tenant_policy ON tokens
    USING (tenant_id = bpm_effective_tenant_id())
    WITH CHECK (tenant_id = bpm_effective_tenant_id());

ALTER TABLE audit_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_entries FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS audit_entries_tenant_policy ON audit_entries;
CREATE POLICY audit_entries_tenant_policy ON audit_entries
    USING (tenant_id = bpm_effective_tenant_id())
    WITH CHECK (tenant_id = bpm_effective_tenant_id());

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS audit_log_tenant_policy ON audit_log;
CREATE POLICY audit_log_tenant_policy ON audit_log
    USING (tenant_id = bpm_effective_tenant_id())
    WITH CHECK (tenant_id = bpm_effective_tenant_id());
