# WF-05 — Parallel Git Protocol

**Version:** 0.2 · 2026-05-26
**Trigger:** ALL WF-02, WF-03, and WF-04 agent-driven workflows (not optional)
**Owner:** `ORCH`

---

## Purpose

WF-05 wraps ALL agent-driven implementation workflows (WF-02, WF-03, WF-04 fix routing) with git branch management. This is **NOT optional coordination** - it is the **default workflow** for all agent work.

**Why always use branches:**
- Creating the feature branch IS the coordination signal
- Other hosts see `origin/feature/WF02-xyz` immediately after first push
- Git/GitHub naturally queues PRs for sequential merge
- No collision detection needed - git handles it

**Single-host mode (working directly on main) only applies to:**
- Human manual edits
- Emergency hotfixes by operators
- Documentation-only changes (WF-01 requirement drafting)

**Agent workflows ALWAYS create a feature branch.**

It adds exactly two steps around the standard WF-02/WF-03/WF-04 pipeline:

- **Step 00 — Git Setup** (before first code-changing step): creates the feature branch, pushes immediately
- **Step Final — Git Merge** (after last step): rebases, creates PR, merges, cleans up

All intermediate steps run unchanged on the feature branch.

---

## When to Use WF-05 (Simple Rule)

**Rule:** ORCH ALWAYS uses WF-05 for agent-driven workflows: WF-02, WF-03, and any fix routing from WF-04.

**No detection check needed.** Every workflow run creates a feature branch in Step 00.

### Why This Works: The Branch IS the Coordination

**Scenario:** Two hosts start work simultaneously

```
10:00 - Host A: WF-02 for API-13 starts
        ↓ Step 00: creates feature/WF02-api13-20260526
        ↓ git push origin feature/WF02-api13-20260526  ← ANNOUNCEMENT
        ↓ Works on feature branch...

10:05 - Host B: WF-02 for API-14 starts  
        ↓ Step 00: creates feature/WF02-api14-20260526
        ↓ git push origin feature/WF02-api14-20260526  ← ANNOUNCEMENT
        ↓ Works on feature branch...
        (Host B can see Host A's branch via: git fetch; git branch -r)

11:00 - Host A: Step Final attempts merge
        ↓ git fetch origin main
        ↓ git rebase origin/main   (clean - A is first)
        ↓ gh pr create + gh pr merge --squash
        ↓ feature/WF02-api13-20260526 merged into main ✓

11:30 - Host B: Step Final attempts merge
        ↓ git fetch origin main   (now includes A's work)
        ↓ git rebase origin/main  (may have conflicts - handle per WF-05 conflict protocol)
        ↓ gh pr create + gh pr merge --squash
        ↓ feature/WF02-api14-20260526 merged into main ✓
```

**The merge queue is natural:**
- First to finish Step Final: merges cleanly
- Second to finish: rebases onto first's merged work
- Third to finish: rebases onto both
- Conflicts detected during rebase, resolved inline

**The `git push origin feature/<run-id>` in Step 00 is the coordination signal** - all other hosts see it immediately after `git fetch`.

### Exception: Documentation-Only Workflows

**WF-01 (requirement development)** does not need WF-05 because it only modifies markdown files in `docs/` that rarely conflict. ORCH may skip WF-05 for WF-01 runs.

---

## ⛔ Mandatory Rule for All Steps

**Every agent completing a step in this workflow MUST call `fn:register-inner-report` immediately before `fn:complete-handoff`.**

---

## Overview

```
[INPUT: VALIDATED requirement IDs; parallel-host execution requested]
           │
           ▼
┌──────────────────────────┐
│  STEP 00: GIT-SETUP      │ ← BACKEND-DEV (backend/mixed) or FRONTEND-DEV (frontend-only)
│  git pull + new branch   │   fn:git-setup
└──────────┬───────────────┘
           │ PASS
           ▼
┌──────────────────────────────────────────────────────────────────┐
│  STEPS 01–06: WF-02 STANDARD PIPELINE (on feature/<run-id>)     │
│  01 CODE-DESIGNER → 02a BACKEND-DEV / 02b FRONTEND-DEV          │
│  03 TEST-DESIGNER → 04 TEST-RUNNER → 05 RELEASE-VALIDATOR       │
│  06 DOC-UPDATER                                                  │
│  (follow WF-02 routing rules including rework and WF-03 exactly) │
└──────────┬───────────────────────────────────────────────────────┘
           │ Step 06 PASS
           ▼
┌──────────────────────────┐
│  STEP FINAL: GIT-MERGE   │ ← same agent as step 00
│  Rebase → PR → merge     │   fn:git-merge
│  → local cleanup         │
└──────────┬───────────────┘
           │ PASS
           ▼
[OUTPUT: feature/<run-id> squash-merged into main; branch deleted; run COMPLETED]
```

---

## Step 00 — Git Setup

**Agent:** `BACKEND-DEV` (backend/mixed runs) or `FRONTEND-DEV` (frontend-only runs)
**Function:** `fn:git-setup`

### Procedure

```
1. git checkout main
2. git pull --ff-only origin main
   If FAIL (non-fast-forward): STOP; fn:complete-handoff(status: FAIL,
     issues: [{severity: BLOCKER, description: "local main has diverged from origin — manual sync required"}])
   Do not proceed until resolved.
3. Branch name = feature/<run-id>   (e.g. feature/WF02-oidc01-20260527)
4. If branch already exists from a prior aborted run:
   git branch -D feature/<run-id>   # delete stale branch
5. git checkout -b feature/<run-id>
6. Verify: git branch --show-current outputs feature/<run-id>
7. IMMEDIATELY push the branch (creates coordination signal):
   git push -u origin feature/<run-id>
   (This announces "I am working" to all other hosts)
8. → fn:register-inner-report
9. → fn:complete-handoff (status: PASS,
     artifacts_out: ["branch: feature/<run-id>"],
     next_action: "Route to CODE-DESIGNER for WF-02 Step 01")
```

### Acceptance criteria

- [ ] `git pull --ff-only` exited 0
- [ ] `git branch --show-current` outputs `feature/<run-id>`
- [ ] `git push -u origin feature/<run-id>` exited 0
- [ ] Other hosts can see the branch via: `git fetch; git branch -r`

---

## Steps 01–06 — WF-02 Core Pipeline

Run these steps exactly as defined in `docs/agents/workflows/WF-02_requirement_implementation.md`.

**All file writes during these steps happen on `feature/<run-id>`.** Agents do not run any git commands during steps 01–06 — only in step 00 and step final.

---

## Step Final — Git Merge

**Agent:** `BACKEND-DEV` (backend/mixed) or `FRONTEND-DEV` (frontend-only) — same agent as step 00
**Function:** `fn:git-merge`

### Procedure

```
1. Verify current branch:
   git branch --show-current
   Must equal feature/<run-id>. If not: STOP; report FAIL to ORCH.

2. Stage all changes:
   git add -A

3. Commit (use the run-id and DOC-UPDATER's result.summary for the message):
   git commit -m "feat(<run-id>): <one-line summary from DOC-UPDATER result.summary>

   Requirements: <comma-separated requirement IDs from context.requirement_ids>
   Handoff: <run-id>"

4. Sync with remote:
   git fetch origin main

5. Rebase onto origin/main:
   git rebase origin/main

   ── CONFLICT HANDLING (fully agent-driven) ──────────────────────────────
   a. Count conflicted files:
      git diff --name-only --diff-filter=U | wc -l
      If count > 5 OR any conflict is in src/engine/ or src/api/middleware/:
        git rebase --abort
        → fn:register-inner-report
        → fn:complete-handoff(status: FAIL,
            issues: [{severity: BLOCKER,
                      description: "Merge conflict too complex for inline resolution: <list files>"}],
            next_action: "ORCH escalates to CODE-DESIGNER for conflict resolution")
        STOP

   b. For each conflicted file (≤ 5 files):
      - Read both HEAD version and incoming version
      - Apply correct resolution (preserve valid changes from both sides)
      - git add <file>

   c. git rebase --continue

   d. Verify build still passes:
      zig build
      If FAIL: fix compile errors, git add <file>, git rebase --continue
      zig build test   (unit tests only — integration tests already passed in WF-02 Step 04)
      If FAIL: → fn:complete-handoff(status: FAIL, ...)
               ORCH routes to ISSUE-FIXER; after ISSUE-FIXER PASS, return to step 5
   ────────────────────────────────────────────────────────────────────────

6. Push branch to remote:
   git push origin feature/<run-id>

7. Create PR:
   gh pr create \
     --title "feat: <one-line summary> [<run-id>]" \
     --body "## Summary
<DOC-UPDATER result.summary>

## Requirements
<comma-separated requirement IDs>

## Validation
- zig build: PASS (WF-02 Step 02)
- Unit + integration tests: PASS (WF-02 Step 04)
- NFR benchmarks: PASS (WF-02 Step 05)

## Handoffs
handoffs/<run-id>/" \
     --base main \
     --head feature/<run-id>

8. Merge PR immediately (no waiting — all gates already passed by agents):
   gh pr merge --squash --delete-branch

9. Local cleanup:
   git checkout main
   git pull --ff-only origin main
   git branch -d feature/<run-id>

10. → fn:register-inner-report
11. → fn:complete-handoff (status: PASS,
      artifacts_out: ["branch: feature/<run-id> (squash-merged into main, branch deleted)"],
      next_action: "WF-05 complete — ORCH releases owned_modules lock")
```

### Acceptance criteria

- [ ] `gh pr merge` exited 0
- [ ] `git branch --show-current` is `main`
- [ ] `git pull --ff-only` on main after merge exited 0
- [ ] `git branch -d feature/<run-id>` exited 0 (local branch deleted)

---

## Conflict Resolution Escalation

When step final returns FAIL due to complex conflict (> 5 files or engine/auth paths):

```
ORCH action:
  1. Route to CODE-DESIGNER with task:
       "Resolve merge conflict between feature/<run-id> and origin/main.
        Conflicting files: <list>. For each file produce the correct merged content."
  2. After CODE-DESIGNER completes (artifacts_out: merged file versions):
       BACKEND-DEV or FRONTEND-DEV applies the resolved files and re-attempts step final from step 5 (rebase).
  3. rework_count applies to step-final: max_rework = 3 before full ESCALATED.
```

---

## Branch Naming Convention

```
feature/<run-id>
```

Examples:
```
feature/WF02-oidc01-20260527
feature/WF02-dsl01-20260527
feature/WF02-lua01-20260527
```

One branch per run-id. ORCH MUST NOT assign overlapping `owned_modules` to two concurrently active WF-05 runs.

---

## ORCH Responsibilities

### At run start

1. Assign branch name `feature/<run-id>` and record it in the step-00 handoff `context`.
2. Record `owned_modules` (list of `src/` paths this run will write) in the handoff context — prevents ORCH from starting a second run that writes to the same files.
3. Check registry: no active WF-05 run may share `owned_modules` with this new run. If overlap detected: defer the new run to PENDING until the conflicting run reaches step-final PASS.
4. Create step-00 handoff → route to BACKEND-DEV or FRONTEND-DEV.
5. After step-00 PASS: create step-01 handoff for CODE-DESIGNER (WF-02 begins normally).

### During WF-02 steps (01–06)

6. Follow WF-02 routing rules exactly (rework, WF-03 dispatch, RELEASE-VALIDATOR bench check, etc.).

### After DOC-UPDATER (step-06) PASS

7. Create step-final handoff → route to same agent that ran step-00.
8. Monitor for PASS/FAIL on step-final.

### After step-final PASS

9. Mark the run COMPLETED in registry.
10. Release the `owned_modules` lock — ORCH may now assign those modules to a new run.

### Log entries for WF-05-specific actions

```
<ISO8601> | GIT_SETUP   | <run-id> | <handoff-id> | ORCH → BACKEND-DEV | PENDING
<ISO8601> | GIT_MERGE   | <run-id> | <handoff-id> | ORCH → BACKEND-DEV | PENDING
<ISO8601> | MODULE_LOCK | <run-id> | ---           | ORCH | LOCKED: <module-paths>
<ISO8601> | MODULE_FREE | <run-id> | ---           | ORCH | RELEASED: <module-paths>
<ISO8601> | DEFER_RUN   | <run-id> | ---           | ORCH | DEFERRED: overlaps with <other-run-id>
```
