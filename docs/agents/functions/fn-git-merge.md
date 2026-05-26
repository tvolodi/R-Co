# fn:git-merge

**Category:** Git
**Used by:** `BACKEND-DEV`, `FRONTEND-DEV`
**Step:** Step Final (WF-02, WF-03, WF-04 sub-workflows)
**Document:** `docs/agents/protocols/GIT_MERGE.md`

---

## Purpose

Commit all work produced by the WF-02 pipeline on the feature branch, rebase onto the latest `origin/main`, push, create and immediately merge a PR, then clean up the local branch.

---

## Procedure

```bash
# 1. Verify on correct branch
git branch --show-current   # must equal feature/<run-id>

# 2. Stage and commit
git add -A
git commit -m "feat(<run-id>): <DOC-UPDATER result.summary one-liner>

Requirements: <comma-separated req IDs>
Handoff: <run-id>"

# 3. Sync
git fetch origin main

# 4. Rebase (see conflict rules below)
git rebase origin/main

# 5. Verify build after rebase
zig build
zig build test   # unit tests only

# 6. Push
git push origin feature/<run-id>

# 7. Create PR
gh pr create \
  --title "feat: <summary> [<run-id>]" \
  --body "..." \
  --base main \
  --head feature/<run-id>

# 8. Merge immediately (all gates already passed by WF-02 agents)
gh pr merge --squash --delete-branch

# 9. Local cleanup
git checkout main
git pull --ff-only origin main
git branch -d feature/<run-id>
```

---

## Conflict Resolution Rules

| Condition | Action |
|---|---|
| ≤ 5 conflicted files, none in `src/engine/` or `src/api/middleware/` | Resolve inline, `git add`, `git rebase --continue`, then verify build |
| > 5 files OR conflict in `src/engine/` or `src/api/middleware/` | `git rebase --abort`; return FAIL; ORCH escalates to CODE-DESIGNER |
| Build fails after conflict resolution | Fix compile errors, re-add, `git rebase --continue`; if still broken return FAIL |
| Unit tests fail after conflict resolution | Return FAIL; ORCH routes to ISSUE-FIXER then returns to rebase step |

---

## Failure Conditions

| Condition | Action |
|---|---|
| `git branch --show-current` is not `feature/<run-id>` | STOP; return FAIL with BLOCKER |
| `gh pr merge` fails (PR not mergeable, branch behind) | Re-run fetch + rebase cycle from step 3; retry once |
| `git pull --ff-only` on main fails after PR merge | Run `git fetch origin main; git reset --hard origin/main`; this is safe post-merge |
