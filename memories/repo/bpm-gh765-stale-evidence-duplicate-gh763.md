# GH-765 stale-evidence duplicate of GH-763

## Symptom
Investigation of GH-765/ISS-0700 (iss205_webhook_outbox_test.zig TC1/TC2/TC3
fails with `PoolError.QueryFailed`) found that **all 3 tests pass cleanly on
main HEAD `93bfeb97`**. No code change was required; the bug was already
fixed upstream.

## Root cause (after the fact)
Migration `1147_par01_events_partitioning.sql` (commit `38cb7967`, PR #713,
2026-08-11) dropped seven `webhook_deliveries` columns that
`023_ext02_webhook_event_dispatch.sql` had added:
`event_type, instance_id, payload_json, trace_id, delivered_at,
last_http_status, last_error`. Any INSERT/SELECT referencing these columns
fails with `column "..." does not exist` (SQLSTATE 42703), surfaced from
`src/db/pool.zig:526` as `PoolError.QueryFailed`.

Same drift in `iss106_webhook_outbox_test.zig` was the canonical report
(GH-763). Fix is migration `1155_gh763_restore_webhook_deliveries_ext02_columns.sql`
in commit `eec9edc3` (PR #771), merged 2026-08-13 11:57 UTC. It restores
the seven columns idempotently under every tenant schema, guarded against
`public` (where GBL-112 already dropped the table).

GH-765 was opened at **2026-08-13T09:33:02Z** — exactly one minute after
GH-763 (09:32:38). The "0/3 tests passed" evidence was a snapshot of the
2h25m window between GH-763 reopening and PR #771 merging. The reporter's
`HEAD~1 before GH-760/ISS-0696 commit 1e4f31f1` confirmation predates the
fix landing on `main` as well.

## Pattern: GH-765 mirrors GH-758
GH-758 (commit `ff70be81` / PR #774) was the first instance — closed as
duplicate of GH-752/ISS-0692 (fixed by `9d06bdf4`). GH-765 is the second.
**Whenever a `PoolError.QueryFailed` / column-does-not-exist error
disappears after a migration-only commit, suspect a stale duplicate of an
already-fixed issue before assuming a new fix is needed.**

## Detection checklist used (works for this class)
1. **`git log --oneline <last-touched-file>`** — check whether the test or
   its dependencies were modified recently.
2. **Cross-check schema** via
   `docker exec -e PGPASSWORD=bpm r-co-db_test-1 psql -U bpm -d bpm_test \
       -c "\d+ tenant_default.webhook_deliveries"` —
   on the live test DB, the seven columns are present.
3. **`gh issue list --search "PoolError.QueryFailed webhook"`** —
   find related closed issues. GH-763 already closed 90 minutes before
   GH-765 was filed.
4. **`git log eec9edc3..HEAD -- src/webhook/ migrations/1155* tests/integration/iss205*`**
   — empty output confirms the fix is intact.
5. **Run the cached test binary in solo mode** — on a fresh DB and on
   the populated DB both pass 3/3.

## Pipeline consequence (mirrors WF03-GH758-20260813)
WF03-GH765-20260813 ran Step 0/0.5/1 only. Steps 2-6 (CODE-DESIGNER,
CODE-DESIGN-VALIDATOR, BACKEND-DEV, TEST-DESIGNER,
TEST-DESIGN-VALIDATOR, TEST-RUNNER) SKIPPED because no code change is
needed. Pipeline collapses to DOC-UPDATER (Step 7) + Step Final
(BACKEND-DEV for `gh issue close 765 --reason duplicate` + CHANGELOG
entry) + housekeeping.

## Artifacts
- `tests/reports/WF03-GH765-diagnosis.md` — full diagnosis
- `scratch/gh765_final_test.log` — cached-binary test capture (3/3 OK)
- `handoffs/WF03-GH765-20260813/step-01-issue-fixer.json` — completed
  handoff with `result.status = PASS`

## Lesson for future ISSUE-FIXER runs
**Always run the failing test in isolation BEFORE building a reproducer
to chase the symptom.** If it passes when run alone, the failure mode
most likely involves either a stale-evidence duplicate OR a parallel
binary that's mutating shared state. For `PoolError.QueryFailed`
specifically, a live `\d+` probe on the test DB resolves column-missing
hypotheses in <2s — the cheapest possible disambiguation before reading
any source code.
