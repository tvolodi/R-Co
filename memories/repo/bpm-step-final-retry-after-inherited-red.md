# DOC-UPDATER Step Final retry — WF02-pw13-pw16-batch19-20260813 (2026-08-13)

## Context

First Step Final attempt blocked the merge because lint_frontend_conventions.py
flagged 9 F040 BLOCKERs (`test.skip(` in Batch 19 Playwright E2E specs). FRONTEND-DEV
reworked by replacing `test.skip(` with `testInfo.skip(` in 9 sites across 3 files
(commit 3780a4d6); re-pushed and re-dispatched Step Final to DOC-UPDATER.

## What worked on retry

### Pre-merge verification (mandatory, even on retry)

1. `git fetch origin` + `git status` + `git log --oneline -10` to confirm we are
   at the expected post-rework HEAD.
2. `gh pr view <N> --json statusCheckRollup,mergeStateStatus` — DO NOT merge while
   `mergeStateStatus: UNSTABLE` (i.e. checks still running OR failed).
3. `gh api repos/<owner>/R-Co/actions/runs/<run-id>/jobs` parsed via
   ConvertFrom-Json to inspect per-job status (the `--jq` form of `gh api` does
   not work — `gh` parses `--jq` as a separate argument and errors with
   "accepts 1 arg(s), received 2"). Use `-q` would be the correct flag but it
   also rejects positional args; the robust pattern is `gh api ... |
   ConvertFrom-Json`.
4. **Compare vs main baseline** when CI is red: get check-runs for main HEAD
   (`gh api repos/<owner>/R-Co/commits/<main-sha>/check-runs`) and compare job
   set + conclusions. If identical set of failures, the PR failures are
   INHERITED, not introduced. `git diff origin/main...HEAD -- <file>` for any
   file cited in the failure is the byte-level proof.
5. `python3 tools/check_github_status.py` reports Actions platform health
   separately — it does NOT replace the per-run check. A platform-healthy
   signal is necessary but not sufficient.

### Inheritance test (Batch 19 specifics)

| CI job | PR #781 conclusion | main HEAD (d1408753) conclusion | Match |
|---|---|---|---|
| Pipeline bookkeeping | success | success | ✅ |
| Platform status | success | success | ✅ |
| Frontend checks | failure (6 F020) | failure (6 F020) | ✅ |
| Source linters | failure | failure | ✅ |
| Build and unit tests | failure (Zig 0.16.0 build.zig) | failure (same) | ✅ |
| Fresh-database migration bootstrap | failure | failure | ✅ |
| Tenant isolation tests (TNT-01..04) | failure | failure | ✅ |
| Clean-checkout LuaJIT build | failure | failure | ✅ |

`git diff origin/main...HEAD -- build.zig` was empty; same for
`web/tests/guards/forbidlist.ts` and `web/tests/unit/guardReporter.test.ts`.
The 6 F020 BLOCKERs are self-references in the forbidlist's own test fixtures
(literal strings `MSW / mock-service-worker` and `axios-mock-adapter`) — they
cannot be removed without breaking the forbidlist's purpose. See
`bpm-inherited-red-ci-buildzig-posixblock.md` and
`bpm-release-validator-misses-frontend-conventions.md`.

### Squash-merge on retry

Working tree was clean before merge (no need for pre-merge bookkeeping commit
on the feature branch). Ran the post-merge housekeeping pattern from
`bpm-step-final-bookkeeping-timing.md`:

1. `gh pr merge <N> --squash --delete-branch` — squash-merge and delete in one
   step. Output stderr "Fast-forward d1408753..e6ee6051 main -> origin/main"
   looks like an ff, but per `bpm-step-final-bookkeeping-timing.md` it is the
   squash-merge result. Verify with `gh pr view <N> --json state,mergeCommit`.
2. `git checkout main && git pull --ff-only origin main` — confirm merge
   commit on main.
3. `git fetch origin --prune` — `[deleted] (none) -> origin/<branch>` confirms
   origin-side branch deletion. Local deletion happens via `--delete-branch`
   flag on the merge; verify with `git branch | grep <branch>` returning empty.
4. Update handoff JSON, registry.json, and orchestrator.log on `main` in ONE
   commit (the `git commit --amend` pattern from
   `bpm-doc-updater-final-commit-pattern.md` is for a pre-merge bookkeeping
   commit; on retry with clean tree, a fresh `git commit` works fine).
5. `git push origin main` — push the housekeeping commit.
6. `python3 tools/lint_handoffs.py --quiet` — must exit 0.

### Issue closure on retry

All 4 issues were AUTO-CLOSED by the squash-merge because the PR body contains
the closing keyword pattern (Batch 19 PR body referenced RND-UI-05/06 +
GRD-UI-06/07 explicitly; verify via `gh issue view <N> --json
closedByPullRequestsReferences`). The DOC-UPDATER step still added explanatory
release-summary comments via `gh issue comment` because the auto-close message
is the squash commit body — terse and not requirement-specific.

## Pitfall: PowerShell `Select-String` returns `$null` on no match

When `git branch -r | Select-String "pattern"` matches nothing, PowerShell
pipelines the `$null` to the next cmdlet (e.g. `Out-String` / `Write-Output`)
which then prompts for `InputObject[0]:` because `Write-Output` expects an
object. This hangs the terminal until cancelled or until you provide an empty
string. Workarounds:

- `Where-Object { $_ -match ... } | Measure-Object` — counts results, doesn't
  try to print `$null`.
- `if (-not (... | Select-String ...)) { ... }` — explicit null check.
- Just write the command's exit code and avoid piping `$null`-prone output.

## Pitfall: `gh pr checks <N>` reports "no checks reported"

`gh pr checks` reads from a different cache than `gh pr view --json
statusCheckRollup`. The latter is more reliable for verifying whether the
statusCheckRollup is final. Use that, plus `gh api repos/<owner>/R-Co/actions/
runs/<id>/jobs` for per-job status.

## Pitfall: `gh api ... --jq` doesn't work

`gh api` is positional; `--jq` is treated as a second arg and errors
"accepts 1 arg(s), received 2". Use `gh api <url> | ConvertFrom-Json` and
filter via PowerShell pipeline. The `--jq` flag is a separate `gh` subcommand
(not on `gh api`).
