-- OIDC-16..OIDC-26 foundational persistence artifacts.

-- scope: public
-- ISS-0185: this migration creates a global-registry table.

CREATE TABLE IF NOT EXISTS public.idp_operation_ledger (
    operation_id UUID PRIMARY KEY,
    endpoint_fingerprint TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    scope TEXT NOT NULL,
    request_hash BYTEA NOT NULL,
    response_status INT,
    response_body_json JSONB,
    state TEXT NOT NULL CHECK (state IN ('PENDING','COMPLETED','FAILED')),
    actor_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_idp_operation_ledger_scope_key
ON public.idp_operation_ledger (endpoint_fingerprint, idempotency_key);

CREATE INDEX IF NOT EXISTS idx_idp_operation_ledger_expiry
ON public.idp_operation_ledger (expires_at);

CREATE TABLE IF NOT EXISTS public.idp_transaction_log (
    transaction_id UUID NOT NULL,
    step_index INT NOT NULL,
    step_kind TEXT NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('FORWARD','COMPENSATION')),
    status TEXT NOT NULL CHECK (status IN ('PENDING','SUCCESS','FAILED','SKIPPED')),
    request_payload_json JSONB,
    response_payload_json JSONB,
    error_code TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    PRIMARY KEY (transaction_id, step_index, direction)
);

CREATE INDEX IF NOT EXISTS idx_idp_txn_status
ON public.idp_transaction_log (transaction_id, direction, status);

CREATE TABLE IF NOT EXISTS public.idp_adapter_audit (
    audit_id UUID PRIMARY KEY,
    actor_id TEXT NOT NULL,
    auth_source TEXT NOT NULL,
    adapter_method TEXT NOT NULL,
    provider_status_code INT NOT NULL,
    duration_ms BIGINT NOT NULL,
    realm_id TEXT,
    resource_id TEXT,
    transaction_id UUID,
    request_payload_redacted JSONB,
    response_payload_redacted JSONB,
    redaction_applied BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_idp_adapter_audit_actor_time
ON public.idp_adapter_audit (actor_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_idp_adapter_audit_txn
ON public.idp_adapter_audit (transaction_id)
WHERE transaction_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.agent_identity_binding (
    binding_id UUID PRIMARY KEY,
    realm_id TEXT NOT NULL,
    agent_kind TEXT NOT NULL,
    provider_client_id TEXT NOT NULL,
    service_account_user_id TEXT NOT NULL,
    scopes_json JSONB NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('ACTIVE','REVOKED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_identity_binding_active
ON public.agent_identity_binding (realm_id, agent_kind)
WHERE status = 'ACTIVE';

CREATE TABLE IF NOT EXISTS public.agent_secret_rotation (
    rotation_id UUID PRIMARY KEY,
    realm_id TEXT NOT NULL,
    provider_client_id TEXT NOT NULL,
    old_secret_fingerprint TEXT NOT NULL,
    new_secret_fingerprint TEXT NOT NULL,
    old_secret_valid_until TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('OVERLAP','FINALIZED','FAILED')),
    created_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finalized_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_agent_secret_rotation_finalize
ON public.agent_secret_rotation (status, old_secret_valid_until)
WHERE status = 'OVERLAP';

CREATE TABLE IF NOT EXISTS public.agent_bootstrap_state (
    singleton_key TEXT PRIMARY KEY CHECK (singleton_key = 'global'),
    enabled BOOLEAN NOT NULL,
    enabled_by TEXT,
    enabled_at TIMESTAMPTZ,
    disabled_at TIMESTAMPTZ,
    last_bootstrap_id UUID,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.agent_bootstrap_audit (
    event_id UUID PRIMARY KEY,
    event_type TEXT NOT NULL CHECK (event_type IN ('BOOTSTRAP_ATTEMPT','BOOTSTRAP_SUCCESS','BOOTSTRAP_DISABLED','BOOTSTRAP_REENABLED')),
    actor_id TEXT,
    outcome TEXT NOT NULL,
    details_json JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.idp_federation_binding (
    federation_binding_id UUID PRIMARY KEY,
    realm_id TEXT NOT NULL,
    provider_alias TEXT NOT NULL,
    federation_type TEXT NOT NULL,
    provider_federation_id TEXT NOT NULL,
    config_digest TEXT NOT NULL,
    jit_link_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    status TEXT NOT NULL CHECK (status IN ('ACTIVE','DELETED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_idp_federation_alias_active
ON public.idp_federation_binding (realm_id, provider_alias)
WHERE status = 'ACTIVE';

CREATE TABLE IF NOT EXISTS public.federation_attribute_mapping (
    mapping_id UUID PRIMARY KEY,
    realm_id TEXT NOT NULL,
    federation_id TEXT NOT NULL,
    attribute_rules_json JSONB NOT NULL,
    role_rules_json JSONB NOT NULL,
    updated_by TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_federation_attribute_mapping
ON public.federation_attribute_mapping (realm_id, federation_id);

CREATE TABLE IF NOT EXISTS public.subsystem_health_probe (
    probe_id UUID PRIMARY KEY,
    subsystem TEXT NOT NULL,
    status TEXT NOT NULL,
    reason TEXT,
    latency_ms BIGINT NOT NULL,
    checked_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_subsystem_health_probe_recent
ON public.subsystem_health_probe (subsystem, checked_at DESC);
