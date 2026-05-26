-- 037_adp11_replay_safe_retention_policy.sql
-- Stage 6.5: ADP-11 -- replay-safe retention policy guardrails.
-- Additive changes:
--   1) Extend retention policy enum to include non-protected hard-delete modes.
--   2) Block hard-delete modes for protected replay-critical families.

ALTER TABLE event_retention_policies
    DROP CONSTRAINT IF EXISTS chk_retention_policy;

ALTER TABLE event_retention_policies
    ADD CONSTRAINT chk_retention_policy CHECK (
        policy IN (
            'keep_forever',
            'keep_days',
            'keep_count',
            'hard_delete_days',
            'hard_delete_count'
        )
    );

ALTER TABLE event_retention_policies
    DROP CONSTRAINT IF EXISTS chk_retention_protected_no_hard_delete;

ALTER TABLE event_retention_policies
    ADD CONSTRAINT chk_retention_protected_no_hard_delete CHECK (
        NOT (
            upper(event_type) LIKE 'INSTANCE_%' OR
            upper(event_type) LIKE 'TASK_%' OR
            upper(event_type) LIKE 'GATEWAY_%' OR
            upper(event_type) LIKE 'EXECUTION_%'
        )
        OR policy IN ('keep_forever', 'keep_days', 'keep_count')
    );
