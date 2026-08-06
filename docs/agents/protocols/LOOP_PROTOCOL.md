# LOOP Protocol — Global Issue Queue with Multi-Workspace Locking

**Version:** 1.0 · 2026-08-06
**Function:** `fn:loop-mode`
**Read by:** `ORCH` (owner); relevant to any workspace running an autonomous fix loop
**Tools:** `tools/queue_claim.py`, `tools/queue_release.py`, `tools/queue_add.py`

---

## Purpose

The ISSUE_QUEUE protocol (see `ISSUE_QUEUE.md`) drains issues *within a single workflow
run* — all found issues are fixed on one branch, one PR. This protocol addresses a
different scenario: **two or more VS Code workspaces working autonomously**, each picking
issues from a shared backlog, with no duplication of effort.

Key differences from the per-run queue:

| | Per-run queue (ISSUE_QUEUE.md) | Global queue (this protocol) |
|---|---|---|
| Scope | One workflow run, one branch | Cross-run, cross-workspace |
| Item count per session | All queued items drained | **One item at a time** |
| Lock mechanism | Git branch ownership | File mutex + item-level TTL lock |
| Stop condition | Queue empty after drain | Queue empty OR `STOP_LOOP` flag present |
| Branch lifecycle | One branch for all items in run | **One branch per item** |

---

## Queue file

`handoffs/global_queue.json` — committed to git; modified by the tools below.

```json
{
  "version": "1",
  "items": [
    {
      "issue_id":        "ISS-0042",
      "github_issue":    "https://github.com/tvolodi/R-Co/issues/42",
      "title":           "Short description",
      "severity":        "MAJOR",
      "status":          "QUEUED",
      "lock":            null,
      "added_at":        "2026-08-06T10:00:00Z",
      "started_at":      null,
      "completed_at":    null,
      "run_id":          null,
      "deferred_reason": null
    }
  ]
}
```

`status` transitions:

```
QUEUED → IN_PROGRESS → RESOLVED
                     → DEFERRED  (scope/severity decision; stays in queue as a record)
```

`lock` is set when `status` is `IN_PROGRESS` and cleared when `RESOLVED` or `DEFERRED`:

```json
{
  "workspace_id": "DESKTOP-XYZ-12345",
  "locked_at":    "2026-08-06T10:05:00Z"
}
```

---

## Locking mechanism

Two layers protect concurrent access:

1. **File mutex** (`handoffs/global_queue.lock`) — atomically created via `O_CREAT|O_EXCL`
   on NTFS. Held only for the duration of a JSON read-modify-write (milliseconds). A mutex
   whose `at` timestamp is older than 120 minutes is considered stale and may be reclaimed.

2. **Item lock** (inside the JSON) — records which workspace owns the item for the duration
   of a full WF-03 run (potentially hours). An item lock older than **120 minutes** is
   considered stale and may be reclaimed by another workspace.

If a workspace crashes mid-fix, its item lock expires after 120 minutes and the next
workspace that calls `queue_claim.py` will reclaim the item automatically.

---

## Tools reference

### queue_claim.py

```
python3 tools/queue_claim.py [<workspace_id>]
```

Atomically claims the first available item and prints its JSON to stdout.

| Exit | Meaning | ORCH action |
|---|---|---|
| 0 | Item claimed; JSON on stdout | Start WF-03 for this item |
| 2 | Queue exhausted | Stop the loop |
| 3 | All items locked by other workspaces | Stop or retry after delay |
| 1 | Unexpected error | Log, stop |

`<workspace_id>` defaults to `<hostname>-<pid>` when omitted. Use a stable value
(e.g. machine name) if you want logs to clearly identify which workspace did the work.

### queue_release.py

```
python3 tools/queue_release.py <issue_id> <workspace_id> [--status RESOLVED|DEFERRED]
python3 tools/queue_release.py <issue_id> <workspace_id> --deferred-reason "<text>"
```

Clears the item lock and sets the final status. Must be called after WF-03 completes
(whether it succeeded or the issue was deferred). The `workspace_id` must match the one
used in `queue_claim.py`.

### queue_add.py

```
python3 tools/queue_add.py <issue_id> --severity BLOCKER|MAJOR|MINOR \
    [--title "<text>"] [--github-issue "<url>"]
```

Adds a new item to the global queue. Exit 4 = duplicate (already present).

Every item added here must already have a corresponding `docs/issues/ISS-NNNN.json`
and a GitHub issue filed — `queue_add.py` does not create them.

---

## Stop flag

Create the file `handoffs/STOP_LOOP` (any content) to signal all running loops to stop
after completing their current item. Delete it to allow loops to start again.

```powershell
# Stop all loops gracefully (current item finishes, then loop exits):
New-Item -ItemType File -Force handoffs/STOP_LOOP

# Resume:
Remove-Item handoffs/STOP_LOOP
```

---

## ORCH loop mode — step by step

ORCH enters loop mode when the user says "start loop", "run autonomous loop",
"process the queue", or equivalent. A stable `<workspace_id>` should be established
once at loop start (e.g. `$env:COMPUTERNAME + "-loop"`).

```
LOOP START
│
├─ Check STOP_LOOP flag → if present: exit loop
│
├─ python3 tools/queue_claim.py <workspace_id>
│   ├─ exit 2 (empty)  → exit loop
│   ├─ exit 3 (locked) → exit loop (another workspace is active)
│   └─ exit 0          → proceed with claimed item JSON
│
├─ Read claimed item: { issue_id, severity, github_issue, ... }
│
├─ Run WF-03 (Steps 0.5 → 1 → 2 → 2b → 3 → [4/4b] → 5 → 6 → 7)
│   ├─ Each step is its OWN git-setup + git-merge (one branch per item)
│   │   Use run_id = "WF03-<issue_id>-<YYYYMMDD>"
│   └─ On WF-03 PASS or deliberate deferral:
│
├─ python3 tools/queue_release.py <issue_id> <workspace_id> [--status RESOLVED|DEFERRED]
│
├─ Commit global_queue.json + orchestrator.log update to main
│   git add handoffs/global_queue.json handoffs/orchestrator.log
│   git commit -m "queue: resolve <issue_id>"
│   git push origin main
│
├─ Append to orchestrator.log:
│   "<ts> | LOOP_ITEM_DONE | <issue_id> | <workspace_id> | RESOLVED"
│
└─ goto LOOP START
```

**One branch per item** — unlike the per-run queue protocol, each issue in the global
queue gets its own full WF-03 run with its own feature branch and PR. This keeps branches
small, reviewable, and mergeable independently.

**No nesting** — if WF-03 discovers a new incidental issue while fixing the claimed item,
`fn:enqueue-issue` adds it to the *global* queue (via `queue_add.py`) rather than the
per-run queue. The current item's WF-03 continues; the new item is processed in the
next loop iteration (by this or another workspace).

---

## Multi-workspace interaction diagram

```
Workspace A                            Workspace B
    │                                      │
    ├─ queue_claim.py → claims ISS-0042    │
    │    lock: {ws-A, 10:00}               │
    │                                      ├─ queue_claim.py → claims ISS-0043
    │                                      │    lock: {ws-B, 10:01}
    │                                      │
    ├─ WF-03 for ISS-0042 (running)        ├─ WF-03 for ISS-0043 (running)
    │  (branch: feature/WF03-ISS-0042-…)  │  (branch: feature/WF03-ISS-0043-…)
    │                                      │
    ├─ queue_release.py ISS-0042 ws-A      │
    ├─ git push → ISS-0042 → RESOLVED      │
    │                                      ├─ queue_release.py ISS-0043 ws-B
    │                                      ├─ git push → ISS-0043 → RESOLVED
    │                                      │
    ├─ queue_claim.py → claims ISS-0044    │
    │  (ISS-0043 already RESOLVED, skip)   ├─ queue_claim.py → exit 2 (empty)
    │                                      └─ Workspace B loop stops
    ...
```

---

## Adding issues to the global queue

ORCH adds an issue to the global queue whenever it decides an issue should be processed
autonomously (rather than interactively or inline). The standard flow:

```python
# 1. Register the issue locally
#    → docs/issues/ISS-NNNN.json  (fn:register-issue)

# 2. File on GitHub (mandatory — see CLAUDE.md "No Issue Left Local-Only")
#    → gh issue create ...

# 3. Add to global queue
import subprocess
subprocess.run([
    "python3", "tools/queue_add.py", "ISS-NNNN",
    "--severity", "MAJOR",
    "--title", "Short description",
    "--github-issue", "https://github.com/tvolodi/R-Co/issues/NNN",
], check=True)

# 4. Commit global_queue.json to main
#    git add handoffs/global_queue.json
#    git commit -m "queue: enqueue ISS-NNNN"
#    git push origin main
```

---

## Invariants

- [ ] Every item in the global queue has a corresponding `docs/issues/ISS-NNNN.json`
- [ ] Every item in the global queue has a corresponding GitHub issue (`github_issue` field non-empty)
- [ ] `queue_claim.py` is the ONLY writer for the `lock` field — no agent sets it directly
- [ ] `queue_release.py` is the ONLY writer that clears the `lock` field
- [ ] `handoffs/global_queue.json` is committed to `main` after every add/release
- [ ] `handoffs/global_queue.lock` is NEVER committed to git (transient mutex file)
