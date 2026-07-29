# Process: Event Log Partition Lifecycle

| Field | Value |
|-------|-------|
| Process ID | `sys-event-log-partitioning` |
| Platform Workflow | PW-06 |
| Requirements | PAR-01, PAR-02, PAR-03, PAR-04, PAR-05, PAR-06 |
| Owner | Platform Admin |
| Scope | System-wide (the `events` table in every tenant schema) |
| Source | `docs/workflows.yaml` (PW-06) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §2.3 |

## Summary

Replaces the row-by-row single-transaction archival of ES-07 with a partition
lifecycle. `events` is declared `PARTITION BY RANGE (created_at)` with one
partition per calendar month. The scheduler creates next month's partition ahead
of need. Ageing out an ADP-11-protected month is `DETACH PARTITION` from `events`
followed by `ATTACH PARTITION` to `events_archive` -- a catalog operation that
moves no rows. Hard deletion by `DROP TABLE` is permitted only for partitions of
`events_ephemeral`, which holds event types whose retention class is deletion and
which never holds an `INSTANCE_*`, `TASK_*`, `GATEWAY_*` or `EXECUTION_*` row.
All partition DDL passes through `ValidatePlatformDDL` (PW-05) before execution.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Scheduler | System (`plat_partition_maintenance` job) | Creates future partitions, detaches aged partitions, drops ephemeral partitions |
| Migration Runner | System | Executes the one-time conversion of the existing `events` table |
| Event Store | System | Routes each append to `events` or `events_ephemeral` by retention class |
| Reconstruction Reader | System (EE-11) | Rebuilds instance state; supplies the time predicate that enables pruning |
| Platform Admin | Human operator | Sets retention windows; receives escalations |
| PostgreSQL | Database | Enforces partition constraints and performs partition pruning |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `partition_granularity` | enum | Fixed value `month`; not operator-configurable |
| `lead_months` | integer | Default 2; the scheduler keeps this many future partitions attached |
| `archive_after_months` | integer | Default 13; partition age at which detach-and-reattach runs |
| `ephemeral_drop_after_months` | integer | Default 3; partition age at which `DROP TABLE` runs |
| `retention_class` | enum | Per event type: `retain_forever`, `archive_queryable`, or `delete`; `delete` is refused for ADP-11 types |
| `instances.first_event_at` | timestamptz | Maintained in the same transaction as the first append for that instance |
| `instances.last_event_at` | timestamptz | Maintained in the same transaction as every append for that instance |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | Migration Runner | Create the parent alongside: `CREATE TABLE events_part (LIKE events INCLUDING DEFAULTS INCLUDING IDENTITY) PARTITION BY RANGE (created_at);` | Parent created? | -> `PartitionParentCreateFailed`; conversion aborts, `events` untouched | PAR-01 |
| 2 | Migration Runner | Widen the keys: primary key becomes `(event_id, created_at)`; the global `idempotency_key` uniqueness moves to the non-partitioned table `plat_event_idempotency (idempotency_key TEXT PRIMARY KEY, event_id UUID, created_at TIMESTAMPTZ)`, written in the same transaction as every append | Global idempotency uniqueness preserved? | -> `IdempotencyScopeLost`; conversion aborts | PAR-01 |
| 3 | Migration Runner | Create one partition per month from `min(created_at)` through `lead_months` ahead, each with `CHECK (tenant_id IS NOT NULL)` declared at creation | Every month in range covered without a gap? | -> `PartitionRangeGap` naming the missing month; conversion aborts | PAR-04 |
| 4 | Migration Runner | Backfill in `created_at` windows of one month, one transaction per window, `INSERT INTO events_part SELECT * FROM events WHERE created_at >= $1 AND created_at < $2 ON CONFLICT (event_id, created_at) DO NOTHING` | Window interrupted or process restarts? | -> Re-run repeats the window; `ON CONFLICT DO NOTHING` makes it idempotent | PAR-05 |
| 5 | Migration Runner | Take `ACCESS EXCLUSIVE` on both tables, replay the catch-up window since the last backfilled row, then `ALTER TABLE events RENAME TO events_legacy; ALTER TABLE events_part RENAME TO events;` in one transaction | Swap transaction commits within `lock_timeout = 3s`? | -> Transaction rolls back; both tables intact; swap retried at the next maintenance window | PAR-05 |
| 6 | Migration Runner | Verify `count(*)` per month matches between `events_legacy` and the new partitions | Counts equal for every month? | -> `ConversionRowCountMismatch`; swap reverted by the inverse rename | PAR-05 |
| 7 | Event Store | Route each append by the event type's retention class: `retain_forever` and `archive_queryable` -> `events`; `delete` -> `events_ephemeral` | Event type is `INSTANCE_*`, `TASK_*`, `GATEWAY_*` or `EXECUTION_*` with class `delete`? | -> `RetentionClassForbidden` at configuration time (ADP-11); the append never reaches `events_ephemeral` | PAR-03 |
| 8 | Scheduler | Run `plat_partition_maintenance` daily at 00:15 UTC | Partitions exist covering every month through `lead_months` ahead? | -> Create the missing months now, before any writer needs them | PAR-02 |
| 9 | Scheduler | Create a future partition: `CREATE TABLE events_YYYY_MM (LIKE events INCLUDING DEFAULTS, CHECK (tenant_id IS NOT NULL), CHECK (created_at >= 'YYYY-MM-01' AND created_at < 'YYYY-(MM+1)-01'));` then `ALTER TABLE events ATTACH PARTITION events_YYYY_MM FOR VALUES FROM ... TO ...;` | Partition already exists and is attached? | -> Step is a no-op; the job is idempotent and safe to run twice in one day | PAR-02 |
| 10 | Scheduler | Confirm the attach took `SHARE UPDATE EXCLUSIVE` and not `ACCESS EXCLUSIVE` | Matching range and `tenant_id IS NOT NULL` CHECK present before attach? | -> Without them PostgreSQL scans the partition under a stronger lock; missing CHECK is `AttachScanRequired` and the attach is refused | PAR-04 |
| 11 | Scheduler | Age out an ADP-11-protected month older than `archive_after_months`: `ALTER TABLE events DETACH PARTITION events_YYYY_MM CONCURRENTLY;` then `ALTER TABLE events_archive ATTACH PARTITION events_YYYY_MM FOR VALUES FROM ... TO ...;` | Both statements commit? | -> Rows are archived with no row movement; a failed attach leaves the partition detached and standalone, recorded `ORPHAN_PARTITION` | PAR-03 |
| 12 | Scheduler | Drop an ephemeral partition older than `ephemeral_drop_after_months`, after the pre-drop guard `SELECT count(*) FROM events_ephemeral_YYYY_MM WHERE split_part(event_type, '_', 1) IN ('INSTANCE', 'TASK', 'GATEWAY', 'EXECUTION')` | Guard returns 0? | -> `DROP TABLE events_ephemeral_YYYY_MM;` executes. Non-zero -> `Adp11GuardTripped`; no drop; escalate | PAR-03 |
| 13 | Reconstruction Reader | Build the reconstruction query with a time predicate: `SELECT * FROM events WHERE instance_id = $1 AND created_at >= $2 AND created_at < $3 ORDER BY sequence_num;` where `$2` and `$3` come from `instances.first_event_at` and `instances.last_event_at + 1 microsecond` | Predicate present? | -> Planner prunes to the partitions spanning the instance lifetime | PAR-06 |
| 14 | Reconstruction Reader | Union the archive when the instance lifetime crosses `archive_after_months`: same predicate against `events_archive` | Lifetime window overlaps an archived month? | -> Both branches read and merged by `sequence_num`; result is identical to pre-archival reconstruction (ES-07, EE-11) | PAR-06 |
| 15 | Reconstruction Reader | Refuse a reconstruction issued without a time predicate | `first_event_at` or `last_event_at` is NULL on the instance row? | -> `ReconstructionWindowMissing`; the projection row is repaired from the event log before the query is retried | PAR-06 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Partition key | `events` and `events_archive` are `PARTITION BY RANGE (created_at)`, one partition per calendar month, named `events_YYYY_MM`. |
| Key widening is mandatory | The partition key must appear in every unique constraint, so the primary key becomes `(event_id, created_at)`. Global `idempotency_key` uniqueness survives in `plat_event_idempotency`, written in the same transaction as the append. |
| Partition-level CHECK | Every partition carries `CHECK (tenant_id IS NOT NULL)` and a CHECK matching its range, declared before `ATTACH PARTITION`. This lets the attach take `SHARE UPDATE EXCLUSIVE` and validate from the catalog instead of scanning. |
| Partitions exist before writers need them | The scheduler keeps `lead_months` future partitions attached at all times. A write is never the event that creates a partition. |
| ADP-11 retention | Types matching `INSTANCE_*`, `TASK_*`, `GATEWAY_*`, `EXECUTION_*` are refused the `delete` retention class at configuration time. They can only be `retain_forever` or `archive_queryable`. |
| Archival moves no rows | Ageing out a protected month is `DETACH PARTITION CONCURRENTLY` followed by `ATTACH PARTITION` to `events_archive`. It is a catalog operation. ES-07's single-transaction row move is retired. |
| Deletion is partition-scoped | Hard deletion is `DROP TABLE` of an `events_ephemeral` partition. No `DELETE` statement runs against `events` or `events_archive` at any point in this process. |
| Pre-drop guard | Every `DROP TABLE` is preceded by a count of ADP-11-protected rows in that partition. A non-zero count blocks the drop and escalates. |
| Pruning needs a time predicate | Partition pruning is driven by `created_at`; reconstruction identifies work by `instance_id`. **The platform resolves this by adding the time predicate, not by accepting per-partition index fan-out.** `instances.first_event_at` and `instances.last_event_at` are maintained in the same transaction as each append, and every reconstruction query is bounded by that window. |
| Fan-out is rejected as the resolution | Keeping `idx_events_instance_seq` on every partition and letting the planner probe all of them costs one index descent per partition per reconstruction. At 13 attached months plus archive that is 13 probes where the bounded query performs one or two. The bounded query is the only supported form. |
| Conversion is online | The one-time conversion runs parent-alongside, backfills in month windows, and swaps by rename inside one transaction holding `ACCESS EXCLUSIVE` for the duration of two catalog updates. |
| Legacy table retention | `events_legacy` is kept read-only for one full `archive_after_months` cycle, then attached to `events_archive` or dropped by the ephemeral rule, never deleted row by row. |
| PW-05 applies | Every statement in this process is submitted to `ValidatePlatformDDL` first. `DETACH PARTITION CONCURRENTLY` and `ATTACH PARTITION` are accepted classes; a `CREATE INDEX` on a partition must be `CONCURRENTLY`. |

---

## Outputs

| Output | Description |
|--------|-------------|
| `events` | Range-partitioned parent with `lead_months` future partitions always attached |
| `events_archive` | Range-partitioned parent holding detached-and-reattached historical months |
| `events_ephemeral` | Range-partitioned parent for `delete`-class types only; source of every `DROP TABLE` |
| `plat_event_idempotency` | Non-partitioned table preserving global `idempotency_key` uniqueness |
| `plat_partition_catalog` | One row per partition: table, range bounds, attached parent, row count, state |
| `instances.first_event_at` / `last_event_at` | The reconstruction window, maintained per append |
| Audit event | `EXECUTION_PARTITION_CREATED`, `EXECUTION_PARTITION_DETACHED`, `EXECUTION_PARTITION_DROPPED` appended to the event log |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| Maintenance cadence | `plat_partition_maintenance` runs daily at 00:15 UTC in every tenant schema |
| Lead time | At least 2 future monthly partitions attached at all times; falling to 1 raises a WARN, falling to 0 raises a BLOCKER before any write can fail |
| Attach duration | `ATTACH PARTITION` with matching CHECKs completes in under 50 ms; exceeding 1 s indicates a missing CHECK and raises `AttachScanRequired` |
| Detach duration | `DETACH PARTITION CONCURRENTLY` waits for concurrent transactions; exceeding 300 s escalates to Platform Admin without cancelling |
| Conversion swap | The rename swap runs with `lock_timeout = 3s`; a timeout rolls back and the swap is retried at the next maintenance window |
| Reconstruction latency | A bounded reconstruction over a single-month instance lifetime returns within the platform read NFR of 200 ms |
| Guard trip | `Adp11GuardTripped` is a BLOCKER: the drop is abandoned, the partition stays attached, and Platform Admin is paged |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| `PartitionParentCreateFailed` | Parent-alongside creation fails during conversion | Conversion aborts before any backfill; `events` is untouched; fix and rerun |
| `IdempotencyScopeLost` | Key widening would drop global `idempotency_key` uniqueness | Conversion aborts; `plat_event_idempotency` is created first, then conversion reruns |
| `PartitionRangeGap` | A month between `min(created_at)` and the lead horizon has no partition | Create the missing month, rerun conversion from step 3 |
| `ConversionRowCountMismatch` | Per-month counts differ between legacy and partitioned tables | Inverse rename restores `events`; the mismatched window is re-backfilled and the swap retried |
| `AttachScanRequired` | Partition lacks the range CHECK or `CHECK (tenant_id IS NOT NULL)` before attach | Attach refused; add both CHECKs to the standalone partition, then attach |
| `RetentionClassForbidden` | `delete` retention configured for an ADP-11-protected event type | Configuration rejected with a structured error; choose `retain_forever` or `archive_queryable` |
| `Adp11GuardTripped` | Pre-drop guard finds protected rows in an ephemeral partition | Drop abandoned; the routing rule that placed protected rows there is fixed; rows are moved to `events` before any retry |
| `ORPHAN_PARTITION` | Detach committed but the archive attach failed | Partition exists standalone and remains queryable; maintenance retries the attach on the next run |
| `PartitionMissingForWrite` | An append arrives for a month with no attached partition | Append fails with a structured error; maintenance creates the month immediately; the lead-time alarm has already fired |
| `ReconstructionWindowMissing` | `first_event_at` or `last_event_at` is NULL for the instance | Projection row repaired by scanning the event log once for that instance; the bounded query is then retried |
| `DetachTimeout` | `DETACH PARTITION CONCURRENTLY` blocked past 300 s | Escalated without cancellation; the partition stays attached and archival is retried next run |
