# Inner Report — WF03-GH482-20260809 / step-01-issue-fixer / Diagnosis

**Run-ID:** WF03-GH482-20260809
**Step:** 1 (ISSUE-FIXER / diagnosis)
**Handoff-ID:** aebd28ab-5be3-4044-a232-150a105bf876
**Started:** 2026-08-09T03:21:59Z
**Completed:** see step-01-issue-fixer.json `completed_at`
**Status:** PASS

## Summary

This is the third diagnosis pass on GH-482 / ISS-0150. The original filed premise
(missing per-tenant `schema_migrations` ledger) was already disproven on
2026-08-07 (PR #519 / commit `4d593ef`, 33 blocks fixed) and re-confirmed on
2026-08-08 (branch `feature/WF03-GH482-20260808`, uncommitted to main). This pass
found the branch from 2026-08-08 abandoned mid-flight at Step 2 (CODE-DESIGNER
close-out design, commit `ef1974f`, unmerged) and picked up from its own
prescribed procedure: a fresh-database re-measurement.

That fresh-database attempt is what surfaced this run's real finding: **fresh
database bootstrap is currently broken on `main`**, at migration
`011_webhook_subscriptions.sql`, due to a scope-mismatch defect introduced by
`a2a8c68` (ISS-0185 / GH #518, merged 2026-08-08) — one of GH-482's own
previously-closed sibling issues. This is filed as **ISS-0630 / GH #605
(BLOCKER)** and routed to CODE-DESIGNER as this run's actual task, since it is
what blocks a trustworthy measurement of GH-482's own acceptance criterion.

A secondary finding — TC-DB-02-04's documented flake, explicitly scoped out of
GH-482's own 63-failure count — was filed as its own follow-up, **ISS-0631 /
GH #606 (MINOR)**, since no tracking issue existed for it yet.

## Sequence executed

### Step 1 — Read handoff, read ISS-0150.json, verify current GitHub/queue state

- Read `handoffs/WF03-GH482-20260809/step-01-issue-fixer.json` in full.
- Read `docs/issues/ISS-0150.json` in full: status `PARTIALLY_RESOLVED`,
  `open_reason` states acceptance criterion 2 not met, 86 residual blocks
  forwarded to ISS-0182/GH#515, ISS-0183/GH#516, ISS-0184/GH#517, ISS-0185/GH#518.
- Checked GitHub: GH-482 is `OPEN`. All four forwarded siblings (#515, #516,
  #517, #518) are `CLOSED` / `COMPLETED`.
- Checked `handoffs/global_queue.json`: GH-482 entry present, `IN_PROGRESS`,
  locked by workspace `r-co-2-loop`, `run_id: null` (this run had not yet
  stamped it).

### Step 2 — Discovered a parallel, more-advanced, unmerged branch

`git log --all --grep` surfaced `feature/WF03-GH482-20260808` (commits
`b6e06c4`, `a43211c`, `e12e481`, `ef1974f`), dated one day before this run,
never merged to `main`. That branch:

- Re-diagnosed GH-482 on 2026-08-08 and reached the same conclusion this run
  independently reaches: the per-tenant-ledger premise is disproven by design
  (`src/design/iss504_migration_tracking.md`), RC-1/2/3 are fixed at PR #519,
  and all four forwarded siblings are resolved.
- Progressed to CODE-DESIGNER (Step 2, commit `ef1974f`) and produced
  `src/design/iss0150-gh482-test-integration-svc-closeout.md` — a Type E
  close-out design mandating a **fresh, workspace-owned database** measurement
  (not the long-lived shared `db_test`) before GH-482 can be closed or
  forwarded further, and an origin/main control comparison for any residual
  failures.
- Stopped there — no Step 3 (BACKEND-DEV) commit exists on that branch; it was
  never carried to completion or merged.

This run does not merge or continue that branch (different run_id, different
feature branch per this run's own instructions); it uses the close-out design's
procedure as the correct methodology and re-executes it fresh on this run's own
branch, since the source is identical to `origin/main` either way (verified:
`git diff origin/main feature/WF03-GH482-20260809 --stat` shows zero source
changes, only handoff bookkeeping).

### Step 3 — Reproduction against the shared `db_test` database

```
BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5453/bpm_test zig build test-integration-svc
```

Ran to completion (~14 minutes) via a backgrounded Bash call with Monitor
watching for the terminal `Build Summary` line. Result:

```
Build Summary: 4/6 steps succeeded (1 failed); 661/736 tests passed
(9 skipped, 65 failed, 1 crashed); 49 leaks
```

35 unique failing test names were extracted from the interleaved output (see
`scratch/gh482-unique-failures.txt`, not committed — scratch). Neither of the
two error signatures named in the *original* GH-482 filing — `42P01 relation
"tenant_<uuid>.schema_migrations" does not exist` and `C23505 ... 
process_definitions_pkey` — appear anywhere in this run's full log (`grep -c`
returned 0 for both). This corroborates the 2026-08-07/08 finding that those
signatures were stderr bleed from a since-fixed stale-filename bug (RC-1), not
a live symptom.

The 35 current failure names were cross-checked against the bodies of the four
closed sibling issues. Several — `xc02_audit_immutability_test`,
`xc06_backwards_compatibility_test`, `exp401_exp402_comp_restore_test`,
`effects_subsystem_test`, `oidc12/15`, `svc01`, `adp02` — match test files
explicitly named in ISS-0182 (closed) or ISS-0184's "holding issue" cluster
list (closed). Their reappearance here, on siblings marked resolved, is the
direct motivation for Step 4's fresh-database check: per the close-out design,
the shared `db_test` container is not a valid pass/fail oracle, since it was
proven (in ISS-0150's own resolution) to carry baked-in ordering artifacts from
stale ledger state.

### Step 4 — Fresh-database re-measurement (the close-out design's mandated procedure)

Created a throwaway database inside the same running `db_test` Postgres
instance (`CREATE DATABASE bpm_fresh_gh482 OWNER bpm`) and ran:

```
BPM_DB_URL=postgres://bpm:bpm@localhost:5453/bpm_fresh_gh482 zig build migrate
```

Result: **migration fails**, not test failure —

```
error: Migration scope mismatch: 011_webhook_subscriptions.sql is declared
public-only (GBL- prefix or '-- scope: public') but performs unqualified
table work that needs the per-tenant pass. Either qualify the tables with
public., or change the scope header to '-- scope: all_schemas'.
```

Confirmed the shared `db_test` container (created 2026-08-06, before the
defect-introducing commit `a2a8c68` merged 2026-08-08) already has
`011_webhook_subscriptions.sql` marked applied in `public.schema_migrations`
(`applied_at: 2026-08-06 07:08:55`), so `migrate` silently skips re-evaluating
its now-broken content there — this is the `shared_db_container_trap` pattern
from ISS-0150's own `docs/anti-patterns.md` entry, recurring on a different
migration.

Pre-seeded the ledger row for `011_...` on the throwaway database and re-ran
`migrate`: it fails identically at the very next `-- scope: public` file,
`022_obs06_alerting_state.sql`. A full scan
(`grep` over every numeric migration's header + unqualified `CREATE
TABLE`/`ALTER TABLE`/`INSERT INTO` lines) found **9 affected files**, all last
touched by the same commit `a2a8c68` (`git log -1` per file, confirmed
individually):

```
011_webhook_subscriptions.sql   022_obs06_alerting_state.sql
038_oidc_claim_mapping_config.sql   039_jit_provisioning_config.sql
041_oidc15_realm_deletion_tracker.sql
042_oidc16_26_agent_lifecycle_foundations.sql
049_repository_service_catalog.sql   056_onboarding_registry.sql
094_entity_subsystem.sql
```

Throwaway database dropped after the check (`DROP DATABASE bpm_fresh_gh482`).

**Consequence: no trustworthy fresh-database measurement of
`test-integration-svc` is currently possible on `main`.** The close-out design
this run intended to execute cannot proceed past its own precondition #3
("use a fresh, workspace-owned db_test database"). This migration-bootstrap
break is therefore the actual, current blocker for GH-482's own acceptance
criterion 2, and is filed as ISS-0630 / GH #605 (BLOCKER) and routed to
CODE-DESIGNER as this run's task.

### Step 5 — Secondary failure modes named in the original filing

- **C23505 duplicate-key on `process_definitions_pkey`**: absent from the
  current full log (`grep -c "23505\|process_definitions_pkey"` → 0).
  Concluded RESOLVED alongside RC-1/2/3 (2026-08-07 fix), not a live failure
  mode. Does not share a root cause with ISS-0630 (that's a migration-file
  defect; this was interleaved stderr misattribution, already fixed).
- **TC-ISS503-02/03 (GBL-084 → GBL-123 LEGACY_RLS removal)**: `test_iss503_rls_removal.zig`
  now correctly reads `GBL-123_rls_removal.sql` (confirmed by direct file
  read); no `TC-ISS503` or `iss503` string appears anywhere in the current
  failure output. RC-1 fix (2026-08-07) holds. Not a live failure mode.

Neither secondary mode shares ISS-0630's root cause (a scope-header/table-
qualification mismatch in migration content). Both are already-fixed,
already-verified-fixed-again findings from the prior two diagnosis passes.

### Step 6 — TC-DB-02-04 flake

Confirmed absent from this run's failure list (0 occurrences of
"TC-DB-02-04" in the full log), consistent with its documented intermittent
1-in-3 rate. Searched GitHub (`gh issue list --search`) for any existing
tracking issue by name/topic — none found. Filed as its own follow-up,
ISS-0631 / GH #606 (MINOR), registered locally, and queued. Explicitly scoped
out of this run per the original issue's own framing; not folded into
ISS-0630 since it is unrelated (connection-pool contention vs. migration-file
content) and not currently reproducing.

### Step 7 — Batch-cap / phasing decision

**This run does NOT attempt to fix the 35 currently-failing
`test-integration-svc` blocks themselves.** They cannot be reliably classified
as pre-existing-on-`main` vs. branch-new vs. environment-artifact until a
fresh-database measurement is possible — which ISS-0630 blocks. Attempting to
diagnose or fix any of those 35 individually right now would mean diagnosing
against a database (`db_test`, alive since 2026-08-06 with accumulated
migration-ordering and tenant-provisioning history across three days of every
workspace's test runs) that ISS-0150's own resolution already proved produces
phantom, non-reproducible failure counts.

**Decision:** Phase this into two issues, in dependency order:
1. **ISS-0630 (this run's routed task, BLOCKER)** — fix the 9-file migration
   scope-mismatch defect. This is a small, well-bounded, single-root-cause,
   single-introducing-commit fix (`public.`-qualify 9 files' `CREATE
   TABLE`/`INSERT INTO` statements). Routing to CODE-DESIGNER now.
2. **GH-482 / ISS-0150 itself stays open**, blocked on ISS-0630. Once ISS-0630
   is fixed, a fresh-database re-measurement (following
   `src/design/iss0150-gh482-test-integration-svc-closeout.md`, already
   written and still valid) becomes possible for the first time since the
   issue was filed, and can then correctly classify the 35 (or however many)
   residual `test-integration-svc` failures as pre-existing / branch-new /
   already-covered-by-a-closed-sibling. That classification work is
   explicitly NOT done in this run — it requires ISS-0630 fixed first, per
   this run's own finding.

This mirrors the batch-cap discipline used for GH-495→ISS-0624/0625 earlier
in this session: a large, heterogeneous failure surface is not fixed in one
pass; the concrete, well-bounded, currently-blocking defect is separated out
and fixed first, with the remainder explicitly deferred and cross-referenced
rather than silently expanded into this run's scope.

## Production vs. test-harness classification

**ISS-0630 is unambiguously a PRODUCTION code defect** — it lives in
`migrations/*.sql`, which is deployed to every environment (dev, CI, staging,
production), not in `tests/`. It breaks migration bootstrap for any consumer
of a fresh database, not merely for the test suite. This satisfies GH-482's
(and ISS-0150's) own acceptance criterion: "any real production defect found
during triage is fixed, not just its test."

The 35 residual `test-integration-svc` failures remain unclassified as of this
run — that is the explicit, stated reason GH-482 stays open, not a
test-vs-production judgment call being deferred without cause.

## Files produced

- `docs/issues/ISS-0630.json` (new, BLOCKER)
- `docs/issues/ISS-0631.json` (new, MINOR)
- `docs/issue-reports/ISS-0150-gh482-20260809-diagnosis.yaml` (this run's diagnosis)
- `handoffs/WF03-GH482-20260809/step-01-inner-report.md` (this file)
- GitHub issues: #605 (ISS-0630), #606 (ISS-0631)
- Global queue: both added via `tools/queue_add.py`

## Next action

Route to CODE-DESIGNER for ISS-0630 (Type: likely a small Type E or direct SQL
edit — 9 migration files need `public.` qualification added to their
unqualified `CREATE TABLE`/`INSERT INTO` statements). Do not implement
directly. GH-482 / ISS-0150 itself is not closed by this run and is not this
run's implementation target — ISS-0630 is.
