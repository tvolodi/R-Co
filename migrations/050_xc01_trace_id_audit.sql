-- 050_xc01_trace_id_audit.sql
-- XC-01: Trace ID support for audit log entries.
-- Adds trace_id column to audit_entries table for end-to-end request tracing.

ALTER TABLE audit_entries
    ADD COLUMN IF NOT EXISTS trace_id TEXT NULL;

CREATE INDEX IF NOT EXISTS idx_audit_entries_trace_id
    ON audit_entries (trace_id, tenant_id, "timestamp" DESC)
    WHERE trace_id IS NOT NULL;
