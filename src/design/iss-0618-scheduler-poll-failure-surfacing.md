# ISS-0618 / GH-567 — Scheduler `pollDueTimers` skip-locked + transaction-failure surfacing

## Problem (from `tests/integration/sch02_timer_polling_test.zig`)

Two test blocks in the SCH-02 polling test are failing:

### Block 1 — TC-SCH-02-02: skip-locked count is 0
- Test holds `FOR UPDATE` on the timer row in another connection.
- Calls `scheduler.pollDueTimers(allocator)`.
- Expects `skipped_summary.skipped_locked > 0`.
- Actually gets `skipped_summary.skipped_locked == 0` (and `fired == 0`).

### Block 2 — TC-SCH-02-03: forced-failure rollback doesn't surface `TransactionFailed`
- Test pre-seeds `events.idempotency_key = 'timer-fired:<timer_id>'` in
  a separate autocommit INSERT, then calls `scheduler.pollDueTimers(allocator)`.
- Expects `error.SchedulerError.TransactionFailed`.
- Actually gets `{fired: 0, skipped_locked: 0}` — no error surfaced.

## Root cause (both in `src/scheduler/scheduler.zig`)

### Cause 1 — `processNextDueTimer` line 211
```zig
const due_rows = conn.query(a,
    \\SELECT id::text, ... FROM timers
    \\WHERE status = 'pending' AND fires_at <= NOW()
    \\ORDER BY fires_at ASC, id ASC
    \\FOR UPDATE SKIP LOCKED
    \\LIMIT 1
, &.{},) catch return SchedulerError.TransactionFailed;

if (due_rows.rows.len == 0) {
    conn.rollback() catch {};
    return .none;       // BUG: conflates "no due timers" with "all due timers locked"
}
```

PostgreSQL's `FOR UPDATE SKIP LOCKED LIMIT 1` returns 0 rows in **two distinct
scenarios** that this code collapses:

| Scenario | due_rows.len | Correct outcome |
|---|---|---|
| No due timers exist | 0 | `.none` |
| Due timers exist but all are locked | 0 | `.skipped_locked` |

The test for the second scenario fails because the poller reports `.none`.

### Cause 2 — `pollDueTimers` fire-path failure handling line 408
```zig
if (!fire_ok) {
    const err_fields = ...;
    logger.logWithTrace(... "timer fire failed — rolling back and recording error", ...) catch {};
    conn.rollback() catch {};
    handleTimerFireError(allocator, self.pool, ...);
    return .none;       // BUG: swallows the underlying DB error
}
```

When `appendTimerFiredEventInTx` fails (e.g. unique-violation on
`events.idempotency_key`), the poller rolls back the tx, records the
failure via `handleTimerFireError`, and reports a normal zero-work
summary. The test expects `SchedulerError.TransactionFailed` so the
caller can detect that something went wrong.

## Fix

### Fix 1: Distinguish "no due timers" from "all due timers locked"

Use a non-locking probe query **before** the FOR UPDATE query to detect
which case applies:

```zig
const probe_rows = conn.query(a,
    \\SELECT EXISTS (
    \\  SELECT 1 FROM timers
    \\  WHERE status = 'pending' AND fires_at <= NOW()
    \\) AS has_due
, &.{},) catch return SchedulerError.TransactionFailed;
defer { var r = probe_rows; r.deinit(); }

if (probe_rows.rows.len == 0)
    return SchedulerError.TransactionFailed;

const has_due = std.mem.eql(u8, colGet(probe_rows.rows[0], 0), "t");

const due_rows = conn.query(a,
    \\SELECT id::text, ... FROM timers
    \\WHERE status = 'pending' AND fires_at <= NOW()
    \\ORDER BY fires_at ASC, id ASC
    \\FOR UPDATE SKIP LOCKED
    \\LIMIT 1
, &.{},) catch return SchedulerError.TransactionFailed;
defer { var r = due_rows; r.deinit(); }

if (due_rows.rows.len == 0) {
    conn.rollback() catch {};
    return if (has_due) .skipped_locked else .none;
}
```

**Race semantics**: A timer added between probe and FOR UPDATE causes
the poller to report `.skipped_locked` instead of `.fired` next time
it runs (benign — caller retries on next cycle). A timer cancelled
between probe and FOR UPDATE causes `.skipped_locked` to be reported
when no rows are actually locked (cosmetic only — counters are advisory).

The probe does NOT hold a row lock and is therefore safe under MVCC.

### Fix 2: Surface forced-failure as `SchedulerError.TransactionFailed`

After `handleTimerFireError(...)` records the failure for retry/DLQ,
return the error so the caller learns that the fire path failed:

```zig
if (!fire_ok) {
    const err_fields = ...;
    logger.logWithTrace(... "timer fire failed — rolling back and recording error", ...) catch {};
    conn.rollback() catch {};
    handleTimerFireError(allocator, self.pool,
        self.config.max_timer_fire_retries,
        timer_id_text, instance_id_text, payload_json);
    return SchedulerError.TransactionFailed;   // was: .none
}
```

`handleTimerFireError` still increments `fire_error_count` and DLQs
after `max_timer_fire_retries`, so the retry/DLQ path is preserved.
The only change is that the **poll cycle caller** is now told that
the timer fire failed, instead of being misled by a clean zero-work
summary.

## Risk analysis

1. **`pollDueTimers` callers**: only in `tests/integration/` (verified
   via `grep -r '\.pollDueTimers(' src tests` — no production callers
   in this repo). Of 39 callers, 6 already use `catch {}` (silent) and
   most use `try` against healthy happy-path tests.

2. **Behaviour change for previously-passing tests**: A test that
   accidentally relied on the silent-swallow behaviour would now fail.
   From the history of `git log -- tests/integration/sch02_timer_polling_test.zig`
   and `tests/integration/sch303_timer_dlq_test.zig`, every test using
   `try` is on the happy path (no pre-seeded collisions, no concurrent
   locks), so it will not be affected. The DLQ test at line 473 uses
   `catch |err|` explicitly to inspect errors.

3. **Performance**: One additional read-only query (`EXISTS ...`) per
   poll cycle. The probe is a single-row index lookup against
   `idx_timers_due` (status + fires_at). Negligible overhead.

4. **Backwards compatibility**: The `SchedulerError.TransactionFailed`
   variant already exists; the public API signature is unchanged.
   The `PollSummary` shape is unchanged. The `PollOutcome` enum is
   unchanged.

## Acceptance criteria

1. `TC-SCH-02-02`: `skipped_locked > 0` after a concurrent `FOR UPDATE`
   lock is held on the timer row.
2. `TC-SCH-02-03`: `pollDueTimers` returns `SchedulerError.TransactionFailed`
   after a pre-seeded `events.idempotency_key` collision; the timer
   remains `pending` (transaction rolled back); `handleTimerFireError`
   increments `fire_error_count`.
3. All other scheduler tests (TC-SCH-02-01, TC-SCH-03-01..04, TC-EXP-103-03,
   TC-SCH-303-*) continue to pass.
4. `zig build` exits 0; `python3 tools/lint_sql_param_types.py src tests`
   exits 0; the 2 target tests pass.

## Test coverage added

No new tests. The existing TC-SCH-02-02 and TC-SCH-02-03 already
encode the desired behaviour — they were the failing tests that
filed this issue.