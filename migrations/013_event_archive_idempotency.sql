-- 013_event_archive_idempotency.sql
-- Stage 1: ES-03 Invariant #5 — idempotency durability across archival
--
-- After an event row is moved from events → events_archive, its
-- idempotency_key is no longer covered by the uq_event_idempotency index on
-- events.  Without a corresponding UNIQUE index on events_archive, a new
-- append with the same key would succeed as a fresh insert, violating ES-03
-- ("a duplicate submitted after a platform restart returns the original
-- record").
--
-- Store.append() implements two-phase deduplication (design artefact
-- src/design/event_store.md, Open Question #1 resolution):
--   1. INSERT INTO events … ON CONFLICT (idempotency_key) DO NOTHING RETURNING *
--   2. If no rows returned: SELECT * FROM events_archive WHERE idempotency_key = $1
--   3. If found in archive: return AppendResult{.is_duplicate = true}
--
-- This index enables step 2 to be efficient and enforces uniqueness within
-- the archive table itself (idempotent archival via ON CONFLICT DO NOTHING).

CREATE UNIQUE INDEX IF NOT EXISTS uq_event_archive_idempotency
    ON events_archive(idempotency_key);
