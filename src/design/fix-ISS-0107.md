# Module: fix-ISS-0107 — widen the existing `bpm_test_migrations_public` advisory lock to cover `resetTestData()` / `applyCompatibilityShims()`

## Summary

GitHub #366 / ISS-0107 (MAJOR). Under a full concurrent `zig build
test-integration` run, the ~19+ non-ISS-503 test-integration binaries
(exp103_instance_waits_test.zig, tnt_schema_isolation_test.zig,
iss205_webhook_outbox_test.zig, db_integration_test.zig, and every other
sibling that calls `TestHarness.init()`) deadlock (40P01) against **each
other**, independent of ISS-0106's ISS-503 fix. ISSUE-FIXER's source-verified
root cause (`docs/issues/ISS-0107.json`): `TestHarness.init()` in
`tests/integration/helpers.zig` calls, in order, `runMigrations()` (locked),
`runMigrationsForSchema()` (locked), `configureTestSearchPath()`,
`resetTestData()` (**unlocked**), `ensureDefaultOidcSeeds()` (unlocked DML),
`applyCompatibilityShims()` (**unlocked**). Both advisory locks already in
this file are released before `resetTestData()`/`applyCompatibilityShims()`
run, so every one of the ~19+ concurrently-running binaries executes
`resetTestData()`'s `TRUNCATE ... RESTART IDENTITY CASCADE` statements (which
Postgres always promotes to `AccessExclusiveLock`) and
`applyCompatibilityShims()`'s `DROP`/`CREATE TRIGGER`/`FUNCTION` DDL with zero
cross-process ordering. This produces genuine N-way circular
`AccessExclusiveLock` waits (40P01), corroborated by `42710`
("trigger ... already exists") and `23505` (`pg_proc` unique-violation)
errors from the unprotected DROP/CREATE-trigger race.

This design addresses the root cause directly: widen the scope of the
**same, already-correct, already-battle-tested** advisory lock this file
already uses for the migration passes, so it also covers `resetTestData()`
and `applyCompatibilityShims()`. It does not introduce a new locking
primitive, a retry wrapper, or a sleep/backoff — those would mask the
symptom (occasional 40P01 aborts) without removing the actual unprotected
concurrent-DDL window that causes it.

## Fix scope confirmation

Exactly the 1 file listed in `ISS-0107.json.files_to_change`:

- `tests/integration/helpers.zig` — the sole change. `Migrations.run()` /
  `Migrations.runForSchema()` (`src/db/migrations.zig`) were already
  re-read in full by ISSUE-FIXER during root-cause diagnosis and confirmed
  to correctly contain no locking of their own — locking is, by this
  file's existing design, entirely the caller's (`helpers.zig`'s)
  responsibility. Extending `helpers.zig`'s own lock scope is consistent
  with that existing design, not a deviation from it. `build.zig` requires
  no change: this is not a build-graph/barrier problem — unlike ISS-0106's
  ISS-503 (one identifiable minority offender bypassing the shared
  harness), every one of the ~19+ binaries here is a symmetric participant
  in the shared `TestHarness.init()` chokepoint, so there is no minority
  sub-group to carve out via a `build.zig` barrier. Total: 1 file, well
  within the ≤5 constraint.

## Current structure (as read from `tests/integration/helpers.zig`, current branch)

`TestHarness.init()` (lines 413–496) runs the following sequence on a single
direct `pg.Conn`, in this exact order:

1. Connect (`pg.Conn.connectUrl`), `configureSessionTimeouts()`.
2. `runMigrations(io, allocator, &conn, url)` (line 440) — internally
   acquires `SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))`
   at line 99, and releases it via `defer conn.exec("SELECT
   pg_advisory_unlock(hashtext('bpm_test_migrations_public'))", &.{}) catch
   {};` at line 100. This `defer` fires at the end of `runMigrations()`'s own
   function body — i.e. the lock is fully released before `runMigrations()`
   returns control to `TestHarness.init()`, long before `resetTestData()` or
   `applyCompatibilityShims()` are anywhere near being called.
3. `_ = conn.exec("SELECT bpm_provision_tenant_schema(...)", ...)` (line
   447, best-effort, errors discarded).
4. `runMigrationsForSchema(io, allocator, &conn, "tenant_default", url)`
   (line 448) — internally acquires a second, per-schema-keyed advisory
   lock, `SELECT pg_advisory_lock(hashtext($1))` with `$1 = "tenant_default"`
   (line 144), released via its own `defer conn.exec("SELECT
   pg_advisory_unlock(hashtext($1))", &.{schema}) catch {};` at line 145 —
   same pattern, same scoping problem: this lock is also fully released
   before `runMigrationsForSchema()` returns.
5. `configureTestSearchPath(&conn)` (line 457) — unlocked, sets
   `search_path`; not itself a source of contention (no DDL/TRUNCATE).
6. `resetTestData(&conn)` (line 463) — **calls happen with NEITHER
   advisory lock held.** Issues eleven sequential
   `TRUNCATE TABLE <table> RESTART IDENTITY CASCADE` statements (via
   `truncateTableBestEffort()`, lines 306–322) against
   `instance_definition_snapshots`, `tasks`, `timers`,
   `instance_projections`, `variable_schemas`, `process_definitions`,
   `events`, `audit_log`, `audit_entries`, `dead_letter_items`,
   `webhook_subscriptions`, `service_catalog` — every one an
   `AccessExclusiveLock`-taking DDL-class statement in Postgres, run with
   zero cross-process ordering against every other concurrently-running
   binary doing the exact same thing.
7. `ensureDefaultOidcSeeds(&conn)` (line 468) — unlocked DML
   (`INSERT ... ON CONFLICT`), not itself DDL, but shares the same
   unprotected window.
8. `applyCompatibilityShims(&conn)` (line 473) — **also called with
   neither advisory lock held.** Issues `CREATE TABLE IF NOT EXISTS`,
   repeated `DROP FUNCTION ... CASCADE` / `CREATE OR REPLACE FUNCTION`, and
   repeated `DROP TRIGGER IF EXISTS` / `CREATE TRIGGER` pairs (lines
   208–296) against the shared `events` and `repository_artifacts` tables —
   again fully exposed to concurrent execution by every other binary.
9. `bpm.api_tenant_context.set(...)`, then `conn.begin()` — the harness's
   own test transaction starts only after all of the above has completed.

The net effect: the two advisory locks that already exist in this file
protect exactly steps 2 and 4 (the migration check-and-apply passes) and
nothing else. By the time execution reaches step 6, the calling process
holds no advisory lock at all, and steps 6 and 8 — both DDL-class,
both touching tables/objects shared by every one of the ~19+ binaries — run
fully concurrently across the whole `test-integration` group. This is the
entire mechanism of the bug: the lock's *scope* was always narrower than
"the full `TestHarness.init()` sequence," and steps 6 and 8 were simply
never brought inside it.

## Required change (structural, not literal diff)

Widen the locked critical section so that the **same class of protection**
already proven correct for steps 2 and 4 also covers steps 6 and 8. Two
structurally-equivalent ways to express this; either satisfies the root
cause, so this section states the decision and the reasoning, not a forced
single mechanical form:

1. **Preferred shape: one lock acquired directly in `TestHarness.init()`,
   held across steps 5–8.** Acquire a session-level advisory lock (see
   "Lock key" section below for which key) at the point in `init()`
   immediately before `configureTestSearchPath()` is called (i.e. right
   after `runMigrationsForSchema()` returns at line 448/451), and release it
   only after `applyCompatibilityShims()` completes (i.e. after line
   473–476, before `bpm.api_tenant_context.set(...)` and `conn.begin()`).
   Concretely, this means: acquire the lock, then let
   `configureTestSearchPath()`, `resetTestData()`, `ensureDefaultOidcSeeds()`,
   and `applyCompatibilityShims()` all execute while it is held, then release
   it (via the same `defer conn.exec("SELECT pg_advisory_unlock(...))")
   catch {};` idiom already used at lines 100 and 145) before proceeding to
   `bpm.api_tenant_context.set(...)`/`conn.begin()`. `configureTestSearchPath()`
   itself does no harm being inside the locked region (it is a single `SET
   search_path` statement, not a source of contention) — including it
   simplifies the acquire/release placement to a single contiguous block
   rather than requiring the lock to open and close around a gap.

2. **Equivalent alternative shape: widen `runMigrationsForSchema()`'s own
   existing lock to not release until after the caller signals it is done
   with the shared section.** Rejected in favor of (1): this would require
   `runMigrationsForSchema()` (a function whose name and existing doc
   comment describe it as being about migrations specifically, lines
   116–187) to somehow know about `resetTestData()`/`applyCompatibilityShims()`
   (functions with no conceptual connection to schema migration), which
   either means passing a callback/closure into `runMigrationsForSchema()`
   (needless coupling and indirection for a same-file, same-caller
   sequence) or moving `resetTestData()`/`applyCompatibilityShims()`'s call
   sites bodily inside `runMigrationsForSchema()` (breaks the existing,
   readable separation of concerns in `TestHarness.init()`, where each
   pipeline stage is its own named function called in sequence). Shape (1)
   — a lock acquired and released directly in `TestHarness.init()`,
   wrapping only the calls that need protecting — keeps every existing
   function's responsibility unchanged and is a strictly smaller, more
   local edit.

Either shape moves the "unlock point" for the relevant critical section from
immediately-after-the-migration-passes (its current position) to
immediately-after-`applyCompatibilityShims()`-completes (its required
position) — this is the one essential boundary change the fix must make,
regardless of which of the two shapes is chosen. BACKEND-DEV should
implement shape (1) as specified; shape (2) is documented here only to
explain why it was considered and rejected, not as an equally-acceptable
option.

Note on `ensureDefaultOidcSeeds()` (step 7): it sits between `resetTestData()`
and `applyCompatibilityShims()` in the existing call order and is pure DML
(`INSERT ... ON CONFLICT DO NOTHING` / `DO UPDATE`), not DDL — Postgres does
not promote these to `AccessExclusiveLock`, so it is not itself a deadlock
source. It is still included inside the widened critical section under
shape (1) simply because it is interleaved between the two functions that do
need protecting, and there is no benefit to carving it out with a
lock-release/re-acquire pair around it — that would add complexity for zero
contention-reduction gain, since the two DDL-bearing neighbors it sits
between already force the lock to span the whole region.

## Performance tradeoff — explicitly assessed and accepted

Widening the critical section means every one of the ~19+ binaries must now
acquire the same session-level advisory lock before running
`resetTestData()`/`applyCompatibilityShims()`, and each must wait for
whichever binary currently holds it to finish that entire sequence
(migrations + reset + shims) before proceeding. This serializes the
reset/shim portion of `TestHarness.init()` across the whole group at
startup — replacing today's "fully concurrent but randomly deadlocks" with
"fully serialized through this one section, but deterministic."

This is accepted as the correct tradeoff, for the same reason WF-03 Step 2
already accepted an analogous cost for ISS-0106 (`src/design/fix-ISS-0106.md`,
"Callers / scripts impacted": *"total wall-clock time increases slightly...
this is the intended fix, not a regression: the prior faster-but-occasionally-
deadlocks-and-produces-a-false-failure-on-unrelated-tests behavior is
strictly worse than slightly-slower-but-deterministic."* The same reasoning
applies here, at a larger scale (all ~19+ binaries pay a small serialized
wait instead of one binary running after the rest): a test suite that
reliably passes with some added serialized wait time at startup is strictly
more valuable than one that runs marginally faster but produces spurious
BLOCKER-level failures on unrelated tests at some non-trivial rate (this
run's reproduction alone captured between 4 and 21+ deadlocks per full run
across observed attempts). The absolute cost is also bounded and small: the
locked section (migrations-check + eleven single-table TRUNCATEs + a handful
of DROP/CREATE DDL statements) is fast per-binary (no large data volumes —
these are freshly-migrated/near-empty test databases), so total added
wall-clock time across ~19+ binaries queuing through a short critical
section is on the order of seconds, not minutes. No alternative in the
candidate list (`ISS-0107.json.candidate_resolution`) avoids this cost while
still fixing the root cause: option (b), a curated `build.zig` barrier
sub-group, was already rejected in `chosen_resolution` because there is no
minority offender to carve out — serializing a barrier sub-group here would
mean the same or a larger serialization footprint with more architectural
complexity (a build-graph change instead of a one-function lock-scope
change). Option (c), retry/timeout, was rejected because it treats symptom
rather than cause and cuts against this repo's established
fix-root-cause-not-symptom convention (see `ISS-0107.json.chosen_resolution`
and `fix-ISS-0106.md` Part 1's non-goals).

## Lock key — reuse `bpm_test_migrations_public`, do not introduce a new key

**Decision: reuse the existing `bpm_test_migrations_public` key** (the same
`hashtext('bpm_test_migrations_public')` value already used at line 99) as
the single lock that spans steps 2, 4 (implicitly, since `runMigrationsForSchema`'s
own per-schema lock is untouched and still runs inside/before this window —
see "Interaction with the per-schema lock" below), and now also 5–8 in shape
(1) above, rather than introducing a second, distinct key such as
`bpm_test_harness_init`.

Reasoning:

- **The actual correctness requirement is mutual exclusion of the *entire*
  `TestHarness.init()` pipeline across binaries, not mutual exclusion of
  "migrations" as a conceptually separate activity from "reset/shim."**
  `resetTestData()` and `applyCompatibilityShims()` are not safe to run
  concurrently with `runMigrations()`/`runMigrationsForSchema()` from
  *another* process either — a TRUNCATE racing a concurrent migration's DDL
  on the same table is exactly the same class of `AccessExclusiveLock`
  collision as a TRUNCATE racing another process's TRUNCATE. Since every
  phase of `TestHarness.init()` needs to be mutually exclusive against every
  phase of every other process's `TestHarness.init()`, one lock covering the
  whole sequence is the more precise model of the actual invariant, not an
  approximation of it.
- **A second, distinct key would not just fail to help — it would reopen a
  gap.** If `resetTestData()`/`applyCompatibilityShims()` were wrapped in a
  *different* key (e.g. `bpm_test_harness_init`), then Process A could hold
  `bpm_test_migrations_public` while running its migration pass at the exact
  moment Process B — having already released `bpm_test_migrations_public`
  itself — acquires `bpm_test_harness_init` and starts truncating tables
  that Process A's migration is concurrently altering. Two distinct keys
  only provide mutual exclusion *within* each key's own critical section,
  never *across* them; nothing stops one process being in its
  "migrations" critical section while a different process is simultaneously
  in its "reset/shim" critical section. A single shared key is what
  guarantees true global exclusivity of the whole pipeline, which is the
  actual property needed here.
- **Reuse is simpler and already proven correct for exactly this pattern.**
  The `bpm_test_migrations_public` key, acquire/release idiom, and
  `hashtext()` keying convention are already battle-tested in this exact
  file for this exact purpose (serializing concurrent `TestHarness.init()`
  callers around shared-`public`-schema contention — see the ISS-0090 doc
  comment at lines 88–98). Reusing it is a strictly smaller change (extend
  one existing acquire/release pair's scope) than introducing and
  documenting a second key with its own semantics.
- **No concrete scenario requires the two to run at genuinely different
  times.** The candidate-resolution note in `ISS-0107.json` raises this as a
  question to resolve ("migrations and reset are conceptually different
  operations that could theoretically run at different times") — but in
  practice every single caller of `TestHarness.init()` always runs
  migrations immediately followed by reset immediately followed by shims,
  in that fixed order, every time, with no caller that skips one phase or
  runs them independently. There is no existing or anticipated use case
  where decoupling them into independently-lockable phases has any benefit;
  it would only add a way for the two phases to interleave incorrectly
  across processes.

**Interaction with the per-schema lock (`runMigrationsForSchema`'s own
`hashtext($1)` lock at line 144):** that lock remains unchanged and
continues to be acquired/released strictly inside step 4, nested temporally
inside the outer `bpm_test_migrations_public` critical section once the
latter is widened per shape (1) above (the outer lock is acquired before
step 4 runs and not released until after step 8, so step 4's own
acquire/release of the per-schema lock happens while the outer lock is
already held — Postgres advisory locks are per-session and re-entrant
across distinct keys, so a session holding `bpm_test_migrations_public` can
freely also acquire and release the `tenant_default`-keyed lock without any
conflict or deadlock risk with itself). This nesting is safe and requires no
special-casing: the per-schema lock still does exactly what it did before
(guard the schema-specific migration check-and-apply pass against other
processes racing on the same schema key), it simply now executes while its
caller also holds the wider `bpm_test_migrations_public` lock around it.

## Error taxonomy changes

None. This is a critical-section-boundary change (moving where an existing
`pg_advisory_lock`/`pg_advisory_unlock` pair is acquired and released), not
a new error path. No new `error{}` members, no changed function return
types, no changed `error_map`. `resetTestData()`, `applyCompatibilityShims()`,
`runMigrations()`, and `runMigrationsForSchema()` keep their existing `!void`
signatures and existing internal error handling (including the
best-effort `error.ServerError` swallowing already present in
`truncateTableBestEffort()` and `execCompatibilitySql()`, which is unrelated
to this fix and must not be touched).

## Callers / scripts impacted

- Every one of the ~19+ `test-integration` binaries calls
  `TestHarness.init()` as their shared bootstrap entry point (directly, or —
  per the ISS-0107.json root-cause note — indirectly via their own
  `makePool()`/harness usage). Because the fix is centralized entirely
  inside `TestHarness.init()`'s own body in `tests/integration/helpers.zig`,
  **no binary-specific change is required anywhere** — every caller
  automatically gets the widened critical section the next time it calls
  `TestHarness.init()`, with no changes to its own source file. This is the
  direct consequence of `TestHarness.init()` being the single shared
  chokepoint every binary already goes through, and is the reason this fix
  stays to exactly 1 file despite protecting ~19+ independent binaries.
- `zig build test-integration` (the umbrella step) — behavior change: total
  wall-clock time increases slightly, because the ~19+ binaries now
  serialize through the widened critical section at startup instead of
  racing through it concurrently. This is the intended fix, not a
  regression (see "Performance tradeoff" above).
- `zig build test-integration-iss503` — unaffected. ISS-503's own binary
  (`test_iss503_rls_removal.zig`) does not call `TestHarness.init()` at all
  (per ISS-0106's root cause, it opens its own raw `pg.Conn` and bypasses
  `helpers.zig` entirely), so it is untouched by this change in either
  direction: it neither contends for the widened lock nor is protected by
  it. This is consistent with ISS-0106's `fix-ISS-0106.md` Part 2, which
  already established that `helpers.zig`'s advisory-lock machinery has no
  effect on ISS-503 unless ISS-503 itself opts in (which it does not, by
  design of that separate, already-closed fix).
- No other `zig build test-integration-*` narrow-scope step (`-xc04`, `-tm`,
  `-svc`, `-env`, etc.) requires any change: every one of them still calls
  `TestHarness.init()` exactly as before, and picks up the widened lock
  scope automatically and uniformly.
- No `build.zig` change of any kind — this is not a build-graph/dependency
  problem (see "Fix scope confirmation" above for why the ISS-0106-style
  barrier approach does not apply here).

## Open questions

None blocking. Shape (1) ("Required change" section above) is the
recommended and expected implementation; shape (2) is documented only as
the rejected alternative, to save BACKEND-DEV from re-deriving and
re-rejecting it independently. The exact local variable naming for the
widened lock's acquire/release calls in `TestHarness.init()` is left to
BACKEND-DEV's judgement, consistent with this file's existing style (plain
`try conn.exec(...)` for acquire, `defer conn.exec(...) catch {};` for
release, matching lines 99–100 and 144–145).
