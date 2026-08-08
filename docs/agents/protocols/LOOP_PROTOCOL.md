# LOOP Protocol — GitHub Issues as Source of Truth, Multi-Workspace Locking

**Version:** 2.1 · 2026-08-07
**Function:** `fn:loop-mode`
**Read by:** `ORCH` (owner); relevant to any workspace running an autonomous fix loop
**Tools:** `tools/gh_claim.py`, `tools/queue_release.py`, `tools/queue_add.py`, `tools/gh_project_status.py`
**See also:** `docs/agents/protocols/PROJECT_BOARD.md` — the project-board status
transitions this loop drives (`Todo → In Progress → Implemented → Validated by UAT
agent → Done`) so the maintainer can read pipeline state without opening agent chats.

---

## Purpose

The loop drains **open GitHub issues** at https://github.com/tvolodi/R-Co/issues — bugs,
BLOCKERs, and anything else that appears there — **except issues labeled `requirement`**.
Those 166 (as of 2026-08-07) are from-scratch, never-implemented requirements; this loop
runs WF-03 (Issue Resolving), which assumes the expected behaviour already exists — the
wrong workflow for them (`ORCHESTRATOR.md`: *"if the feature has not been specified yet →
WF-02"*). They are drained instead by the "Requirement batch loop mode" below, via
`docs/requirements.yaml` and WF-02. Before this exclusion existed, `gh_claim.py`'s
newest-number-first ordering meant a `requirement`-labeled issue could be — and, per a
dry-run check, was about to be — claimed ahead of ordinary bugs simply for having a higher
issue number, sending a from-scratch requirement through the wrong pipeline. See
`docs/anti-patterns.md`.

The loop runs until every non-`requirement` open GitHub issue is resolved (exit 2) or all
remaining ones are locked by other workspaces (exit 3).

`handoffs/global_queue.json` is a **lock registry only**. It records which workspace is
currently processing which GitHub issue so two workspaces never work the same item
simultaneously. It is NOT a backlog — the backlog is GitHub itself.

The two protocols are the two halves of one flow:

| | ISSUE_QUEUE.md (produce) | LOOP_PROTOCOL.md (consume) |
|---|---|---|
| Question answered | Where does a newly-found issue go? | How does a queued issue get fixed? |
| Actor | Any agent, mid-run | ORCH in loop mode |
| Action | File ISS + GitHub issue, `queue_add.py` | `gh_claim.py` → full WF-03 run → `queue_release.py` |
| Effect on current run | None — the run finishes its own job | Each claimed item is its own run, own branch, own PR |

> **Changed 2026-08-07 (v2).** Source of truth is now GitHub issues.
> `queue_claim.py` (backlog-based) is replaced by `gh_claim.py` (GitHub-based).
> `global_queue.json` is retained as the cross-workspace lock file only.

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

### gh_claim.py  ← USE THIS FOR LOOP MODE

```
python3 tools/gh_claim.py [<workspace_id>]
```

Queries GitHub for all open issues (https://github.com/tvolodi/R-Co/issues), takes the
**newest** one not currently locked, records the lock in `global_queue.json`, and prints
the item JSON to stdout.

**Source of truth: GitHub. Lock registry: `global_queue.json`.**

| Exit | Meaning | ORCH action |
|---|---|---|
| 0 | Item claimed; JSON on stdout | Start WF-03 for this item |
| 2 | No claimable issues (GitHub has 0 open, all are locked, or every remaining open issue is already resolved locally — see below) | Stop the loop |
| 3 | At least one open issue is locked by another workspace, and no unlocked/unresolved issue was found | Stop or retry after delay |
| 1 | Unexpected error (gh CLI failure, JSON error) | Log, stop |

**Already-resolved-but-still-open detection (2026-08-07).** Before claiming a candidate
issue, `gh_claim.py` checks whether any `docs/issues/ISS-*.json` already links this
GitHub issue via its `github_issue` field with `status` in `RESOLVED` /
`RESOLVED-WITH-INFRA-BLOCK`. If so, it skips the issue (printing a note to stderr) rather
than claiming it. This exists because closing a GitHub issue and merging its fix are two
separate actions with nothing enforcing they happen together — an issue can be fixed and
merged to `main` by any workspace while staying open on GitHub, and the next
`gh_claim.py` call (from any workspace, including the one that shipped the fix) would
otherwise claim and re-work it. This happened four times in one session on 2026-08-07
(GH-545, GH-548, GH-532, GH-366/GH-364) before being caught and fixed — see
`docs/anti-patterns.md`. ISSUE-FIXER's Step 0.5 registry lookup already catches this once
a run has started; this check catches it before a branch is even created, and matters
more for a design/implementation run that can otherwise drift past the "already resolved"
signal instead of stopping on it (observed on GH-548: the design step proceeded and
failed its own validation gate before anyone noticed the issue was already fixed).
**This check does not replace closing the GitHub issue** — the fix's own Step Final /
DOC-UPDATER should still close it; this is a safety net for when that didn't happen.

`<workspace_id>` defaults to `<hostname>-<pid>` when omitted — note the `-<pid>` makes this
actually unique per *process*, but not stable across a workspace's *runs* (a new pid each time
defeats "logs clearly identify which workspace did the work" across a history of loop runs).
For loop mode, pass an explicit stable value instead: `BPM_WORKSPACE_ID` from `.env` (see
"ORCH loop mode — step by step" below). Do **not** use `$env:COMPUTERNAME` alone or
`$env:COMPUTERNAME + "-loop"` — every parallel checkout on the same host shares `COMPUTERNAME`,
so that pattern collides across workspaces and lets two of them claim the same issue under an
identical lock key (see `docs/anti-patterns.md`, 2026-08-07 GH-542 incident).

The claimed item JSON includes `issue_id` in the form `GH-<number>` (e.g. `GH-533`).
Pass this as the `<issue_id>` argument to `queue_release.py`.

### queue_release.py

```
python3 tools/queue_release.py <issue_id> <workspace_id> [--status RESOLVED|DEFERRED]
python3 tools/queue_release.py <issue_id> <workspace_id> --deferred-reason "<text>"
```

Clears the item lock in `global_queue.json` and sets the final status. Must be called
after WF-03 completes (whether it succeeded or the issue was deferred). `<workspace_id>`
must match the one used in `gh_claim.py`. For GitHub-sourced items, `<issue_id>` is
`GH-<number>` (e.g. `GH-533`).

### queue_add.py

```
python3 tools/queue_add.py <issue_id> --severity BLOCKER|MAJOR|MINOR \
    [--title "<text>"] [--github-issue "<url>"]
```

Adds a new item to the global queue. Exit 4 = duplicate (already present).

Every item added here must already have a corresponding `docs/issues/ISS-NNNN.json`
and a GitHub issue filed — `queue_add.py` does not create them.

### queue_heartbeat.py

```
python3 tools/queue_heartbeat.py <issue_id> <workspace_id>
```

Refreshes `lock.heartbeat_at` (leaving `lock.locked_at` untouched — that field keeps
its original "claim started" audit meaning) for an item this workspace still owns.
Call periodically during a long WF-03 run — after each major step transition is a
reasonable cadence — and push immediately after each call, same discipline as a claim.
`gh_claim.py`'s staleness check (`TTL_MINUTES` = 120) considers `heartbeat_at` when
present, falling back to `locked_at` if the item was never heartbeated, so a workspace
sending regular heartbeats keeps its claim alive past 120 minutes of genuine ongoing
work while one that has actually stalled or died still ages out normally. Exit 1 if the
item isn't found, isn't locked by `<workspace_id>`, or isn't `IN_PROGRESS`.

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

ORCH enters loop mode when the user says "start loop", "process issues", "run autonomous loop",
"drain GitHub issues", or equivalent. Establish a stable `<workspace_id>` once at loop start —
**read `BPM_WORKSPACE_ID` from `.env`, do not derive it from `$env:COMPUTERNAME` alone.**
Two checkouts of this repo on the same host share the same `COMPUTERNAME`, so a
`$env:COMPUTERNAME`-derived value collides across parallel workspaces and lets both claim the
same GitHub issue under the identical lock key — this is exactly what happened on 2026-08-07
for GH-542 (see `docs/anti-patterns.md`). `BPM_WORKSPACE_ID` is per-checkout, set by hand in each
workspace's own `.env` (see `.env.example`), so it is guaranteed distinct:

```powershell
$workspace_id = (Get-Content .env | Select-String '^BPM_WORKSPACE_ID=').ToString().Split('=')[1]
if (-not $workspace_id) {
    Write-Error "BPM_WORKSPACE_ID not set in .env — set it before running loop mode (see .env.example)."
    exit 1
}
```

If `.env` has no `BPM_WORKSPACE_ID`, do not fall back to a `$env:COMPUTERNAME`-derived value —
that silently reintroduces the collision. Stop and ask the operator to set it.

```
LOOP START
│
├─ Check STOP_LOOP flag
│   Test-Path handoffs/STOP_LOOP  →  if present: exit loop gracefully
│
├─ PULL MAIN BEFORE CLAIMING — gh_claim.py reads handoffs/global_queue.json from the
│  LOCAL WORKING TREE ONLY; it never fetches or pulls. A workspace with a stale local
│  checkout can claim an issue another workspace already locked and pushed to
│  origin/main minutes ago, simply because its local copy predates that push. The
│  end-of-claim push-rejection check (below) catches this eventually, but only after
│  wasting the time between a stale claim and the rejected push — pulling first avoids
│  the wasted work rather than merely detecting it after the fact:
│   git checkout main
│   git pull --ff-only origin main
│   If this fails (local main has diverged / uncommitted changes): resolve before
│   proceeding — do not claim against a working tree that isn't known-fresh.
│
├─ python3 tools/gh_claim.py <workspace_id>
│   ├─ exit 2 → GitHub has 0 open issues  →  loop complete, stop
│   ├─ exit 3 → all open issues locked    →  stop (another workspace active)
│   ├─ exit 1 → unexpected error          →  log, stop
│   └─ exit 0 → item claimed, JSON on stdout
│
├─ PUSH THE CLAIM TO MAIN IMMEDIATELY — before any WF-03 work starts, INCLUDING Step 00
│  git-setup (creating the feature branch). This step remains mandatory even after
│  pulling first above: the pull only closes the window before gh_claim.py runs, not a
│  second race against another workspace claiming between your pull and your push.
│  Treat this as defense-in-depth, not redundant:
│   git add handoffs/global_queue.json
│   git commit -m "queue: claim GH-<number> for <workspace_id>"
│   git fetch origin main && git rebase origin/main   ← resolve any interleaving here
│   git push origin main
│   If the push is rejected (another workspace pushed a claim first): fetch, inspect
│   whether THIS issue is now locked by someone else. If yes, your claim lost the race —
│   release your local lock state, re-run gh_claim.py for a different issue, do not
│   proceed with this one. This step is what makes the lock visible to other
│   workspaces; gh_claim.py itself only writes the LOCAL file and never pushes —
│   skipping this step is what caused two workspaces to both claim GH-542 on
│   2026-08-07 (see docs/anti-patterns.md).
│
├─ VERIFY THE PUSH LANDED — do not proceed to Step 00 on the strength of "git push
│  exited 0" alone. A local push can report success to the calling process while a
│  slow agent turn, a subsequent unrelated step, or simply time pressure delays the
│  actual network completion being visible to a concurrent reader — or the workspace
│  can simply move on to git-setup before confirming, which is what actually happened
│  on 2026-08-07 (GH-518: workspace r-co-1-loop committed its claim, pushed its OWN
│  feature branch, and began Step 00 work, all without the claim commit having reached
│  origin/main — a second workspace's gh_claim.py, reading a main that still showed
│  GH-518 unclaimed, was handed the same issue and had to detect the collision itself
│  via a manual branch check, costing several minutes neither workspace's protocol
│  compliance actually required). Confirm explicitly:
│   git fetch origin main
│   git log --oneline -1 origin/main   ← must show YOUR claim commit's message/hash
│   If it does not: your push has not actually landed yet (or was superseded — check
│   for a rejection first). Do not proceed to Step 00 until this check passes. Retry
│   the push-then-verify pair (bounded — a handful of attempts with a short pause
│   between) rather than looping indefinitely; if it still hasn't landed after several
│   tries, treat it as an unexpected error (log, stop) rather than guessing.
│
├─ HEARTBEAT DURING LONG RUNS — a lock older than TTL_MINUTES (120) becomes reclaimable
│  by another workspace's gh_claim.py even if the original claimant is still actively
│  working (this happened 2026-08-07: GH-526's lock, claimed by r-co-1-loop, was
│  reclaimed by a second workspace after 120+ minutes while r-co-1-loop was still
│  committing to its branch every few minutes — no double-run resulted only because
│  the original run finished and merged moments after the reclaim attempt). Call
│  periodically during a WF-03 run for the claimed item — after each major step
│  transition is a reasonable cadence, no need to call more often than every few
│  minutes:
│   python3 tools/queue_heartbeat.py GH-<number> <workspace_id>
│   git add handoffs/global_queue.json
│   git commit -m "queue: heartbeat GH-<number> for <workspace_id>"
│   git fetch origin main && git rebase origin/main
│   git push origin main
│  An un-pushed heartbeat provides no protection — the push is not optional bookkeeping,
│  it is the mechanism. gh_claim.py checks lock.heartbeat_at (falling back to
│  lock.locked_at if no heartbeat was ever sent) when deciding staleness.
│
├─ Parse claimed item:
│   {
│     "issue_id":     "GH-533",       ← pass to queue_release.py
│     "issue_number": 533,
│     "github_issue": "https://github.com/tvolodi/R-Co/issues/533",
│     "title":        "...",
│     "severity":     "MAJOR",
│     ...
│   }
│
├─ Determine workflow:
│   Every GitHub issue → WF-03 (issue resolving)
│   run_id = "WF03-GH<number>-<YYYYMMDD>"   e.g. "WF03-GH533-20260807"
│
├─ python3 tools/gh_project_status.py <issue_number> --target in_progress
│   (moves the board card Todo -> In Progress; see PROJECT_BOARD.md.
│    a failure here is logged and never blocks the run — see that doc's
│    "Failure handling" section)
│
├─ Run WF-03:  Step 00 → 0.5 → 1 → 2 → 2b → 3 → [4/4b] → 5 → [6] → 7 → Final
│   (Step Final also moves the board to Implemented/Done — see
│    CLAUDE.md "GitHub Branch Management (MANDATORY)" and PROJECT_BOARD.md)
│   Own feature branch: feature/WF03-GH<number>-<YYYYMMDD>
│   Own PR, own squash-merge
│
├─ After WF-03 Step Final returns PASS (or deliberate deferral decision):
│
├─ python3 tools/queue_release.py GH-<number> <workspace_id> --status RESOLVED
│   (or --status DEFERRED --deferred-reason "..." if scope decision made)
│
├─ Commit lock registry + audit log to main:
│   git add handoffs/global_queue.json handoffs/orchestrator.log
│   git commit -m "queue: resolve GH-<number>"
│   git push origin main
│
├─ Append to orchestrator.log:
│   "<ts> | LOOP_ITEM_DONE | WF03-GH<number>-<date> | <workspace_id> | RESOLVED (PR #NNN)"
│
└─ goto LOOP START
```

**One branch per item** — unlike the per-run queue protocol, each issue in the global
queue gets its own full WF-03 run with its own feature branch and PR. This keeps branches
small, reviewable, and mergeable independently.

**No nesting** — if WF-03 discovers a new incidental issue while fixing the claimed item,
`fn:enqueue-issue` adds it to the global queue via `queue_add.py`. The current item's WF-03
continues to its own Step Final unchanged; the new item is processed in a later loop
iteration (by this or another workspace). An iteration never grows to include a second
issue.

---

## Requirement batch loop mode (WF-02, `docs/requirements.yaml`)

**Source of truth: `docs/requirements.yaml` (status=`DRAFT` requirements). Lock registry:
`handoffs/batch_queue.json`.** This is a second, parallel loop — distinct from the
GitHub-issue loop above — for draining a backlog of specified-but-unimplemented
requirements via WF-02 (Requirement Implementation), not WF-03 (Issue Resolving).

**Why a separate queue file, not `global_queue.json`:** a requirement batch has no GitHub
issue to key off, and WF-02's git wrapping differs from WF-03's (own branch naming:
`feature/WF02-batch-<N>-<date>`, no per-issue PR). The locking *discipline* is identical —
`tools/_queue_sync.py` (fetch-fresh-before-write), the same-machine file mutex, and the
mandatory immediate-push-after-claim rule all apply exactly as documented above for
`global_queue.json`, just pointed at `handoffs/batch_queue.json`.

**Trigger phrases:** "start requirement loop", "drain requirements backlog", "process
requirement batches", or equivalent — distinct from "start loop" (GitHub issues) so an
operator can run either independently, or both (GitHub issues first, by convention, since
bugs blocking other work should usually clear before new features build on top of a
possibly-broken base — but nothing enforces that ordering; it is an operator choice).

**Multiple independently-authored backlogs must be planned separately, via `--stage`.**
`docs/requirements.yaml` can hold several `DRAFT` backlogs migrated from different source
documents, each with its own internal ordering logic — e.g. the 92-requirement backlog
(implicit ordering derived from `**Extends:**` markers added during migration) and the
20-requirement `BRW-*` "borrowing" set (`stage: "BRW — Borrowing from ASCOA-GO"`, ordering
transcribed directly from `docs/addon-2/03-implementation-order.md`'s hand-authored Track
A / Track M plan). Planning them together (no `--stage` filter) produces a single merged
batch stream where unrelated requirements from different backlogs land in the same batch
— confirmed when this was built: without `--stage`, `BRW-*` Track-A engine work
interleaved with unrelated `CAC-UI`/`CMP-UI` frontend work from the other backlog, exactly
the unrelated-batch churn `ORCHESTRATOR.md`'s WF-02 rules exist to prevent. Always pass
`--stage "<exact stage value>"` to `reqctl_batch_plan.py`, `reqctl_batch_claim.py`, and
`reqctl_batch_release.py` together when draining a backlog that has one; omit it only for
a backlog meant to interleave freely with everything else.

**Tools reference:**

```
python3 tools/reqctl_batch_plan.py [--status DRAFT] [--stage "<stage value>"] [--json]
```
Computes the ordered batch list from `docs/requirements.yaml`, optionally restricted to
one `stage` value (see above). Topological order from each requirement's
`**Extends:** <ID>` marker (a genuine directional dependency — unlike `**See:**`, which is
symmetric cross-referencing with no ordering meaning in how this repo writes it; verified
when this was built that the `See:` graph among the initial 92-requirement backlog
migration had 34 mutual-reference cycles while the `Extends:` graph was a clean DAG),
workflow-clustered (keeps one feature's requirements adjacent), capped at 4 per batch
(`ORCHESTRATOR.md`'s WF-02 hard limit), and a requirement never shares a batch with the
thing it `Extends` even if the dependency graph says it's technically "ready" —
CODE-DESIGNER needs the extended requirement's design settled first.

```
python3 tools/reqctl_batch_claim.py <workspace_id> [--stage "<stage value>"]
```
Claims the next unclaimed, non-`DONE` batch within the given stage (or across all stages
if omitted). Exit 0 = claimed (JSON on stdout), exit 2 = nothing left to claim, exit 3 =
all unclaimed batches locked by other workspaces, exit 1 = error. Same exit-code semantics
as `gh_claim.py`. Batches from different `--stage` values are locked independently — they
share `handoffs/batch_queue.json` but are keyed by `(stage_key, batch_index)`, never by a
bare index, so claiming batch 0 of one backlog never collides with batch 0 of another.

```
python3 tools/reqctl_batch_release.py <batch_index> <workspace_id> [--run-id RUN_ID] [--stage "<stage value>"]
```
Marks a claimed batch `DONE`. Same lock-ownership check as `queue_release.py` (refuses to
release a batch locked by a different `workspace_id`).

**Loop skeleton:**

```
LOOP START
│
├─ Check STOP_LOOP flag (same flag as the GitHub-issue loop — shared kill switch)
│
├─ PULL MAIN BEFORE CLAIMING (same rationale as the GitHub-issue loop):
│   git checkout main && git pull --ff-only origin main
│
├─ python3 tools/reqctl_batch_claim.py <workspace_id>
│   ├─ exit 2 → nothing left to batch → loop complete, stop
│   ├─ exit 3 → all unclaimed batches locked → stop or retry after delay
│   ├─ exit 1 → unexpected error → log, stop
│   └─ exit 0 → batch claimed, JSON on stdout (requirement_ids list)
│
├─ PUSH THE CLAIM TO MAIN IMMEDIATELY — before any WF-02 work starts (mirrors the
│  GitHub-issue loop's mandatory immediate-push step exactly):
│   git add handoffs/batch_queue.json
│   git commit -m "batch: claim batch <N> for <workspace_id>"
│   git fetch origin main && git rebase origin/main
│   git push origin main
│   If rejected: fetch, check whether this batch is now locked by someone else;
│   if so, stand down and re-run reqctl_batch_claim.py.
│
├─ Run WF-02 for requirement_ids (Step 00 git-setup through Step 06 doc-updater,
│  Step Final git-merge) — own branch feature/WF02-batch-<N>-<YYYYMMDD>, own PR,
│  own squash-merge, per ORCHESTRATOR.md's WF-02 pipeline table
│
├─ python3 tools/reqctl_batch_release.py <N> <workspace_id> --run-id WF02-batch-<N>-<date>
│
├─ Commit + push handoffs/batch_queue.json + handoffs/orchestrator.log to main
│
└─ goto LOOP START
```

**No cross-loop interference:** a workspace running the GitHub-issue loop and a workspace
running the requirement-batch loop can run simultaneously without racing each other —
they read/write different queue files (`global_queue.json` vs `batch_queue.json`) and
target different requirement/issue spaces entirely.

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
- [ ] `gh_claim.py` is the ONLY writer for the `lock` field — no agent sets it directly
- [ ] `queue_release.py` is the ONLY writer that clears the `lock` field
- [ ] `queue_heartbeat.py` is the ONLY writer for `lock.heartbeat_at` — no agent sets it directly
- [ ] `handoffs/global_queue.json` is committed AND PUSHED to `main` immediately after every claim — never deferred to end-of-run (see "ORCH loop mode — step by step" above; a deferred push is what let two workspaces both claim GH-542 on 2026-08-07, see `docs/anti-patterns.md`)
- [ ] `handoffs/global_queue.json` is committed to `main` after every release
- [ ] `handoffs/global_queue.json` is committed AND PUSHED to `main` after every heartbeat, same discipline as a claim — an un-pushed heartbeat protects nothing
- [ ] `handoffs/global_queue.lock` is NEVER committed to git (transient mutex file)
- [ ] **Before Step 00 (git-setup), not just before "implementation work"**: re-fetch `origin/main` and confirm `git log --oneline -1 origin/main` actually shows this workspace's claim commit — not merely that the earlier `git push` command exited 0. A push that reports success locally is not the same as a push whose result a concurrent reader can see; verify by reading the ref back. A rejected/raced/not-yet-landed push means stand down or retry, not proceed to branch creation (see "VERIFY THE PUSH LANDED" above; skipping this exact check is what let workspace r-co-1-loop start Step 00 on GH-518 before its claim was visible on `main`, on 2026-08-07 — no double-run resulted only because the second workspace caught the collision manually via a branch check, see `docs/anti-patterns.md`)
- [ ] For any WF-03 run expected to run longer than ~30-60 minutes, a heartbeat is sent at least once every ~30-60 minutes (well inside the 120-minute TTL) so a still-active claim is never seen as stale by another workspace's `gh_claim.py`
