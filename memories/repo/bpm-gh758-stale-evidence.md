# GH-758 stale evidence: lesson learned

## Symptom
Reproduced a "client hang after SET lock_timeout=5s" signature in solo mode
across multiple integration tests. Spent significant effort on a reproducer
before ISSUE-FIXER Step 1 discovered the symptom was already fixed.

## Root cause (after the fact)
GH-758 was a duplicate of GH-752/ISS-0692, fixed by commit 9d06bdf4 on main
(2026-08-13). The fix zeroed both `lock_timeout` and `statement_timeout`
around the `pg_advisory_lock` acquire so it cannot be cancelled by 57014.

The "client hang" symptom was caused by a 57014 statement_timeout cancellation
during contention that was slow to propagate through build_runner IPC — the
error path made the lock acquirer look hung when in fact it was waiting for
the cancel to round-trip.

## Why the evidence was stale
The scratch/gh758_*.log trace labels said "lock_timeout=90s sent" because they
were captured DURING the ISS-0211/GH-752 rework cycle, before the commit
9d06bdf4 final fix. The current code at tests/integration/helpers.zig:909
reads `SET lock_timeout = '0'`. The 90s label was stale.

## Pattern for future: stale-evidence detection

When a "client hang" symptom is reproduced, before spending time on a
diagnostic reproducer:

1. **Check `git log --oneline -- tests/integration/helpers.zig` to see when
   the lock-acquire bracket was last modified.** If the change is recent
   (within a few days of the symptom), the symptom may have been fixed but
   not yet closed/deduplicated.

2. **Cross-check the trace labels in scratch/*.log against the current code.**
   If the labels say "lock_timeout=90s sent" but the current code says
   "lock_timeout='0'", the log is stale.

3. **Run `git log --all --oneline --grep="<GitHub issue number>"` to find
   related fix commits.** A duplicate-of relationship will be evident.

4. **List the open issues that match the symptom class.** If another open
   issue has the same symptom class (e.g. "test-integration hang") and is
   recently fixed, the new issue is likely a duplicate.

## Key file locations
- tests/integration/helpers.zig:127-131 (runMigrations)
- tests/integration/helpers.zig:188-192 (runMigrationsForSchema)
- tests/integration/helpers.zig:906-910 (acquireIntegrationLock)
- All three use the `lock_timeout='0'` + `statement_timeout='0'` bracket
- tests/integration/repro_g758.zig (committed at 13632334, kept as a
  reference; not wired into any build step)

## Pipeline consequence
WF03-GH758-20260813 ran: Step 0/0.5/1/7/Final. Steps 2-5 (CODE-DESIGNER,
CODE-DESIGN-VALIDATOR, BACKEND-DEV, TEST-DESIGNER, TEST-DESIGN-VALIDATOR,
TEST-RUNNER, RELEASE-VALIDATOR) were SKIPPED because no code change was
needed. The duplicate detection happened in Step 1 (root cause analysis).

This is a useful pattern: when a Step 1 diagnosis finds the issue is a
duplicate of an already-fixed issue, the rest of the pipeline collapses to
just Step 7 (DOC-UPDATER) and Step Final (BACKEND-DEV for PR + close).
