-- Migration 088: ISS-105 — Backfill active_tokens from current_nodes
-- Date: 2026-06-12
--
-- PREREQUISITE: Migration 083 must have run first (adds active_tokens + join_counters columns).
--
-- STRATEGY:
--   1. Convert old-format current_nodes rows (string arrays like ["node_A", "node_B"])
--      to new-format active_tokens ([{token_id, node_id, branch_id}]).
--   2. Rows already in new format (object arrays) are skipped.
--   3. join_counters initialized to '{}' by column DEFAULT in 083 -- no backfill needed.
--   4. Additive only -- no DROP, no destructive change.
--
-- IDEMPOTENCY:
--   The UPDATE uses a WHERE clause that checks:
--     a. active_tokens is still empty ('[]')
--     b. current_nodes has at least one string element (old format)
--   So re-running the migration is a no-op for already-migrated rows.

DO $$
DECLARE
    v_instance_proj_oid OID;
    v_updated_count INTEGER;
BEGIN
    -- Guard: instance_projections table must exist
    v_instance_proj_oid := to_regclass('instance_projections');
    IF v_instance_proj_oid IS NULL THEN
        RAISE NOTICE 'Migration 088: instance_projections does not exist — nothing to backfill.';
        RETURN;
    END IF;

    -- Guard: active_tokens column must exist (from migration 083)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'instance_projections'
          AND column_name = 'active_tokens'
    ) THEN
        RAISE NOTICE 'Migration 088: active_tokens column not found — run migration 083 first.';
        RETURN;
    END IF;

    -- Backfill: convert old-format current_nodes (string array) to active_tokens (object array).
    -- Only targets rows where:
    --   - active_tokens is still the default '[]' (not yet backfilled)
    --   - current_nodes is a non-empty JSONB array
    --   - the first element of current_nodes is a string (old format, not an object)
    UPDATE instance_projections
    SET active_tokens = (
        SELECT jsonb_agg(
            jsonb_build_object(
                'token_id', gen_random_uuid()::text,
                'node_id', elem::text,
                'branch_id', instance_id::text || '/' || elem::text || '/0'
            )
            ORDER BY ordinality
        )
        FROM jsonb_array_elements_text(current_nodes) WITH ORDINALITY AS elem(value, ordinality)
    )
    WHERE current_nodes IS NOT NULL
      AND jsonb_typeof(current_nodes) = 'array'
      AND jsonb_array_length(current_nodes) > 0
      AND active_tokens = '[]'::jsonb
      AND jsonb_typeof(current_nodes -> 0) = 'string';

    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    RAISE NOTICE 'Migration 088: backfilled % rows.', v_updated_count;
END $$;
