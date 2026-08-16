# r-co TaskManager frequently has zero OPEN items — idle state

## Symptom
At session start, `task/current.json` is `{}` AND `python
C:\Users\tvolo\dev\ai-dala\TaskManager\scripts\claim.py r-co task/current.json`
returns `nothing OPEN to claim for repo_id=r-co` (exit 1). This is not a
script bug — it is the genuine state of the queue.

## What I observed on 2026-08-16 (r-co-1-loop)
- `task/current.json` = `{}`
- Direct DB query: `CLAIMED: 1, DEFERRED: 40, DONE: 20, OPEN: 0`
- The one CLAIMED item (`r-co:BATCH-4c5bcf433769`, PRM-02..05) is owned by
  `r-co-2-loop` (different workspace) — not mine.
- Working tree clean, no stash relevant to current work, no in-flight WIP.

## What the user actually sees
When the user says "Resolve the next issue" and the queue has no OPEN items,
the truthful answer is "nothing to claim right now." Do NOT:
- Steal another workspace's CLAIMED item.
- Pick something out of `handoffs/global_queue.json` directly
  (per LOOP_PROTOCOL, that file is no longer the source of truth).
- Pick something out of `docs/issues/*.json` directly
  (per `core-directives.md`, that file is a pipeline working file, not a
  source-of-truth for the user).
- Fabricate work to look productive.

## What to do instead
1. Report state truthfully: nothing OPEN, what is CLAIMED by which workspace,
   what was last DONE.
2. Suggest the operator either (a) trigger WF-02 to draft a new batch /
   open more work items, or (b) switch to the other workspace where work is
   queued.
3. Verify with both the canonical script AND a direct DB count
   (`SELECT status, COUNT(*) FROM work_items GROUP BY status`) so the
   "nothing to do" claim is sourced and not guessed.

## Why this happens
The TaskManager only has `OPEN` items when an upstream workflow (WF-01,
WF-02 batch creation, or a manual `requirements_pull.py` / `github_pull.py`)
has materialised a batch and pushed it into the work_items table. Between
batch completion (DONE) and the next batch creation, the queue is empty by
design — `claim.py` is supposed to refuse to return anything stale or
someone else's claim.

## Workspace-id drift cross-check
If `claim.py` says "nothing OPEN" but direct DB query shows OPEN > 0, the
likely cause is `bpm-taskmanager-local-path-drift.md` (DB `repos.local_path`
points at a sibling workspace whose `.env` defines a different
`BPM_WORKSPACE_ID`). Re-run `claim.py` with `--workspace-id <my-workspace>`
to bypass auto-resolution.