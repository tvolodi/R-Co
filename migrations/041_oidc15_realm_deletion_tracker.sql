-- Migration: 041_oidc15_realm_deletion_tracker.sql
-- OIDC-15: Realm deletion safety — two-phase deletion lifecycle.
--
-- Tracks realms that have been marked for deletion (phase 1) so that the
-- grace-period scheduler can perform hard deletion (phase 2) after the
-- configured delay.
--
-- Also provides a UNIQUE index on tenant.idp_realm_id to enforce the
-- one-to-one binding invariant from OIDC-12 (duplicate guard).

-- scope: public
-- ISS-0185: this migration creates a global-registry table.

CREATE TABLE IF NOT EXISTS public.realm_deletion_tracker (
    realm_id TEXT PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'MARKED_FOR_DELETION'
        CHECK (status IN ('MARKED_FOR_DELETION', 'DELETING', 'DELETED')),
    marked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    marked_by UUID NOT NULL,
    reason TEXT NOT NULL DEFAULT '',
    grace_period_seconds BIGINT NOT NULL DEFAULT 604800,
    hard_delete_after TIMESTAMPTZ NOT NULL,
    hard_deleted_at TIMESTAMPTZ,
    retry_count INT NOT NULL DEFAULT 0,
    last_retry_at TIMESTAMPTZ,
    metadata_json JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE realm_deletion_tracker IS
  'Tracks realms undergoing two-phase deletion (OIDC-15).'
  ' MARKED_FOR_DELETION = phase 1 complete, hard delete pending;'
  ' DELETING = hard delete in progress;'
  ' DELETED = realm permanently removed from the provider.';

-- Index for the grace-period scheduler query.
CREATE INDEX IF NOT EXISTS idx_realm_deletion_tracker_pending
ON realm_deletion_tracker (status, hard_delete_after)
WHERE status = 'MARKED_FOR_DELETION';

COMMENT ON INDEX idx_realm_deletion_tracker_pending IS
  'Supports the OIDC-15 grace-period scheduler:'
  ' find all MARKED_FOR_DELETION rows where hard_delete_after <= NOW().';

-- Re-enforce the one-to-one realm-tenant binding (OIDC-12).
-- Idempotent: only creates the index if it does not already exist.
CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_idp_realm_id
ON tenant (idp_realm_id)
WHERE idp_realm_id IS NOT NULL;

COMMENT ON INDEX idx_tenant_idp_realm_id IS
  'Enforces one-to-one realm-tenant binding (OIDC-12).';
