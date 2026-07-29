> **Extends:** ES-07, replacing the row-by-row archival move with a partition lifecycle.

> The `events` and `events_archive` tables SHALL be declared `PARTITION BY RANGE (created_at)` with one partition per calendar month, named `events_YYYY_MM`. Because PostgreSQL requires the partition key to appear in every unique constraint, the primary key SHALL widen from `event_id` to `(event_id, created_at)`. Global `idempotency_key` uniqueness SHALL be preserved by the separate non-partitioned table `plat_event_idempotency (idempotency_key TEXT PRIMARY KEY, event_id UUID, created_at TIMESTAMPTZ)`, written in the same transaction as every append.

**Acceptance Criteria:**
- GIVEN the converted schema, WHEN `events` is inspected, THEN its partition strategy is RANGE on `created_at`, its primary key is `(event_id, created_at)`, and one partition exists for every calendar month covered by the data.
- GIVEN two appends supplying the same `idempotency_key` in different calendar months, WHEN the second is attempted, THEN it is rejected by the primary key of `plat_event_idempotency`; partitioning does not narrow idempotency to a per-month scope.
- GIVEN an append, WHEN it commits, THEN the `events` row and the `plat_event_idempotency` row are written in one transaction; a failure of either rolls back both.
- GIVEN an append whose `created_at` falls in a month with no attached partition, WHEN it executes, THEN it fails with `PartitionMissingForWrite` and a structured error rather than being routed to another partition.
- Every partition of `events` and `events_archive` carries the index `(instance_id, sequence_num)`, so per-partition access preserves the ordering reconstruction depends on.

**See:** ES-07 (the archival requirement this supersedes), ADP-11 (the protected event types), PAR-04 (partition constraints), PAR-05 (the conversion), PAR-06 (reconstruction bounding), DB-01
