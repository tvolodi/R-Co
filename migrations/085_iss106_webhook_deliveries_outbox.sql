-- Migration 085: ISS-106 — Formalize webhook_deliveries as a transactional-outbox table
-- Date: 2026-06-11
--
-- Note: numeric slot 084 was consumed by a concurrent branch (084_iss104_artifact_hash.sql,
--       already applied in the live environment), so this migration takes the next free
--       numeric slot, 085. Design references 084; the iss106 name is preserved.
--
-- Covers: ISS-106 (webhook_deliveries outbox table formalization)
-- Related: EXT-02 (original table + dispatcher), ISS-205 (outbox insert + worker claim — OUT OF SCOPE)
-- Design: src/design/iss-106-webhook-outbox.md
--
-- STRATEGY (additive + idempotent reconciliation of the existing table):
--   1. Add `attempt` column (additive alias of legacy `attempt_count`; keep both — ISS-205 converges them)
--   2. Backfill `attempt` from `attempt_count`
--   3. Remap legacy lowercase status values to the uppercase domain BEFORE adding the CHECK
--   4. Replace the status CHECK constraint with the contract domain (PENDING, DELIVERED, FAILED, RETRYING)
--   5. Re-assert the (status, next_attempt_at) worker-claim index (reconcile, do not duplicate)
--
-- HARD RULES:
--   Additive only — NO DROP TABLE, NO DROP COLUMN. `attempt_count` is retained.
--   Unqualified table names only — applies under each per-tenant search_path.
--   Idempotent — re-running the whole migration is a no-op.

-- ── Step 1: Add the `attempt` column (additive) ──────────────────────────────
ALTER TABLE webhook_deliveries
    ADD COLUMN IF NOT EXISTS attempt INTEGER NOT NULL DEFAULT 0;

-- ── Step 2: Backfill `attempt` from the existing `attempt_count` ─────────────
UPDATE webhook_deliveries
SET attempt = attempt_count
WHERE attempt IS DISTINCT FROM attempt_count;

-- ── Step 3: Remap legacy status values to the uppercase domain ───────────────
-- MUST run before Step 4 so the new CHECK cannot fail on existing data.
-- ELSE status leaves already-uppercase values untouched → idempotent on re-run.
UPDATE webhook_deliveries
SET status = CASE status
    WHEN 'pending'   THEN 'PENDING'
    WHEN 'success'   THEN 'DELIVERED'
    WHEN 'failed'    THEN 'FAILED'
    WHEN 'exhausted' THEN 'FAILED'
    ELSE status
END
WHERE status IN ('pending', 'success', 'failed', 'exhausted');

-- ── Step 4: Replace the status CHECK constraint ──────────────────────────────
ALTER TABLE webhook_deliveries
    DROP CONSTRAINT IF EXISTS webhook_deliveries_status_check;

ALTER TABLE webhook_deliveries
    ADD CONSTRAINT webhook_deliveries_status_check
    CHECK (status IN ('PENDING', 'DELIVERED', 'FAILED', 'RETRYING'));

-- ── Step 5: Re-assert the worker-claim index (reconcile, do not duplicate) ───
CREATE INDEX IF NOT EXISTS idx_wd_status_next_attempt
    ON webhook_deliveries (status, next_attempt_at);
