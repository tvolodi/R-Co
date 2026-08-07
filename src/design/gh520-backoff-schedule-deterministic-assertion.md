# Module: GH #520 / ISS-0186 Fix — Deterministic Single-Round-Trip Backoff Assertion

Local issue identifier: ISS-0186. GitHub: https://github.com/tvolodi/R-Co/issues/520

This is a test-infrastructure defect fix; no functional requirement ID applies.

## Module purpose

`TC-EXP-301-05` (`tests/integration/effects_subsystem_test.zig`, block at
lines 570-696) verifies that `Queue.markRetry` (`src/effects/queue.zig:84-108`)
advances `next_attempt_at` by the caller-supplied `backoff_ms` on each retry.
The current implementation measures this by issuing two *separate* queries —
one immediately before calling `markRetry`, one immediately after — reading
`EXTRACT(EPOCH FROM next_attempt_at) * 1000` each time, and asserting the
difference (`next_ms_after - next_ms_before`) falls within `expected_ms ±
500ms`. Both queries run inside the one transaction the test harness holds
open for the whole test (see the corrected transaction-semantics analysis
immediately below), so this is not a measurement of two independently-timed
client-server round trips; it is the arithmetic difference between two
`next_attempt_at` values, each computed server-side as `frozen_NOW() +
<that write's own interval>`. The "before" read captures whatever a prior
write left in `next_attempt_at` — for most iterations, the seed loop's own
`Queue.markRetry(..., 500, ...)` call, not a value that depends cleanly on
`expected_backoff[i]` alone — so `next_ms_after - next_ms_before` measures
`expected_delay - <prior write's interval>`, not `expected_delay` itself.
The ±500ms tolerance was, in effect, absorbing that latent mismatch between
what the assertion intended to measure and what it actually computed, not
absorbing any genuine timing jitter. This is fragile in the same way
regardless of concurrent load, but it manifests as a flake under the ~20
concurrent `zig build test-integration-svc` binaries contending for one
PostgreSQL instance because the exact prior-write interval used for seeding
depends on incidental execution-order/state details that vary run to run.

**Corrected transaction-semantics analysis (REWORK 1).** The prior version of
this design justified a ±50ms tolerance on the theory that `markRetry`'s
`UPDATE` and the test's read-back run as two separate implicit
(autocommit) transactions, each with its own independently-evaluated
`NOW()`. **That premise is false for this test**, and the corrected analysis
below replaces it in full.

`TC-EXP-301-05` runs entirely inside `TestHarness.init()`'s single explicit
`conn.begin()` (`tests/integration/helpers.zig:1085`), which stays open for
the whole test body and is only closed by `TestHarness.deinit()`'s
`self.conn.rollback()` (`tests/integration/helpers.zig:1147`) at final
teardown. Every statement the test issues — the fixture `INSERT` via
`Queue.insertEffectInTx`, the seed-loop `Queue.markRetry` calls, the
pre-`markRetry` read, `Queue.markRetry` itself, and the read-back — is
issued on the **same** `&h.conn` object (see current lines 604, 611, 623,
643/645, 661/663, 670: all call sites pass `&h.conn`), and none of them
call `conn.begin()`, `conn.commit()`, or `conn.rollback()` — confirmed by
grep over the whole test file. `vendor/pg/pg.zig:149-174` shows `Conn.exec`
and `Conn.query` call only `extendedQuery` + `readUntilReady`; neither
issues implicit per-call `BEGIN`/`COMMIT`. Only the explicit
`begin()`/`commit()`/`rollback()` wrappers (`pg.zig:180-190`, each a
`simpleQuery` of the literal SQL keyword) touch transaction state. So there
is exactly one transaction for the entire test, opened once, and **every**
statement in `TC-EXP-301-05` — including `markRetry`'s `UPDATE` and the
read-back `SELECT` — executes inside it.

PostgreSQL's `NOW()` is defined as an alias for `transaction_timestamp()`:
it returns the timestamp of the current transaction's *start*, and that
value is frozen for the transaction's entire duration — identical across
every statement in the transaction, not merely identical within one
statement. (`statement_timestamp()` would advance between statements;
`clock_timestamp()` advances continuously and is not transaction- or
statement-stable. `NOW()`/`CURRENT_TIMESTAMP`/`transaction_timestamp()` are
the frozen-at-`BEGIN` family; this codebase uses only `NOW()` — grepping
production SQL and migrations for `clock_timestamp` returns no matches.)
Consequently, `markRetry`'s `UPDATE` (`next_attempt_at = NOW() +
$backoff_ms::interval`, `src/effects/queue.zig:100`) and a read-back
`SELECT ... NOW() ...` issued moments later in the same transaction read
the **exact same** `NOW()` value — not two independently-drifting samples
close in wall-clock time, but one frozen value read twice. There is no
inter-statement latency window for a tolerance to absorb, because no
per-statement wall-clock component is being measured at all.

**Reconciling why the original two-read design was ever flaky.** If
`NOW()` is frozen for the whole transaction, the fact that the old
"before" and "after" reads were both, unknowingly, sampling the same
frozen base does not itself explain the flake — and it should not, because
the old design's actual defect was different from what it diagnosed. The
old assertion computed `next_ms_after - next_ms_before`, i.e. the
difference between two **written** `next_attempt_at` values, each equal to
`frozen_NOW + <that write's own interval>`. Because `frozen_NOW` is
identical in both terms, it cancels exactly: `next_ms_after -
next_ms_before = interval_after - interval_before` — a pure, deterministic
integer with no wall-clock component whatsoever, contrary to both this
design's original theory (cross-round-trip network jitter) and this
design's rejected revision (same-connection statement-dispatch latency).
The old test's fragility was therefore never actually a timing/jitter
problem in the sense either version of this document claimed; the
±500ms tolerance was doing nothing but silently absorbing the fact that
`interval_before` was not solely a function of `i` the way the assertion
implicitly assumed (the "before" value depends on the seed loop's own
`markRetry(..., 500, ...)` writes, which is a correctness gap in the
comparison being made, not a jitter budget). This design does not attempt
to preserve or explain that old comparison — see below, it removes it
entirely in favor of a comparison that has no dependency on any prior
write's value.

**Corrected design.** Because `NOW()` is frozen for the whole transaction,
the fix does not need to read `next_attempt_at` twice (once before, once
after `markRetry`) at all — every `NOW()` read anywhere in this test,
before or after `markRetry`, returns the identical frozen value. The
design instead reads `next_attempt_at` and `NOW()` **together, in the same
read-back `SELECT`**, immediately after `markRetry` returns, and asserts
the algebraic identity `next_attempt_at - NOW() == backoff_ms` directly.
Since both quantities come from the same frozen-`NOW()` transaction and
`next_attempt_at` was itself computed server-side as `NOW() +
backoff_ms::interval` using that identical frozen value, the two sides of
this comparison are related by exact server-side arithmetic on the same
constant — not by any measurement of elapsed time, client- or
server-side. The only residual "noise" is client-side floating-point
round-trip through `EXTRACT(EPOCH FROM ...) * 1000` and
`std.fmt.parseFloat`, which is a numeric-precision concern, not a timing
one (see §Public interface, point 3, for the resulting near-zero
tolerance).

## Fix scope confirmation

Test-only change, 1 file:

- `tests/integration/effects_subsystem_test.zig` — the `TC-EXP-301-05` block
  (lines 570-696). The "before" read (lines 623-640) is removed. The "after"
  read (lines 670-694) is replaced by a single combined query that reads
  `attempt_count`, `status`, `next_attempt_at`, and server `NOW()` in one
  round trip, followed by an assertion against the algebraic identity
  `next_attempt_at - NOW() ≈ backoff_ms` with a near-zero fixed tolerance
  (float round-trip epsilon only — see §Public interface point 3) instead of
  the previous cross-round-trip delta.

No production code changes. `src/effects/queue.zig` is unmodified — `markRetry`
already computes the correct value; only the test's *measurement* of that
value changes.

## Public interface

Type E prose only — no compilable Zig, per lego-catalog.md and the lint's
40-line fenced-code-block limit. This section describes the query shape and
assertion logic that BACKEND-DEV implements literally inside the existing
`for (delivery_ids, 0..) |delivery_id, i| { ... }` loop.

1. **Before-read query is removed entirely.** The existing "before" block
   (current lines 623-640: the `SELECT attempt_count::text, EXTRACT(EPOCH
   FROM next_attempt_at) * 1000 ... WHERE effect_delivery_id = $1::uuid`
   query, its row-count assertion, its `attempt_before` parse, and its
   `next_ms_before` parse) is deleted in full. It is not needed under the
   new design: the new assertion compares `next_attempt_at` against the
   *same query's* `NOW()`, not against a previously-read `next_attempt_at`
   value. The `attempt_count` check that the before-read used to perform
   (`attempt_before == i`) is preserved, but moved — see point 4 below — to
   a lightweight pre-`markRetry` existence/attempt-count check that does not
   need to capture any timestamp.

   Rationale for keeping *some* pre-`markRetry` check rather than dropping
   it outright: the loop body branches on `attempt_before + 1 >=
   EFFECT_MAX_ATTEMPTS` to decide whether this iteration exercises the
   dead-letter path (current lines 642-657) or the retry path (current
   lines 659-694). That branch condition is still needed, so the minimal
   pre-`markRetry` read becomes: `SELECT attempt_count::text FROM
   effects_outbox WHERE effect_delivery_id = $1::uuid` — a single-column
   query with no timestamp extraction, since the timestamp comparison no
   longer depends on a "before" value at all.

2. **Retry-path after-read becomes one combined query, issued once,
   immediately after `Queue.markRetry` returns.** Pseudocode (not
   compilable Zig — table/column names as they exist today):

   ```
   query:
     SELECT
       attempt_count::text,
       status,
       EXTRACT(EPOCH FROM next_attempt_at) * 1000,
       EXTRACT(EPOCH FROM NOW()) * 1000
     FROM effects_outbox
     WHERE effect_delivery_id = $1::uuid
   params: [delivery_id]
   ```

   This is the same table, same predicate, and same two of the four
   selected expressions (`attempt_count`, `next_attempt_at`) as the current
   after-read (current lines 670-680); it adds `status` (already selected
   today) and one new expression, `EXTRACT(EPOCH FROM NOW()) * 1000`,
   evaluated in the same statement execution as `next_attempt_at`.

3. **Assertion logic replaces the delta-of-two-reads with a
   same-statement algebraic check:**

   ```
   parse: attempt_after   <- column 0 (existing parse, unchanged)
          status_after    <- column 1 (existing parse, unchanged)
          next_ms         <- column 2 (existing parse, renamed from next_ms_after)
          now_ms           <- column 3 (new parse, same f64 parse helper
                                          already used for next_ms)

   assert attempt_after == attempt_before_from_point_1 + 1   (unchanged assertion,
                                                                just re-sourced)
   assert status_after == "pending"                           (unchanged assertion)

   observed_delta_ms = next_ms - now_ms
   expected_ms       = f64(expected_backoff[i])

   # Tolerance (corrected -- REWORK 1): markRetry's UPDATE and this
   # read-back SELECT run in the SAME already-open transaction (see
   # corrected §Module purpose analysis), so NOW() is frozen and identical
   # for both -- this is exact server-side arithmetic, not a timing
   # measurement. Residual error is client-side float round-trip only
   # (EXTRACT/parseFloat), not jitter. See prose below for full derivation.
   tolerance_ms = 1.0   # float round-trip epsilon only; see prose below

   assert observed_delta_ms >= expected_ms - tolerance_ms
   assert observed_delta_ms <= expected_ms + tolerance_ms
   ```

   `tolerance_ms = 1.0` reflects that this is now a same-transaction,
   frozen-`NOW()` algebraic identity, not a measurement of elapsed time.
   It is deliberately not `0.0` only because floating-point round-trip
   through `EXTRACT(EPOCH FROM ...) * 1000` (PostgreSQL evaluates this as
   `float8`) and `std.fmt.parseFloat(f64, ...)` on the text-protocol
   representation is not guaranteed to be bit-exact for arbitrary
   timestamp/interval combinations, even though the underlying
   `TIMESTAMPTZ` and `INTERVAL` arithmetic PostgreSQL performs server-side
   is exact. 1ms is generous headroom for that float round-trip (which is
   sub-microsecond in practice) while remaining unable to mask any real
   backoff-schedule regression, since the smallest `expected_backoff` value
   in this test is 5000ms — 5000x the tolerance.

4. **Dead-letter path (current lines 642-657) is otherwise unchanged**,
   except that `attempt_before` is now sourced from the minimal
   single-column pre-check in point 1 instead of the deleted two-column
   before-read.

5. **Loop-level unchanged assertions**: the `expectEqual(usize, 1,
   ...rows.len)` row-count checks, the `attempt_after == attempt_before + 1`
   check, and the terminal-state checks in the dead-letter branch
   (`status == "dead_lettered"`, `attempt_count == "4"`, `last_error ==
   "max attempts exhausted"`) are all retained verbatim — none of them
   measure wall-clock time and none are touched by this fix.

## Why the assertion still catches a genuine backoff regression

The new assertion compares the same underlying quantity the old one did:
the interval `markRetry` actually wrote into `next_attempt_at`, relative to
the transaction's frozen `NOW()`. If `markRetry`'s interval computation
regressed — e.g. the SQL `NOW() + $3::interval` were changed to add the
wrong unit, drop the multiplier, or use a stale/hardcoded backoff —
`next_attempt_at` would land at the wrong offset from that same frozen
`NOW()`, and `next_ms - now_ms` (both read in the same statement execution)
would still differ from `expected_ms` by far more than the 1ms float
round-trip tolerance for any of this test's backoff values (5000, 30000,
120000, 600000 ms — the smallest is 5000ms, i.e. 5000x the tolerance). The
fix changes only *how* the comparison against "now" is made — same
statement instead of two reads straddling a call to `markRetry` — not what
property is being verified, so a real regression in the backoff schedule
remains just as detectable — more so, since collapsing the comparison into
one query removes any dependency on a previously-written `next_attempt_at`
value (which the old design implicitly, and incorrectly, assumed was a
clean function of `i` alone; see the reconciliation note above). It is not
weakened into a tautology: `next_attempt_at > NOW()` alone (the tautology
the acceptance criteria explicitly warn against) would pass for *any*
positive backoff, including a completely wrong one; this design retains the
bound comparison against `expected_ms` for each of the four distinct
schedule values, so a schedule that used the wrong index, wrong multiplier,
or wrong base unit still fails.

## Error taxonomy

No new error variants. The combined query reuses the existing
`h.conn.query(...) catch return error.QueryFailed` pattern already used by
every other query in this test file (see current lines 632, 649, 680) — the
new query is a drop-in replacement for the existing after-read query with
one additional selected column, so it inherits the same `error.QueryFailed`
mapping on a failed round trip. The removed before-read's error handling is
deleted along with the query itself (point 1). The new minimal pre-check
query (point 1) uses the same `error.QueryFailed` pattern. `std.fmt.parseInt`
and `std.fmt.parseFloat` failure paths (`catch return error.QueryFailed`)
are unchanged in shape, just applied to one additional column (`now_ms`).

## Dependencies

- `EXTRACT(EPOCH FROM ...)` — already used by this test file for
  `next_attempt_at`; the fix applies the identical expression to `NOW()`
  in the same `SELECT` list. No new PostgreSQL feature.
- `std.fmt.parseFloat(f64, ...)` — already used by this test file (current
  line 640, 685) for the two existing timestamp columns; the fix reuses it
  for the new `now_ms` column. No new dependency.
- No change to `src/effects/queue.zig`, `Queue.markRetry`, or any other
  production module. `markRetry`'s SQL (`next_attempt_at = NOW() +
  $3::interval`, `src/effects/queue.zig:100`) is exactly the computation
  this design's assertion verifies; it is read, not modified.

## Out of scope

- **Any change to `Queue.markRetry` or its SQL.** The interval computation
  is correct; only the test's method of observing it is flawed.
- **Reducing tolerance to exactly `0.0`.** Rejected only for the narrow
  reason that PostgreSQL's `float8`/text-protocol round-trip of
  `EXTRACT(EPOCH FROM ...) * 1000` through `std.fmt.parseFloat` is not
  contractually guaranteed bit-exact, not because of any transactional
  concern — `markRetry`'s `UPDATE` and the read-back `SELECT` already run
  in the same transaction with the same frozen `NOW()` (see corrected
  §Module purpose analysis above), so the server-side arithmetic itself
  is exact; `1.0` is a numeric-precision safety margin only, not a
  concurrency or latency budget.
- **Explicitly wrapping the read-back and `markRetry` in their own shared
  transaction to force byte-identical `NOW()` values.** Unnecessary — they
  are already in the same transaction (`TestHarness.init()`'s single
  `conn.begin()`, held open for the whole test). No additional
  transactional wrapping is needed or proposed.
- **The seed-attempt loop** (current lines 607-617, the `for (0..i) |_| {
  try Queue.markRetry(..., 500, "seed attempt_count", 1); }` block that
  seeds each row to `attempt_count = i` using a 1ms backoff). This loop
  does not assert on timing at all — it only advances `attempt_count` — and
  is unaffected by this fix.
- **`TC-EXP-301-06` and other blocks in this file.** Out of scope; ISS-0186
  is specific to `TC-EXP-301-05`'s wall-clock measurement.

## Acceptance criteria

1. `src/design/gh520-backoff-schedule-deterministic-assertion.md` exists
   with all required sections (this file).
2. `tests/integration/effects_subsystem_test.zig::TC-EXP-301-05` no longer
   issues a "before" read that captures `next_attempt_at` prior to calling
   `Queue.markRetry` for the timing assertion; the pre-`markRetry` read (if
   retained for the `attempt_count` branch condition) selects only
   `attempt_count`, not any timestamp column.
3. The retry-path read-back after `Queue.markRetry` is a single query that
   selects `attempt_count`, `status`, `EXTRACT(EPOCH FROM next_attempt_at) *
   1000`, and `EXTRACT(EPOCH FROM NOW()) * 1000` in one round trip.
4. The timing assertion compares `next_attempt_at - NOW()` (both from the
   same query execution) against `expected_backoff[i]` with a fixed
   tolerance of `1.0` ms — a client-side float round-trip epsilon, not a
   wall-clock/jitter budget (not the previous `500.0` ms, and not exactly
   `0.0`).
5. The assertion is not a tautology: it still bounds the observed interval
   against each of the four distinct `expected_backoff` values (5000, 30000,
   120000, 600000 ms), so a genuine regression in `markRetry`'s interval
   computation fails the test.
6. `attempt_count` and `status` assertions (`attempt_after == attempt_before
   + 1`, `status == "pending"`) are preserved unchanged.
7. The dead-letter branch (`status == "dead_lettered"`, `attempt_count ==
   "4"`, `last_error == "max attempts exhausted"`) is preserved unchanged.
8. No file other than `tests/integration/effects_subsystem_test.zig` is
   modified.
9. `zig build test-integration-svc` (or the specific binary containing this
   test) passes `TC-EXP-301-05` repeatedly (BACKEND-DEV/TEST-RUNNER to
   confirm across at least 2 consecutive runs under concurrent load, per
   ISS-0186's third acceptance criterion) without the previous ±500ms
   flakiness.
10. `python tools/lint_design_artefact.py
    src/design/gh520-backoff-schedule-deterministic-assertion.md` exits 0
    with no BLOCKER or MAJOR.

## Test plan

No new test files. The fix is entirely inside the existing
`TC-EXP-301-05` block. BACKEND-DEV implements per §Public interface, then:

1. Run the modified test standalone (single binary, no contention) and
   confirm all four schedule values (5000, 30000, 120000, 600000 ms) pass
   with the new 1ms tolerance.
2. Run the modified test under the same concurrent-load condition that
   originally exposed the flake (multiple `zig build test-integration-svc`
   binaries invoked in parallel against the shared PostgreSQL instance, per
   `docs/guides/test_infrastructure_guide.md`), repeated at least twice, to
   confirm the fix holds under the load that caused ISS-0186.
3. As a sanity check only (not a committed test), BACKEND-DEV may
   temporarily perturb `expected_backoff` in a scratch copy to confirm the
   new assertion still fails on a mismatched schedule value before
   reverting — this is manual verification of §Why the assertion still
   catches a genuine backoff regression, not a new automated test.

## Documentation update

Add a short comment immediately above the `TC-EXP-301-05` test block
(replacing/extending the existing section-header comment at current lines
566-568) noting the fix:

```
// TC-EXP-301-05: Backoff Schedule Verification (Integration)
// ISS-0186 (GitHub #520): asserts next_attempt_at - NOW() against the
// expected backoff using a single same-statement read-back instead of two
// separate reads straddling the markRetry call. Both next_attempt_at and
// this NOW() are evaluated inside the one transaction TestHarness.init()
// opens for the whole test, so NOW() is frozen and identical between them
// (transaction_timestamp() semantics) -- the comparison is exact
// server-side arithmetic, not a wall-clock/jitter measurement. See
// src/design/gh520-backoff-schedule-deterministic-assertion.md.
```
