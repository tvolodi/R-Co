> **Extends:** ADP-11, giving the deletion prohibition a physical retention mechanism.

> Retention SHALL be partition-scoped. An `events` partition older than `archive_after_months` (default 13) SHALL be aged out by `ALTER TABLE events DETACH PARTITION events_YYYY_MM CONCURRENTLY` followed by `ALTER TABLE events_archive ATTACH PARTITION events_YYYY_MM FOR VALUES FROM ... TO ...`, a catalog operation that moves no rows. Hard deletion by `DROP TABLE` SHALL be confined to partitions of `events_ephemeral`, which holds only event types whose retention class is `delete`. No `DELETE` statement SHALL run against `events` or `events_archive` at any point.

**Acceptance Criteria:**
- GIVEN an event type in the set `{INSTANCE_*, TASK_*, GATEWAY_*, EXECUTION_*}`, WHEN retention class `delete` is configured for it, THEN configuration is rejected with `RetentionClassForbidden` and the type never routes to `events_ephemeral`.
- GIVEN a 14-month-old `events` partition holding 40 million rows, WHEN it ages out, THEN the detach and attach complete without copying a row, and the rows remain readable through `events_archive`.
- GIVEN an `events_ephemeral` partition older than `ephemeral_drop_after_months` (default 3), WHEN a drop is attempted, THEN the guard `SELECT count(*) FROM events_ephemeral_YYYY_MM WHERE split_part(event_type, '_', 1) IN ('INSTANCE', 'TASK', 'GATEWAY', 'EXECUTION')` must return 0 before `DROP TABLE` executes.
- GIVEN that guard returns a non-zero count, WHEN the scheduler evaluates it, THEN `Adp11GuardTripped` is raised as a BLOCKER, the partition stays attached, and no drop occurs.
- GIVEN a detach commits but the archive attach fails, WHEN the failure is recorded, THEN the partition exists standalone in state `ORPHAN_PARTITION`, remains queryable, and the attach is retried on the next maintenance run.
- Detach and drop each append `EXECUTION_PARTITION_DETACHED` or `EXECUTION_PARTITION_DROPPED` to the event log.

**See:** ADP-11 (the deletion prohibition this implements), ES-07 (the retention policy surface), IR-07 (archives remain queryable), PAR-01, PAR-06 (reconstruction spanning both parents)
