> The one-time conversion of an existing `events` table into a partitioned parent SHALL run online. A new parent is created alongside, historical rows are backfilled in `created_at` windows of one calendar month with one transaction per window and `ON CONFLICT (event_id, created_at) DO NOTHING`, and the tables are exchanged by a rename swap inside a single transaction. `plat_event_idempotency` SHALL be created and populated before the swap, so global `idempotency_key` uniqueness is never absent.

**Acceptance Criteria:**
- GIVEN conversion begins, WHEN the parent is created, THEN it is `CREATE TABLE events_part (LIKE events INCLUDING DEFAULTS INCLUDING IDENTITY) PARTITION BY RANGE (created_at)`, and the live `events` table continues to accept appends unchanged.
- GIVEN a month between `min(created_at)` and the lead horizon has no partition, WHEN conversion validates coverage, THEN `PartitionRangeGap` is raised naming the missing month and no backfill starts.
- GIVEN a backfill window is interrupted and re-run, WHEN it repeats, THEN `ON CONFLICT (event_id, created_at) DO NOTHING` absorbs the duplicates and the end state is identical to an uninterrupted run.
- GIVEN the swap transaction, WHEN it runs, THEN it replays the catch-up window since the last backfilled row and issues `ALTER TABLE events RENAME TO events_legacy; ALTER TABLE events_part RENAME TO events;` in one transaction with `lock_timeout = 3s`; a lock timeout rolls the transaction back, leaves both tables intact and readable, and the swap is retried at the next maintenance window.
- GIVEN the swap has committed, WHEN per-month `count(*)` is compared between `events_legacy` and the new partitions, THEN every month matches; a mismatch raises `ConversionRowCountMismatch` and the inverse rename restores the original `events`.
- `events_legacy` is retained read-only for one full `archive_after_months` cycle and then attached to `events_archive`; it is never emptied row by row.

**See:** PAR-01 (the target shape), PAR-03 (how the legacy table finally ages out), PAR-04, DDL-04 (the batched-backfill discipline this reuses)
