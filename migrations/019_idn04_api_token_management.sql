-- 019_idn04_api_token_management.sql
-- IDN-04: API token management schema alignment.
-- Additive only: extends existing api_tokens and adds token audit table.

ALTER TABLE api_tokens
    ADD COLUMN IF NOT EXISTS roles_json JSONB NOT NULL DEFAULT '[]'::jsonb;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'api_tokens_roles_json_array_check'
    ) THEN
        ALTER TABLE api_tokens
            ADD CONSTRAINT api_tokens_roles_json_array_check
            CHECK (jsonb_typeof(roles_json) = 'array');
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_api_tokens_created_at
    ON api_tokens(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_api_tokens_revoked_at
    ON api_tokens(revoked_at);

CREATE INDEX IF NOT EXISTS idx_api_tokens_expires_at
    ON api_tokens(expires_at);

-- ISS-0641 / GH-637: PER_TENANT (canonical home = tenant_default).
-- migrations.zig's migrationScope() has no per-table scope primitive (only
-- whole-file .public_only vs .all_schemas), so this file correctly keeps
-- running in every schema pass to create the tenant_default copy, but that
-- also creates an unwanted public shadow. See
-- docs/issue-reports/ISS-0185-diagnosis.yaml and
-- migrations/GBL-141_iss0641_drop_dual_schema_shadows.sql, which drops the
-- public shadow (idempotent, re-run after any cold-start replay).
CREATE TABLE IF NOT EXISTS api_token_audit (
    audit_id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    token_id         UUID        NOT NULL REFERENCES api_tokens(id) ON DELETE CASCADE,
    action           TEXT        NOT NULL CHECK (action IN ('ISSUED', 'REVOKED', 'VALIDATED')),
    actor_user_id    UUID        REFERENCES users(id),
    trace_id         TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata         JSONB       NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_api_token_audit_token_created
    ON api_token_audit(token_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_api_token_audit_action
    ON api_token_audit(action, created_at DESC);

INSERT INTO roles (name, description, is_system)
VALUES ('TASK_WORKER', 'Complete and read assigned tasks', true)
ON CONFLICT (name) DO NOTHING;
