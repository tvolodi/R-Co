-- 1156_prm06_promotion_assertion_runs.sql
-- PRM-06: idempotent pre-promotion assertion re-run state.
--
-- Per-tenant table: the FK to public.tenant identifies the owning tenant;
-- rows live in the tenant's own schema (no tenant_id column required under
-- SPT architecture, but the design retains tenant_id for parity with the
-- few other cross-schema-readable audit-trail tables and so the FK to
-- public.tenant is explicit). Created via the standard per-tenant bootstrap
-- path.
--
-- Idempotency contract (PRM-06 AC1, AC4):
--   INSERT ... ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
-- where idempotency_key is "promotion_rerun:<review_id>:<plan_digest>".
--
-- Prerequisite: promotion_reviews must exist in the tenant schema (created in
-- the PRM-04 batch). The FK is added conditionally via to_regclass so this
-- file can also run before PRM-04 in development environments — a NOTICE is
-- emitted when the FK is omitted and the column stays NOT NULL.
--
-- scope: tenant_only.

CREATE TABLE IF NOT EXISTS promotion_assertion_runs (
    id                    UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id             UUID         NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    review_id             UUID         NOT NULL,
    idempotency_key       TEXT         NOT NULL,
    status                TEXT         NOT NULL
        CHECK (status IN ('running','passed','failed','teardown_failed')),
    sandbox_id            UUID,
    plan_digest           TEXT         NOT NULL,
    assertions_total      INTEGER      NOT NULL DEFAULT 0,
    assertions_passed     INTEGER      NOT NULL DEFAULT 0,
    assertions_failed     INTEGER      NOT NULL DEFAULT 0,
    failing_assertion_ids JSONB,
    teardown_error        TEXT,
    reaper_claimed_at     TIMESTAMPTZ,
    started_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    completed_at          TIMESTAMPTZ,
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_promotion_assertion_runs_idempotency
        UNIQUE (tenant_id, idempotency_key)
);

DO $$
BEGIN
    IF to_regclass('promotion_reviews') IS NOT NULL THEN
        EXECUTE 'ALTER TABLE promotion_assertion_runs
                 ADD CONSTRAINT promotion_assertion_runs_review_fk
                 FOREIGN KEY (review_id) REFERENCES promotion_reviews(id) ON DELETE CASCADE';
    ELSE
        RAISE NOTICE '1156: promotion_reviews absent in schema % — review_id FK omitted (BACKEND-DEV must apply PRM-04 batch first).', current_schema();
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_promotion_assertion_runs_tenant_review
    ON promotion_assertion_runs (tenant_id, review_id);
CREATE INDEX IF NOT EXISTS idx_promotion_assertion_runs_status
    ON promotion_assertion_runs (status)
    WHERE status IN ('running', 'teardown_failed');
CREATE INDEX IF NOT EXISTS idx_promotion_assertion_runs_reaper
    ON promotion_assertion_runs (reaper_claimed_at)
    WHERE reaper_claimed_at IS NULL;