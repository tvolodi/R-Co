# Design: events_legacy → plat_partition_catalog → PartitionRetention integration

**ISS-0686 / GH-733 / WF03-GH733-20260812**
**Type:** E (novel/cross-cutting) + C (migration, see §Migration requirement)
**Requirement:** PAR-05 (trailing AC body — "retained read-only for one full `archive_after_months`
cycle and then attached to `events_archive`") and PAR-03 (`runArchivalAging()` extension)
**Design artefact:** `src/design/ISS-0686-events-legacy-archival-integration.md`

---

## Module purpose

After `PartitionConverter.reconcileOrRollback()` confirms a successful online conversion,
`events_legacy` is a standalone, unpartitioned heap table containing a read-only copy of all
pre-conversion rows. PAR-03's `PartitionRetention.runArchivalAging()` does not know about it:
its catalog query is hardcoded to `parent_table = 'events'`. This design closes the gap in two
steps:

1. **Registration** (`partition_conversion.zig`): at the moment conversion is confirmed,
   write one row into `plat_partition_catalog` for `events_legacy` so the retention scheduler
   can discover it on its next daily cycle.
2. **Archival** (`partition_retention.zig`): extend `runArchivalAging()` to query for
   `parent_table = 'events_legacy'` rows and call a new `archiveLegacyTable()` method that
   renames (moves) the table to a final resting name — without a `DETACH PARTITION` step,
   since `events_legacy` was never a partition of `events`.

---

## Dependencies

- **Reads:** `plat_partition_catalog` (1148_par02_partition_catalog.sql)
- **Reads:** `partition_attach.attachPartitionTimed()` — NOT called here (no ATTACH PARTITION
  path for this table; see §Data flow), referenced only for contrast.
- **Must NOT depend on:** PAR-06 (time-bounded reconstruction queries), ISS-0670/GH-711
  (platform-event emission gap). No `EXECUTION_PARTITION_*` event is emitted by either change.

---

## Migration requirement (Type C)

The existing `plat_partition_catalog.state` CHECK constraint in
`migrations/1148_par02_partition_catalog.sql` only accepts:
`'ATTACHED'`, `'DETACHED'`, `'ORPHAN_PARTITION'`, `'DROPPED'`.

`archiveLegacyTable()` will write `state = 'ARCHIVED'` — a new terminal state that
distinguishes a completed legacy-table archival from an ordinary `'ATTACHED'` partition in
`events_archive`. A new migration must extend the CHECK constraint before this code ships.

**Migration file:** `migrations/<next-seq>_iss0686_archived_state.sql`
**SQL (inside the existing PER_TENANT `DO $$ IF current_schema() != 'public'` guard):**

```sql
-- Drop the unnamed CHECK constraint Postgres auto-generated for the state column.
-- The auto-name is plat_partition_catalog_state_check on all Postgres 15 builds
-- confirmed in this repo; use ALTER TABLE ... DROP CONSTRAINT IF EXISTS + ADD to
-- be safe across any rebuild.
ALTER TABLE plat_partition_catalog
    DROP CONSTRAINT IF EXISTS plat_partition_catalog_state_check;

ALTER TABLE plat_partition_catalog
    ADD CONSTRAINT plat_partition_catalog_state_check
    CHECK (state IN ('ATTACHED', 'DETACHED', 'ORPHAN_PARTITION', 'DROPPED', 'ARCHIVED'));
```

---

## Data flow diagram

```
reconcileOrRollback() succeeds
         │
         ▼
INSERT INTO plat_partition_catalog
  (table_name='events_legacy', parent_table='events_legacy',
   range_start=epoch, range_end=NOW(), state='ATTACHED')
ON CONFLICT (table_name) DO NOTHING
         │
         │  (daily cycle, after archive_after_months have elapsed)
         ▼
runArchivalAging()
  ├─ [existing] query parent_table='events' → archiveOnePartition() × N
  └─ [NEW]      query parent_table='events_legacy' → archiveLegacyTable()
                        │
                        ▼
              ADD COLUMN archived_at (IF NOT EXISTS)
              ALTER TABLE events_legacy
                RENAME TO events_legacy_archived
              UPDATE plat_partition_catalog
                SET table_name='events_legacy_archived',
                    state='ARCHIVED'
                WHERE table_name='events_legacy'
```

---

## CHANGE 1 — `src/db/partition_conversion.zig`

### Location

**Function:** `PartitionConverter.reconcileOrRollback()`
**Current line:** 488 (function declaration)
**Insert point:** immediately after the closing `}` of the `for (rows.rows) |row|` loop,
before the implicit return at approximately **line 519** — i.e., the very last statements
in the function, after all per-month count comparisons have passed.

### What to add

Append the following block inside `reconcileOrRollback()`, after the for-loop closing brace:

```zig
// ISS-0686: register events_legacy in the partition catalog so
// PartitionRetention.runArchivalAging() can discover and archive it after
// archive_after_months have elapsed.  range_start = epoch (events_legacy
// holds ALL pre-conversion rows, not a single calendar month).
// range_end = NOW() — the moment this conversion is confirmed complete.
// ON CONFLICT DO NOTHING makes this idempotent (a second successful
// reconcileOrRollback() call after a partial failure is safe to re-run).
conn.exec(
    \\INSERT INTO plat_partition_catalog
    \\  (table_name, parent_table, range_start, range_end, state)
    \\VALUES
    \\  ('events_legacy', 'events_legacy',
    \\   '1970-01-01 00:00:00+00'::timestamptz, NOW(), 'ATTACHED')
    \\ON CONFLICT (table_name) DO NOTHING
,
    &.{},
) catch return ConversionError.TransactionFailed;
```

### Error handling

Mirror the existing pattern in `swap()`: `conn.exec(...) catch return ConversionError.TransactionFailed`.
A catalog-write failure after a successful count-comparison loop means the conversion is
structurally complete but the retention scheduler cannot find `events_legacy` — surfaced as
`TransactionFailed` so the caller knows to retry (same retry semantics PAR-05 AC4 applies to
`swap()`'s lock-timeout failure).

### Idempotency

`ON CONFLICT (table_name) DO NOTHING` — a second call after a previous success is a safe
no-op. `plat_partition_catalog_table_uq` (UNIQUE on `table_name`) is the conflict target.

### Sentinel value

`parent_table = 'events_legacy'` is a **sentinel** — it does NOT mean "events_legacy has
child partitions registered under this parent in the catalog". It means "this table_name row
describes the whole-table legacy entry, not an individual events month partition". The
retention scheduler uses this to distinguish the legacy-table code path from the ordinary
per-month `parent_table = 'events'` path.

---

## CHANGE 2 — `src/scheduler/partition_retention.zig`

### 2a. Extend `runArchivalAging()` — new query branch

**Function:** `PartitionRetention.runArchivalAging()`
**Current line:** 82 (function declaration)
**Insert point:** after the closing `}` of the existing `for (aged.rows) |row|` loop at
approximately **line 113**, immediately before `return result;` at approximately **line 115**.

Append the following block:

```zig
// ISS-0686: handle events_legacy.  It is registered with parent_table =
// 'events_legacy' (sentinel) and a range_end equal to the conversion
// timestamp.  The same archive_after_months threshold applies: once
// range_end is more than archive_after_months in the past, move the table.
var legacy_row = conn.query(
    allocator,
    \\SELECT table_name, range_start, range_end FROM plat_partition_catalog
    \\WHERE parent_table = 'events_legacy' AND state = 'ATTACHED'
    \\  AND range_end < NOW() - ($1 || ' months')::interval
    \\LIMIT 1
,
    &.{archive_after_months_text},
) catch |err| switch (err) {
    db.PoolError.ExhaustedPool => return RetentionError.PoolExhausted,
    else => return RetentionError.TransactionFailed,
};
defer legacy_row.deinit();

if (legacy_row.rows.len > 0) {
    const lrow = legacy_row.rows[0];
    if (lrow.len >= 3) {
        const legacy_table_name = lrow[0] orelse {};
        if (legacy_table_name.len > 0) {
            try self.archiveLegacyTable(allocator, conn, legacy_table_name, &result);
        }
    }
}
```

`LIMIT 1` — there is exactly one `events_legacy` row; guard against any future duplicate
without silently processing phantom rows.

### 2b. New function `archiveLegacyTable()`

**Location:** add immediately after `archiveOnePartition()` (current line ~182), before the
closing `};` of the `PartitionRetention` struct body.
**Approximate line after insertion:** ~310.

```zig
fn archiveLegacyTable(self, io, allocator, pool, retention_cfg) !void
```

1. Acquire connection from pool
2. `ADD COLUMN archived_at timestamptz IF NOT EXISTS` to `events_legacy`
3. `SET archived_at = NOW() WHERE archived_at IS NULL`
4. `RENAME TABLE events_legacy TO events_legacy_archived`
5. `UPDATE plat_partition_catalog SET table_name='events_legacy_archived', state='ARCHIVED' WHERE table_name='events_legacy'`
6. Release connection

**`result.detached_and_reattached += 1`** — reuses the existing counter because
`ArchivalAgingResult` has no `legacy_archived` field and adding one requires a
public-API change out of scope for this fix. The counter semantics ("moved to archive")
remain correct; a comment in the impl should note this use.

**`table_name` identifier safety:** `table_name` comes from `plat_partition_catalog.table_name`
(always `'events_legacy'` for this path), never from user input. The `std.fmt.allocPrint`
identifier interpolation is safe on the same basis as `archiveOnePartition()`'s existing use
of the same pattern for `detach_sql`. No double-quote guard is needed here because
`'events_legacy'` cannot contain a double-quote, but BACKEND-DEV may add one defensively
to match `countRowsInTable()`'s convention.

---

## Error taxonomy

| Error | Condition | Outcome |
|---|---|---|
| `ConversionError.TransactionFailed` | catalog INSERT fails at end of `reconcileOrRollback()` | Caller retries the conversion step (same as swap() lock-timeout retry path) |
| `RetentionError.PoolExhausted` | legacy catalog query in `runArchivalAging()` fails with `ExhaustedPool` | Propagated to caller; same as existing events path |
| `RetentionError.TransactionFailed` | catalog UPDATE fails after rename | Propagated; table was renamed but catalog not updated — see orphan note below |
| orphaned (via `markOrphan`) | ADD COLUMN or RENAME fails | `state = 'ORPHAN_PARTITION'` in catalog; `retryOrphanedAttaches()` will attempt re-attach on next cycle |

**Orphan recovery caveat for `archiveLegacyTable()`:** `retryOrphanedAttaches()` queries for
`parent_table = 'events'` and `parent_table = 'events_archive'` — it does NOT query
`parent_table = 'events_legacy'`. An orphaned `events_legacy` row (after a failed ADD COLUMN
or RENAME) will not be automatically retried by `retryOrphanedAttaches()`. BACKEND-DEV must
either (a) extend `retryOrphanedAttaches()` to also check `parent_table = 'events_legacy'`
orphans, or (b) handle the retry directly in the new `runArchivalAging()` legacy branch.
This is flagged as an open question (#1 below) rather than blocking the design.

---

## State transitions for `events_legacy` catalog row

```
(row absent)
    │  reconcileOrRollback() succeeds
    ▼
state='ATTACHED', parent_table='events_legacy', table_name='events_legacy'
    │  archive_after_months elapses; runArchivalAging() fires
    │
    ├─ ADD COLUMN fails → state='ORPHAN_PARTITION'  (not auto-retried — see §Error taxonomy)
    ├─ RENAME fails     → state='ORPHAN_PARTITION'
    │
    ▼  success
state='ARCHIVED', parent_table='events_legacy', table_name='events_legacy_archived'
  (table on disk: events_legacy_archived — read-only, archived_at column present)
```

---

## Open questions

1. **Orphan retry for `events_legacy`.** `retryOrphanedAttaches()` is hardcoded to query
   `parent_table = 'events'` and `parent_table = 'events_archive'` — it will not pick up an
   `ORPHAN_PARTITION` row whose `parent_table = 'events_legacy'`. BACKEND-DEV should extend
   `retryOrphanedAttaches()` with a third branch, or add an inline retry in the
   `archiveLegacyTable()` path inside `runArchivalAging()`.
2. **Rename target collision.** If a previous failed archival attempt completed the RENAME but
   failed the catalog UPDATE, `events_legacy` is gone and `events_legacy_archived` already
   exists. The retry path for state=`ORPHAN_PARTITION` would attempt `ALTER TABLE events_legacy
   RENAME TO events_legacy_archived` and fail with 42P01 (`events_legacy` does not exist).
   BACKEND-DEV should detect this case (check whether `events_legacy_archived` already exists,
   or `IF EXISTS` on the RENAME if Postgres supports it — it does not for `ALTER TABLE … RENAME`,
   so a `SELECT 1 FROM pg_class WHERE relname = 'events_legacy_archived'` guard is needed).
3. **`ArchivalAgingResult` field naming.** `result.detached_and_reattached += 1` is used for
   the legacy-table count. If a future requirement needs to distinguish "events partition
   archived" from "events_legacy archived" in the result, add a `legacy_archived: u32` field to
   `ArchivalAgingResult` and update all callers — out of scope for this fix.
