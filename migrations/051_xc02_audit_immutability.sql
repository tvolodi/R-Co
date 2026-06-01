-- 051_xc02_audit_immutability.sql
-- XC-02: Audit immutability with cryptographic chaining.
-- Adds chain_hash and prev_chain_hash columns for tamper detection.
-- Adds tenant_id for multi-tenant isolation.

-- Ensure pgcrypto extension is available for digest/hash functions
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Add tenant_id column (nullable for backward compatibility)
ALTER TABLE audit_entries
    ADD COLUMN IF NOT EXISTS tenant_id UUID NULL;

-- Add chain hash columns for cryptographic chaining
ALTER TABLE audit_entries
    ADD COLUMN IF NOT EXISTS chain_hash TEXT NULL;

ALTER TABLE audit_entries
    ADD COLUMN IF NOT EXISTS prev_chain_hash TEXT NULL;

-- Add trace_id column for distributed tracing (after chain hash columns)
ALTER TABLE audit_entries
    ADD COLUMN IF NOT EXISTS trace_id TEXT NULL;

-- Create index for efficient chain queries (using timestamp instead of created_at)
CREATE INDEX IF NOT EXISTS idx_audit_entries_tenant_chain
    ON audit_entries (tenant_id, "timestamp" DESC, audit_id DESC)
    WHERE tenant_id IS NOT NULL;

-- NOTE: Chain hash functions (bpm_audit_compute_chain_hash, bpm_audit_apply_chain_hash)
-- are defined in migration 035_adp09_tamper_evident_audit_chain.sql
-- XC-02 adds the immutability constraints below.

-- Function to enforce audit immutability (prevent UPDATE/DELETE)
DROP FUNCTION IF EXISTS bpm_audit_enforce_immutability();
CREATE FUNCTION bpm_audit_enforce_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'audit entries are immutable and cannot be modified or deleted';
END;
$$;

-- Trigger to prevent UPDATE on audit_entries
CREATE TRIGGER trg_bpm_audit_prevent_update
BEFORE UPDATE ON audit_entries
FOR EACH ROW EXECUTE FUNCTION bpm_audit_enforce_immutability();

-- Trigger to prevent DELETE on audit_entries
CREATE TRIGGER trg_bpm_audit_prevent_delete
BEFORE DELETE ON audit_entries
FOR EACH ROW EXECUTE FUNCTION bpm_audit_enforce_immutability();

-- NOTE: validate_chain function is defined in migration 035_adp09_tamper_evident_audit_chain.sql
-- XC-02 does not override it.
