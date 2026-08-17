# Design: DDL-04 Backfill Bookkeeping Fix

**Artefact type:** Type E (novel fix — cross-cutting; touches public interface, SQL, and test)
**Issue:** ISS-0716 / GH-814
**Run:** WF03-GH814-20260817
**Affected files:** `src/platform/backfill.zig`, `tests/integration/ddl04_backfill_loop_test.zig`
**Predecessor design:** `src/design/ddl-04-idempotent-batched-backfill.md`

---

## Module purpose

`backfill.zig` executes DDL-04's phase-2 batched backfill loop and records per-batch
progress into `plat_migration_state`. Two bookkeeping invariants are currently violated:

1. The `backfill_batch_size` column in the persisted row always shows the initial default
   (5000) because the live adaptive batch size is never passed to `recordBatchProgress`.
2. The persisted `status` column remains `running` after the loop completes because no
   terminal-status write is made; `runBackfill` returns `BackfillResult.status` (in-memory)
   without flushing `applied`/`failed` to the database.

This design specifies the minimal changes to correct both invariants without altering the
existing batch atomicity guarantee (AC6: progress write commits on the same transaction as
the batch UPDATE).

---

## Public interface changes

### 1. `recordBatchProgress` — add `batch_size` parameter

**Current signature (9 parameters after `conn`):**

```
pub fn recordBatchProgress(
    conn:               anytype,
    migration_id:       []const u8,
    tenant_schema:      []const u8,
    phase:              []const u8,
    rows_updated_total: i64,
    rows_remaining:     i64,
    last_batch_rows:    i64,
    last_batch_ms:      i64,
    stall_count:        u32,
) BackfillError!void
```

**New signature (10 parameters after `conn`) — `batch_size` inserted after `stall_count`:**

```
pub fn recordBatchProgress(
    conn:               anytype,
    migration_id:       []const u8,
    tenant_schema:      []const u8,
    phase:              []const u8,
    rows_updated_total: i64,
    rows_remaining:     i64,
    last_batch_rows:    i64,
    last_batch_ms:      i64,
    stall_count:        u32,
    batch_size:         u32,        ← NEW
) BackfillError!void
```

Rationale: `batch_size` is the live value computed by the adaptive policy in each loop
iteration; it reflects any halving that occurred. Appending it at the end minimises diff
noise at all call sites.

### 2. New function: `recordTerminalStatus`

```
pub fn recordTerminalStatus(
    conn:             anytype,
    migration_id:     []const u8,
    tenant_schema:    []const u8,
    phase:            []const u8,
    final_status:     []const u8,   // "applied" or "failed"
    final_batch_size: u32,
) BackfillError!void
```

This function writes the terminal state after the loop exits. It is called on a **separate
pool connection** (the loop's last connection was already committed and released). No
surrounding transaction is required: the single UPDATE is autocommitted by `conn.exec`.

---

## SQL parameter tables

### `recordBatchProgress` — INSERT/ON CONFLICT UPSERT

| Param | Zig binding     | Column                  | Notes                                      |
|-------|-----------------|-------------------------|--------------------------------------------|
| $1    | migration_id    | migration_id            | unchanged                                  |
| $2    | tenant_schema   | tenant_schema           | unchanged                                  |
| $3    | phase           | phase                   | unchanged                                  |
| $4    | rows_updated_total (text) | rows_updated_total | unchanged                         |
| $5    | rows_remaining (text)    | rows_remaining     | unchanged                         |
| $6    | last_batch_rows (text)   | last_batch_rows    | unchanged                         |
| $7    | last_batch_ms (text)     | last_batch_ms      | unchanged                         |
| $8    | stall_count (text)       | stall_count        | unchanged                         |
| $9    | batch_size (text)        | backfill_batch_size | **new** — replaces literal `5000` |

**INSERT VALUES row (revised):**

```sql
($1, $2, $3, 'running', 1, $9,
 $4, $5, $6, $7, $8,
 now(), now())
```

**ON CONFLICT UPDATE SET (revised):**

Remove: `status = 'running',`  
Add:    `backfill_batch_size = EXCLUDED.backfill_batch_size,`

Rationale: `status` must NOT be reset to `running` on each UPDATE — once
`recordTerminalStatus` writes `applied`/`failed`, a re-entrant `recordBatchProgress`
(impossible in the current loop but defensive) must not clobber it. The INSERT already
writes `'running'` for the first-batch row; subsequent batches should not touch `status`
at all.

Full revised ON CONFLICT UPDATE SET clause:

```sql
ON CONFLICT (migration_id, tenant_schema, phase) DO UPDATE SET
  backfill_batch_size    = EXCLUDED.backfill_batch_size,
  rows_updated_total     = EXCLUDED.rows_updated_total,
  rows_remaining         = EXCLUDED.rows_remaining,
  last_batch_rows        = EXCLUDED.last_batch_rows,
  last_batch_ms          = EXCLUDED.last_batch_ms,
  stall_count            = EXCLUDED.stall_count,
  updated_at             = now()
```

### `recordTerminalStatus` — UPDATE

| Param | Zig binding           | Column              | Notes                        |
|-------|-----------------------|---------------------|------------------------------|
| $1    | migration_id          | migration_id        | WHERE clause anchor          |
| $2    | tenant_schema         | tenant_schema       | WHERE clause anchor          |
| $3    | phase                 | phase               | WHERE clause anchor          |
| $4    | final_status (text)   | status              | `"applied"` or `"failed"`    |
| $5    | final_batch_size (text) | backfill_batch_size | final adaptive value       |

**SQL:**

```sql
UPDATE plat_migration_state
SET    status               = $4,
       backfill_batch_size  = $5,
       updated_at           = now()
WHERE  migration_id   = $1
  AND  tenant_schema  = $2
  AND  phase          = $3
```

Note: `backfill_batch_size` is also written here (redundant with the last
`recordBatchProgress` call) to guarantee the correct value is persisted even if the loop
exits on the zero-rows-remaining break before the AC4 policy reduces the size.

---

## Data flow

```
runBackfill()
  │
  ├─ validateGeneratedBackfill()         [pure guard — no DB]
  │
  └─ while (true)
       │
       ├─ pool.acquire()                 [per-batch connection]
       ├─ conn.begin()
       ├─ SET LOCAL lock/statement timeout
       ├─ conn.query(batch_sql)          [UPDATE ... RETURNING ctid]
       ├─ conn.query(remaining_sql)      [SELECT count IS NULL]
       ├─ recordBatchProgress(conn, ..., batch_size)  ← batch_size now passed
       ├─ conn.commit()
       └─ pool.release(conn)            [via defer]
         │
         ├─ break on rows_remaining == 0 (success)
         └─ break on stall_count >= threshold (stall → stalled=true)
  │
  ├─ pool.acquire()                      [terminal-status connection]
  ├─ recordTerminalStatus(conn, ...,
  │    if (stalled) "failed" else "applied",
  │    final_batch_size)                 ← NEW call site
  └─ pool.release(conn)
  │
  └─ return BackfillResult{ .status = if (stalled) .failed else .applied, ... }
```

---

## Call site in `runBackfill`

**Location:** between the closing `}` of the `while (true)` loop and the
`return BackfillResult{...}` statement (currently at the function's last lines).

**Prose specification:**

1. Acquire a fresh connection: `const term_conn = pool.acquire() catch return error.PoolExhausted;`
2. Defer release: `defer pool.release(term_conn);`
3. Call `recordTerminalStatus` with:
   - `term_conn`
   - `backfill.migration_id`, `backfill.tenant_schema`, `"backfill"` (phase constant, same as loop)
   - `final_status`: the string `"failed"` if `stalled` is `true`, otherwise `"applied"`
   - `final_batch_size`: the `final_batch_size` variable accumulated in the loop
4. Propagate the error upward with `try`.

The `return BackfillResult{...}` statement is unchanged; it follows immediately after.

**Error semantics:** A failure in `recordTerminalStatus` returns `error.PersistenceFailed`
to the caller, same as any other persistence step. The batch data itself is already
committed; only the terminal-status row is missing. This is acceptable: the caller
(migration runner) already handles `BackfillError` uniformly.

---

## Error taxonomy (no additions)

All errors produced by this fix are existing members of `BackfillError`:

| Error              | Condition                                              |
|--------------------|--------------------------------------------------------|
| `PersistenceFailed`| `recordBatchProgress` exec failure (line 379 SQL change stays in `conn.exec`) |
| `PersistenceFailed`| `recordTerminalStatus` exec failure or UPDATE affects 0 rows |
| `PoolExhausted`    | `pool.acquire()` for the terminal-status write fails  |
| `OutOfMemory`      | `allocPrint` for the new `$9` batch_size_text binding in `recordBatchProgress` |

---

## State transitions in `plat_migration_state`

```
[row absent]
     │
     │  first batch — INSERT
     ▼
  status = 'running'
  backfill_batch_size = <initial batch size>  ← was always 5000, now correct
     │
     │  subsequent batches — ON CONFLICT UPDATE (no status change)
     ▼
  status = 'running'
  backfill_batch_size = <last batch size>     ← updated per-batch
     │
     │  loop exits (success or stall)
     │  recordTerminalStatus UPDATE
     ▼
  status = 'applied' | 'failed'               ← was never written, now written
  backfill_batch_size = <final adaptive size>
```

---

## Dependencies

- **Depends on:** `pool_mod.Pool` (for terminal-status connection), `std.fmt` (for
  `batch_size` text serialisation), `std.heap.page_allocator` (existing pattern in
  `recordBatchProgress`).
- **Must NOT depend on:** any `DdlStep` machinery; `backfill.zig` is explicitly excluded
  from the `migration_fanout.zig` transaction contract (see module doc-comment).
- **Callers of `recordBatchProgress`:** exactly one call site in `runBackfill` at line ~284.
  Update the call to pass the live `batch_size` as the new 10th argument.

---

## Test changes — TC-DDL-04-AC6

**File:** `tests/integration/ddl04_backfill_loop_test.zig`
**Test name:** `TC-DDL-04-AC6-loop-records-progress`

### Query change

Add `backfill_batch_size::text` to the SELECT column list to assert the adaptive value is
persisted. The query changes from 5 columns to 6:

```sql
SELECT rows_updated_total::text, rows_remaining::text, last_batch_rows::text,
       last_batch_ms::text, status, backfill_batch_size::text
FROM plat_migration_state
WHERE migration_id = $1 AND tenant_schema = 'tenant_default' AND phase = 'backfill'
```

### Assertion changes

| Current assertion                                    | Revised assertion                                     |
|------------------------------------------------------|-------------------------------------------------------|
| `expectEqualStrings("running", row[4] orelse "")`    | `expectEqualStrings("applied", row[4] orelse "")`     |
| *(absent)* `backfill_batch_size` assertion           | `expectEqual(row.len >= 6, true)` then assert `row[5]` equals the expected final batch size (e.g. `"5000"` if no adaptive halving occurred in the 12000-row fixture, or the halved value if the fixture triggers AC4) |

**Remove:** the NOTE comment block that documents the divergence as an accepted discrepancy:

```zig
// NOTE: the implementation leaves status = 'running' after the loop (the
// design's applied/failed terminal transition is not written) — asserted
// here as the actual behaviour; reported as a MINOR discrepancy.
```

**Stall path (new assertion in the stall test, if one exists):** any test that exercises
the `stalled = true` exit path should assert `status = 'failed'` on the persisted row.

---

## Open questions

None. The root cause is fully diagnosed in ISS-0716 with exact line references.
The fix is localised to two functions and one call site. No requirement ambiguity.

---

## Artefact type classification

| Type | Applicable? | Reason |
|------|-------------|--------|
| A (CRUD endpoint) | No | No HTTP surface changed |
| B (Admin list page) | No | No UI surface changed |
| C (Migration + test) | No | No schema change; `plat_migration_state` already has `backfill_batch_size` and `status` columns with the correct types |
| D (React Flow node) | No | Backend only |
| **E (Novel/cross-cutting)** | **Yes** | Interface change to a public function; new public function; SQL rewrite; test assertion update |
