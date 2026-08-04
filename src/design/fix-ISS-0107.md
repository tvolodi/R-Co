# Module: fix-ISS-0107 — widen the existing `bpm_test_migrations_public` advisory lock to cover `resetTestData()` / `applyCompatibilityShims()`, and scope the pre-existing `lock_timeout` around the widened acquire

## Revision history

- **Original (this run's Step 2):** widen the `bpm_test_migrations_public`
  advisory lock to cover `resetTestData()`/`applyCompatibilityShims()`.
  Implemented verbatim by BACKEND-DEV (commit `5f25d99`). Verified over 3
  full `zig build test-integration` runs to eliminate the original 40P01
  deadlock storm (22 → 1 → 2 → 0 deadlocks, residual 1–2 confirmed unrelated
  to this critical section). **Not sufficient on its own**: it surfaced a
  new failure mode — later-queued binaries' own `pg_advisory_lock()` acquire
  call (the exact statement this fix added, `helpers.zig:473`) is itself
  cancelled by Postgres `55P03` ("canceling statement due to lock timeout")
  because of the pre-existing `lock_timeout = '5s'` session setting
  (`configureSessionTimeouts()`, set earlier in the same `TestHarness.init()`,
  unrelated in origin to this fix). 55P03 count trended 1 → 4 → 16 across the
  same 3 runs, inversely correlated with the falling deadlock count — the
  same underlying contention converted from one Postgres error code to
  another, not eliminated. TC-DB-01-01/02 still failed in all 3 runs. Full
  detail: `docs/issues/ISS-0107.json.verification_result`,
  `handoffs/WF03-iss0107-20260731/step-03-backend-dev.json`.
- **Rework 1 (this revision):** the widened-lock-scope fix from the original
  design is **kept unchanged** — it is proven to close the original deadlock
  window and is not the source of the new failure. Added: a precisely-scoped
  `lock_timeout` bracket around *only* the one widened-lock acquire statement
  at `helpers.zig:473`, raising it from `'5s'` to `'90s'` immediately before
  that one statement and restoring it to `'5s'` immediately after, leaving
  every other `lock_timeout`-governed wait in the file (the migration-pass
  lock at line 99, the per-schema lock at line 144, and everything after
  `conn.begin()` at line 516) at the original, untouched 5s. See "Why this is
  not a symptom-masking workaround" and "Timeout value — why 90s, not 0 /
  disabled" below for the full reasoning, and "Required change" for the exact
  scoping mechanics (including why `SET LOCAL` is not usable here).

## Summary

GitHub #366 / ISS-0107 (MAJOR). Under a full concurrent `zig build
test-integration` run, the ~19+ non-ISS-503 test-integration binaries
(exp103_instance_waits_test.zig, tnt_schema_isolation_test.zig,
iss205_webhook_outbox_test.zig, db_integration_test.zig, and every other
sibling that calls `TestHarness.init()`) deadlocked (40P01) against **each
other**, independent of ISS-0106's ISS-503 fix. ISSUE-FIXER's source-verified
root cause (`docs/issues/ISS-0107.json`): `TestHarness.init()` in
`tests/integration/helpers.zig` calls, in order, `runMigrations()` (locked),
`runMigrationsForSchema()` (locked), `configureTestSearchPath()`,
`resetTestData()` (was unlocked), `ensureDefaultOidcSeeds()` (unlocked DML),
`applyCompatibilityShims()` (was unlocked). Both advisory locks already in
this file were released before `resetTestData()`/`applyCompatibilityShims()`
ran, so every one of the ~19+ concurrently-running binaries executed
`resetTestData()`'s `TRUNCATE ... RESTART IDENTITY CASCADE` statements (which
Postgres always promotes to `AccessExclusiveLock`) and
`applyCompatibilityShims()`'s `DROP`/`CREATE TRIGGER`/`FUNCTION` DDL with zero
cross-process ordering. This produced genuine N-way circular
`AccessExclusiveLock` waits (40P01), corroborated by `42710`
("trigger ... already exists") and `23505` (`pg_proc` unique-violation)
errors from the unprotected DROP/CREATE-trigger race.

The original design's fix for that root cause — widening the scope of the
same, already-correct, already-battle-tested advisory lock this file already
used for the migration passes so it also covers `resetTestData()` and
`applyCompatibilityShims()` — is **confirmed correct and is retained
unchanged by this revision** (see "Rework 1" above and BACKEND-DEV's 3-run
verification data). What the original design did not anticipate is a
second-order interaction: widening a critical section that ~19+ independent
processes must now queue through necessarily increases each process's worst-
case wait time for that lock, and this file already carries an unrelated,
pre-existing `lock_timeout = '5s'` session setting whose job is to bound
*statement-level* waits on lock acquisition. Once enough binaries queue
behind the widened lock, that 5s ceiling is no longer generously long enough
for the *back* of the queue, and Postgres cancels those binaries' own lock
acquire statement (`55P03`) before the lock is ever granted to them —
converting the closed deadlock window into a new, still-blocking failure
mode. This revision scopes `lock_timeout` narrowly around exactly the one
acquire statement this fix's own widened critical section depends on,
leaving the 5s protection intact everywhere else in the file.

## Fix scope confirmation

Exactly the 1 file listed in `ISS-0107.json.files_to_change`, unchanged from
the original design:

- `tests/integration/helpers.zig` — the sole change, now covering both (a)
  the already-implemented widened-lock-scope fix (unchanged) and (b) the new
  `lock_timeout` scoping this revision adds, which sits immediately adjacent
  to (a)'s acquire statement in the same function (`TestHarness.init()`). No
  other file requires changes for the same reasons the original design gave:
  `Migrations.run()`/`Migrations.runForSchema()` (`src/db/migrations.zig`)
  contain no locking or timeout configuration of their own by design: this
  remains entirely a caller-side (`helpers.zig`) concern. `build.zig`
  requires no change: this is still not a build-graph/barrier problem — the
  new failure mode is a same-file, same-function interaction between two
  session settings, not a scheduling/ordering problem between binaries.
  Total: 1 file, well within the ≤5 constraint.

## Current structure (as read from `tests/integration/helpers.zig`, current branch — i.e. post-Rework-0/pre-Rework-1 state, with the original widened-lock fix already applied and committed at `5f25d99`)

`TestHarness.init()` (lines 413–520+) runs the following sequence on a
**single direct `pg.Conn`** obtained via `pg.Conn.connectUrl()` (line 427).
This connection is **not wrapped in a transaction until line 516**
(`conn.begin()`), which happens well after the entire section this fix
concerns itself with has already completed and the widened lock has already
been released. This fact is load-bearing for the "Required change" section
below — every statement discussed here, including the widened lock's
acquire/release, runs in Postgres's default autocommit mode on a plain
session connection, not inside any transaction.

The exact current sequence:

1. Connect (`pg.Conn.connectUrl`, line 427).
2. `configureSessionTimeouts(&conn)` (line 433) — calls, in order (lines
   200–206): `SET lock_timeout = '5s'`, `SET statement_timeout = '60s'`,
   `SET idle_in_transaction_session_timeout = '120s'`. **This runs before
   anything else in `init()`, including before `runMigrations()`.** All
   three settings are plain session-level `SET`s with no transaction open at
   the time, so they apply to every subsequent statement on this connection
   for the rest of the session (i.e. for the entire remaining life of
   `TestHarness.init()` and beyond, until explicitly changed again) — this is
   exactly why the pre-existing `lock_timeout = '5s'` was still in effect,
   unmodified, when the original design's newly-added acquire statement at
   line 473 started being cancelled.
3. `runMigrations(io, allocator, &conn, url)` (line 440) — internally
   acquires `SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))`
   at line 99, released via `defer` at line 100 at the end of
   `runMigrations()`'s own function body. **Unaffected by this revision** —
   this acquire already runs under the ambient 5s `lock_timeout` today and
   is not reported as a 55P03 source in BACKEND-DEV's 3-run data (only the
   *new*, widened acquire at line 473 was). It stays at the ambient 5s
   because it protects only the migration check-and-apply pass, which is a
   short, already-narrow critical section not implicated in this issue's
   queue-depth growth.
4. `runMigrationsForSchema(io, allocator, &conn, "tenant_default", url)`
   (line 448) — internally acquires a second, per-schema-keyed advisory
   lock at line 144, released via `defer` at line 145. **Also unaffected by
   this revision**, for the same reason as (3).
5. **The widened critical section added by the original ISS-0107 fix, lines
   453–505, unchanged by this revision except for the timeout bracket this
   revision adds immediately around line 473's acquire statement:**
   - Line 473: `try conn.exec("SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))", &.{});`
     — **the exact statement BACKEND-DEV's run 3 trace identified as the
     55P03 failure point.** This is the acquire this revision brackets.
   - `configureTestSearchPath(&conn)` (line 479).
   - `resetTestData(&conn)` (line 485) — eleven sequential
     `TRUNCATE TABLE ... RESTART IDENTITY CASCADE` statements.
   - `ensureDefaultOidcSeeds(&conn)` (line 490) — DML, not DDL.
   - `applyCompatibilityShims(&conn)` (line 495) — `DROP`/`CREATE
     TRIGGER`/`FUNCTION` DDL.
   - Line 505: `conn.exec("SELECT pg_advisory_unlock(hashtext('bpm_test_migrations_public'))", &.{}) catch {};`
     — release point, unchanged.
6. `bpm.api_tenant_context.set(...)`, then `conn.begin()` (line 516) — the
   harness's own per-test transaction starts only after all of the above,
   including the widened critical section's release, has completed.

The mechanism of the new failure: because `configureSessionTimeouts()` (step
2) runs once, at the very start of `init()`, and its `SET lock_timeout =
'5s'` has no expiry or re-scoping until something else explicitly changes
it, the 5s ceiling is still the ambient value when execution reaches line
473 — even though line 473's acquire is now waiting on a *much larger*
critical section (an entire other process's migration-check + 11 TRUNCATEs +
DDL shims) than the narrow, fast critical sections the other two acquires
(lines 99, 144) wait on. `lock_timeout` was configured with those narrower,
faster critical sections in mind; the original design's widening of the
critical section at line 473 changed what that acquire is waiting for
without correspondingly reconsidering how long it should be allowed to wait.

## Why this is not a symptom-masking workaround

This repo has an established convention against retry/timeout workarounds
that mask a root cause instead of fixing it (see `fix-ISS-0106.md`'s explicit
rejection of a lock-timeout/retry approach for a *different* problem, and
`ISS-0107.json.chosen_resolution`'s own rejection of candidate (c) for the
*original* deadlock). This revision's proposal — raising `lock_timeout`
around one specific statement — needs to be justified against that
convention on its merits, not exempted from it. The distinction that makes
it a legitimate fix rather than a workaround is what `lock_timeout` is
actually *for*, versus what it is now incidentally doing:

- **What `lock_timeout` is for:** catching a session that is stuck waiting on
  a lock for longer than is ever expected under normal operation —
  typically because something else is genuinely hung, deadlocked without
  Postgres's own deadlock detector catching it in time, or holding a lock
  far longer than its operation should ever take. In that scenario, an
  unbounded wait is itself the bug, and `lock_timeout` converting it into a
  prompt, diagnosable error is the correct, desired behavior. This is a real
  protective mechanism and the design must not blunt it in general.
- **What it is now incidentally doing at line 473, post-widening:** cancelling
  a wait that is not a hang, not unbounded, and not a bug — it is a *finite,
  fully-expected* queue wait behind at most (N − 1) other binaries' worth of
  the exact same short, bounded sequence (one migration-freshness check +
  eleven single-table `TRUNCATE`s on near-empty test tables + a handful of
  `DROP`/`CREATE TRIGGER`/`FUNCTION` statements), where N is the number of
  `test-integration` binaries (~19–22, confirmed by counting
  `test_integration_others_step.dependOn(...)` entries in `build.zig`: 22).
  This is precisely the "fully serialized instead of racily concurrent"
  behavior the original ISS-0107 fix *intentionally* introduced as its own
  stated tradeoff (`fix-ISS-0107.md`'s original "Performance tradeoff"
  section, retained below) — every binary queuing for its turn behind this
  lock is the fix working exactly as designed, not a symptom of anything
  going wrong.
- **The two are distinguishable by what's on the other end of the wait.**
  `lock_timeout` cannot itself tell the difference between "stuck behind a
  hung process" and "queued behind 21 fast, well-behaved, sequentially-
  completing processes" — both look identical to Postgres as "waiting to
  acquire this lock." The distinction has to be made by whoever configures
  the timeout, with knowledge of what's expected to be on the other side.
  For this one acquire, we — the fix's authors — have that knowledge: we
  designed the wider critical section, we know its worst-case bound (see
  "Timeout value" below), and we know a wait longer than 5s here reflects
  queue position, not a hang. Scoping the timeout to reflect that specific,
  local knowledge — while leaving the *general* 5s protection in place for
  every other wait in the file, where no such special knowledge applies — is
  the definition of a precise fix, not a broad relaxation.
- **Contrast with what a workaround would look like:** a workaround would be
  raising or removing `lock_timeout` for the *entire session* (i.e. leaving
  `configureSessionTimeouts()`'s original `SET lock_timeout = '5s'` at line
  203 unchanged/untouched, or worse, changing it there), which would blind
  every other lock-acquisition wait in the file — including the two
  existing, already-correctly-scoped acquires at lines 99 and 144, and every
  wait inside the per-test transaction that begins at line 516 and runs
  arbitrary test-body business logic afterward — to genuine hangs. That
  would be exactly the kind of blanket relaxation this repo's convention
  correctly prohibits, because it removes protection from code paths that
  have nothing to do with this fix and were never shown to have a queue-
  depth problem. This revision does not do that: it raises the timeout for
  the duration of exactly one statement, then restores it, so every other
  wait in the file — before, during, and after this one acquire — keeps the
  original, unmodified 5s ceiling.
- **It does not mask the original 40P01 bug.** The original deadlock was
  caused by a missing critical section (no lock at all around
  `resetTestData()`/`applyCompatibilityShims()`), and the original design's
  widened lock already fixes that structurally — this revision makes zero
  changes to that structural fix. If this revision's timeout-scoping were
  removed and `resetTestData()`/`applyCompatibilityShims()` were once again
  left unlocked, the original 40P01 storm would return in full; the timeout
  scoping only concerns how long the (now-correctly-required) wait for that
  lock is allowed to run before Postgres gives up on it, which is an
  orthogonal, independent concern from whether the lock exists at all.

## Timeout value — why 90s, not 0 / disabled

Two options were considered for the raised value: fully disabling
`lock_timeout` (`SET lock_timeout = 0`, Postgres's documented way to mean
"no timeout, wait indefinitely") for the duration of the acquire, or raising
it to a large-but-still-finite value.

**Decision: raise to `'90s'`, not disable.** Reasoning:

- **A finite, generously-bounded value preserves a real safety net at
  negligible cost, so there is no reason to give it up.** The concern raised
  in this rework's brief — "if the timeout is set to 0/very high and
  something else genuinely does hang, have you removed a real safety net?"
  — is valid and is not free to wave away. The critical section this acquire
  is waiting to enter (migration-freshness check + eleven single-table
  `TRUNCATE`s on near-empty freshly-migrated test databases + a handful of
  `DROP`/`CREATE TRIGGER`/`FUNCTION` statements — no large data volumes, no
  business logic, no external I/O) is itself bounded and fast per-binary; the
  original design's own "Performance tradeoff" section already estimated the
  *total* added wall-clock cost across all ~19+ binaries queuing through it
  as "on the order of seconds, not minutes." Even a pessimistic per-binary
  estimate — say, a few seconds each — multiplied by a worst-case queue
  position of 21 binaries ahead (22 total binaries, one already running)
  comfortably fits inside a bound well under 90s. 90s was chosen as a value
  that (a) is generously larger than any plausible worst-case queue-drain
  time by a wide margin (multiple times over, not a hairline fit), so it
  will not itself become a new source of flakiness if a future binary is
  added to the barrier group or a CI runner is briefly slower than usual,
  while (b) still being finite, so a *genuinely* stuck acquire (e.g. a
  process that crashed mid-critical-section while still holding the
  advisory lock, or a real Postgres-level hang unrelated to expected
  queueing) is still caught and reported within a bounded, debuggable time
  instead of hanging the whole test run indefinitely.
- **Disabling it entirely (`0`) would remove a safety net for zero
  additional benefit**, since a finite generous value already comfortably
  covers the real expected wait with wide margin — there is no scenario
  where 90s is too short for legitimate queueing but "no timeout at all"
  is needed instead. Choosing `0` would only be justified if the worst-case
  legitimate wait were unbounded or unpredictable, which it is not here: the
  critical section's contents are fixed and known (the same
  `resetTestData()`/`applyCompatibilityShims()` sequence for every binary),
  and the queue depth is bounded by the fixed, known binary count in
  `build.zig`'s barrier group (22, not an open-ended or growing-without-limit
  number in normal operation).
- **This also directly addresses the "have you removed a real safety net?"
  self-check**: no. `statement_timeout = '60s'` (line 204,
  `configureSessionTimeouts()`, untouched by this revision) independently
  bounds the *entire* statement — including any lock-acquisition sub-wait —
  regardless of what `lock_timeout` is set to, because `lock_timeout` and
  `statement_timeout` are orthogonal Postgres settings that both apply
  concurrently to the same statement (`lock_timeout` bounds only the
  wait-for-lock portion; `statement_timeout` bounds the statement's total
  execution time, lock wait included). A hypothetical genuine hang during
  this one acquire is still caught and reported by `statement_timeout` at
  60s even with `lock_timeout` raised to 90s for that same statement, so the
  net effect of this change is not "no safety net," it is "a somewhat wider,
  still-present safety net, correctly re-sized for what this specific
  acquire is now expected to wait on." (In practice `lock_timeout=90s`
  exceeding `statement_timeout=60s` means the *effective* ceiling on this
  one acquire is 60s, governed by `statement_timeout` — which is more than
  generous enough per the queue-depth estimate above, and is an acceptable,
  intentional side effect of choosing a round, clearly-generous
  `lock_timeout` value rather than hand-tuning it to fall just under 60s.
  If a future run shows the real worst-case queue wait approaching 60s, the
  fix to make then is to raise `statement_timeout` too, not to have picked a
  tighter `lock_timeout` now for a scenario not yet observed.)

## Required change (structural, not literal diff)

Two independent pieces, both inside `TestHarness.init()` in
`tests/integration/helpers.zig`:

**(A) Widened critical section — already implemented, unchanged by this
revision.** The advisory-lock acquire at line 473 and release at line 505,
spanning `configureTestSearchPath()`, `resetTestData()`,
`ensureDefaultOidcSeeds()`, and `applyCompatibilityShims()`, stays exactly
as BACKEND-DEV implemented it in commit `5f25d99`. Nothing in this revision
requires changing the lock's acquire/release points, its key
(`bpm_test_migrations_public`, reused per the original design's reasoning —
see that section below, also unchanged), or which functions run inside it.

**(B) New: scope `lock_timeout` around exactly the line-473 acquire
statement.** Immediately before the existing `try conn.exec("SELECT
pg_advisory_lock(hashtext('bpm_test_migrations_public'))", &.{});` at line
473, add one statement raising `lock_timeout` to `'90s'` on the session.
Immediately after that acquire statement succeeds (i.e. the very next
statement after line 473, before `configureTestSearchPath()` runs), add one
statement restoring `lock_timeout` back to `'5s'`. Structurally:

```
raise lock_timeout to '90s'
acquire the widened advisory lock (existing line 473, unchanged)
restore lock_timeout to '5s'
... existing widened critical section body, unchanged ...
release the widened advisory lock (existing line 505, unchanged)
```

**Mechanism — plain `SET`/`SET`, not `SET LOCAL`.** As established in
"Current structure" above, every statement in this section of
`TestHarness.init()` runs on a plain autocommit `pg.Conn` with no open
transaction — `conn.begin()` does not happen until line 516, well after this
entire section (including the lock release) has completed. `SET LOCAL` only
takes effect for the remainder of the *current transaction* and is a no-op
outside one (Postgres either raises a warning or, depending on driver/mode,
silently behaves like a plain session-level `SET` with no automatic
reset point to fall back to — either way it does not provide the
"automatically reverts" behavior its name implies here, since there is no
enclosing transaction boundary for it to revert *at*). Using `SET LOCAL`
here would therefore either silently fail to scope correctly or silently
persist past the point intended, defeating the purpose of scoping it at all.
The correct mechanism, given a plain autocommit connection, is an explicit
**plain session-level `SET` immediately before the acquire, paired with an
explicit plain session-level `SET` immediately after it that restores the
original `'5s'` value** — i.e. the same idiom `configureSessionTimeouts()`
already uses to set these values in the first place (line 203: `SET
lock_timeout = '5s'`), just invoked twice more, narrowly bracketing the one
statement that needs a different value. This requires no new primitive and
no dependency on transaction semantics — it is the same plain-`SET`
mechanism already proven throughout this file.

**Failure-path correctness — no separate failure-path restore is needed,
because there is nothing left to restore on failure.** The restore
introduced in (B) is the single plain sequential `SET lock_timeout = '5s'`
statement described above — it runs once, unconditionally, on the
success path, immediately after the line-473 acquire returns and before
`configureTestSearchPath()` runs. It is deliberately **not** a `defer` (or
`errdefer`), and this file already has a mechanism that makes a separate
deferred restore both unnecessary and counter to this section's own
scoping goal: `errdefer conn.close()`, registered at line 431 immediately
after the connection is established, fires on *every* error return from
`TestHarness.init()` — including an error surfaced by the raise-to-`'90s'`
statement itself, by the line-473 acquire failing/timing out, or by
anything later in `init()` (up to and including `conn.begin()` at line
516). `errdefer conn.close()` does not selectively reset session
variables; it discards the entire `pg.Conn`, socket and all, so whatever
session-level `lock_timeout` value happened to be in effect at the moment
of failure — `'90s'`, `'5s'`, or anything else — is torn down along with
the rest of the session state and can never be observed by another
caller. There is no code path on which a failed `init()` hands back a live
connection with `lock_timeout` still at `'90s'`: either `init()` returns
successfully, in which case the plain sequential restore in (B) already
ran before `configureTestSearchPath()`, or it returns an error, in which
case `errdefer conn.close()` has already closed the connection the
`'90s'` setting lived on. A `defer`-based restore registered alongside the
raise would therefore be redundant on the failure path (the connection is
gone either way) while actively harmful on the success path, since a
`defer` inside `TestHarness.init()` fires at function-scope exit —
i.e. after `conn.begin()` at line 516 — not immediately before
`configureTestSearchPath()` as (B) requires; using `defer` here would
leave `lock_timeout` stuck at `'90s'` through `resetTestData()`,
`ensureDefaultOidcSeeds()`, `applyCompatibilityShims()`, and the start of
the per-test transaction, undermining the "tighter, more defensible
scope" this revision is meant to achieve. The plain sequential `SET`
described in (B) is therefore the only restore mechanism this design
specifies, on both the success and failure paths.

**Why bracket only the acquire statement, not the whole widened critical
section (B does not extend through `resetTestData()`/`applyCompatibilityShims()`):**
`lock_timeout` only governs the *wait-to-acquire* phase of a
lock-requesting statement — once `pg_advisory_lock()` returns (lock
granted), there is nothing left for `lock_timeout` to apply to for the
remainder of the critical section, since none of `configureTestSearchPath()`,
`resetTestData()`, `ensureDefaultOidcSeeds()`, or `applyCompatibilityShims()`
themselves block waiting on this same advisory lock (they run only after
it's already held) — the `TRUNCATE`/DDL statements inside them can
themselves take other, unrelated locks momentarily, but those are not what
BACKEND-DEV's data or ISSUE-FIXER's root cause implicated, and widening the
`lock_timeout` bracket to cover them would provide no benefit while
needlessly relaxing protection over a larger stretch of code than necessary.
Restoring to `'5s'` immediately after the acquire succeeds — rather than
only after the whole critical section completes and the lock is released —
is therefore both correct and the tighter, more defensible scope.

## Lock key — reuse `bpm_test_migrations_public`, do not introduce a new key

**Unchanged from the original design.** Reuse the existing
`bpm_test_migrations_public` key (the same `hashtext('bpm_test_migrations_public')`
value already used at line 99) as the single lock spanning the migration
passes and, per the original design's widening, `resetTestData()`/
`applyCompatibilityShims()` too. Full reasoning (mutual exclusion must cover
the entire `TestHarness.init()` pipeline, not just "migrations" as a
conceptually separate activity; a second key would reopen a cross-key race;
reuse is proven and simpler; no caller ever needs the phases decoupled) is
unchanged from the original design and is not repeated here — see the
original reasoning, retained verbatim below for audit-trail completeness.

> The actual correctness requirement is mutual exclusion of the *entire*
> `TestHarness.init()` pipeline across binaries, not mutual exclusion of
> "migrations" as a conceptually separate activity from "reset/shim."
> `resetTestData()` and `applyCompatibilityShims()` are not safe to run
> concurrently with `runMigrations()`/`runMigrationsForSchema()` from
> *another* process either — a TRUNCATE racing a concurrent migration's DDL
> on the same table is exactly the same class of `AccessExclusiveLock`
> collision as a TRUNCATE racing another process's TRUNCATE. A second,
> distinct key would not just fail to help — it would reopen a gap: two
> distinct keys only provide mutual exclusion *within* each key's own
> critical section, never *across* them. Reuse is simpler and already proven
> correct for exactly this pattern (ISS-0090 doc comment, lines 88–98). No
> concrete scenario requires the two to run at genuinely different times —
> every caller of `TestHarness.init()` always runs migrations immediately
> followed by reset immediately followed by shims, in that fixed order,
> every time.

**Interaction with the per-schema lock and with this revision's timeout
scoping:** unchanged from the original design for the per-schema lock
(`runMigrationsForSchema`'s own `hashtext($1)` lock at line 144 remains
nested temporally inside the outer widened critical section, safe because
Postgres advisory locks are per-session and re-entrant across distinct
keys). This revision adds one new fact: the per-schema lock's own acquire at
line 144 runs *before* line 473's acquire in program order (step 4 precedes
step 5 in "Current structure" above) and is therefore unaffected by this
revision's timeout bracket, which opens only immediately before line 473 and
closes immediately after it — the per-schema lock's acquire at line 144
keeps the ambient 5s `lock_timeout` throughout, exactly as before.

## Performance tradeoff — explicitly assessed and accepted (unchanged from original design, reproduced for audit-trail completeness)

Widening the critical section means every one of the ~19+ binaries must now
acquire the same session-level advisory lock before running
`resetTestData()`/`applyCompatibilityShims()`, and each must wait for
whichever binary currently holds it to finish that entire sequence
(migrations + reset + shims) before proceeding. This serializes the
reset/shim portion of `TestHarness.init()` across the whole group at
startup — replacing the prior "fully concurrent but randomly deadlocks" with
"fully serialized through this one section, but deterministic." This
revision adds no new tradeoff of its own kind — raising `lock_timeout` to
`'90s'` only for the one acquire statement does not change how long binaries
actually wait (that is governed by the critical section's real contents and
the queue depth, both unchanged by this revision); it only changes the
point at which Postgres would give up on a wait that was already happening,
so that a wait already accepted as correct in "Performance tradeoff" is no
longer mis-classified as a timeout failure.

This remains accepted as the correct tradeoff for the same reasoning
originally given (referencing `fix-ISS-0106.md`'s analogous acceptance, and
noting the absolute cost is bounded and small — on the order of seconds per
binary, not minutes, across ~19+ binaries queuing through a short critical
section).

## Error taxonomy changes

None, unchanged from the original design's assessment. This revision is
also a critical-section/session-configuration-boundary change (adding two
more plain `SET lock_timeout = ...` statements bracketing an existing
`pg_advisory_lock` acquire, using the same plain `try conn.exec(...)`
idiom `configureSessionTimeouts()` already uses throughout this file), not
a new error path. No new `error{}` members, no changed function return
types, no changed `error_map`. `TestHarness.init()` keeps its existing
`!TestHarness` signature; both new `SET lock_timeout` statements — the
raise to `'90s'` and the restore to `'5s'` — use the same plain
`try conn.exec(...)` idiom as `configureSessionTimeouts()`'s existing
calls, propagating `error.ServerError`/connection errors exactly as every
other `try conn.exec(...)` call in this function already does. Neither one
is `defer`-guarded (see "Failure-path correctness" above for why): if the
raise, the acquire, or the restore itself fails, `init()` returns an error
and `errdefer conn.close()` at line 431 discards the connection — the same
"best-effort cleanup on a connection that will not be reused by the
caller" reasoning that already justifies line 505's release being a
`catch {}`-wrapped call applies here too, just without needing a `defer`
to get there, since a plain sequential statement on the success path is
sufficient when the failure path is already fully covered by connection
teardown.

## Callers / scripts impacted

Unchanged from the original design: every one of the ~19+ `test-integration`
binaries calls `TestHarness.init()` as their shared bootstrap entry point,
so this revision's timeout scoping — like the original widened-lock fix —
applies automatically to every caller with no binary-specific changes
required anywhere. `zig build test-integration-iss503` remains unaffected
(ISS-503's binary does not call `TestHarness.init()` at all, per
`fix-ISS-0106.md`). No `build.zig` change of any kind.

## Verification expectations for this revision

BACKEND-DEV should re-run the same 3-run `zig build test-integration`
verification protocol used for the original design, and confirm:

1. Deadlock count (40P01) stays at the same low/zero level already
   demonstrated (the widened-lock fix itself is unchanged, so this should
   not regress).
2. 55P03 ("canceling statement due to lock timeout") count drops to zero
   specifically for occurrences whose stack trace points at
   `helpers.zig`'s line-473 acquire (the exact statement this revision
   brackets) — any *other* 55P03 occurrence elsewhere in the file (e.g. at
   lines 99 or 144, which remain at the ambient 5s) would indicate a
   genuinely different, unaddressed contention point and should be reported
   as a new finding, not assumed to be fixed by this revision.
3. TC-DB-01-01 and TC-DB-01-02 in `db_integration_test.zig` pass under a
   full concurrent `zig build test-integration` run — the original #357
   acceptance bar this issue chain has been working toward.
4. No unrelated regressions, consistent with the original design's
   acceptance criteria.

If 55P03 still occurs at line 473 despite the 90s bracket, that would mean
the real worst-case queue-drain time exceeds both 90s (`lock_timeout`, this
revision) and, more importantly, the untouched 60s `statement_timeout`
ceiling — in which case the finding should come back with the observed wait
time so the estimate in "Timeout value" can be revisited with real data
rather than the current pessimistic-but-untested estimate.

## Open questions

None blocking. The two pieces of this revision — (A) the already-implemented
widened lock, kept unchanged, and (B) the new `lock_timeout` bracket around
line 473's acquire — are both fully specified above. The exact local
variable naming for (B)'s two plain sequential `try conn.exec(...)`
statements (raise, then restore) is left to BACKEND-DEV's judgement,
consistent with this file's existing style, matching the idiom already
used for `configureSessionTimeouts()`'s own `SET` statements immediately
adjacent to it. Neither statement is `defer`-guarded — see "Failure-path
correctness" above.
