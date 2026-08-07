# PROJECT_BOARD Protocol — GitHub Project as the Human-Readable Status Board

**Version:** 1.0 · 2026-08-07
**Function:** `fn:update-board-status`
**Read by:** `ORCH` (owner); `BACKEND-DEV`/`FRONTEND-DEV` (Step 00, Step Final); `UAT-RUNNER`; `PRODUCT-OWNER`
**Tool:** `tools/gh_project_status.py`
**Board:** https://github.com/users/tvolodi/projects/3 ("R-Co system")

---

## Purpose

Every other protocol in this repo (`ISSUE_QUEUE.md`, `LOOP_PROTOCOL.md`, `HANDOFF_PROTOCOL.md`)
answers "how does the pipeline move an issue through its steps." None of them answer
"where does a human look to see what's in flight right now" — that has required opening
handoff JSON, `orchestrator.log`, or an agent's chat transcript.

This protocol wires the pipeline into the **Status** field that already exists on the
"R-Co system" GitHub Project (project number 3), so the maintainer can read pipeline
state from one board instead of reconstructing it from agent output.

**The board is a side effect of the pipeline, never a gate.** A failure to update the
board must never block or fail a workflow step — see "Failure handling" below.

---

## Status field (already exists on the board — do not rename without updating this doc and `tools/gh_project_status.py`)

```
Todo → In Progress → Implemented → Validated by UAT agent → Done
```

| Status | Meaning |
|---|---|
| `Todo` | Filed, not yet claimed by any agent |
| `In Progress` | Claimed — an agent is actively running a workflow against it |
| `Implemented` | The fix is merged to `main`. For a **UAT-scoped** issue, this is where it stops until UAT-Runner validates it. |
| `Validated by UAT agent` | UAT-Runner exercised the relevant scenario(s) and it passed |
| `Done` | Terminal. Reached directly from `Implemented` for non-UAT-scoped issues; reached from `Validated by UAT agent` otherwise. |

---

## Is an issue UAT-scoped?

An issue is **UAT-scoped** if the fix's requirement ID(s) have UAT scenario coverage.
Concretely, the discovering/fixing agent checks:

```bash
# For each requirement ID the fix touches (from the ISS file's context or the
# handoff's requirement_ids):
grep -ril "<REQ-ID>" tests/simulation/scenarios/**/*.yaml
```

- **Match found** → UAT-scoped. The requirement is exercised by a business scenario
  belonging to one of the simulated companies (SwiftRoute / Vortex / Meridian), so a
  business owner should see it validated before it's Done. Stop the board at
  `Implemented`; UAT-Runner (WF-05) advances it to `Validated by UAT agent` → `Done`
  the next time it runs and that scenario passes.
- **No match** → not UAT-scoped (pure infra/build/CI/tooling fixes — e.g. a `.gitignore`
  fix, a CI workflow change, a linter defect — have no requirement ID at all, and most
  requirement-linked fixes still won't intersect a written scenario). Move straight from
  `Implemented` to `Done` in the same Step Final.

This mirrors how WF-05 itself decides scenario applicability — there is no separate
classification scheme to maintain.

**If an issue has no requirement ID at all** (the common case for infra/CI/tooling
issues, and for issues filed by `ISSUE_QUEUE.md`'s forwarding path that don't name one):
treat it as not UAT-scoped without running the grep.

---

## Tool: `tools/gh_project_status.py`

```
python3 tools/gh_project_status.py <issue-number> --target <in_progress|implemented|validated|done>
```

- `<issue-number>` is the **GitHub issue number**, not the local `ISS-NNNN` id — these
  are different sequences (see `ISSUE_QUEUE.md`). Get it from the ISS file's
  `github_issue` field.
- Idempotent and monotonic: calling it with a target at or behind the current status is
  a no-op that still exits 0. It is always safe to call unconditionally at each
  transition point below rather than trying to track whether a previous call already
  ran.
- Exit 0 = moved or already there. Exit 1 = a real error (see "Failure handling").

---

## Transition points

| When | Who calls it | Call |
|---|---|---|
| Issue claimed (WF-03 Step 00, or `gh_claim.py`/`queue_claim.py` claim) | `BACKEND-DEV`/`FRONTEND-DEV` | `gh_project_status.py <N> --target in_progress` |
| WF-03 Step Final, issue is **not** UAT-scoped | `BACKEND-DEV`/`FRONTEND-DEV` (as part of `fn:git-merge`) | `gh_project_status.py <N> --target implemented` then `--target done` |
| WF-03 Step Final, issue **is** UAT-scoped | `BACKEND-DEV`/`FRONTEND-DEV` (as part of `fn:git-merge`) | `gh_project_status.py <N> --target implemented` (stop — do not call `done`) |
| WF-05 Step 1, UAT-Runner's scenario run covers this issue's requirement and it PASSES | `UAT-RUNNER` | `gh_project_status.py <N> --target validated` then `--target done` |
| WF-05 Step 1, scenario FAILS or the requirement regresses | `UAT-RUNNER` | do not advance the board; the issue stays `Implemented` — this is itself informative (implemented but not yet UAT-clean) |

**Where to run it in an existing run:** the calls at Step 00 and Step Final happen
inside the same shell session as `fn:git-setup` / `fn:git-merge` — no new handoff step
is needed. Treat it the same way `fn:register-issue` is already threaded through
existing steps rather than becoming its own row in the pipeline table.

---

## Failure handling

If `gh_project_status.py` exits 1 (rate limit, network, a renamed Status option, the
PR/issue number collision guard tripping):

- **Never fail the workflow step because of it.** Log the failure (one line to
  `handoffs/orchestrator.log`, event `BOARD_UPDATE_FAILED`) and continue. The board is
  a visibility aid; a stale card is a minor inconvenience, not a pipeline defect.
- Do not retry in a loop and do not add `continue-on-error`-style suppression around
  the *workflow's own* gates to work around it — this only touches the board call
  itself, which was never a gate.
- If it fails repeatedly across runs (e.g. the Status field was renamed in the UI),
  file it as its own issue per `ISSUE_QUEUE.md` — it is a real defect in the tooling,
  just not one that should have ever blocked a merge.

---

## Why per-issue lookups, not `gh project item-list`

`gh project item-list` pages the entire board (300+ items on "R-Co system" as of
2026-08-07) and is expensive enough in GraphQL cost to contribute to rate-limit
exhaustion when called once per transition across many concurrent WF-03 runs. The tool
instead reads a single issue's card via `gh issue view <N> --json projectItems` (one
cheap GraphQL node) and only pays for `gh project field-list` / `item-edit` when a real
move is needed. Do not "simplify" this back to `item-list` — it was tried in this
session and burned the GraphQL quota within a single afternoon of loop activity.

---

## Acceptance criteria

- [ ] Every issue that reaches `In Progress` on the board corresponds to an active
      lock in `handoffs/global_queue.json` (or, going forward, an item claimed via
      `gh_claim.py`) — the board and the lock registry never disagree about what's
      actively being worked
- [ ] No issue reaches `Done` on the board while its GitHub issue is still open
- [ ] No UAT-scoped issue reaches `Done` without first passing through
      `Validated by UAT agent`
- [ ] A board-update failure never appears as a workflow FAIL result
