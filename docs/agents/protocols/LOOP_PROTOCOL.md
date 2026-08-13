# LOOP Protocol — TaskManager as Source of Truth, Multi-Workspace Locking

**Version:** 3.0 · 2026-08-13
**Function:** `fn:loop-mode`
**Read by:** `ORCH` (owner); relevant to any workspace running an autonomous fix loop
**Tool:** `C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\` (external to this repo — see below)
**See also:** `docs/agents/protocols/PROJECT_BOARD.md` — the project-board status
transitions this loop drives (`Todo → In Progress → Implemented → Validated by UAT
agent → Done`) so the maintainer can read pipeline state without opening agent chats.

---

## What changed in v3 and why

Every version of this protocol before v3 tried to make `handoffs/global_queue.json` (a
plain JSON file, committed to git) behave like a lock across multiple concurrent
workspaces. It never could, structurally: **git has no compare-and-swap.** Two workspaces
can each read the file, each see an item unclaimed, each write a claim, and each push —
the second push either wins outright (silently clobbering the first workspace's claim) or
fails with a conflict that has to be caught, interpreted, and manually resolved after the
fact. Every incident this file's history records (GH-542, GH-518, GH-526 — all still in
`docs/anti-patterns.md`) is the same race in a different disguise, and the file accumulated
increasingly elaborate defense-in-depth trying to detect the race after it happened
(push-then-reread verification, mutex TTLs, "no TTL at all" as a fix for the TTL fix)
rather than making the race impossible.

**v3 replaces the git-committed-JSON lock with a real transaction.** `TaskManager` is a
small SQLite-backed tool living **outside this repo**, at
`C:\Users\tvolo\dev\ai-dala\TaskManager\`, shared by every workspace on this machine. A
claim is one `BEGIN IMMEDIATE` SQLite transaction: SQLite takes the write lock before the
"is anything OPEN" read even runs, so a second workspace calling claim at the same instant
blocks until the first commits, then re-reads a world where that item is already `CLAIMED`
— there is no window where two workspaces both see the same item as claimable. This is not
a smaller, tighter version of the old race-detection scaffolding; it removes the race the
scaffolding existed to catch. Verify-the-push-landed, mutex-TTL-reclaim, and the
"someone forgot to push before Step 00" class of incident are gone because the failure mode
they existed to catch cannot occur — pushing to `main` is no longer part of how a claim
becomes visible to other workspaces at all.

GitHub issues (and `docs/requirements.yaml` DRAFT requirement batches) remain the two
sources of *work* — TaskManager mirrors both into one local table (`work_items`) and pushes
claim/release state back to GitHub as a label (`claimed-by-<workspace_id>`) so a human
looking at GitHub sees live state without opening the DB. GitHub itself is not, and was
never meant to be, the lock — see "Why not GitHub" below if that distinction is unclear.

---

## Purpose (unchanged from v2)

The loop drains open work — GitHub issues (bugs, BLOCKERs) via WF-03, and
`docs/requirements.yaml` DRAFT requirement batches via WF-02 — until nothing claimable
remains. Issues labeled `requirement` are excluded from the GitHub-issue loop (they're
from-scratch, never-implemented requirements — the wrong workflow; see
`ORCHESTRATOR.md`: *"if the feature has not been specified yet → WF-02"*). They're drained
instead by the requirement-batch loop below.

---

## The task file — what an agent actually reads

Every workspace's R-Co checkout has `task/current.json` (git-ignored). This file is the
**only** thing an agent-in-loop-mode looks at to know what to work on:

- `{}` → no claimed work. Call `claim.py` (see below).
- Populated → this workspace has exactly one claimed item. Work it. Do not call `claim.py`
  again until this is cleared.

**Never read `handoffs/global_queue.json`, `handoffs/batch_queue.json`, or GitHub's issue
list directly to decide what to work on.** Those files may still exist for historical/audit
reasons during the migration window, but they are not the source of truth and reasoning
about them (e.g. "this branch has been quiet for hours, the claim must be stale, I'll treat
it as mine") is exactly the failure mode that produced the GH-752/GH-758 double-work
incident on 2026-08-13 (see `docs/anti-patterns.md`). If `task/current.json` is empty, you
have no work — full stop, ask `claim.py` for the next item. Do not decide an item is
"probably abandoned" and start on it through any other route.

---

## Tools reference

All commands below are run from **anywhere** (they take `repo_id`, not a path) but are
typically run from the R-Co checkout root so `task/current.json` resolves as a relative
path. `repo_id` for this repo is `r-co`.

### claim.py

```powershell
python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\claim.py" r-co task/current.json
```

Atomically claims the newest `OPEN` work item for `r-co`, writes it into
`task/current.json`, and (for GitHub-sourced items) adds a `claimed-by-<workspace_id>`
label to the actual GitHub issue.

**`workspace_id` is resolved automatically** — `claim.py` reads `BPM_WORKSPACE_ID` from
this repo's own `.env` (via `repos.local_path`, set once by `repo_add.py`). Nobody has to
compute or pass it by hand; the previous version required every call site to read `.env`
itself, which is exactly the kind of repeated boilerplate that gets forgotten or done
inconsistently. Pass `--workspace-id <id>` only to override (testing, or a repo that
doesn't use the `.env` convention).

| Exit | Meaning | ORCH action |
|---|---|---|
| 0 | Claimed; item JSON on stdout, `task/current.json` populated | Determine workflow (below), start it |
| 2 | Nothing `OPEN` for `r-co` | Stop the loop |
| 3 | `task/current.json` already non-empty | Caller bug — finish/release the current item first, do not retry blindly |
| 1 | Unexpected error (including `BPM_WORKSPACE_ID` unset in `.env` — set it per `.env.example` before running loop mode) | Log, stop |

### release.py

```powershell
python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\release.py" task/current.json --status DONE
python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\release.py" task/current.json --status DEFERRED --reason "..."
python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\release.py" task/current.json --status DONE --close-github-issue
```

Reads `item_id` from `task/current.json` (you don't need to remember it), resolves
`workspace_id` from `.env` the same way `claim.py` does, verifies **this** workspace holds
the claim, marks the item `DONE` or `DEFERRED` in the DB, clears the GitHub claim label, and
empties `task/current.json` back to `{}`.

**This call is mandatory at the end of every WF-02/WF-03 run** — it belongs in the same
step that already exists (Step Final / DOC-UPDATER's git-merge step), not as a new step to
remember. `--close-github-issue` only makes sense for `--status DONE` on a `github_issue`
item, and mirrors what Step Final's "close the requirement's tracking issue" instruction in
`.claude/agents/doc-updater.md` already does — pass it there instead of calling `gh issue
close` separately.

| Exit | Meaning |
|---|---|
| 0 | Released |
| 4 | `task/current.json` empty/missing — nothing to release |
| 5 | Item is claimed by a **different** workspace — refused (this is not your claim to release) |
| 1 | Unexpected error |

### status.py — human-readable view, no DB browser needed

```powershell
python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\status.py"              # everything
python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\status.py" r-co         # one repo
python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\status.py" --claimed    # only CLAIMED, any repo
python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\status.py" --log r-co:GH-752   # full claim history for one item
```

Also visible directly on GitHub: any item currently `CLAIMED` carries a
`claimed-by-<workspace_id>` label on its issue.

### github_pull.py / requirements_pull.py — refresh the mirror

```powershell
python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\github_pull.py" r-co --exclude-label requirement
python "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\requirements_pull.py" r-co --stage "16"
```

Run at loop start (or whenever new issues/requirements might exist that aren't in the DB
yet) to pick up anything new. Never overwrites an existing item's status — a `CLAIMED` or
`DONE` row stays exactly as it is regardless of what GitHub or `requirements.yaml` currently
shows; only genuinely new `OPEN` items get added. `requirements_pull.py` refuses to run
against a repo that has an un-migrated legacy `handoffs/batch_queue.json` (see Migration
note below) — this is deliberate, not a bug.

---

## ORCH loop mode — step by step

```
LOOP START
│
├─ python <TaskManager>\scripts\github_pull.py r-co --exclude-label requirement
│  (cheap; refresh the mirror so newly-filed issues are claimable)
│
├─ python <TaskManager>\scripts\claim.py r-co task/current.json
│   (workspace_id auto-resolved from .env — nothing to compute here)
│   ├─ exit 2 → nothing OPEN → loop complete, stop
│   ├─ exit 3 → task/current.json already has an item → finish/release it first
│   ├─ exit 1 → unexpected error (incl. BPM_WORKSPACE_ID unset in .env) → log, stop
│   └─ exit 0 → item claimed, task/current.json populated
│
├─ Read task/current.json — this IS your task, do not re-derive it from anywhere else:
│   { "item_id": "r-co:GH-533", "source": "github_issue", "source_ref": "533",
│     "title": "...", "claimed_by": "r-co-1-loop", "claimed_at": "..." }
│   or, for a requirement batch:
│   { "item_id": "r-co:BATCH-<key>", "source": "requirement_batch",
│     "payload": {"stage_key": "16", "requirement_ids": ["PRM-02", ...], "batch_index": 0} }
│
├─ Determine workflow from `source`:
│   github_issue      → WF-03 (issue resolving)
│                        run_id = "WF03-GH<number>-<YYYYMMDD>"
│                        branch = feature/WF03-GH<number>-<YYYYMMDD>
│   requirement_batch  → WF-02 (requirement implementation)
│                        run_id = "WF02-batch-<N>-<YYYYMMDD>"
│                        branch = feature/WF02-batch-<N>-<YYYYMMDD>
│
├─ (github_issue only) python3 tools/gh_project_status.py <issue_number> --target in_progress
│   (moves the board card Todo -> In Progress; failure here is logged and never
│    blocks the run — see PROJECT_BOARD.md "Failure handling")
│
├─ Run the determined workflow's full step sequence to its own Step Final —
│   own feature branch, own PR, own squash-merge, exactly as WF-02/WF-03 already specify
│   in ORCHESTRATOR.md. Nothing about the workflow steps themselves changed in v3 — only
│   how the item was selected and how the claim is held/released did.
│
├─ Step Final / DOC-UPDATER calls, as part of its existing git-merge step:
│   python <TaskManager>\scripts\release.py task/current.json --status DONE [--close-github-issue]
│   (or --status DEFERRED --reason "..." if a scope decision was made instead of finishing;
│    workspace_id auto-resolved from .env here too)
│
└─ goto LOOP START
```

**One branch per item**, exactly as before — each claimed item gets its own feature branch
and PR, independent of every other item.

**No nesting** — if a run discovers a new incidental issue while working the claimed item,
`fn:enqueue-issue` still files it (ISS + GitHub issue) — `queue_add.py` is retired; the new
GitHub issue will simply appear as an `OPEN` `work_items` row the next time `github_pull.py`
runs, and get claimed in a later loop iteration. The current item's run continues to its own
Step Final unchanged.

---

## Why not GitHub itself as the lock

GitHub's issue list has no compare-and-swap either — an assignee field or a label can be
written by two API calls in quick succession with no guarantee about which one "wins," and
there's no way to make a read-then-write against it atomic without an external lock in
front of it. That's exactly what TaskManager is: GitHub stays the human-readable record of
*what work exists* and, via the claim label, *who currently has it* — but the actual
decision of who gets to claim next is made inside one SQLite transaction that GitHub's API
has no part in.

---

## Requirement batch loop mode (WF-02, `docs/requirements.yaml`)

No longer a separate loop with its own queue file — `requirements_pull.py` mirrors DRAFT
requirement batches into the same `work_items` table as GitHub issues, under
`source='requirement_batch'`, `item_id` of the form `r-co:BATCH-<key>`. `claim.py` and
`release.py` work identically regardless of `source` — the loop skeleton above already
covers both. Run `requirements_pull.py r-co --stage "<value>"` before looping if you want to
drain a specific backlog stage; omit `--stage` only for a backlog meant to interleave freely
(same caveat as the old `reqctl_batch_plan.py --stage` guidance — planning two
independently-ordered backlogs together produces unrelated-batch churn).

**Trigger phrases:** "start requirement loop", "drain requirements backlog", "process
requirement batches" — same as before, just routed through `claim.py`/`release.py` now
instead of `reqctl_batch_claim.py`/`reqctl_batch_release.py`.

---

## Stop flag

Unchanged — `handoffs/STOP_LOOP` still works as the shared kill switch, still checked at
the top of every `LOOP START` regardless of which source the loop is draining:

```powershell
New-Item -ItemType File -Force handoffs/STOP_LOOP   # stop after current item finishes
Remove-Item handoffs/STOP_LOOP                       # resume
```

---

## Migration note (one-time, per repo)

A repo with an existing `handoffs/global_queue.json` / `handoffs/batch_queue.json` from the
v2 protocol needs its live claims imported once, so TaskManager knows about in-flight work
instead of re-offering it as fresh `OPEN` items:

```powershell
python <TaskManager>\scripts\repo_add.py r-co tvolodi/R-Co --path "C:\Users\tvolo\dev\ai-dala\R-Co"
python <TaskManager>\scripts\migrate_batch_queue.py r-co
python <TaskManager>\scripts\github_pull.py r-co --exclude-label requirement
python <TaskManager>\scripts\requirements_pull.py r-co --stage "16"
```

Already done for `r-co` as of 2026-08-13 — the `PRM-02..05` batch that was `IN_PROGRESS`
under the v2 protocol carried its claim through intact (`claimed_by` preserved). This
section stays in the doc for the next repo TaskManager is wired into, or if this repo's DB
ever needs rebuilding from scratch.

`tools/gh_claim.py`, `tools/queue_release.py`, `tools/queue_add.py`,
`tools/reqctl_batch_claim.py`, `tools/reqctl_batch_release.py` are **retired** — calling
them now prints a pointer to this document and exits non-zero rather than silently writing
to the old (no-longer-authoritative) queue files. `handoffs/global_queue.json` and
`handoffs/batch_queue.json` are kept as read-only historical record; nothing writes to them
going forward.

---

## Invariants

- [ ] `task/current.json` is the only place any agent looks to determine current work — never `handoffs/global_queue.json`, `handoffs/batch_queue.json`, or a raw `gh issue list`
- [ ] Every claim goes through `claim.py`; every release goes through `release.py` — no agent edits `work.db` directly, and no agent decides a claim is "probably stale" and works the item anyway (see `docs/anti-patterns.md`, 2026-08-13 GH-752/GH-758 incident — a branch going quiet for hours is not evidence its claiming workspace is gone)
- [ ] `release.py` is called as part of the run's existing Step Final, not a separately-remembered step
- [ ] A GitHub issue's `claimed-by-<workspace_id>` label reflects the current DB state — if you see a label with no corresponding `CLAIMED` row (or vice versa), that is a sync bug worth filing, not something to work around by editing the label by hand
