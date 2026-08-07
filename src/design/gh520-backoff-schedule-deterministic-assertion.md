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
500ms`. Because `next_attempt_at` is computed server-side as `NOW() +
$backoff_ms::interval` inside `markRetry`'s own `UPDATE` statement, and the
"before" read happens in a wholly separate round trip that captures the
*previous* `next_attempt_at` value (not a synchronized clock reading), the
±500ms tolerance is a budget for network/scheduler jitter between two
independent client-server round trips — not for anything about the backoff
schedule itself. Under ~20 concurrent `zig build test-integration-svc`
binaries contending for one PostgreSQL instance, that jitter routinely
exceeds 500ms, and the assertion fails on builds where the backoff schedule
was computed correctly.

This design replaces the two-round-trip wall-clock delta with a
single-round-trip, single-statement comparison: read `next_attempt_at` and
the server's own `NOW()` in the *same* `SELECT`, executed once, immediately
after `markRetry` returns. Both values are produced by the same statement
execution on the same backend, so there is no cross-request scheduling
window between them at all — the only "noise" is the same-statement
evaluation of two expressions, which PostgreSQL guarantees is not noise:
`now()` (and `NOW()`, `CURRENT_TIMESTAMP`, `transaction_timestamp()`) all
return the *transaction's* start-of-transaction timestamp, so multiple
references to `NOW()` within one statement — indeed within one transaction —
are byte-for-byte identical unless something explicitly advances to
`clock_timestamp()` or a new transaction begins between them. This is
documented PostgreSQL semantics (`now()` is stable per transaction, unlike
`clock_timestamp()`).

This has a direct consequence for this fix: `markRetry`'s `UPDATE` sets
`next_attempt_at = NOW() + $backoff_ms::interval` inside its own statement
(effectively its own implicit transaction, since the test harness does not
wrap it and a bare `conn.exec` auto-commits). The subsequent read-back
statement runs as a **new, later** transaction/statement, so its own `NOW()`
is *not* required to equal the `NOW()` captured inside `markRetry`'s
`UPDATE` — some real, small amount of server-side processing time separates
the two statements (connection round trip + planner + executor for the
`UPDATE`, then the same again for the `SELECT`). That gap is on the order of
sub-millisecond to low-single-digit milliseconds on a local/CI PostgreSQL
instance — categorically different from the multi-hundred-millisecond
cross-process scheduling jitter the current two-*application*-round-trip
design is exposed to, because there is now only one client-observed round
trip in the assertion window (the read-back), not two. The tolerance can
therefore be tightened by roughly two orders of magnitude while remaining
robust to real load: this design proposes a fixed generous-but-tight bound
(see §Public interface, point 3) rather than zero, because zero would be
brittle to legitimate (if tiny) inter-statement latency under heavy
concurrent load — which is exactly the kind of self-inflicted flakiness this
fix exists to eliminate.

## Fix scope confirmation

Test-only change, 1 file:

- `tests/integration/effects_subsystem_test.zig` — the `TC-EXP-301-05` block
  (lines 570-696). The "before" read (lines 623-640) is removed. The "after"
  read (lines 670-694) is replaced by a single combined query that reads
  `attempt_count`, `status`, `next_attempt_at`, and server `NOW()` in one
  round trip, followed by an assertion against the algebraic identity
  `next_attempt_at - NOW() ≈ backoff_ms` with a tight fixed tolerance instead
  of the previous cross-round-trip delta.

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

   # Tolerance: same-statement expression evaluation, not cross-round-trip
   # wall clock. PostgreSQL guarantees `NOW()` is stable for the lifetime
   # of the executing transaction (transaction_timestamp() semantics), so
   # `now_ms` here is *not* smeared by planner/executor time the way a
   # second independent round trip would be. The residual gap this
   # tolerance absorbs is (a) client-side float round-trip through
   # EXTRACT(EPOCH ...) * 1000 and %f64 parsing, and (b) the difference
   # between the transaction timestamp captured by markRetry's own UPDATE
   # statement and the transaction timestamp captured by this SELECT
   # (a separate statement/transaction issued immediately afterward) --
   # bounded by the server-side executor time for one UPDATE plus one
   # SELECT on a single-row indexed lookup, not by any client-observed
   # network/scheduler gap.
   tolerance_ms = 50.0   # two orders of magnitude tighter than the
                          # current +/-500ms; see rationale below

   assert observed_delta_ms >= expected_ms - tolerance_ms
   assert observed_delta_ms <= expected_ms + tolerance_ms
   ```

   `tolerance_ms = 50.0` is deliberately not `0.0`. The two statements
   (`markRetry`'s `UPDATE` and this `SELECT`) are not the same transaction,
   so their respective `NOW()` calls are not contractually required to be
   bit-identical — only each statement's *own* internal repeated references
   to `NOW()` are guaranteed identical (which is not what is being compared
   here). What is bounded is the wall-clock gap between the `UPDATE`
   committing and the follow-up `SELECT` executing, which is server-side
   statement-dispatch latency on an already-open connection to an
   already-open indexed row — not a scenario where 20 contending processes'
   scheduling jitter stacks into the measurement, because no client-side
   wait or second network round trip sits between the two `NOW()`
   evaluations being compared. 50ms leaves roughly 10x headroom over
   typical same-connection statement-dispatch latency even under load,
   while remaining 10x tighter than the old 500ms budget was ever able to
   guarantee.

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
"now". If `markRetry`'s interval computation regressed — e.g. the SQL
`NOW() + $3::interval` were changed to add the wrong unit, drop the
multiplier, or use a stale/hardcoded backoff — `next_attempt_at` would land
at the wrong offset from the transaction's `NOW()`, and `next_ms - now_ms`
(evaluated in the read-back statement, moments later) would still differ
from `expected_ms` by far more than 50ms for any of this test's backoff
values (5000, 30000, 120000, 600000 ms — the smallest is 5000ms, i.e. 100x
the tolerance). The fix changes *only* which two timestamps are subtracted
and how far apart, in wall-clock terms, they were captured; it does not
change what property is being verified, so a real regression in the backoff
schedule remains just as detectable — more so, since the removal of
cross-round-trip jitter means the test no longer has to choose between a
tolerance tight enough to catch real bugs and one loose enough to survive
contention. It is not weakened into a tautology: `next_attempt_at > NOW()`
alone (the tautology the acceptance criteria explicitly warn against) would
pass for *any* positive backoff, including a completely wrong one; this
design retains the bound comparison against `expected_ms` for each of the
four distinct schedule values, so a schedule that used the wrong index,
wrong multiplier, or wrong base unit still fails.

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
- **Reducing tolerance to `0.0`.** Rejected — see §Public interface point 3;
  the two statements are not the same transaction, so a non-zero (but tight)
  bound is required for correctness under real (non-adversarial) latency.
- **Wrapping the after-read and `markRetry` in an explicit shared
  transaction to force byte-identical `NOW()` values.** This would make the
  tolerance genuinely `0.0`-safe (same-transaction `NOW()` stability), but
  it changes the transactional shape of the test relative to how `markRetry`
  is actually called in production (as an independent, auto-committing
  statement from the effects worker) and is unnecessary complexity relative
  to a 50ms tolerance that already gives ~10x headroom. Not pursued.
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
   tolerance of `50.0` ms (not the previous `500.0` ms, and not `0.0`).
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
   with the new 50ms tolerance.
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
// expected backoff using a single same-statement read-back, not two
// separate round trips, to avoid cross-request scheduling jitter under
// concurrent test load. See
// src/design/gh520-backoff-schedule-deterministic-assertion.md.
```
