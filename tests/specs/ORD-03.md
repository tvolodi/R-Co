# Test Spec: ORD-03 — Sequence order guard and gap sweeping

**Requirement:** ORD-03 — A completion SHOULD be applied only when `sequence_no = applied_seq + 1`,
where `applied_seq` is read from `plat_correlation_cursor` for that `correlation_id` while the
execute guard of ORD-02 is held. A completion that is not next in sequence SHALL cause a silent
`ROLLBACK` with no error and no retry-count increment, leaving the row `PENDING`. The apply and the
cursor advance `UPDATE plat_correlation_cursor SET applied_seq = $2 WHERE correlation_id = $1 AND
applied_seq = $2 - 1` SHALL commit in one transaction.

**Priority:** SHOULD
**Test layer:** integration (real `applyCompletion` / `advanceCursor` / `readOrInitCursor` /
`recordCompletion` / `sweepStalledCorrelations` against `plat_effect_completion` +
`plat_correlation_cursor` + `public.events` + `dead_letter_queue`)
**Test-tier score (test_developer_guide.md §2.1):** DB schema (2, the two tables `plat_effect_completion`
and `plat_correlation_cursor` already exist from ORD-01/ORD-04) + transactional boundary (1, the
apply and the cursor advance must commit/roll back as one transaction — AC2/AC4) = **3 points →
sandbox tier by the rubric's raw score** — same note as `tests/specs/ORD-01.md`: no Wasm/sandbox
surface exists for the ordering family, so integration against real Postgres (including genuine
cross-connection cursor semantics) is the proportionate ceiling.
**Design:** `src/design/ord-03-sequence-order-guard-gap-sweeping.md`
**Implementation:** `src/ordering/cursor.zig` (`readOrInitCursor`, `advanceCursor`,
`recordCompletion`), `src/ordering/consumer.zig` (`applyCompletion`), `src/ordering/sweeper.zig`
(`sweepStalledCorrelations`), `src/dlq/store.zig` (`EFFECT_CORRELATION`), migration
`1166_ord03_ordering_event_types_seed.sql`

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN `applied_seq = 4` for correlation X and the completion for sequence 6 arrives before sequence 5, WHEN sequence 6 is claimed, THEN it is not applied, the transaction rolls back silently, its retry counter is unchanged, and the row remains `PENDING`. | `TC-ORD-03-AC1-out-of-order-deferred` (integration `applyCompletion` → `.deferred`, row stays PENDING, no event, no status change) |
| AC2 | GIVEN sequence 5 then arrives, WHEN it is applied, THEN `applied_seq` advances to 5 and sequence 6 is applied on the next claim, so the engine observes 5 before 6. | `TC-ORD-03-AC2-ordered-apply-advances-cursor` (integration: apply 5 → applied + cursor 5 + event; apply 6 → applied + cursor 6; events ordered 5 then 6) |
| AC3 | GIVEN the conditional cursor update reports 0 updated rows, WHEN the consumer evaluates it, THEN the transaction rolls back and the completion is re-claimed; this guard makes a double-apply impossible even if both other guards were bypassed. | `TC-ORD-03-AC3-cursor-race-0-rows` (integration: `advanceCursor` returns 0 for a stale precondition — the conditional guard) + `TC-ORD-03-AC3-double-apply-guard` (re-applying an already-applied sequence returns `.deferred`) |
| AC4 | GIVEN the apply raises a typed engine error, WHEN the transaction rolls back, THEN neither the instance state change nor the cursor advance is committed, so applied state and `applied_seq` cannot diverge. | `TC-ORD-03-AC4-apply-failed-rollback` (integration: forced apply failure → `.apply_failed`; cursor and row unchanged after rollback) |
| AC5 | GIVEN a successor has been `PENDING` for longer than `gap_timeout_seconds` (default 300) while its predecessor is absent, WHEN the gap sweeper runs on its 60 s cadence, THEN every `PENDING` row of that correlation moves to `status = 'DEAD'` and is routed to the dead letter queue as one unit, so no correlation is left half-applied. | `TC-ORD-03-AC5-sweep-stalled-to-dead` (integration `sweepStalledCorrelations`: all PENDING rows → DEAD; `SweptCorrelation` carries every unapplied sequence_no) + `TC-ORD-03-AC5-non-stalled-not-swept` (predecessor-present correlation is left alone) |
| AC6 | GIVEN the Effects Worker re-inserts an existing `(correlation_id, sequence_no)`, WHEN the insert runs, THEN it is absorbed by `ON CONFLICT DO NOTHING` and no second apply occurs. | `TC-ORD-03-AC6-on-conflict-do-nothing` (integration `recordCompletion` twice → one row) |

---

## Test cases

### TC-ORD-03-AC1-out-of-order-deferred: sequence 6 before 5 is silently deferred
**Given:** `plat_correlation_cursor.applied_seq = 4` for correlation X; a `PENDING` completion row
at `sequence_no = 6`.
**When:** `applyCompletion` runs for the sequence-6 claim on a transaction that is then rolled back.
**Then:** Returns `.deferred`; the completion row stays `PENDING` (no status change, no retry
consumed); no `EXECUTION_EFFECT_APPLIED` event is appended; the cursor stays at 4.
**Layer:** integration
**Acceptance criterion mapped:** AC1
**Zig test:** `TC-ORD-03-AC1-out-of-order-deferred` (`tests/integration/ord03_ordering_test.zig`)

### TC-ORD-03-AC2-ordered-apply-advances-cursor: sequence 5 then 6 applies in order with cursor + event
**Given:** `applied_seq = 4` for correlation X; `PENDING` rows at sequence 5 and 6.
**When:** `applyCompletion` runs for the sequence-5 claim (committed), then for the sequence-6 claim
(committed).
**Then:** Sequence 5 returns `.applied`; the row becomes `APPLIED`; `applied_seq` advances to 5; an
`EXECUTION_EFFECT_APPLIED` event is appended with `sequence_no: 5`. Sequence 6 then returns
`.applied`, row `APPLIED`, cursor advances to 6, event with `sequence_no: 6` — the engine observes
5 before 6 (events ordered by appended sequence).
**Layer:** integration
**Acceptance criterion mapped:** AC2
**Zig test:** `TC-ORD-03-AC2-ordered-apply-advances-cursor` (`tests/integration/ord03_ordering_test.zig`)

### TC-ORD-03-AC3-cursor-race-0-rows: the conditional advance returns 0 when the cursor moved
**Given:** `applied_seq = 4` for correlation X.
**When:** `advanceCursor(X, 5)` succeeds (returns 1), then a stale caller issues `advanceCursor(X, 6)`
whose precondition `applied_seq = 5` no longer matches (cursor is now 5 but the caller read 4).
**Then:** The first returns 1 and cursor becomes 5; the stale call returns 0 (no update) — the
conditional `WHERE applied_seq = $2 - 1` makes a mis-advance impossible.
**Layer:** integration
**Acceptance criterion mapped:** AC3 (the conditional guard)
**Zig test:** `TC-ORD-03-AC3-cursor-race-0-rows` (`tests/integration/ord03_ordering_test.zig`)

### TC-ORD-03-AC3-double-apply-guard: re-applying an already-applied sequence is deferred
**Given:** Correlation X with `applied_seq = 5` after sequence 5 was applied.
**When:** `applyCompletion` is called again for the SAME sequence-5 claim (a re-claim of an
already-applied row).
**Then:** Returns `.deferred` (5 != 5 + 1) — the order guard makes a double-apply impossible even
if both the claim and execute guards were bypassed.
**Layer:** integration
**Acceptance criterion mapped:** AC3 (double-apply impossible)
**Zig test:** `TC-ORD-03-AC3-double-apply-guard` (`tests/integration/ord03_ordering_test.zig`)

### TC-ORD-03-AC4-apply-failed-rollback: a typed apply failure rolls back state and cursor together
**Given:** A `PENDING` row for correlation X at `sequence_no = 5` with `applied_seq = 4`, and a claim
whose `completion_id` is malformed (so the apply's `completion_id = $1::uuid` cast fails with
SQLSTATE 22P02 — a typed apply error).
**When:** `applyCompletion` runs inside a transaction that is rolled back on `.apply_failed`.
**Then:** Returns `.apply_failed` (not `.applied`, not `.deferred`); after the rollback the row is
still `PENDING`, `applied_seq` is still 4, and no event was appended — applied state and
`applied_seq` cannot diverge.
**Layer:** integration
**Acceptance criterion mapped:** AC4
**Zig test:** `TC-ORD-03-AC4-apply-failed-rollback` (`tests/integration/ord03_ordering_test.zig`)

### TC-ORD-03-AC5-sweep-stalled-to-dead: the gap sweeper dead-letters a stalled correlation as one unit
**Given:** Correlation X with `applied_seq = 1` and `PENDING` rows at sequence 3 and 4 whose
`received_at` is older than `gap_timeout_seconds` (predecessor sequence 2 absent); a second
correlation Y that is NOT stalled.
**When:** `sweepStalledCorrelations(conn, gap_timeout_seconds)` runs with a timeout that makes X's
rows old.
**Then:** Every `PENDING` row of X moves to `DEAD` (in one transaction — both 3 and 4); the returned
`SweptCorrelation` for X carries `correlation_id = X`, `unapplied_sequence_nos = [3, 4]`, and
`pending_row_count = 2` — the data a single DLQ `EFFECT_CORRELATION` entry carries; Y is not swept.
**Layer:** integration
**Acceptance criterion mapped:** AC5
**Zig test:** `TC-ORD-03-AC5-sweep-stalled-to-dead` (`tests/integration/ord03_ordering_test.zig`)

### TC-ORD-03-AC5-non-stalled-not-swept: a slow-but-present predecessor is not dead-lettered
**Given:** Correlation Y with `applied_seq = 2`, a `PENDING` row at sequence 3 (predecessor present,
cursor at 2), and a `PENDING` row at sequence 5 (gap), both older than the timeout.
**When:** `sweepStalledCorrelations` runs.
**Then:** Y is NOT swept (its lowest PENDING sequence 3 is exactly `applied_seq + 1`, so the
predecessor is present — the correlation is merely behind, not gapped); no `DEAD` rows for Y.
**Layer:** integration
**Acceptance criterion mapped:** AC5 (distinguishes "missing predecessor" from "slow correlation" — design open question 2)
**Zig test:** `TC-ORD-03-AC5-non-stalled-not-swept` (`tests/integration/ord03_ordering_test.zig`)

### TC-ORD-03-AC6-on-conflict-do-nothing: a re-inserted completion is absorbed
**Given:** `recordCompletion(X, 5)` already inserted one `PENDING` row.
**When:** `recordCompletion(X, 5)` runs again.
**Then:** No error; exactly one row exists for `(X, 5)` — the `ON CONFLICT (correlation_id,
sequence_no) DO NOTHING` clause absorbs the duplicate and no second apply can occur.
**Layer:** integration
**Acceptance criterion mapped:** AC6
**Zig test:** `TC-ORD-03-AC6-on-conflict-do-nothing` (`tests/integration/ord03_ordering_test.zig`)

### ord03_ordering: readOrInitCursor inserts a fresh row at applied_seq 0 (MissingCursorRow recovery)
**Given:** No `plat_correlation_cursor` row for correlation Z.
**When:** `readOrInitCursor(Z)` runs.
**Then:** Returns `0` and a cursor row at `applied_seq = 0` exists for Z.
**Layer:** integration
**Acceptance criterion mapped:** supports AC1/AC2 (the cursor must exist before the order guard reads it)
**Zig test:** `TC-ORD-03-AC0-read-or-init-cursor` (`tests/integration/ord03_ordering_test.zig`)

---

## Fixture isolation
All fixtures use per-test UUIDs for `correlation_id`, created via a real pool connection
(`makePool` pattern, `BPM_TEST_DB_URL`) and deleted in `defer` — the same pattern as
`tests/integration/ordering_consumer_test.zig` (genuine cross-connection semantics require
committed fixtures, so `TestHarness`'s single rolled-back transaction is not used here). No
module-level mutable state; no `error.SkipZigTest` on any MUST/SHOULD case.

---

## Run status (2026-08-16, `test-integration-ord03`)
8/9 tests pass. The single failure is `TC-ORD-03-AC5-non-stalled-not-swept` — expected fail-first:
`sweepStalledCorrelations`'s predicate is `p.lowest_seq > c.applied_seq` (missing `+ 1`), so a
slow-but-present correlation (whose lowest PENDING sequence equals `applied_seq + 1`) is wrongly
dead-lettered. Per the requirement (AC5: predecessor must be ABSENT) and the design's open question
2, the predicate should be `p.lowest_seq > c.applied_seq + 1`. Reported as an implementation
defect (BLOCKER) in the handoff.
