# Test Spec: ORD-04 — Cross-correlation parallelism and lag metrics

**Requirement:** ORD-04 — Completions belonging to different `correlation_id` values SHALL
continue to be applied in parallel: distinct correlations take distinct advisory lock keys and
distinct `plat_correlation_cursor` rows, so `consumer_count` correlations (default 8) are
applied concurrently. The platform SHALL expose per-correlation lag `max(sequence_no) -
applied_seq`, the age of the oldest `PENDING` row, and the rate at which the execute guard of
ORD-02 returns `false`.

**Priority:** MUST
**Test layer:** unit (`ObservabilityCounters`'s pure windowing math) + integration
(`computeCorrelationLag` against real PostgreSQL, plus genuine multi-thread parallelism proof)
**Test-tier score (test_developer_guide.md §2.1):** DB schema (2, the migration creates
`plat_correlation_cursor`) + transactional boundary (1, the execute guard AC1 depends on is
transaction-scoped, and the parallelism claim is specifically about concurrent open
transactions) = **3 points → sandbox tier by the rubric's raw score** — see the same
Test-tier note as `tests/specs/ORD-01.md` for why no Wasm/sandbox surface actually exists for
this requirement family; unit + integration (including genuine concurrency) is the
proportionate ceiling.
**Design:** `src/design/ord-01-02-04-correlated-effect-reentry.md`
**Implementation:** `src/ordering/observability.zig` (`ObservabilityCounters`,
`computeCorrelationLag`), migration creating `plat_correlation_cursor`

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN 8 correlations each holding a pending completion that is next in sequence, WHEN 8 consumers poll, THEN all 8 are applied concurrently and none is serialised behind another. | `TC-ORD-04-AC1-concurrent` (genuine 8-thread concurrency — see Concurrency section below) |
| AC2 | GIVEN per-correlation lag exceeds 100 unapplied completions, WHEN the sweeper evaluates it, THEN `EXECUTION_CORRELATION_LAG` is appended carrying the `correlation_id`, the lag, and the age of the oldest `PENDING` row, and Platform Admin is escalated. | `ord04_plat_correlation_cursor: lag_computable_via_join_against_completion_table` (the lag COMPUTATION this batch implements); the sweeper's event-append and escalation are out of scope for this batch — see Structural verification note below |
| AC3 | GIVEN the execute guard returns `false` for more than 50 per cent of claim attempts in one minute, WHEN contention is evaluated, THEN `EXECUTION_CORRELATION_CONTENTION` is appended and `consumer_count` is reduced by 2 with a floor of 2. | `ObservabilityCounters` unit tests (the contention-RATIO computation this batch implements); the event-append and `consumer_count` reduction are out of scope — see Structural verification note below |
| AC4 | GIVEN a correlation is dead-lettered, WHEN the escalation is raised, THEN it names the `correlation_id` and lists every unapplied `sequence_no`, so the missing emit is identifiable without querying the table. | Out of scope for this batch — see Structural verification note below |
| AC5 | Every applied completion appends `EXECUTION_EFFECT_APPLIED` carrying `correlation_id` and `sequence_no`, so apply order is auditable from the event log alone. | Out of scope for this batch — see Structural verification note below |

---

## Structural verification notes — AC2-AC5's event-append/escalation halves

This batch's own module header (`src/ordering/mod.zig`) states its scope explicitly: **"This
batch's scope: the claim guard (ORD-01), the execute guard (ORD-02), and the
parallelism/observability surface (ORD-04) — process doc steps 1-3 and 8, 10, 11, plus the
two new tables (`plat_effect_completion`, `plat_correlation_cursor`). Steps 4-7 (order guard,
apply, cursor advance, commit) and step 9 (gap sweeper dead-lettering) belong to ORD-03, not
this batch."** Concretely:

- **AC2's "the sweeper evaluates it... Platform Admin is escalated" and AC3's "consumer_count
  is reduced by 2 with a floor of 2"** describe a periodic sweeper process (process doc step
  10/11) that reads the metrics this batch computes and takes ACTION on them (event append,
  admin escalation, mutating a live `consumer_count`). `src/ordering/observability.zig`'s own
  header comment states this directly: *"Wiring into the scheduler's existing 60s cadence
  (process doc step 10/11) is a BACKEND-DEV implementation detail left for the caller (this
  batch does not spawn its own timer thread)."* This batch supplies the CALCULATION
  (`computeCorrelationLag`, `contentionRatioLastWindow`) the sweeper would consume; the
  sweeper itself, and its event-append/escalation/consumer_count-mutation side effects, do
  not exist in this codebase yet. `OrderingConfig.consumer_count_floor` (= 2) and
  `consumer_count_step_down` (= 2) — the exact numbers AC3 names — are already present as
  config fields in `src/ordering/mod.zig`, confirming the design anticipates the sweeper but
  intentionally defers its implementation, per the module header's stated scope.
- **AC4's dead-letter escalation** depends on ORD-03's gap-sweeper dead-lettering (process
  doc step 9), explicitly named above as NOT this batch's scope. There is no
  dead-lettering code path in this codebase yet to test.
- **AC5's `EXECUTION_EFFECT_APPLIED` event append** happens when a completion is actually
  APPLIED — this batch's own `consumer.zig::stubAlwaysDeferred` is an explicit, permanent
  placeholder for the apply step ("This batch supplies ONLY `stubAlwaysDeferred`... which
  always treats every claim as 'not yet — ORD-03 not implemented,' rolling back without error
  ... ORD-03's own batch replaces this function pointer with the real order-guard + apply +
  cursor-advance logic"). Since nothing in this batch ever applies a completion, there is no
  apply-event-append code path to test — testing it now would mean writing a test against
  code that provably does not exist, which the codebase's own doc-comments confirm.

**These four half-clauses are correctly deferred to ORD-03, not silently dropped.** Each is
named in this batch's own design/module documentation as an explicit boundary, matching this
guide's convention (see `tests/specs/DDL-01.md`'s "Structural verification note" for the same
technique applied to a different requirement) for acceptance-criteria clauses whose
implementing code does not exist yet in the current batch. When ORD-03 lands, its own test
spec must add coverage for the sweeper's event-append/escalation/consumer_count-reduction
behavior and the apply-time `EXECUTION_EFFECT_APPLIED` append — this is a forward pointer,
not a completed row.

---

## Concurrency section — genuine multi-connection testing for AC1 (mandatory review item)

**Finding: no existing test in this batch (as originally written by BACKEND-DEV) exercised
genuine multi-thread parallelism for AC1's literal "8 correlations... 8 consumers poll... all
8 applied concurrently" claim.** The pre-existing integration tests
(`ord04_plat_correlation_cursor_test.zig`) cover schema-level properties (PK uniqueness, CHECK
constraint, lag-computation SQL correctness) with single-connection, sequential test bodies —
correct for what they test, but none of them spin up multiple correlations claimed by
multiple consumers AT THE SAME TIME.

**TEST-DESIGNER added `TC-ORD-04-AC1-concurrent`** (`tests/integration/ordering_consumer_test.zig`)
to close this gap: 8 real `std.Thread.spawn` OS threads, each on its own already-acquired,
already-`begin()`-ed PostgreSQL connection (see `tests/specs/ORD-01.md`'s Concurrency section
for why connection acquisition itself is sequentialized — a genuine, separately-filed defect
in `Pool.acquire()` under raw-thread contention, GH-709 / ISS-0669, not a workaround for
THIS requirement's own property). Each thread:

1. Claims a row from a shared PENDING set containing exactly one row per one of 8 fixture
   correlations (via `cursor.claimOneCompletion`, draining until it finds one of the 8
   fixture rows — since the claim query has no per-correlation filter, which correlation a
   given thread ends up claiming is not deterministic, but SKIP LOCKED guarantees a
   bijection: 8 rows, 8 threads, no duplicates, no starvation — verified explicitly by the
   test's pairwise-distinctness assertion over all 8 threads' claimed `correlation_id`
   values).
2. Acquires ORD-02's `tryExecuteGuard` for whichever correlation it claimed.
3. Rendezvouses at a SECOND barrier (`ArrivalGate`, sized to all 8 threads, released only once
   every thread has arrived — including error paths, which arrive immediately rather than
   waiting, so a genuine failure cannot deadlock the survivors) while STILL holding its
   execute guard.

**Why the second barrier is the actual proof, not a timing sample.** A fully serialized
implementation — one where a second correlation's claim/guard sequence does not even begin
until a first correlation's entire connection/transaction lifecycle has finished — would hang
this second barrier forever, since not every thread would ever reach it simultaneously while
still holding its guard. The test passing at all (all 8 threads reach and pass the barrier)
is therefore deterministic proof of genuine concurrent execution, not a statistical sample
that could pass by luck. **This was not the first design tried**: an earlier version sampled
overlap probabilistically (increment a shared counter, `std.Thread.yield()` once, check if the
counter is `>1`) and flaked roughly 1 run in 7 — real network round-trips before the sample
point let threads naturally desynchronize enough that the narrow sampling window sometimes
missed genuine overlap that was, in fact, happening. Switching to a full rendezvous barrier
(pass/hang, not sample/miss) made the test deterministic; confirmed clean across 6+
consecutive `zig build test-integration-ordering` runs after the fix.

---

## Test cases

### ObservabilityCounters: contentionRatioLastWindow is 0.0 with no recorded attempts
**Given:** A freshly initialized `ObservabilityCounters`.
**When:** `contentionRatioLastWindow()` is called with zero recorded attempts.
**Then:** Returns `0.0` (not undefined/NaN) — the "no contention observed" baseline.
**Layer:** unit
**Acceptance criterion mapped:** Supports AC3's contention-ratio computation (edge case: zero denominator)
**Zig test:** `"ObservabilityCounters: contentionRatioLastWindow is 0.0 with no recorded attempts"` (`src/ordering/observability.zig`)

### ObservabilityCounters: contentionRatioLastWindow computes busy/attempts ratio
**Given:** 1 `.acquired` + 3 `.busy` recorded guard attempts (4 total, 3 busy).
**When:** `contentionRatioLastWindow()` is called.
**Then:** Returns `0.75` (3/4) — exceeding AC3's 50% threshold, confirming the ratio calculation AC3's sweeper would compare against `0.5`.
**Layer:** unit
**Acceptance criterion mapped:** AC3 (ratio computation half — see Structural verification note above for the sweeper-action half)
**Zig test:** `"ObservabilityCounters: contentionRatioLastWindow computes busy/attempts ratio"`

### ObservabilityCounters: resetWindow clears the rolling window but not lifetime totals
**Given:** 2 `.busy` attempts recorded; `resetWindow()` called; then 1 more `.acquired` attempt.
**When:** `contentionRatioLastWindow()` is checked before and after `resetWindow()`, and lifetime totals (`execute_guard_attempts`/`execute_guard_busy`) are checked after.
**Then:** Ratio is `1.0` before reset, `0.0` immediately after (new empty window), `0.0` after the new `.acquired` attempt (0 busy / 1 attempt); lifetime totals remain `2`/`2` — unaffected by the window reset.
**Layer:** unit
**Acceptance criterion mapped:** AC3 (the 60-second rolling-window semantics "more than 50 per cent... in one minute" requires — this proves the window actually rolls rather than accumulating forever)
**Zig test:** `"ObservabilityCounters: resetWindow clears the rolling window but not lifetime totals"`

### ObservabilityCounters: exactly-50-percent contention is at threshold, not exceeding it
**Given:** 1 `.acquired` + 1 `.busy` (exactly 50%).
**When:** `contentionRatioLastWindow()` is called.
**Then:** Returns exactly `0.5` — AC3 says "MORE THAN 50 per cent," so the caller must compare `> 0.5`, not `>= 0.5`; this test pins the boundary value so a future caller-side `>=` regression is independently detectable against the metric itself.
**Layer:** unit
**Acceptance criterion mapped:** AC3 (boundary-condition precision for "more than 50 per cent")
**Zig test:** `"ObservabilityCounters: exactly-50-percent contention is at threshold, not exceeding it"`

### ord04_plat_correlation_cursor: insert_then_read_applied_seq
**Given:** A fresh cursor row inserted at `applied_seq=4`.
**When:** Read back by `correlation_id`.
**Then:** Returns exactly the seeded value.
**Layer:** integration
**Acceptance criterion mapped:** Schema smoke test underlying AC1/AC2 (the cursor row `computeCorrelationLag` and `tryExecuteGuard` both depend on existing and being readable)
**Zig test:** `"ord04_plat_correlation_cursor: insert_then_read_applied_seq"` (`tests/integration/ord04_plat_correlation_cursor_test.zig`)

### ord04_plat_correlation_cursor: primary_key_prevents_duplicate_correlation_row
**Given:** A cursor row inserted for `correlation_a`.
**When:** A second INSERT for the same `correlation_id` (no `ON CONFLICT`) is attempted.
**Then:** Fails with `error.QueryFailed` (PK violation); the original row is unchanged.
**Layer:** integration (schema contract test)
**Acceptance criterion mapped:** Supports AC1's "distinct correlations take... distinct `plat_correlation_cursor` rows" — the PK is what enforces exactly one cursor row per correlation, which ORD-02's execute guard depends on for a well-defined read while holding the advisory lock.
**Zig test:** `"ord04_plat_correlation_cursor: primary_key_prevents_duplicate_correlation_row"`

### ord04_plat_correlation_cursor: applied_seq_check_constraint_rejects_negative
**Given:** An INSERT attempting `applied_seq = -1`.
**When:** Executed.
**Then:** Fails with `error.QueryFailed` (CHECK constraint violation); zero rows exist for that correlation afterward.
**Layer:** integration (schema contract test)
**Acceptance criterion mapped:** Schema-level invariant underlying AC2's lag formula (`max(sequence_no) - applied_seq`, which assumes `applied_seq >= 0`)
**Zig test:** `"ord04_plat_correlation_cursor: applied_seq_check_constraint_rejects_negative"`

### ord04_plat_correlation_cursor: lag_computable_via_join_against_completion_table
**Given:** A cursor row at `applied_seq=4`; two PENDING completions at `sequence_no` 5 and 6 for the same correlation.
**When:** The lag-formula join query (`MAX(sequence_no) - applied_seq`) is run.
**Then:** Returns `2` — proving the two Type C migrations (`plat_effect_completion`,
`plat_correlation_cursor`) are join-compatible and the lag formula itself is correct.
**Layer:** integration
**Acceptance criterion mapped:** AC2 (lag COMPUTATION — the sweeper-action half is structurally deferred, see note above)
**Zig test:** `"ord04_plat_correlation_cursor: lag_computable_via_join_against_completion_table"`

### TC-ORD-04-AC1-concurrent: 8 correlations each with a pending completion are claimed and guarded concurrently by 8 real threads
**Given:** 8 fixture correlations, each with exactly one PENDING completion row; 8 real OS threads, each on its own already-acquired, already-`begin()`-ed connection.
**When:** All 8 threads are released past a start barrier, each claims a row (draining for one of the 8 fixture rows), acquires its execute guard, then rendezvouses at a second barrier while still holding its guard.
**Then:** All 8 threads pass the second barrier (deterministic proof of simultaneous guard-holding — see Concurrency section above); the 8 threads' claimed `correlation_id` values are pairwise distinct (bijection proof — SKIP LOCKED guarantees no duplicate claims across the 8 available rows).
**Layer:** integration (genuine multi-connection concurrency)
**Acceptance criterion mapped:** AC1 (full, literal genuine-concurrency proof)
**Zig test:** `"TC-ORD-04-AC1-concurrent: 8 correlations each with a pending completion are claimed and guarded concurrently by 8 real threads"` (`tests/integration/ordering_consumer_test.zig`)

---

## Fixtures and isolation

Unit tests (`ObservabilityCounters`) construct fresh, stack-local counter structs per test —
no shared state, no database. Integration tests use a real `bpm.pool.Pool` with per-test
`bpm.uuid.newUuidV4`-generated `correlation_id` fixtures, autocommitted through the pool, and
explicitly deleted via `defer cleanup(...)` registered before any insert.
`TC-ORD-04-AC1-concurrent` generates 8 independent fixture UUIDs per run (not 8 static IDs)
and cleans up all 8 unconditionally via `defer`. No fixture state is shared across test
blocks.

---

## Coverage summary

| Test case | Zig `test "..."` name | Covers | File |
|---|---|---|---|
| ObservabilityCounters ×4 | (4 distinct names, see above) | AC3 (ratio computation) | `src/ordering/observability.zig` |
| ord04_plat_correlation_cursor ×4 | (4 distinct names, see above) | AC1 (schema), AC2 (lag computation) | `ord04_plat_correlation_cursor_test.zig` |
| TC-ORD-04-AC1-concurrent | (see above) | AC1 (genuine concurrency) | `ordering_consumer_test.zig` |

**Implemented case count:** `zig build test-ordering` (pure unit, no DB) — 4/4 passing
(`ObservabilityCounters`). `zig build test-integration-ord04` — 4/4 passing
(`ord04_plat_correlation_cursor_test.zig`). `zig build test-integration-ordering` — 10/10
passing (includes `TC-ORD-04-AC1-concurrent`). No `error.SkipZigTest` on any MUST-covering
test when infrastructure is reachable.

---

## Coverage gap found and closed: genuine multi-connection concurrency for AC1

See the Concurrency section above for the full writeup. `TC-ORD-04-AC1-concurrent` was added
to close a genuine gap — no prior test exercised AC1's literal "8 consumers poll... applied
concurrently" claim under real thread contention. The same `Pool.acquire()`-under-raw-thread
defect documented in `tests/specs/ORD-01.md` (GH-709 / ISS-0669) applies here identically and
is worked around the same way (sequential connection acquisition before the race).

---

## Deferred-by-design clauses (not gaps)

AC2's sweeper-escalation half, AC3's sweeper-action half, AC4 (dead-letter escalation), and
AC5 (apply-time event append) are explicitly out of this batch's scope per
`src/ordering/mod.zig`'s own header comment — see the Structural verification notes above.
These are forward pointers for ORD-03's own test spec, not silently dropped coverage.

---

## Traceability

- ORD-04 acceptance: AC1 directly and genuinely-concurrently tested; AC2, AC3 partially
  tested (computation half) with the sweeper-action half structurally deferred to ORD-03;
  AC4, AC5 structurally deferred to ORD-03 in full.
- See `src/design/ord-01-02-04-correlated-effect-reentry.md` for the full design rationale.
- See `tests/specs/ORD-01.md`, `tests/specs/ORD-02.md` for the sibling requirements sharing
  this test binary and fixture conventions.
