# ISS-0618 — Scheduler: lock-collision signaling and constraint-failure propagation

Covers: ISS-0618

Related: GH #567, ISS-303 (original fire-path error-swallowing design, `src/design/scheduler-concurrency-epic3.md`)

## Module purpose

`src/scheduler/scheduler.zig`'s `Scheduler.processNextDueTimer` (private method, called once
per iteration of `pollDueTimers`'s poll loop) claims the next due timer row, fires it inside a
transaction, and reports one of three `PollOutcome` values (`fired`, `skipped_locked`, `none`)
back to the caller. Two reporting gaps exist in the non-escalation ("ordinary timer") branch of
this function:

1. A due-but-currently-locked timer is reported identically to "no due timer exists" — both
   collapse to `.none`. Only the `human_task_escalation` branch (a different query, against
   `tasks`, not `timers`) currently distinguishes the two.
2. A genuine, non-retryable database error inside the fire transaction (e.g. a unique-constraint
   violation on `events.idempotency_key`) is unconditionally swallowed by the `fire_blk` labeled
   block's `catch break :fire_blk false`, then routed through `handleTimerFireError` (itself
   fully error-swallowing by design) and reported as a plain `.none` — indistinguishable from
   "nothing to do this cycle." `SchedulerError.TransactionFailed` exists and is used elsewhere in
   this file, but this call path can never produce it.

This design closes both gaps without disturbing the retry/DLQ machinery ISS-303 built around the
`fire_blk` catch-all, which this document traces in detail below before proposing changes.

## What ISS-303 actually protects (read before implementing)

`src/design/scheduler-concurrency-epic3.md` (the ISS-301/302/303 design) and the current
`fire_blk` comment ("ISS-303: Wrap the entire fire path in a labeled block so any failure can be
caught, the transaction rolled back, and the error count incremented without propagating errors
that inflate skipped_locked/fired counters") describe a **retry-accounting contract**, not a
"never surface an error" contract:

- `handleTimerFireError` runs a *separate* transaction (Tx2) that increments
  `timers.fire_error_count` after every failed fire attempt, and — once the count reaches
  `max_timer_fire_retries` — a third transaction (Tx3) that moves the timer to `FAILED` and
  writes a `dead_letter_items` row. Both steps require the *poll loop to keep running* across
  multiple `pollDueTimers` calls so the count can climb from 0 to `max_timer_fire_retries`.
- `tests/integration/sch303_timer_dlq_test.zig`'s `TC-SCH-303-03` and `TC-SCH-303-04` are the
  tests that pin this contract down. Both fixtures pre-insert a row with the exact
  `timer-fired:<timer_id>` idempotency key the scheduler will construct — the *same trigger
  ISS-0618/TC-SCH-02-03 uses* — and then call `scheduler.pollDueTimers(allocator) catch {}` in a
  loop (2 or 3 iterations), asserting on `timers.fire_error_count` / `status` /
  `dead_letter_items` afterward. They explicitly discard whatever `pollDueTimers` returns
  (`catch {}`) and only care about the accumulated DB side effects across repeated polls.
- If `processNextDueTimer` were changed to unconditionally propagate every error out of
  `fire_blk` (naively undoing ISS-303), `pollDueTimers`'s `try self.processNextDueTimer(...)` at
  line 142 would return the error immediately on the *first* failure, the `while` loop would
  never run a second or third iteration, `fire_error_count` would never reach
  `max_timer_fire_retries`, and TC-SCH-303-03/04 would regress: the timer would never reach
  `FAILED`, and no DLQ entry would ever be written. That is the exact bug ISS-303 fixed
  originally (an earlier, unguarded version of this path let one bad fire attempt propagate and
  stop the whole poll cycle rather than being retried and eventually DLQ'd).

**The correct fix therefore is not "stop catching errors in `fire_blk`."** It is: keep catching
and routing to `handleTimerFireError` for the retryable case exactly as today, but make the ONE
call site whose failure the test suite needs to observe as a hard signal — the
`appendTimerFiredEventInTx` unique-constraint violation — distinguishable from the other
`fire_blk` call sites, and have `.none` -mapped return value at that one site replaced with a
propagated `SchedulerError.TransactionFailed`, while every other `fire_blk` failure (parse
errors, `now_rows` query failures, recurrence computation failures, DB errors from
`markTimerFiredInTx` / `insertRecurringPendingTimerInTx`) continues to be caught, rolled back, and
routed to `handleTimerFireError` exactly as today.

This is safe for TC-SCH-303-03/04 because those tests' fixture uses `scheduled_transition` timers
whose fire path also goes through `appendTimerFiredEventInTx` with a colliding idempotency key —
**the same call site TC-SCH-02-03 exercises**. This looks like a conflict but is not: see
"Reconciling with TC-SCH-303-03/04" below — the resolution is that the retry/DLQ tests must stop
relying on swallowing an error they no longer need to swallow, because `pollDueTimers`'s caller in
that test already wraps every call in `catch {}`. No test file changes are needed to the
assertions themselves, only to how many `catch {}` calls tolerate the new error — which they
already do, since they already ignore the return value.

## Fix 1 — TC-SCH-02-02: distinguish "no due timer" from "due timer, locked"

### Mechanism: pre-check with a lock-agnostic existence query

Immediately after entering `processNextDueTimer`, and immediately before or after the existing
`FOR UPDATE SKIP LOCKED LIMIT 1` query (see ordering note below), when that query returns zero
rows, issue a second, lock-agnostic query against the same predicate — `status = 'pending' AND
fires_at <= NOW()` — using a plain `SELECT ... LIMIT 1` with **no `FOR UPDATE`**. Two cases:

- The plain query also returns zero rows → genuinely no due timer exists. Roll back and return
  `.none` exactly as today.
- The plain query returns one (or more) rows → a due timer exists but was excluded by `SKIP
  LOCKED` because another transaction holds its row lock. Roll back and return `.skipped_locked`
  instead of `.none`.

This mirrors the existing precedent in `fireEscalationTimerInTx` at a design level (both
distinguish "row absent" from "row present but locked"), but cannot reuse that exact code path,
because the escalation branch's `SKIP LOCKED` query is against `tasks` (keyed by
`payload.task_id`, a single known row), whereas the ordinary-timer query has no candidate row
identity yet when it returns zero rows — the whole point of the query was to *find* the next due
timer, so there is no `id` to re-query by. The fix must therefore re-run the *set-based* predicate
(same `WHERE`, same `ORDER BY ... LIMIT 1`, no `FOR UPDATE`), not a single-row lookup by id.

### Placement and transaction semantics

Run the plain existence check on the *same connection* (`conn`), inside the *same transaction*
that is about to roll back — i.e. immediately before the existing `conn.rollback()` call at what
is currently line 213, replacing the unconditional `return .none;` with:

1. If `due_rows.rows.len == 0` (unchanged condition — the original SKIP LOCKED query found
   nothing claimable):
   - Issue the plain existence query: `SELECT 1 FROM timers WHERE status = 'pending' AND
     fires_at <= NOW() ORDER BY fires_at ASC, id ASC LIMIT 1` (no `FOR UPDATE`, no `SKIP LOCKED`).
     No parameters needed (same as the existing zero-arg pattern used elsewhere in this file, e.g.
     the `NOW()`-only queries at lines 247-251 and 310-314).
   - `conn.query(...)` failure on this second query: treat as `SchedulerError.TransactionFailed`
     (same convention as every other `conn.query` failure in this function) — do not silently
     fall back to `.none`, since a query failure here is a genuine infrastructure problem, not an
     expected "nothing due" case.
   - If the plain query returns 0 rows: `conn.rollback()`, return `.none` (unchanged behavior for
     the genuinely-empty case).
   - If the plain query returns ≥1 row: `conn.rollback()`, return `.skipped_locked` (the new
     behavior).

This keeps the transaction read-only and short (one extra `SELECT`, no extra round trip beyond
what's needed), and does not change the transaction's isolation behavior — both queries run under
whatever isolation level `conn.begin()` already establishes for this function, and the second
query intentionally omits any locking clause so it is never itself blocked by the row lock it is
trying to detect the presence of.

### Interaction with `pollDueTimers`'s outer loop

No change needed to `pollDueTimers` (lines 141-154). It already increments
`summary.skipped_locked` and `break`s out of the poll loop when `processNextDueTimer` returns
`.skipped_locked` — that logic is correct today and is exercised correctly by the escalation
branch; this fix simply makes the ordinary-timer branch capable of producing that same variant
when appropriate.

### Testability against TC-SCH-02-02

TC-SCH-02-02 holds a real `FOR UPDATE` row lock on the timer's own row (an uncommitted
transaction on a separate connection, held open for the duration of the assertion — see
`sch02_timer_polling_test.zig:577-581`), then calls `pollDueTimers` and asserts
`skipped_summary.skipped_locked > 0`. Under this fix: the original `SKIP LOCKED` query excludes
the locked row (0 rows, unchanged), the new plain existence query finds the same row (no lock
clause, so the outstanding `FOR UPDATE` on the other connection does not block a plain `SELECT`),
and `.skipped_locked` is returned and counted. No change to the test file is required — this
satisfies the existing assertion as written.

## Fix 2 — TC-SCH-02-03: let a genuine constraint failure surface as `TransactionFailed`

### Mechanism: split `fire_blk`'s catch sites by failure class, not a blanket catch

Do not remove the `fire_blk` labeled block, and do not change any call site other than
`appendTimerFiredEventInTx`. The distinguishing question is not "which error variant was
returned" (both `appendTimerFiredEventInTx` and its neighbors return the same
`SchedulerError` set, so the *type* alone cannot distinguish a constraint violation from a
transient connection failure) — it is **which call site produced the failure**. Change the single
call site to no longer feed into the shared `false`-producing block:

- Current: `appendTimerFiredEventInTx(allocator, conn, instance_id_text, timer_id_text,
  ext_payload) catch break :fire_blk false;`
- New: call `appendTimerFiredEventInTx` and, on error, do NOT `break :fire_blk false`. Instead,
  propagate immediately — roll back the transaction right there (the `errdefer conn.rollback()
  catch {}` already registered near the top of `processNextDueTimer`, at what is currently line
  187, already covers this: it fires on any error return out of the function, including one
  returned from inside `fire_blk`) and `return SchedulerError.TransactionFailed;` directly from
  that call site, bypassing `fire_blk`'s `false`/`handleTimerFireError`/`.none` path entirely for
  this one failure.

  Concretely, restructure so that `fire_blk` is no longer the single point every sub-step falls
  through to. `appendTimerFiredEventInTx`'s call becomes a plain `try` at the top level of
  `processNextDueTimer` (outside `fire_blk`, or as the first statement that, on error, returns
  directly) rather than living inside the `fire_blk: { ... }` expression. Every other step that
  currently participates in `fire_blk` (the `now_rows` query, `buildTimerFiredPayload`,
  `markTimerFiredInTx`, `parseRecurrenceState`, `computeRearmDecision`,
  `updateRecurrencePayloadFiredCount`, `parseUuid`, `insertRecurringPendingTimerInTx`) keeps its
  existing `catch break :fire_blk false` exactly as today — none of those change.

  This is a control-flow reordering, not a new error type: `appendTimerFiredEventInTx` already
  returns `SchedulerError!void` today (see its signature) and already surfaces
  `SchedulerError.TransactionFailed` internally on the `conn.exec` failure inside
  `appendEventInTx` — the only change is that `processNextDueTimer` stops catching it into `false`
  at this one call site and instead lets it propagate out of the function, exactly like the
  `now_rows` query failure inside the escalation branch (line 252) or the `due_rows` query failure
  (line 206) already do today for their respective paths.

### Why only this call site, and why this is safe

`appendTimerFiredEventInTx` is the one step in the fire sequence that can fail for a reason that
is (a) deterministic and non-retryable — a duplicate `idempotency_key` will collide on every
retry attempt identically, since the key is derived solely from `timer_id_text`, which does not
change between polls — and (b) a data-integrity signal worth surfacing distinctly rather than
silently retried into oblivion. Contrast with the other `fire_blk` steps: a transient `now_rows`
query failure, a malformed recurrence payload, or a pool exhaustion error on
`insertRecurringPendingTimerInTx` are exactly the kind of "might succeed on the next poll" or
"needs the DLQ escalation path to eventually catch it" failures ISS-303's retry/DLQ design was
built for, and those must keep flowing through `handleTimerFireError`'s counter-increment logic
unchanged.

This also matches the existing DB-level intent: `events.idempotency_key`'s unique constraint
(`uq_event_idempotency`) exists specifically to make double-appends impossible, and unlike a
connection drop or a malformed payload, a collision on a key derived from stable inputs
(`timer-fired:<timer_id>`) will reproduce identically on every retry — routing it into the same
`fire_error_count`-increment-and-eventually-DLQ machinery as transient failures would eventually
also DLQ it (after `max_timer_fire_retries` polls), but only after masking a genuine
data-corruption-risk signal as an ordinary retry for that whole window. Surfacing it immediately
as `TransactionFailed` is strictly more informative to the caller and does not weaken any existing
retry guarantee for *other* failure classes.

### Reconciling with TC-SCH-303-03/04

Re-read `tests/integration/sch303_timer_dlq_test.zig` (`TC-SCH-303-03` lines 102-216,
`TC-SCH-303-04` lines 222+): both pre-insert an `events` row whose `idempotency_key` collides with
`timer-fired:<timer_id>` — the exact trigger this fix now propagates as `TransactionFailed` — and
both invoke the scheduler as `_ = scheduler.pollDueTimers(allocator) catch {};` inside a loop.
Because the return value is explicitly discarded with `catch {}`, these tests do not depend on
`pollDueTimers` returning a *value*; they depend on it having attempted the fire, failed, and
triggered `handleTimerFireError`'s side effects (`fire_error_count` increment, eventual
`FAILED`+DLQ). Under this fix, `pollDueTimers` (line 142's `try self.processNextDueTimer(...)`)
will now propagate the `TransactionFailed` error up through `pollDueTimers` itself and out to the
test's `catch {}` — which already tolerates exactly this. **No change to
`handleTimerFireError`'s invocation is introduced by this fix, because Fix 2 only changes the
`appendTimerFiredEventInTx` call site, and `handleTimerFireError` is never reached from that call
site today or after this fix** — this is the crux of why TC-SCH-303-03/04 remain green.

Wait — this needs to be stated precisely, because it is easy to misread: today,
`appendTimerFiredEventInTx`'s failure already skips straight to `false` → `!fire_ok` →
`handleTimerFireError` (the current, pre-fix behavior). TC-SCH-303-03/04 rely on
`handleTimerFireError` actually running (that is what increments `fire_error_count` and,
eventually, DLQs the timer) — so the fix must NOT remove that call for this trigger, only make the
*poller's return value* surface `TransactionFailed` in addition to `handleTimerFireError` still
running. Revise the mechanism above accordingly: at the `appendTimerFiredEventInTx` call site,
on failure:

1. Roll back the transaction (`conn.rollback() catch {}`), same as `!fire_ok` does today.
2. Call `handleTimerFireError(...)` with the same arguments `!fire_ok`'s branch passes today
   (`allocator`, `self.pool`, `self.config.max_timer_fire_retries`, `timer_id_text`,
   `instance_id_text`, `payload_json`) — preserving the retry-count increment and eventual DLQ
   routing exactly as before.
3. THEN return `SchedulerError.TransactionFailed` instead of `.none`.

This is the accurate design: **both effects happen** — the retry bookkeeping ISS-303 built
(unchanged), and a `TransactionFailed` propagated to the caller (new). TC-SCH-303-03/04 still see
`fire_error_count` incremented and the timer eventually DLQ'd across repeated polls (their `catch
{}` tolerates the now-returned error each time). TC-SCH-02-03 sees exactly the propagated
`SchedulerError.TransactionFailed` it asserts via `std.testing.expectError`, on the very first
poll — consistent with its test not looping and not pre-existing a `fire_error_count` budget to
exhaust.

Every other `fire_blk` call site is unchanged: on their failure, `fire_blk` still evaluates to
`false`, `!fire_ok` still fires, `handleTimerFireError` still runs, and the function still returns
`.none` — identical to current behavior, preserving ISS-303's protection for those cases.

### Revised control-flow sketch (prose, not compilable)

Within the `else` branch (non-escalation timers), replace the current structure:

- OLD: `fire_ok = fire_blk: { ...; appendTimerFiredEventInTx(...) catch break :fire_blk false; ...
  }` then `if (!fire_ok) { rollback; handleTimerFireError(...); return .none; }`.
- NEW: keep `fire_blk` for every step up to and including building `ext_payload` (the
  `now_rows` query, `isFiredLate`, `buildTimerFiredPayload`) — those failures still fall through
  to `false`/`handleTimerFireError`/`.none`, unchanged. Once `ext_payload` is available, call
  `appendTimerFiredEventInTx` as a distinguishable step: on success, continue into the remainder
  of the existing `fire_blk` body (`markTimerFiredInTx` onward, unchanged, still using `catch
  break :fire_blk false` for each of its own steps) to preserve the existing recurrence/rearm
  logic exactly as today. On `appendTimerFiredEventInTx` failure specifically: perform the same
  rollback + `handleTimerFireError` call that `!fire_ok`'s branch performs today, then `return
  SchedulerError.TransactionFailed;` directly — do not fall through to `fire_blk`'s `false`
  result or `.none`.

  The cleanest realization of this without restructuring `fire_blk`'s block expression type
  (`bool`) is to keep `fire_blk` evaluating to `bool` for the "ordinary retryable failure" cases,
  but change the `appendTimerFiredEventInTx` line inside it from `catch break :fire_blk false` to
  a `catch |err|` clause that performs the rollback + `handleTimerFireError(...)` call *inline*
  (i.e., duplicates the two calls that `!fire_ok`'s branch would otherwise make) and then does
  `return SchedulerError.TransactionFailed;` — a `return` from inside a labeled block exits the
  enclosing function directly, it does not merely break the block, so this does not need a new
  block-result variant. The `errdefer` already registered for `conn.rollback()` near the top of
  `processNextDueTimer` means the explicit rollback call in this new branch is technically
  redundant with the errdefer, but should be kept explicit to mirror the existing `!fire_ok`
  branch's style (which also calls `conn.rollback()` explicitly before `handleTimerFireError`,
  despite the errdefer) — consistency with the surrounding code, not a functional requirement.

### Testability against TC-SCH-02-03

TC-SCH-02-03 pre-inserts a colliding `events` row with `idempotency_key = "timer-fired:<timer_id
under test>"`, then asserts `std.testing.expectError(SchedulerError.TransactionFailed,
scheduler.pollDueTimers(allocator))`, followed by assertions that the timer is still `pending`
(not `fired`). Under this fix: `appendTimerFiredEventInTx` fails on the unique-constraint
violation inside `appendEventInTx`'s `conn.exec` (line ~888 today), which already returns
`SchedulerError.TransactionFailed` from that inner function — the new call-site handling at
`processNextDueTimer` propagates that same error value out of `pollDueTimers` on the very first
poll of the outer `while` loop (line 142's `try` forwards it, since `try` on an error simply
returns it from the enclosing function — here `pollDueTimers` itself, matching the test's
expectation exactly). The transaction was rolled back before the error was returned, so
`markTimerFiredInTx` never ran and the timer row is untouched (`status` remains `'pending'`,
matching the test's `pending_count == 1` / `fired_count == 0` assertions).

## Error taxonomy (unchanged)

No new `SchedulerError` variants are introduced. `SchedulerError` remains:

- `PoolExhausted` — connection pool exhausted on `acquire()`.
- `TransactionFailed` — any transactional/DB-level failure; now additionally reachable from the
  `appendTimerFiredEventInTx` call site inside the ordinary-timer fire path (previously
  unreachable from that specific site).
- `OutOfMemory` — allocation failure.

`PollOutcome` remains `fired | skipped_locked | none` — no new variants. Fix 1 makes
`skipped_locked` reachable from a second code path (the ordinary-timer branch, in addition to the
existing escalation branch); Fix 2 does not touch `PollOutcome` at all — it changes when the
function returns an `error` instead of a `PollOutcome` value.

## Public interface (unchanged signatures)

- `pub fn pollDueTimers(self: *Scheduler, allocator: std.mem.Allocator) SchedulerError!PollSummary`
  — signature unchanged. Behavior change: may now return `SchedulerError.TransactionFailed` in a
  case (ordinary-timer idempotency-key collision) where it previously always returned a normal
  `PollSummary`.
- `fn processNextDueTimer(self: *const Scheduler, allocator: std.mem.Allocator)
  SchedulerError!PollOutcome` — signature unchanged. Behavior changes described above (Fix 1, Fix
  2).
- `fn appendTimerFiredEventInTx(...) SchedulerError!void` — signature unchanged; no internal
  change required, its existing `SchedulerError.TransactionFailed` return on constraint violation
  is what Fix 2 now lets propagate instead of being caught.
- `handleTimerFireError` — signature and internal behavior unchanged; Fix 2 adds one additional
  call site (mirroring the existing `!fire_ok` branch's call) rather than modifying the function
  itself.

## Dependencies

- No new migrations. No new tables/columns.
- No changes to `store.zig`, `recurrence.zig`, or `tasks/store.zig`.
- No changes to `tests/integration/sch02_timer_polling_test.zig` or
  `tests/integration/sch303_timer_dlq_test.zig` are required by this design — both existing test
  files' assertions are satisfied as-is (see "Testability" subsections above and "Reconciling
  with TC-SCH-303-03/04").

## Acceptance criteria mapping

| Acceptance criterion | Addressed by |
|---|---|
| Distinguish "no due timers" from "due timer exists but locked" for the ordinary-timer path | Fix 1 — lock-agnostic existence re-check on zero-row `SKIP LOCKED` result |
| Make `TransactionFailed` reachable for the forced-failure scenario | Fix 2 — `appendTimerFiredEventInTx` call site returns `TransactionFailed` directly instead of folding into `fire_blk`'s `false` |
| Does not regress ISS-303's original intent | "What ISS-303 actually protects" + "Reconciling with TC-SCH-303-03/04" — `handleTimerFireError`'s retry/DLQ side effects still run on this trigger; only the *return value* changes, and only for this one call site; every other `fire_blk` step is untouched |
| Precise enough for BACKEND-DEV to implement without re-deriving the strategy | "Revised control-flow sketch" gives the exact call site, exact ordering of rollback → handleTimerFireError → return, and explicitly rules out a `fire_blk`-wide change |
| No implementation code present | This document uses prose and named-step descriptions only; no compilable Zig blocks |
