-- 056_onboarding_registry.sql
-- OIDC-35: Company onboarding orchestration — idempotency registry table.
-- Stores onboarding request/response for idempotent replay, saga state,
-- and hostname-based lookup.

-- scope: public
-- ISS-0185: this migration creates a global-registry table.

CREATE TABLE IF NOT EXISTS public.onboarding_registry (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    onboarding_id       UUID        NOT NULL,
    idempotency_key     TEXT        NOT NULL,
    request_hash        BYTEA       NOT NULL,
    tenant_id           UUID,
    hostname            TEXT,
    response_status     SMALLINT    NOT NULL DEFAULT 201,
    response_body       JSONB,
    state               TEXT        NOT NULL DEFAULT 'pending'
                        CONSTRAINT onboarding_registry_state_check
                        CHECK (state IN ('pending', 'completed', 'failed')),
    idempotency_expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '24 hours'),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at        TIMESTAMPTZ,

    CONSTRAINT onboarding_registry_key_uq UNIQUE (idempotency_key)
);

CREATE INDEX IF NOT EXISTS onboarding_registry_onboarding_id_idx
    ON public.onboarding_registry (onboarding_id);

CREATE INDEX IF NOT EXISTS onboarding_registry_hostname_idx
    ON public.onboarding_registry (hostname)
    WHERE hostname IS NOT NULL;

CREATE INDEX IF NOT EXISTS onboarding_registry_expires_idx
    ON public.onboarding_registry (idempotency_expires_at)
    WHERE state IN ('pending', 'completed');
