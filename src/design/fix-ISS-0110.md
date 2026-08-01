# Module: fix-ISS-0110 — scope `lock_timeout` narrowly around the line-99 `pg_advisory_lock` acquire inside `runMigrations()`

**Tracker:** GitHub #366 (reopened) / ISS-0107 regression at a different acquire site / recommended new local entry `ISS-0110`.
**Parent run:** `WF03-gh364-20260801` (parent issue GitHub #364 / ISS-0106).
**Parent handoff:** `3195ef19-1619-466f-be1c-5a0f8418014e` (Step 3, FAIL with GH-366 / GH-374 / GH-359 blockers).
**Blocker triage handoff:** `f7c3b8e2-4a1d-4f8e-9b2c-1e5a7d3f6c8b` (Step 03a, PASS — see `docs/issue-reports/WF03-gh364-20260801-step-03a-issue-fixer-blockers-INNER-REPORT.yaml`).
**GH-359 env verification handoff:** `d6f18058-b70a-4d2f-bcde-8ca847b1f397` (Step 03b, PASS — precondition-already-false; shadow table absent).
**Reopened-issue comment:** `https://github.com/tvolodi/R-Co/issues/366#issuecomment-5149832990`.
**Classification:** **Type E** (cross-cutting — DB-driver timeout + test-helper critical-section interaction). This is novel design work: it scopes a session-level `lock_timeout` override around an existing advisory-lock acquire, distinct from any template pattern, and the design must reason about Postgres session vs. statement vs. transaction timeout semantics, lock-key disjointness, and failure-path correctness across `TestHarness.init()`. Not a CRUD endpoint, not a list page, not a migration, not a React Flow node. Per `templates/lego-catalog.md` selection rule 5 ("Type E otherwise") this is unambiguously Type E.

---

## Summary

GitHub #366 / ISS-0107 (MAJOR → re-opened to BLOCKER for this regression). The closed `fc5884b` (Rework 1) fix to ISS-0107 already brackets the **widened** `bpm_test_migrations_public` advisory-lock acquire at `tests/integration/helpers.zig:486-488` with `SET lock_timeout = '90s'` / `SET lock_timeout = '5s'`, and that bracket works: TC-DB-01-01/02 are no longer cancelled at the line-487 acquire. But the proven Rework-1 pattern is **not applied at the OTHER `pg_advisory_lock(hashtext('bpm_test_migrations_public'))` acquire site in this file — the one inside `runMigrations()` at `tests/integration/helpers.zig:99`** — and that other site is now the next-bottleneck acquire under the same concurrent-binary queue. When the back of the queue reaches that line-99 acquire, Postgres cancels it with `55P03` ("canceling statement due to lock timeout") under the ambient `lock_timeout='5s'` set by `configureSessionTimeouts()` (called earlier in the same `TestHarness.init()` at `tests/integration/helpers.zig:432-437`). The error propagates as `runMigrations failed: error.ServerError` and aborts `TestHarness.init()` for every binary that lands at the back of the queue.

**Captured evidence (from `scratch/WF03-gh364-20260801-step03-full-integration-utf8.log`):**

- 44 occurrences of `C55P03 canceling statement due to lock timeout ... runMigrations failed: error.ServerError ... helpers.zig:99:5: ... in runMigrations ... conn.exec("SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))", .{}) ... helpers.zig:442:13: ... in init` (sample line offsets in the log: 70, 97, 124, 160, 187, …).
- 2 genuine `C40P01 deadlock detected` events at unrelated business-table OIDs (lines 16, 660 in the log) — a different sub-symptom of the same queue-depth / cross-binary contention class; not in scope of this design (see "Non-solutions and what they are not" below).
- Zero occurrences of any `iss503` / `test_iss503` / `iss503_rls_removal` identifier in any failure window → the previously-approved #364 barrier (commit `35471e7`) remains effective and is not the cause. **This design explicitly does not touch the barrier or the `test_iss503_rls_removal.zig` doc comment.**

This is a code defect (a regression of the closed ISS-0107 fix at a different acquire site), not an environment problem: reproducing on a freshly-migrated, empty-row `db_test` container (verified by the Step 3 inner report) yields the same 44× `55P03` count. The fix is the minimal, root-cause-correct extension of the proven Rework-1 pattern to the second (and final) advisory-lock acquire site in `TestHarness.init()` that guards a critical section wide enough to admit queue pressure. No retry, no sleep, no global timeout inflation, no driver change, no second lock key.

---

## Root cause (definitive, source- and log-verified)

`TestHarness.init()` in `tests/integration/helpers.zig` calls, in order, on a single direct `pg.Conn` obtained via `pg.Conn.connectUrl()` (line 428), with `conn.begin()` deferred to line 516 (well after the section this fix concerns itself with has completed):

1. `configureSessionTimeouts(&conn)` (line 432-437) — calls, in order, `SET lock_timeout = '5s'`, `SET statement_timeout = '60s'`, `SET idle_in_transaction_session_timeout = '120s'`. All three are plain session-level `SET`s with no transaction open at the time; they apply to every subsequent statement on this connection for the rest of the session until explicitly changed again.
2. `runMigrations(io, allocator, &conn, url)` (line 441) — internally acquires `SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))` at line 99, released via `defer` at line 100. **Unprotected by any `lock_timeout` override.** This acquire is on the **narrow** migration check-and-apply critical section.
3. `runMigrationsForSchema(io, allocator, &conn, "tenant_default", url)` (line 449) — internally acquires a per-schema-keyed advisory lock at line 144, released via `defer` at line 145. **Also unprotected.** This acquire guards a narrow per-schema migration pass.
4. `pg_advisory_lock(hashtext('bpm_test_migrations_public'))` (the **WIDENED** acquire at line 487, the one Rework-1 bracketed) — already correctly bracketed by `SET lock_timeout = '90s'` (line 486) / `SET lock_timeout = '5s'` (line 488), with explicit `pg_advisory_unlock` at line 505. This guards the widened section covering `configureTestSearchPath() / resetTestData() / ensureDefaultOidcSeeds() / applyCompatibilityShims()`.

The 55P03 errors in the captured log are stack-traced to **step 2 (line 99)**, not step 4. Why: `fc5884b`'s widening of the line-487 critical section + Rework-1's `lock_timeout='90s'` bracket around line 487 means the *front* of the queue (those who get the lock at line 487) now holds the lock for the whole widened section's worth of work. The *back* of the queue (those who would have queued at line 487 in the pre-fc5884b era) instead serializes at the **earlier** acquire at line 99 — and waits behind the same widened front, for roughly the same total wall time as line 487's queue used to. The ambient `lock_timeout='5s'` was tuned for the narrow line-99 critical section; the back-of-queue now legitimately needs more than 5s to acquire the line-99 lock because the lock holder is busy in line-487's widened section, not in line-99's narrow migration check-and-apply. The same mechanism Rework-1 fixed for line 487 — the ambient 5s ceiling cancelling an otherwise-valid queue wait — now manifests at line 99.

**Why the line-99 acquire is "earlier" than line-487:** `runMigrations()` (which contains the line-99 acquire) is called at line 441 of `init()`, BEFORE the line-487 acquire. So all ~19+ binaries first queue at line 99, and the line-99 lock is held across `markPublicGlobalSkipsApplied()` + the entire `Migrations.run()` call (which itself is a long DDL walk over the canonical `migrations/` directory — the one that needs to read every file, parse it, and either apply or skip against the canonical `public.schema_migrations` table). The line-99 critical section is not as narrow as the doc comment suggests once the migration set reaches the size the current repo carries. The pre-ISS-0107 era masked this because the line-487 acquire used to be effectively no-op (it duplicated the line-99 acquire with no extra work), so the two acquires were effectively one acquire; after `fc5884b` they are no longer the same code path.

---

## Fix scope confirmation

Exactly **1 file**, exactly **1 function** (`runMigrations()`), exactly **2 lines added** to the source file (the SET bracket above and below the existing `try conn.exec("SELECT pg_advisory_lock(...)", ...)` at line 99):

- `tests/integration/helpers.zig` — bracketing pair: add `try conn.exec("SET lock_timeout = '90s'", &.{});` immediately before the existing line-99 `pg_advisory_lock` acquire, and `try conn.exec("SET lock_timeout = '5s'", &.{});` immediately after it succeeds and before `markPublicGlobalSkipsApplied(conn)`. Both are plain sequential `SET`s (NOT `SET LOCAL`, NOT `defer`, NOT `errdefer` — see "Failure-path correctness" below). No other file requires changes for the same reasons the Rework-1 design gave: `Migrations.run()`/`runForSchema()` (`src/db/migrations.zig`) were re-read in full during the prior ISS-0107 investigation and confirmed to contain no locking or timeout configuration of their own by design; this is a caller-side (`helpers.zig`) concern, not a migrator-side concern. `build.zig` requires no change: this is the same function-internal timeout-scoping pattern, not a build-graph/barrier problem.

Stays well within the ≤5 file Fix Scope Rule (1 of 5).

---

## Required change (exact source delta)

At the **inside** of `fn runMigrations(...)` in `tests/integration/helpers.zig`, around the existing `try conn.exec("SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))", &.{});` at line 99:

```zig
// ... existing code: function signature, doc comment through line 98 ...
// GH-366 / ISS-0107 regression: bracketing the line-99 acquire with the same
// '90s'/'5s' lock_timeout scoping that fc5884b's ISS-0107 Rework-1 already
// applies at the (different) line-487 widened acquire. The line-99 critical
// section's "narrow" assumption no longer holds under the post-fc5884b queue
// depth: the lock holder is now busy in the line-487 widened section, so
// the back of the queue legitimately needs more than the ambient 5s ceiling
// to acquire this lock. See src/design/fix-ISS-0110.md for full analysis
// and src/design/fix-ISS-0107.md for the proven Rework-1 pattern this
// brackets. Plain sequential SET (not SET LOCAL — the connection is not
// inside a transaction at this point; not defer/errdefer — errdefer
// conn.close() on the caller already discards the whole connection on any
// error path, and a function-scope defer would not fire until after the
// function returned, which is too late).
try conn.exec("SET lock_timeout = '90s'", .{});
try conn.exec("SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))", &.{});
try conn.exec("SET lock_timeout = '5s'", &{});

try markPublicGlobalSkipsApplied(conn);
// ... rest of runMigrations() unchanged ...
```

That is the entire change. Two `try conn.exec(...)` lines added above the existing line-99 acquire, one added below. No edits to the existing `defer conn.exec("SELECT pg_advisory_unlock(...)")` (line 100) — it remains the correct release point, immediately after the now-restored 5s ceiling.

---

## Why this is not a symptom-masking workaround

This repo's established convention (`docs/anti-patterns.md` Database/Migrations table; `fix-ISS-0106.md`'s explicit rejection of lock-timeout/retry workarounds; `fix-ISS-0107.md`'s own rejection of candidate (c) for the original deadlock; `ISS-0107.json.chosen_resolution` "WHY (c) IS REJECTED HERE") prohibits retry/timeout workarounds that mask a root cause. This fix must justify itself against that convention on its merits:

- **What `lock_timeout` is for:** catching a session stuck waiting on a lock longer than is ever expected under normal operation (genuine hang, undetected deadlock, runaway lock holder). An unbounded wait is itself a bug; `lock_timeout` converting it into a prompt, diagnosable error is the correct, desired behavior. This protection must not be blunted globally.
- **What it is now incidentally doing at line 99, post-fc5884b:** cancelling a wait that is not a hang, not unbounded, and not a bug — it is a *finite, fully-expected* queue wait behind at most (N − 1) other binaries' worth of the exact same short, bounded sequence (one migration freshness check + the canonical `Migrations.run()` DDL walk + one widened-critical-section-worth of TRUNCATEs + a handful of DROP/CREATE TRIGGER/FUNCTION statements), where N is the count of `test-integration` binaries (~22, confirmed by counting `test_integration_others_step.dependOn(...)` entries in `build.zig`). This is precisely the "fully serialized instead of racily concurrent" behavior `fc5884b` introduced as its own stated tradeoff — every binary queuing for its turn is the prior fix working as designed, not a symptom of anything going wrong.
- **The two are distinguishable by what's on the other end of the wait.** `lock_timeout` cannot itself tell the difference between "stuck behind a real hang" and "stuck behind a deliberately-widened critical section", so the design's job is to keep the protection on for the rest of the file and lift it **only for the one acquire whose queue target was deliberately widened by the prior fix and which therefore legitimately needs more than the ambient 5s ceiling to acquire**. The 5s protection is the right ceiling for the per-schema-keyed acquire at line 144 (still a narrow critical section) and for every other `lock_timeout`-governed wait in the file.
- **The 90s override is not a free pass.** Even at 90s, a truly-hung session is still cancelled well within a developer's attention span and the test pipeline's overall timeout budget (the `zig build test-integration` step's runner-level timeout is much longer than 90s). 90s is generously enough for a worst-case N=22 queue × ~3-4s per binary's worth of work to drain, and tight enough that a real hang surfaces as a 55P03 within a single dev's tea break rather than as an overnight `zig build test-integration` that nobody notices hung.
- **Safety net, second independent timeout.** The same `configureSessionTimeouts()` call also sets `statement_timeout = '60s'` (line 205). Even if a future code change accidentally re-widens the line-99 critical section past 90s, `statement_timeout` still cancels the inner migration `Migrations.run()` call within 60s of any one statement going long — that is an independent safety net untouched by this fix, and is one of the two safety nets the ISS-0107 Rework-1 design explicitly relied on to justify not making the lock_timeout override session-wide.
- **Why not just raise the ambient `lock_timeout` from 5s to 90s globally?** Because that would (a) blunt the genuine-hang protection for the per-schema lock at line 144, (b) blunt the same protection for any future narrow-section acquire the harness adds, (c) convert the design's principled "one acquire's queue was deliberately widened, so that one acquire's ceiling is also deliberately raised" reasoning into a blanket inflation that would be the textbook "widening a critical section's scope without checking interaction with an existing timeout" anti-pattern — the very anti-pattern `fix-ISS-0107.md`'s "Prevention" section (`ISS-0107.json.prevention[0]`) was specifically added to warn against, and which `docs/anti-patterns.md` (Database / Migrations table) now catalogs as a cross-referenced general-purpose lesson linked to GitHub #366 itself. A blanket 5s→90s change at this site would re-introduce the same anti-pattern the closed ISS-0107 work explicitly designed around.

---

## Failure-path correctness

The bracketing is plain sequential `SET`, NOT `SET LOCAL`, NOT `defer`/`errdefer`. This is load-bearing for three reasons and was validated by the ISS-0107 Rework-1 design that this fix mirrors exactly:

1. **Why not `SET LOCAL`:** `SET LOCAL` only takes effect inside an open transaction and is reset at `COMMIT`/`ROLLBACK`. The line-99 acquire runs on the harness's direct connection, which is not inside a transaction at this point (`conn.begin()` is at line 516, well after the entire section this fix concerns). `SET LOCAL` would be silently rejected by Postgres with a warning that the test harness does not surface, leaving the ambient 5s ceiling in effect — i.e. the fix would be a no-op. Plain session-level `SET` is the only correct option here.
2. **Why not `defer`:** a function-scope `defer` on the `SET lock_timeout = '5s'` would only fire when `runMigrations()` returned. That is too late: the `defer` would run AFTER `markPublicGlobalSkipsApplied(conn)` and AFTER `Migrations.run()` (the long DDL walk), which means the inner DDL walk would be running with the elevated 90s ceiling rather than the protected 5s ceiling. The 5s protection would be effectively removed for the entire migration body — the very thing this fix is meant to preserve, and the very thing the ISS-0107 Rework-1 design explicitly called out as a reason to avoid `defer`.
3. **Why not `errdefer`:** an `errdefer` would only run on the error path. On the success path, the plain sequential `SET lock_timeout = '5s'` immediately after the acquire already restores the ambient 5s. On the error path, the caller's pre-existing `errdefer conn.close()` (line 430) discards the whole `*pg.Conn` on any error from any statement in `runMigrations()`, so any un-restored `lock_timeout` would be discarded along with the connection — no leak, no cross-binary contamination, no need for an `errdefer` to handle the error path separately. (The same logic was source-verified by the ISS-0107 Rework-1 design, which reached the same conclusion for the line-487 acquire.)

The existing `defer conn.exec("SELECT pg_advisory_unlock(hashtext('bpm_test_migrations_public'))", &.{}) catch {};` at line 100 is unchanged — it still releases the advisory lock at function return, after the 5s ceiling has been restored, exactly as today.

---

## What this fix does NOT do (explicit non-solutions)

- **Does not retry on 55P03.** Retries mask queue depth, can starve the queue, and violate the repo's no-retry-workaround convention. `pg.zig` propagates `PgError.ServerError` from `ErrorResponse` correctly today; the design assumes that propagation continues to hold.
- **Does not raise the ambient `lock_timeout='5s'` set by `configureSessionTimeouts()`.** The 5s ceiling is the right value for the per-schema-keyed acquire at line 144, the migration body's DDL walk (whose per-statement safety is already covered by `statement_timeout='60s'`), and every other acquire site in the file. Inflating it globally would blunt genuine-hang protection and is the exact anti-pattern the closed ISS-0107 work was designed to prevent.
- **Does not introduce a second lock key.** A second key would only provide mutual exclusion within each key's own critical section, never across them, and would reopen the same cross-binary race that ISS-0107's chosen_resolution explicitly considered and rejected (see `ISS-0107.json.chosen_resolution` "WHY A SECOND LOCK KEY IS REJECTED HERE").
- **Does not remove the line-99 lock.** It is essential — it serializes the `public` migration check-and-apply pass for exactly the same reason ISS-0090 originally required it, and removing it would re-introduce the race that ISS-0090's fix was filed to prevent.
- **Does not globally serialize all ~19+ test-integration binaries.** The #364 barrier already serializes ISS-503 out of the concurrent group; the remaining ~19+ are deliberately concurrent, and globally serializing them would erase the throughput gain the #364 barrier introduced.
- **Does not touch `build.zig` or the #364 barrier.** The barrier structure is proven correct (Step 3 verification: zero `iss503` identifiers in any failure window). The 55P03 errors are a function-internal timeout-scoping problem, not a scheduling/ordering problem.
- **Does not touch `tests/integration/test_iss503_rls_removal.zig`.** That file's doc comment block (cross-referencing ISS-0106/#364 and the barrier) is documentation-only and already complete; no behavioral change is needed.
- **Does not change `vendor/pg/pg.zig`.** The driver already correctly propagates `PgError.ServerError` from `ErrorResponse`; no retry path, no error-swallowing, no pool-level conversion to empty success.
- **Does not delete or weaken the 55P03 detection at line 99.** The error must still surface so that a future genuine hang (not a queue wait) still produces a 55P03; the fix just makes the lock acquire tolerate the legitimate queue-wait case.

---

## Verification plan

### Acceptance bar (all required to PASS)

1. `zig build` exits 0.
2. `zig build test` exits 0.
3. `zig build migrate` exits 0.
4. Error-set validation: `zig build 2>&1 | grep -i "error set"` produces zero output.
5. **Focused test target** `zig build test-integration-iss503` exits 0 — proves the barrier-respected serial path is unaffected (the `iss503` test binary takes the line-487 widened acquire, which is now bracketed by the proven `fc5884b` pattern, AND the line-99 acquire, which is now bracketed by THIS fix).
6. **Full `zig build test-integration`** exits 0.
7. **Direct log scan** of the full-suite log:
   - `select-string -path <log> -pattern helpers.zig:99 -simplematch` → 0 matches in any error/failure window (the bracketed acquire is no longer a 55P03 source).
   - `select-string -path <log> -pattern "C55P03|55P03|canceling statement due to lock timeout" -simplematch` → 0 matches in any error/failure window.
   - `select-string -path <log> -pattern "C40P01|40P01|deadlock detected" -simplematch` → 0 matches in any error/failure window (the 2 deadlocks observed in the pre-fix log were an unrelated sub-symptom; this design does not claim to fix them, but a clean re-run with the line-99 bracket applied is expected to also reduce/eliminate them because the queue depth at the OTHER acquire (line 487, the actual deadlock source) is now bounded by the 90s ceiling, not by 55P03-cancelled acquires leaving the queue half-formed).
   - `select-string -path <log> -pattern "iss503|iss_503|ISS-503|test_iss503|test-integration-iss503|iss503_rls_removal" -simplematch` → 0 matches in any deadlock/failure window (the #364 barrier remains effective; this fix does not touch it).
8. **TC-DB-01-01 and TC-DB-01-02 pass from actual test output** — `select-string -path <log> -pattern "TC-DB-01-01|TC-DB-01-02" -simplematch` must show the actual passing test output for both (not just the absence of a failure line).
9. **Tracked-file git status is clean** (`git status --short` for tracked files is empty after the commit; only the workflow artefact files under `handoffs/`, `docs/issue-reports/`, and `scratch/` may be untracked/modified).

### Focused regression tests (new tests added by this design)

**Design-side guidance (the implementation is BACKEND-DEV's job; this is the design prescription):**

10. **Re-run the existing `zig build test-integration` capture-and-scan procedure** (the same procedure the Step 3 inner report performed) over the post-fix full-suite log and confirm items 7 and 8. This is the design's primary verification.
11. **Add a small regression assertion script** (under `scratch/`, never committed) that scans the full-suite log for the line-99 helper stack frame, asserts zero occurrences in any error window, and writes a 1-line PASS/FAIL summary. This is the same kind of post-hoc evidence the existing `tests/reports/report-20260731-WF03-iss0106-20260731-step05-verify.yaml` produced, and is meant to be the artifact DOC-UPDATER references when closing GitHub #366.
12. **Re-run the closed-ISS-0107 verification gates** end-to-end to ensure the new bracket does not regress the proven `fc5884b` pattern:
    - `zig build test-integration-iss503` still exits 0 (narrow target preserved).
    - A 2-binary concurrent pair run (any two of the existing integration binaries in the same `zig build test-integration` invocation) completes without 55P03 at either the line-99 OR the line-487 acquire — confirms the queue behaves correctly under contention at both sites now that both are bracketed.
    - A 22-binary concurrent run (the full suite) still completes with zero 40P01 / zero 55P03 / zero `iss503` identifiers in any failure window — the full acceptance bar.

### Abort conditions

- If any of items 1-9 fail: route back to CODE-DESIGNER for rework (rework 1 of 3).
- If the line-99 acquire is still the source of 55P03 after the fix: the bracket is not in the right place or the wrong key — route back to CODE-DESIGNER for rework with the captured log.
- If the `fc5884b` Rework-1 pattern at line 487 is now observed to fail (new 55P03 at line 487 that was not present before): the new line-99 bracket has inadvertently affected the line-487 acquire's behavior — route back to CODE-DESIGNER (this would indicate a misunderstanding of session vs. statement scope).
- If the design's "no_iss503_overlap" property is broken (any `iss503` identifier appears in a deadlock/failure window): the #364 barrier is broken — escalate immediately to ORCH (this is a regression of the previously-approved barrier, not a blocker-fix issue).

---

## Data flow / control flow

```
TestHarness.init()  (helpers.zig:422-)
  ├─ connectUrl → conn          (errdefer conn.close on caller)
  ├─ configureSessionTimeouts   SET lock_timeout='5s' (ambient)
  ├─ runMigrations()            ◄── THIS FUNCTION (ISS-0110 bracket)
  │    SET lock_timeout='90s' ─── ISS-0110 NEW
  │    pg_advisory_lock          ◄── line 99 acquire (was 55P03)
  │    SET lock_timeout='5s'  ─── ISS-0110 NEW (restore)
  │    markPublicGlobalSkipsApplied
  │    Pool.init → Migrations.run
  │    defer pg_advisory_unlock  ◄── line 100 release
  ├─ provisionTenantSchema
  ├─ runMigrationsForSchema      (narrow, 5s ambient, line 144)
  ├─ SET lock_timeout='90s'      ◄── fc5884b (unchanged)
  │    pg_advisory_lock           ◄── line 487 widened acquire
  │    SET lock_timeout='5s'      ◄── line 488 restore
  ├─ configureTestSearchPath
  ├─ resetTestData               (11× TRUNCATE)
  ├─ ensureDefaultOidcSeeds
  ├─ applyCompatibilityShims
  ├─ pg_advisory_unlock          ◄── line 505 release of widened lock
  └─ conn.begin                  (line 516, per-test tx)
```

Both bracket pairs (line 99 / 487) operate on the same connection sequentially; the 90s ceiling is in effect only for the literal `pg_advisory_lock` statement at the line, then immediately restored to 5s for the rest of the connection's lifetime. They do not interact with each other because they are temporally disjoint on any single connection.

---

## Public interface change

**None at the public function level.** The change is internal to the body of `fn runMigrations(...)` in `tests/integration/helpers.zig`. `TestHarness.init()`'s signature, the function's return type, and every other call site are unaffected. The change is invisible to every test that uses `TestHarness` (i.e. every test in the integration suite except `tests/integration/test_iss503_rls_removal.zig`).

The internal call surface of `runMigrations` itself is also unchanged: same parameters, same return type, same error set. The only added effect on the connection is that the ambient `lock_timeout` is briefly lifted to 90s for the duration of the one acquire statement at line 99, then restored.

---

## Error taxonomy

No new error cases are introduced. The error set of `runMigrations` is unchanged:

- `pg.Conn.exec` errors propagate exactly as before (network, auth, syntax, etc.).
- The pre-existing `try` / `catch` / `defer` patterns in the function body are unchanged.
- A 55P03 at the line-99 acquire is still possible if the queue depth is so extreme (e.g. > 22 binaries' worth of work, which is not the case in this repo's current binary count) that 90s is still not enough; in that scenario, the error is still surfaced via `pg.zig`'s `PgError.ServerError`, propagated up `TestHarness.init()`, and reported as `runMigrations failed:` — but the failure would be a real signal of a queue-depth pathology that requires structural intervention, not a routine occurrence that masks itself.

The new `SET lock_timeout = '90s'` and `SET lock_timeout = '5s'` statements can themselves fail (e.g. if the connection is closed between statements). In that case, the pre-existing `try` propagation returns the error to the caller, the `errdefer conn.close()` at line 430 discards the connection, and the next caller's `runMigrations` starts with a fresh connection. No partial state is observable.

---

## Dependencies

**Calls into:**

- `pg.Conn.exec` (`vendor/pg/pg.zig`) — unchanged; still propagates `PgError.ServerError` from `ErrorResponse`. No driver change.
- `bpm.pool.Pool.init`, `bpm.migrations.Migrations.run` (`src/db/migrations.zig`) — unchanged; neither sets or reads `lock_timeout` itself. The migrator is intentionally a "dumb applier" that does not manage session timeouts; that responsibility stays with the caller (the harness), as confirmed by the closed ISS-0107 investigation.

**Does not depend on / must not depend on:**

- `Migrations.runForSchema()` (used at line 144 in `runMigrationsForSchema()`, not in `runMigrations()`).
- `configureSessionTimeouts()` — already called once at line 432-437 of `init()`, before `runMigrations()` runs. The new bracket at line 99 must respect the ambient value the prior call set; the design specifies that explicit "respect" by bracketing exactly to the line-99 acquire, not the entire function body.
- `build.zig`'s test-integration graph — not in scope (per "What this fix does NOT do" above).

---

## State transitions

`runMigrations()` has no externally-observable state machine. The internal sequence on the direct connection is:

```
[unlocked] ──SET 90s──► [about-to-acquire-90s] ──pg_advisory_lock──► [locked-90s] ──SET 5s──► [locked-5s] ── ... ──defer unlock──► [unlocked]
```

Each state is a sub-millisecond transition except the `[locked-90s]` and `[locked-5s]` states, which are the actual work the function does. The bracket ensures the only statement that runs in the elevated `lock_timeout` regime is the one acquire itself.

---

## Open questions

None blocking. Two minor items for REQ-ANALYST / future maintenance:

- **If a third advisory-lock acquire is ever added to `TestHarness.init()` or `runMigrations()` or `runMigrationsForSchema()`:** the developer must apply the same `SET '90s'` / `SET '5s'` bracket pattern at that acquire site, and update `docs/anti-patterns.md`'s "Database / Migrations" table cross-reference to GitHub #366 / ISS-0110 with the new site. This is a known maintenance burden, not a design defect.
- **If the `test-integration` binary count ever exceeds ~22 in a way that pushes the worst-case wait past 90s:** the 90s value may need to be revisited. The current count is 22, and 90s leaves ~4s of headroom per binary's worth of work — comfortable. If the count grows, recompute as `4s × N + safety margin` and document the new value with a back-reference to this design. The `statement_timeout='60s'` set by `configureSessionTimeouts()` is an independent ceiling that does NOT need to be revisited (it bounds single-statement time, not queue time).

---

## Cross-references

- **Parent design:** `src/design/fix-ISS-0106.md` (build-graph barrier; #364; UNCHANGED by this design).
- **Predecessor design:** `src/design/fix-ISS-0107.md` (widened-lock + Rework-1 `lock_timeout='90s'`/`'5s'` pattern at line 487; UNCHANGED by this design and the exact pattern this fix mirrors at line 99).
- **Local issue:** `docs/issues/ISS-0107.json` (RESOLVED, retained as historical record; recommended new local entry `ISS-0110` will be registered by ISSUE-FIXER as the regression tracker).
- **GitHub issue:** https://github.com/tvolodi/R-Co/issues/366 (reopened via comment 5149832990; to be closed again by DOC-UPDATER after this fix lands and verifies).
- **Blocker triage:** `docs/issue-reports/WF03-gh364-20260801-step-03a-issue-fixer-blockers-INNER-REPORT.yaml` (Step 03a, ISSUE-FIXER, 2026-08-01).
- **Step 3 inner report:** `docs/issue-reports/WF03-gh364-20260801-step-03-backend-dev-INNER-REPORT.yaml` (BACKEND-DEV, 2026-08-01; FAIL — full-suite evidence cited above).
- **Anti-patterns entry:** `docs/anti-patterns.md` Database/Migrations table, "Widening an existing lock's or other critical section's scope to fix a concurrency bug, without checking whether a pre-existing, unrelated session/statement-level timeout already governs waits inside or around that section" — already cross-references GitHub #366 / ISS-0107, and should be updated by DOC-UPDATER to also cross-reference this fix and ISS-0110 to capture the new general lesson: "when a critical section is widened, audit EVERY acquire site in the function, not just the one that was widened; multiple acquire sites can each independently begin to see queue-depth-induced 55P03 cancellations."

---

*No code is implemented by this design artefact. The change is 1 file, 1 function, 2 lines added (plus a 5-line comment block).*
