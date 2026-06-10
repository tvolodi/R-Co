-- TNT-04: Add migration_window_active flag to onboarding_registry.
--
-- During the TNT-05 backfill run the operator sets this flag to TRUE.
-- The startup audit (src/bootstrap/audit.zig) reads it and downgrades
-- any unexpected-public-table log entry from ERROR to WARN, allowing
-- zero-downtime migration windows per TNT-04 acceptance criterion.
--
-- After TNT-05 completes and all business tables are removed from public,
-- the operator resets the flag to FALSE (or it stays FALSE by default).
--
-- This migration creates NO business table in public.
ALTER TABLE onboarding_registry
    ADD COLUMN IF NOT EXISTS migration_window_active BOOLEAN NOT NULL DEFAULT FALSE;
