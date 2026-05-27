-- OIDC-09: Per-realm JIT provisioning configuration.
--
-- Stores per-realm configuration for automatic user provisioning
-- from OIDC bearer tokens. When no row exists for a realm, the
-- system uses DEFAULT_JIT_CONFIG (enabled=true, status=ACTIVE).
--
-- This is a configuration table, not an event-store table.

CREATE TABLE IF NOT EXISTS jit_provisioning_config (
    realm           VARCHAR(64) PRIMARY KEY,
    enabled         BOOLEAN     NOT NULL DEFAULT TRUE,
    default_status  TEXT        NOT NULL DEFAULT 'ACTIVE'
                    CHECK (default_status IN ('ACTIVE', 'INACTIVE')),
    default_roles   JSONB       NOT NULL DEFAULT '[]' ::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Seed the default realm with JIT enabled, ACTIVE status, no default roles.
INSERT INTO jit_provisioning_config (realm, enabled, default_status, default_roles)
VALUES ('bpm-default', TRUE, 'ACTIVE', '[]' ::jsonb)
ON CONFLICT (realm) DO NOTHING;

-- Trigger to auto-update updated_at on row modification.
CREATE OR REPLACE FUNCTION jit_provisioning_config_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_jit_provisioning_config_updated_at ON jit_provisioning_config;
CREATE TRIGGER trg_jit_provisioning_config_updated_at
BEFORE UPDATE ON jit_provisioning_config
FOR EACH ROW EXECUTE FUNCTION jit_provisioning_config_set_updated_at();
