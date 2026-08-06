# ISSUE_QUEUE Protocol — Forwarding Issues Found Mid-Run

**Version:** 1.0 · 2026-08-06
**Function:** `fn:enqueue-issue`
**Read by:** `ORCH` (owner); referenced by all agents that can discover a new issue mid-run (`TEST-RUNNER`, `RELEASE-VALIDATOR`, `ISSUE-FIXER`, `CODE-DESIGN-VALIDATOR`, `TEST-DESIGN-VALIDATOR`)
**Used in:** WF-02 Step 4/5, WF-03, WF-04 sub-runs, WF-05 Step 2c

---

## Purpose

A run does one job. When an agent trips over a defect that is **not** the thing it was asked to fix, that defect is **filed and forwarded** — it does not extend the current run.

Forwarding means: the discovering agent registers the issue (`docs/issues/ISS-NNNN.json`),
files it on GitHub (mandatory — CLAUDE.md "No Issue Left Local-Only"), and adds it to the
**global queue** (`handoffs/global_queue.json`) via `tools/queue_add.py`. It is picked up
later as its own WF-03 run, with its own branch and PR — by this workspace's next loop
iteration, or by another workspace. See `docs/agents/protocols/LOOP_PROTOCOL.md`.

**There is no in-run drain loop.** A run has no per-run issue queue, no "Queue Check"
between its last step and Step Final, and no repeated passes over WF-03 Steps 1–7. Step 00
(git-setup) and Step Final (git-merge) still run exactly once per run — but Step Final now
follows the run's last normal step directly.

> **History.** Versions 0.x of this protocol specified the opposite: a per-run
> `handoffs/<run_id>/issue_queue.json`, drained FIFO on the run's existing branch before
> Step Final, to any depth. That inner loop was removed on 2026-08-06. Per-run
> `issue_queue.json` files committed under `handoffs/` before that date are retained as
> audit history; **do not create new ones**, and do not treat an existing one as a signal
> to drain.

---

## Why the inner loop was removed

| | Inner drain loop (removed) | Forward to global queue (current) |
|---|---|---|
| Run scope | Grew unboundedly with each discovery | Fixed at what the run was started to do |
| Branch content | One branch mixing the original task + N unrelated fixes | One branch, one concern |
| PR reviewability | A squashed PR of unrelated changes | Independently reviewable per issue |
| Failure blast radius | One escalation stranded the whole branch, unmerged | An escalation affects only its own item |
| Depth | Unbounded — issues found while fixing issues, recursively | Flat: discovery always ends at "filed + queued" |

The original motivation for the inner loop was avoiding repeated git-setup/git-merge
overhead. That cost is real but small, and it bought unbounded run scope in exchange —
a run could not finish until every incidentally-discovered defect was also fixed.

---

## When an agent discovers a new issue

Any agent, in any step of any workflow, that finds an issue **which is not the thing it was
already asked to fix**:

```
1. → fn:search-issues (docs/issues/issue_index.json) — check for a duplicate, same as
   WF-03 Step 0.5 today. If a match exists, do not create a new ISS file; note the
   recurrence on the existing ISS file per WF-03 Step 0.5's procedure. If that existing
   issue is already in the global queue, stop here — it is already scheduled.

2. If new: → fn:register-issue (docs/issues/ISS-<NNNN>.json) — same schema and same
   "file it on GitHub" mandatory step as WF-03 Step 0.5 / CLAUDE.md's
   "No Issue Left Local-Only" directive. UNCHANGED — every issue still gets an ISS file
   and a GitHub issue.

3. → fn:enqueue-issue — add it to the GLOBAL queue:

     python3 tools/queue_add.py ISS-<NNNN> \
         --severity BLOCKER|MAJOR|MINOR \
         --title "<short description>" \
         --github-issue "<url from step 2>"

   Exit 4 means it is already queued — that is success, not an error.

4. → fn:complete-handoff as normal for the CURRENT step (PASS/FAIL on the thing this
   agent was actually asked to do). Discovering an incidental issue does NOT change this
   step's own result, and does NOT block the current run from reaching Step Final.
```

**Exception — the issue IS the current step's failure.** If TEST-RUNNER's own test run
fails, or RELEASE-VALIDATOR's own NFR check fails, that is not an incidental issue — it is
*this step's* result, and it drives the current run into rework as normal (WF-03 Steps 1–7
for the run's own task, per the active workflow's routing table). Forwarding is only for
issues found *alongside* what the agent was asked to check — e.g. TEST-RUNNER's full-suite
regression run turning up 3 pre-existing unrelated failures while validating the 1 thing it
was dispatched to verify.

The Unblock-Everything directive (CLAUDE.md) still applies and is not in tension with this:
if a defect **blocks the current run from completing** — an unrelated compile error that
stops the build, a broken migration that blocks yours — fix it in this run. Forwarding is
for defects that are merely *adjacent*, not ones standing in the way.

---

## What ORCH does after the run's last step

Nothing extra. When the active workflow's last normal step returns PASS, ORCH dispatches
Step Final (git-merge) directly. There is no queue to check.

Issues forwarded during the run are visible in `handoffs/global_queue.json` and on GitHub.
If ORCH is in loop mode (`LOOP_PROTOCOL.md`), the next iteration claims one of them.

---

## owned_modules

The run's `owned_modules` lock (ORCHESTRATOR.md §10) covers the branch's lifetime from
Step 00 to Step Final, as before. Because the run's scope no longer grows with discovered
issues, the lock's declared module list should not need expanding mid-run. If a fix the run
legitimately needs would touch a module outside the declared list, expand it and log
`MODULE_LOCK` again with the expanded list — same as any other scope expansion.

---

## Interaction with WF-02 / WF-03 / WF-04 / WF-05

- **WF-02 Step 4 (TEST-RUNNER) / Step 5 (RELEASE-VALIDATOR):** a FAIL of the step's own
  criteria is rework for this run, per WF-02's routing table. Incidental findings alongside
  it are forwarded per this protocol and do not gate WF-02's Step Final.
- **WF-03:** an issue found while fixing an issue is forwarded to the global queue, not
  fixed in this run. WF-03 always runs Steps 0.5 → 7 exactly once per run.
- **WF-04 (Full Test Run):** each NFR/coverage/regression failure that is the checked
  step's own result drives that step's rework; anything else found alongside is forwarded.
- **WF-05 Step 2c (ORCH routing gate):** a BLOCKED UAT verdict is the run's own result —
  see WF-05 Step 2c for how it routes. Incidental BO findings outside the run's scope are
  forwarded.
- **WF-01:** unaffected — no git wrapper, docs-only.

---

## Acceptance criteria

- [ ] No new `handoffs/<run_id>/issue_queue.json` file is created by any workflow
- [ ] Every issue discovered mid-run has a `docs/issues/ISS-NNNN.json` AND a filed GitHub issue AND an entry in `handoffs/global_queue.json`
- [ ] Step 00 (git-setup) appears exactly once per run in `handoffs/orchestrator.log`
- [ ] Step Final (git-merge) appears exactly once per run, immediately following the run's last normal step — with no intervening drain passes
- [ ] `handoffs/global_queue.json` is committed after every forward (per LOOP_PROTOCOL.md)
- [ ] An incidental discovery never changes the discovering step's own PASS/FAIL verdict
