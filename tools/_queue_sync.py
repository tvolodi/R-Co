"""_queue_sync.py — shared fetch-fresh-before-write helper for the global
issue-lock queue (handoffs/global_queue.json).

Why this exists
----------------
gh_claim.py, queue_release.py, and queue_add.py each read
handoffs/global_queue.json from the LOCAL WORKING TREE, mutate it in memory,
and write the WHOLE file back. The existing file mutex
(handoffs/global_queue.lock) only serializes two processes on the SAME
machine writing to the SAME file — it does nothing when two independent git
checkouts (e.g. two parallel workspaces on one host, per this repo's
documented parallel-workspace setup) each hold their own on-disk copy.

A workspace whose local copy predates another workspace's already-pushed
change can: (a) claim an issue the other workspace already locked and
pushed, because its local copy doesn't show the lock yet; or worse,
(b) release/add an item and, in writing the WHOLE file back from a stale
in-memory copy, silently REVERT the other workspace's already-pushed changes
to every OTHER item in the file. This was discovered during a deliberate
concurrent-workspace stress test on 2026-08-07 (see docs/anti-patterns.md).

What this module does
----------------------
sync_queue_from_origin() fetches origin/main (network only — never touches
the working tree, branch, or any other file) and returns the queue dict as
it exists on origin/main RIGHT NOW, via `git show origin/main:<path>`. This
works regardless of what branch is currently checked out or what
uncommitted changes exist elsewhere in the tree, which matters because
queue_release.py and queue_add.py are called mid-run, from a feature
branch, with real uncommitted WF-03 artifacts present — a blind `git pull`
there would be wrong (wrong branch, would conflict with in-progress work).
`git fetch` + `git show <ref>:<path>` touches neither.

Callers should sync INSIDE their existing file-mutex critical section,
immediately before mutating, so the in-memory copy they write back is as
fresh as this process can make it. This narrows the remaining race to "two
workspaces both fetch fresh and then race to push" — which the mandatory
immediate-push step (LOOP_PROTOCOL.md) already resolves via git's own
non-fast-forward push rejection.
"""

from __future__ import annotations

import json
import subprocess

QUEUE_PATH_IN_REPO = "handoffs/global_queue.json"


def sync_queue_from_origin(local_fallback: dict, queue_path: str = QUEUE_PATH_IN_REPO) -> dict:
    """Return the queue as it exists on origin/main, fetching first.

    `queue_path` defaults to the GitHub-issue lock file
    (handoffs/global_queue.json) but any repo-relative JSON queue file using
    the same read-mutate-write-whole-file pattern can pass its own path —
    e.g. handoffs/batch_queue.json for WF-02 requirement-batch locking
    (tools/reqctl_batch_claim.py). The race this guards against is generic
    to "a JSON file two independent checkouts each hold a stale copy of,"
    not specific to the GitHub-issue queue.

    Falls back to `local_fallback` (the caller's already-read local copy) if
    the fetch or remote read fails for any reason (offline, no remote
    configured, network hiccup) — a queue tool must remain usable without
    network access, just with the pre-existing (weaker) staleness guarantee
    in that case. Every fallback path is logged to stderr so a silent
    same-machine-only guarantee is never mistaken for the cross-workspace one.
    """
    import sys

    try:
        subprocess.run(
            ["git", "fetch", "origin", "main"],
            capture_output=True,
            timeout=30,
            check=True,
        )
    except Exception as exc:
        print(f"[_queue_sync] git fetch origin main failed ({exc}); using local copy — staleness guarantee weakened to same-machine only", file=sys.stderr)
        return local_fallback

    try:
        proc = subprocess.run(
            ["git", "show", f"origin/main:{queue_path}"],
            capture_output=True,
            timeout=15,
            check=True,
        )
        return json.loads(proc.stdout.decode("utf-8-sig"))
    except Exception as exc:
        print(f"[_queue_sync] could not read {queue_path} from origin/main ({exc}); using local copy (may be genuinely new/uncommitted) — staleness guarantee weakened to same-machine only", file=sys.stderr)
        return local_fallback
