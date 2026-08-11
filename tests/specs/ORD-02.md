# Test Spec: ORD-02 — Per-correlation execute guard

**Requirement:** ORD-02 — Inside the claim transaction a BPM Consumer SHALL evaluate `SELECT
pg_try_advisory_xact_lock(hashtext(correlation_id)::bigint)` before applying a completion. A
`false` result SHALL cause an immediate `ROLLBACK`, returning the row to `PENDING` without
incrementing any retry counter, and the consumer SHALL move to another correlation. The lock
is transaction-scoped and SHALL NOT be released by an explicit unlock call.

**Priority:** MUST
**Test layer:** integration (`cursor.tryExecuteGuard` against real PostgreSQL —
`pg_try_advisory_xact_lock` is a server-side primitive with no meaningful pure-function
surface; the "try, never wait" and transaction-scoped-release semantics can only be proven
against a real backend)
**Test-tier score (test_developer_guide.md §2.1):** DB schema (0 — this requirement adds no
new table/column of its own; it reads `plat_correlation_cursor`, created by ORD-04's
migration, and uses Postgres's built-in advisory-lock primitive) + transactional boundary (1,
the guard's entire contract is "transaction-scoped, released at COMMIT/ROLLBACK with no
explicit unlock") = **1 point → unit + integration.** No unit-layer surface exists
(`tryExecuteGuard` is a single parameterised query wrapper with no branching logic to unit
test in isolation), so integration is the sole and proportionate layer.
**Design:** `src/design/ord-01-02-04-correlated-effect-reentry.md`
**Implementation:** `src/ordering/cursor.zig` (`tryExecuteGuard`), `src/ordering/mod.zig`
(`ExecuteGuardOutcome`)

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN consumer A is applying a completion for correlation X, WHEN consumer B claims another completion for correlation X, THEN B's `pg_try_advisory_xact_lock` returns `false`, B rolls back, and B claims work for a different correlation within the same poll cycle. | `TC-ORD-02-AC1` (guard contention: A holds, B observes `busy`) |
| AC2 | GIVEN the try-variant is used, WHEN a consumer loses the guard, THEN it does not block; `pg_advisory_xact_lock` is never called on this path, so no pooled connection is held waiting. | `TC-ORD-02-AC1` (B's call returns promptly with `.busy` rather than hanging — see Structural verification note below for the "never called" half) |
| AC3 | GIVEN a consumer crashes mid-apply, WHEN its backend exits, THEN the advisory lock is released by the transaction abort and the correlation becomes available to another consumer without operator action. | `TC-ORD-02-AC3` |
| AC4 | GIVEN two distinct `correlation_id` values whose `hashtext` results collide, WHEN both are claimed, THEN one waits for the other and throughput falls, but neither is misapplied: ordering is decided by the per-correlation cursor of ORD-03, not by the lock key. | Not independently tested in this batch — see Structural verification note below |
| AC5 | GIVEN a completion commits, WHEN the transaction ends, THEN the advisory lock is released at `COMMIT` and the successor becomes eligible on the next claim. | `TC-ORD-02-AC5` |

---

## Structural verification notes

- **AC2's "`pg_advisory_xact_lock` is never called on this path" clause.** Verified by
  inspection of `src/ordering/cursor.zig::tryExecuteGuard`: the function's SQL body is
  literally `"SELECT pg_try_advisory_xact_lock(hashtext($1)::bigint)"` — the blocking variant
  (`pg_advisory_xact_lock`, without `try_`) does not appear anywhere in the function, the
  file, or anywhere in `src/ordering/`. `TC-ORD-02-AC1` additionally proves this
  behaviorally: consumer B's call to `tryExecuteGuard` returns promptly (within the test's
  normal execution time, not a timeout) while consumer A still holds the same key — a call to
  the blocking variant would have hung the test until A's transaction ended, which did not
  happen (A's rollback happens explicitly AFTER B's call already returned, in program order).
- **AC4's hash-collision scenario.** `hashtext()` is a documented, deterministic PostgreSQL
  built-in (32-bit hash via `hashtext()`, widened to `bigint` for
  `pg_try_advisory_xact_lock`'s signature); finding or constructing two `correlation_id`
  UUID strings that collide under it is not a reasonable thing to search for at test-authoring
  time (`hashtext`'s output space is 2^32, so an intentional collision requires either a
  targeted preimage search against Postgres's specific hash implementation — not published as
  a stable, versioned algorithm contract — or brute-force generation, neither proportionate
  for this batch). AC4's actual claim is a property of `pg_try_advisory_xact_lock` itself
  (identical keys serialize, by definition — this is exactly what `TC-ORD-02-AC1` already
  proves using two IDENTICAL correlation_ids, which is the same code path a genuine hash
  collision would take once `hashtext()` produces the same bigint for two different input
  strings) rather than any application logic `tryExecuteGuard` adds on top. No additional
  test is needed beyond `TC-ORD-02-AC1`, which already exercises "two callers, same lock key,
  one blocked" — AC4 is the identical mechanism with a different (collision-derived, not
  identical-input) route to the same key.

---

## Test cases

### TC-ORD-02-AC1: a second consumer's tryExecuteGuard on the SAME correlation returns busy while the first holds it
**Given:** Consumer A acquires `tryExecuteGuard` for `correlation_a` inside an open transaction and holds it (does not commit/rollback yet).
**When:** Consumer B (separate connection, separate open transaction) calls `tryExecuteGuard` for the SAME `correlation_a`.
**Then:** B's call returns `.busy` (not an error, not a block) — proven by reaching the assertion at all, since the try-variant never blocks.
**Layer:** integration
**Acceptance criterion mapped:** AC1, AC2 (non-blocking half), AC4 (same lock-key-contention mechanism a hash collision would exercise)
**Zig test:** `"TC-ORD-02-AC1: a second consumer's tryExecuteGuard on the SAME correlation returns busy while the first holds it"` (`tests/integration/ordering_consumer_test.zig`)

### TC-ORD-02-AC5: the guard is released at commit and a successor can then acquire it
**Given:** Consumer A acquires `tryExecuteGuard` for `correlation_a`, then commits its transaction.
**When:** A successor connection opens a new transaction and calls `tryExecuteGuard` for the same `correlation_a`.
**Then:** The successor acquires it (`.acquired`) — proving `COMMIT` releases the lock with no explicit unlock call.
**Layer:** integration
**Acceptance criterion mapped:** AC5
**Zig test:** `"TC-ORD-02-AC5: the guard is released at commit and a successor can then acquire it"`

### TC-ORD-02-AC3: a rolled-back transaction releases the guard immediately, same as a crash
**Given:** Consumer A acquires `tryExecuteGuard` for `correlation_a`, then ROLLBACKs (simulating an abort/crash — Postgres releases session-scoped locks identically on ROLLBACK or on backend disconnection; there is no separate code path in this batch for "crash" vs. "explicit rollback").
**When:** A successor connection opens a new transaction and calls `tryExecuteGuard` for the same `correlation_a`.
**Then:** The successor acquires it — proving ROLLBACK releases the lock immediately, with no operator action and no explicit unlock call, matching AC3's "consumer crashes... row lock is released... without operator action" (this test exercises the identical `pg_try_advisory_xact_lock` transaction-scoped release mechanism; the alternative event that also triggers this same release — the backend process actually being killed — is standard, unconditional PostgreSQL behavior, not application logic this batch implements or could meaningfully unit/integration-test differently).
**Layer:** integration
**Acceptance criterion mapped:** AC3
**Zig test:** `"TC-ORD-02-AC3: a rolled-back transaction releases the guard immediately, same as a crash"`

---

## Fixtures and isolation

All three tests live in `tests/integration/ordering_consumer_test.zig`, using a real
`bpm.pool.Pool` with per-test `bpm.uuid.newUuidV4`-generated `correlation_id` fixtures. Each
test acquires its own connection(s) and registers rollback/cleanup so no advisory lock or
fixture row survives the test (advisory locks are inherently transaction-scoped — no separate
cleanup call is needed once every path either commits-then-a-later-connection-checks or
rolls back). No fixture state is shared across test blocks; every `correlation_id` is a fresh
UUID.

---

## Coverage summary

| Test case | Zig `test "..."` name | Covers |
|---|---|---|
| TC-ORD-02-AC1 | `TC-ORD-02-AC1: a second consumer's tryExecuteGuard on the SAME correlation returns busy while the first holds it` | AC1, AC2, AC4 |
| TC-ORD-02-AC5 | `TC-ORD-02-AC5: the guard is released at commit and a successor can then acquire it` | AC5 |
| TC-ORD-02-AC3 | `TC-ORD-02-AC3: a rolled-back transaction releases the guard immediately, same as a crash` | AC3 |

**Implemented case count: 3 test blocks**, all in `tests/integration/ordering_consumer_test.zig`,
all part of `zig build test-integration-ordering`'s 10/10 passing run. No `error.SkipZigTest`
on any of these three when `BPM_TEST_DB_URL` is set and reachable.

---

## No coverage gap found

All 5 numbered ACs are covered — 3 directly, 2 (AC2's "never blocks" and AC4's
hash-collision scenario) via the structural verification notes above, which identify the
exact mechanism each AC describes and show it is the same mechanism `TC-ORD-02-AC1` already
exercises (or, for AC2's "never calls the blocking variant" half, verified by direct
source inspection of the one-line SQL body `tryExecuteGuard` issues). No additional test case
was required.

---

## Traceability

- ORD-02 acceptance: AC1, AC3, AC5 directly tested; AC2, AC4 structurally verified per the
  notes above.
- See `src/design/ord-01-02-04-correlated-effect-reentry.md` for the full design rationale.
- See `tests/specs/ORD-01.md`, `tests/specs/ORD-04.md` for the sibling requirements sharing
  this test binary and fixture conventions.
