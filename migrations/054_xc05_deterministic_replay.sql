-- 054_xc05_deterministic_replay.sql
-- XC-05: Deterministic Replay
-- State reconstruction via point-in-time queries produces identical results.
-- Service tasks and Tier 4 nodes replay from recorded outputs.

-- Ensure deterministic event ordering via created_at timestamp
-- Events table already has created_at for replay ordering
-- Point-in-time queries use: SELECT ... FROM events WHERE instance_id = $1 AND created_at <= $2 ORDER BY created_at, sequence_number

-- Add index for efficient point-in-time state reconstruction queries
CREATE INDEX IF NOT EXISTS idx_events_instance_order
    ON events (instance_id, created_at DESC, sequence_number DESC);
