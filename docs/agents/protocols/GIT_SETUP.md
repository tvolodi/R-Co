# GIT_SETUP Protocol

**Version:** 0.1 · 2026-05-26  
**Function:** `fn:git-setup`  
**Read by:** `BACKEND-DEV`, `FRONTEND-DEV`  
**Used in:** WF-02 Step 00, WF-03 Step 00, WF-04 direct-routed fix Step 00

---

## Purpose

Creates the feature branch and announces work to all other hosts before any file changes are made. The `git push` in step 7 is the coordination signal — other hosts see the branch immediately after `git fetch`.

---

## Branch Naming Convention

```
feature/<run-id>
```

Examples:
```
feature/WF02-oidc01-20260527
feature/WF03-EE05-fix-20260527
feature/WF04-nfr-SCH01-20260527
feature/WF04-cov-ES03-20260527
```

One branch per run-id. ORCH ensures no two concurrent runs share `owned_modules`.

---

## Procedure

```
1. git checkout main

2. git pull --ff-only origin main
   If FAIL (non-fast-forward):
     → fn:register-inner-report
     → fn:complete-handoff(status: FAIL,
         issues: [{severity: BLOCKER,
                   description: "local main has diverged from origin — manual sync required"}])
   Do not proceed until resolved.

3. Branch name = feature/<run-id>  (supplied by ORCH in context.branch_name)

4. If branch already exists from a prior aborted run:
   git branch -D feature/<run-id>

5. git checkout -b feature/<run-id>

6. Verify: git branch --show-current  →  must equal feature/<run-id>

7. Push immediately (coordination signal — announces work to all other hosts):
   git push -u origin feature/<run-id>

8. → fn:register-inner-report

9. → fn:complete-handoff(status: PASS,
     artifacts_out: ["branch: feature/<run-id>"],
     next_action: "ORCH routes to next step per active workflow")
```

---

## Acceptance Criteria

- [ ] `git pull --ff-only` exited 0
- [ ] `git branch --show-current` outputs `feature/<run-id>`
- [ ] `git push -u origin feature/<run-id>` exited 0
- [ ] Other hosts can see the branch via: `git fetch; git branch -r`
