# ISSUE_QUEUE Protocol — In-Run Issue Draining

**Version:** 0.1 · 2026-08-05
**Function:** `fn:enqueue-issue`, `fn:drain-issue-queue`
**Read by:** `ORCH` (owner); referenced by all agents that can discover a new issue mid-run (`TEST-RUNNER`, `RELEASE-VALIDATOR`, `ISSUE-FIXER`, `CODE-DESIGN-VALIDATOR`, `TEST-DESIGN-VALIDATOR`)
**Used in:** WF-02 Step 4/5, WF-03 (self-nesting), WF-04 sub-runs, WF-05 Step 2c

---

## Purpose

Before this protocol existed, every issue discovered mid-run — a TEST-RUNNER regression, a RELEASE-VALIDATOR NFR failure, a stray defect an agent tripped over while doing something else — triggered its own **full WF-03 run**, complete with its own `git-setup` (new branch) and `git-merge` (own PR, own squash-merge). A run that surfaced 4 incidental issues produced 5 branches and 5 PRs for what a human would think of as one unit of work, and paid the git-setup/git-merge overhead 5 times.

This protocol replaces that pattern with **one branch, one PR, one merge per top-level run**, no matter how many issues are found and fixed along the way. All issue-fixing work happens as repeated passes over WF-03's Steps 1–7 (diagnose → design → design-gate → fix → test → test-gate → verify → doc-update) **on the run's existing branch**. Steps 00 (git-setup) and Final (git-merge) run exactly once per top-level run: 00 at the very start, Final only after the queue is empty.

---

## Core concept: the issue queue

Every top-level run (a WF-02, WF-03, WF-04, or WF-05 invocation that itself performed Step 00) owns exactly one issue queue, persisted at:

```
handoffs/<run_id>/issue_queue.json
```

```json
{
  "run_id": "<run_id>",
  "created_at": "<ISO8601>",
  "branch_name": "feature/<run_id>",
  "items": [
    {
      "issue_id": "ISS-NNNN",
      "github_issue": "https://github.com/tvolodi/R-Co/issues/NNN",
      "status": "QUEUED",
      "severity": "BLOCKER|MAJOR|MINOR",
      "discovered_at": "<ISO8601>",
      "discovered_by": "<agent + step, e.g. TEST-RUNNER Step 4>",
      "discovered_while_fixing": null,
      "started_at": null,
      "completed_at": null
    }
  ]
}
```

- `discovered_while_fixing`: `null` if this issue was found during the original task's own steps; otherwise the `issue_id` of the queue item that was being drained when this one was found. This is what lets the queue nest to any depth while staying a flat list — see **Draining order** below.
- `status` moves `QUEUED` → `IN_PROGRESS` → `DRAINED` (fixed) or `ESCALATED` (rework exhausted; see WF-03 §Rework Tracking).

This file is created empty (`items: []`) by ORCH immediately after Step 00 of the top-level run returns PASS, and is a **workflow artifact** — commit it alongside `handoffs/` per CLAUDE.md's Bookkeeping directive.

---

## When an agent discovers a new issue

Any agent, in any step of any workflow, that finds an issue **which is not the thing it was already asked to fix** does the following instead of asking ORCH to "launch WF-03":

```
1. → fn:search-issues (docs/issues/issue_index.json) — check for a duplicate, same as
   WF-03 Step 0.5 today. If a match exists, do not create a new ISS file or queue entry;
   note the recurrence on the existing ISS file per WF-03 Step 0.5's procedure.

2. If new: → fn:register-issue (docs/issues/ISS-<NNNN>.json) — same schema and same
   "file it on GitHub" mandatory step as WF-03 Step 0.5 / CLAUDE.md's
   "No Issue Left Local-Only" directive. This step is UNCHANGED — every issue still
   gets an ISS file and a GitHub issue, regardless of whether it will be fixed inside
   this run's queue or left for a future run.

3. → fn:enqueue-issue:
   Append to handoffs/<run_id>/issue_queue.json:
     {
       "issue_id": "ISS-<NNNN>",
       "github_issue": "<url from step 2>",
       "status": "QUEUED",
       "severity": "<severity>",
       "discovered_at": "<ISO8601, real clock>",
       "discovered_by": "<this agent + step>",
       "discovered_while_fixing": "<current queue item's issue_id, or null if this is
                                    the top-level task>"
     }

4. → fn:complete-handoff as normal for the CURRENT step (PASS/FAIL on the thing this
   agent was actually asked to do). Discovering an incidental issue does NOT change
   this step's own result — it is recorded separately, in the queue, and does not
   block or fail the current step unless the current step's own acceptance criteria
   require the discovered defect to be absent (e.g. TEST-RUNNER regressions: see
   note below).
```

**Exception — the issue IS the current step's failure.** If TEST-RUNNER's own test run fails, or RELEASE-VALIDATOR's own NFR check fails, that is not an "incidental" issue — it is *this step's* result, and it drives the current queue item (or the top-level task, if none is active yet) into rework via WF-03 Steps 1–7 as normal. Enqueueing is only for issues found *alongside* what the agent was asked to check — e.g. TEST-RUNNER's full-suite regression run turning up 3 pre-existing unrelated failures while validating the 1 thing it was dispatched to verify.

---

## Draining order (steps 2–6, looped)

After the top-level task's own pass through WF-03/WF-02/etc. steps reaches its Step 7 (Doc Update) and would normally proceed to Step Final, ORCH instead:

```
1. Read handoffs/<run_id>/issue_queue.json.
2. If items with status QUEUED exist:
   a. Pick the OLDEST QUEUED item (FIFO — first discovered, first fixed).
   b. Set its status to IN_PROGRESS, stamp started_at (real clock).
   c. Re-enter WF-03 at Step 1 (Diagnose) for this issue, reusing the SAME branch
      (context.branch_name = the top-level run's branch — do NOT run Step 00 again).
   d. Run Steps 1 → 2 → 2b → 3 → (4 → 4b conditional) → 5 → 6 (conditional) → 7 exactly
      as WF-03 defines them. Any issue discovered during this pass is enqueued per the
      procedure above with discovered_while_fixing = this item's issue_id — the queue
      grows, it does not nest a new branch or a new git-setup/git-merge pair.
   e. On Step 7 completion: set this item's status to DRAINED, stamp completed_at.
   f. On rework exhaustion (WF-03's max_rework): set status to ESCALATED, stop draining,
      escalate per WF-03's existing escalation procedure — this ends the run without
      reaching Step Final; the branch is left pushed but unmerged for human review.
   g. GOTO step 1 (re-read the queue — new items may have been appended in step d).
3. If no items with status QUEUED remain (queue fully DRAINED, or was always empty):
   proceed to Step Final (git-merge) for the top-level run, exactly once.
```

This is the literal "goto step 2 for the next found issue" loop: step 2 of the numbering in this protocol corresponds to WF-03's own Step 1 (Diagnose) — the first thing that happens for any issue, top-level or queued.

**FIFO, not LIFO:** issues are drained in discovery order, not depth-first. If fixing issue A surfaces issue B, B is appended to the end of the queue and fixed after whatever else was already ahead of it — not immediately. This keeps the loop simple (one flat queue) and matches "fully drain the queue, any depth" without needing a call stack.

**No queue-drain issue writes files outside the branch.** Every fix in the loop lands as its own commit on the one shared branch (per WF-03 Step 3 / Step 7's existing commit conventions) — see **Commit shape** below.

---

## Commit shape

Because Step 00 and Step Final each run once, but Steps 1–7 run once per queue item (plus once for the original task), the branch accumulates one commit per item:

```
feat(<run-id>): implement <original task>              ← original task's own Step N commit
fix(<run-id>): <ISS-NNNN summary> (ISS-NNNN)            ← first drained issue's Step 3/7 commit
fix(<run-id>): <ISS-MMMM summary> (ISS-MMMM)            ← second drained issue's commit
...
feat/fix(<run-id>): finalize artifacts — reports, changelog   ← Step Final's own catch-all commit
```

All of these are squashed into **one** merge commit by Step Final (`gh pr merge --squash`), same as today — squashing was already the norm; what changes is that there is only ever one PR to squash, not one per issue.

---

## owned_modules — no new lock per queue item

Because queue items reuse the top-level run's branch, they also reuse its `owned_modules` lock (ORCHESTRATOR.md §10). **Do not** register a new `owned_modules` entry or a new registry row per drained issue — the lock covers the branch's entire lifetime, from Step 00 to Step Final, regardless of how many issues are drained on it in between. If a drained issue's fix would need to touch a module outside the run's declared `owned_modules`, treat that the same as any other out-of-scope fix: expand the declared `owned_modules` for the run (log `MODULE_LOCK` again with the expanded list) rather than starting a second branch.

---

## Interaction with WF-02 / WF-04 / WF-05

- **WF-02 Step 4 (TEST-RUNNER) / Step 5 (RELEASE-VALIDATOR):** on FAIL, instead of "Route to WF-03" as a nested full run, enqueue the failure (if it's a distinct issue from what's already queued) and drain per this protocol before WF-02's own Step 6/Step Final.
- **WF-04 (Full Test Run):** each NFR/coverage/regression failure across its sub-runs is enqueued onto the single run's queue rather than spawning independent WF-03 branches. See WF-04's own doc for how its sub-runs map onto one top-level branch.
- **WF-05 Step 2c (ORCH routing gate):** a BLOCKED UAT verdict enqueues one item per BO-flagged issue, drained the same way, before Step 1 (UAT-RUNNER) is re-run.
- **WF-01:** unaffected — WF-01 has no git wrapper (docs-only) and does not produce code, so there is nothing to queue against.

---

## Acceptance criteria

- [ ] `handoffs/<run_id>/issue_queue.json` exists for every run from the moment Step 00 (top-level) returns PASS
- [ ] Every enqueued item has a corresponding `docs/issues/ISS-NNNN.json` AND a filed GitHub issue — enqueueing never substitutes for either
- [ ] Step 00 (git-setup) appears exactly once per top-level run's `handoffs/orchestrator.log` entries
- [ ] Step Final (git-merge) appears exactly once per top-level run's `handoffs/orchestrator.log` entries, after the last item reaches DRAINED or ESCALATED
- [ ] No `owned_modules` registry entry is created per queue item — only per top-level run
- [ ] `issue_queue.json` is committed to the branch (workflow artifact, per CLAUDE.md Bookkeeping directive)
