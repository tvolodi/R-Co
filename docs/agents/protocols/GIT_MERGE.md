# GIT_MERGE Protocol

**Version:** 0.1 · 2026-05-26  
**Function:** `fn:git-merge`  
**Read by:** `BACKEND-DEV`, `FRONTEND-DEV`  
**Used in:** WF-02 Step Final, WF-03 Step Final, WF-04 direct-routed fix Step Final

---

## Purpose

Rebases the feature branch onto current main, creates a PR, merges it, and cleans up. All pipeline gates (build, tests, NFR benchmarks) have already passed before this step runs — the merge is unconditional once rebase succeeds.

---

## Procedure

```
1. Verify current branch:
   git branch --show-current
   Must equal feature/<run-id>. If not: STOP; report FAIL to ORCH.

2. Stage any remaining uncommitted files (test specs, reports, changelogs, handoffs written by
   downstream agents since BACKEND-DEV's implementation commit):
   git add -A

   If `git status` shows a clean tree (BACKEND-DEV already committed everything), skip to step 4.

3. Commit remaining artifacts (use run-id and summary from the last completed agent's result.summary):
   git commit -m "feat(<run-id>): finalize artifacts — test specs, reports, changelog

   Requirements: <comma-separated requirement IDs from context.requirement_ids>
   Handoff: <run-id>"

   For WF-03 fix branches use prefix "fix" instead of "feat":
   git commit -m "fix(<run-id>): <one-line summary from ISSUE-FIXER result.summary>"

   Note: BACKEND-DEV commits its implementation in step N (the implementation step), so
   Step Final typically only needs to commit artifacts produced by TEST-DESIGNER, TEST-RUNNER,
   RELEASE-VALIDATOR, and DOC-UPDATER. Both commits end up squash-merged in step 8.

4. Sync with remote:
   git fetch origin main

5. Rebase onto origin/main:
   git rebase origin/main

   ── CONFLICT HANDLING ────────────────────────────────────────────────────────

   a. Count conflicted files:
      git diff --name-only --diff-filter=U | wc -l

      If count > 5  OR  any conflicted file is under src/engine/ or src/api/middleware/:
        git rebase --abort
        → fn:register-inner-report
        → fn:complete-handoff(status: FAIL,
            issues: [{severity: BLOCKER,
                      description: "Merge conflict too complex for inline resolution: <list files>"}],
            next_action: "ORCH escalates to CODE-DESIGNER for conflict resolution")
        STOP

   b. For each conflicted file (≤ 5 files, not in engine/middleware):
      - Read HEAD version and incoming version
      - Apply correct resolution (preserve valid changes from both sides)
      - git add <file>

   c. git rebase --continue

   d. Verify build still passes:
      zig build
      If FAIL: fix compile errors, git add <file>, git rebase --continue
      zig build test   (unit tests only — integration tests already passed upstream)
      If FAIL:
        → fn:complete-handoff(status: FAIL,
            issues: [{severity: BLOCKER, description: "Build/unit tests failed after rebase"}])
        ORCH routes to ISSUE-FIXER; after ISSUE-FIXER PASS, return to step 5

   ─────────────────────────────────────────────────────────────────────────────

6. Push branch to remote:
   git push origin feature/<run-id>

7. Create PR:
   gh pr create \
     --title "feat: <one-line summary> [<run-id>]" \
     --body "## Summary
<last-agent result.summary>

## Requirements
<comma-separated requirement IDs>

## Validation
- zig build: PASS
- Unit + integration tests: PASS
- NFR benchmarks: PASS

## Handoffs
handoffs/<run-id>/" \
     --base main \
     --head feature/<run-id>

   For WF-03 branches use --title "fix: <one-line summary> [<run-id>]"

8. Merge PR immediately (all gates already passed):
   gh pr merge --squash --delete-branch

9. Local cleanup:
   git checkout main
   git pull --ff-only origin main
   git branch -d feature/<run-id>

10. → fn:register-inner-report

11. → fn:complete-handoff(status: PASS,
      artifacts_out: ["branch: feature/<run-id> (squash-merged into main, branch deleted)"],
      next_action: "ORCH marks run COMPLETED and releases owned_modules lock")
```

---

## Acceptance Criteria

- [ ] `gh pr merge` exited 0
- [ ] `git branch --show-current` is `main`
- [ ] `git pull --ff-only` on main after merge exited 0
- [ ] `git branch -d feature/<run-id>` exited 0

---

## Conflict Escalation

When this step returns FAIL due to complex conflict (> 5 files or engine/auth paths), ORCH:

1. Routes to CODE-DESIGNER:
   > "Resolve merge conflict between feature/<run-id> and origin/main. Conflicting files: <list>. For each file produce the correct merged content."
2. After CODE-DESIGNER completes (artifacts_out: resolved file versions):
   BACKEND-DEV or FRONTEND-DEV applies the resolved files and re-attempts from step 5 (rebase).
3. `rework_count` applies to this step; `max_rework = 3` before full ESCALATED.
