# fn:git-setup

**Category:** Git
**Used by:** `BACKEND-DEV`, `FRONTEND-DEV`
**Step:** Step 00 (WF-02, WF-03, WF-04 sub-workflows)
**Document:** `docs/agents/protocols/GIT_SETUP.md`

---

## Purpose

Ensure the local `main` branch is current with `origin/main` and create the feature branch for this run. This must complete before any implementation work begins.

---

## Procedure

```bash
git checkout main
git pull --ff-only origin main
# If already exists from a prior aborted run:
#   git branch -D feature/<run-id>
git checkout -b feature/<run-id>
git branch --show-current   # verify output equals feature/<run-id>
```

---

## Failure Conditions

| Condition | Action |
|---|---|
| `pull --ff-only` fails (diverged history) | STOP; return FAIL with BLOCKER: "local main has diverged from origin" |
| Branch `feature/<run-id>` already exists | Delete it first: `git branch -D feature/<run-id>`, then recreate |
| Uncommitted changes on main | Do NOT stash. Return FAIL with BLOCKER: "main has uncommitted changes — stale work from a prior run must be reviewed" |
| `git checkout main` fails (detached HEAD) | `git checkout -B main origin/main`, then continue from pull |
