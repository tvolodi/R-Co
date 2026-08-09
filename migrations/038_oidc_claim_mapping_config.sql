-- OIDC-08: Per-realm claim mapping configuration.
--
-- Stores per-realm overrides for OIDC claim-to-IdentityContext mapping.
-- When no row exists for a realm, the system uses DEFAULT_CLAIM_MAPPING_CONFIG.
--
-- This is a configuration table, not an event-store table. It is read during
-- startup and on config reload, never on the hot authentication path.

-- scope: public
-- ISS-0185: this migration creates a global-registry table.

CREATE TABLE IF NOT EXISTS public.realm_claim_mapping_config (
    realm                   VARCHAR(64) PRIMARY KEY,
    tenant_id_claim         VARCHAR(128) NOT NULL DEFAULT 'tenant_id',
    roles_claim_paths       TEXT[] NOT NULL DEFAULT ARRAY['realm_access.roles','roles'],
    email_claim             VARCHAR(128) NOT NULL DEFAULT 'email',
    preferred_username_claim VARCHAR(128) NOT NULL DEFAULT 'preferred_username',
    display_name_claim      VARCHAR(128) NOT NULL DEFAULT 'display_name',
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
