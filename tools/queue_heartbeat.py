#!/usr/bin/env python3
"""
queue_heartbeat.py — refresh the lock's locked_at timestamp for an item this
workspace still owns, so a long-running WF-03 pass doesn't cross gh_claim.py's
TTL_MINUTES (120) staleness window while genuinely still active.

Why this exists
----------------
gh_claim.py treats any lock older than TTL_MINUTES as reclaimable by another
workspace, regardless of whether the original claimant is still working. On
2026-08-07, workspace r-co-1-loop was still actively committing to
feature/WF03-GH526-20260807 (last commit ~8 minutes prior) when a second
workspace's gh_claim.py call reclaimed GH-526 — correct per the TTL rule as
written, but wrong in effect, since the original claimant had not abandoned
the item. The run finished and merged moments later, so no double-run
actually occurred, but nothing in the protocol prevented one. See
docs/anti-patterns.md.

The lock's locked_at is also used as the item's audit "work started" time in
some reports — refreshing it as a heartbeat would corrupt that meaning if
done unconditionally. This tool therefore SPLITS the two: `locked_at` is
left untouched (audit meaning preserved); a new `lock.heartbeat_at` field is
added/updated instead. gh_claim.py's staleness check now considers a lock
expired only if `heartbeat_at` (or `locked_at` if no heartbeat has ever been
sent) is older than TTL_MINUTES — so a workspace sending regular heartbeats
keeps its claim indefinitely, while one that has genuinely stalled or died
still ages out normally.

Usage:
  python3 tools/queue_heartbeat.py <issue_id> <workspace_id>

Call this periodically during a WF-03 run for the claimed item — e.g. once
per major step transition (after Step 00, after each CODE-DESIGNER/BACKEND-
DEV/TEST-RUNNER handoff completes) is a reasonable cadence; there is no need
to call it more often than every few minutes, since TTL_MINUTES is 120.

The caller MUST commit and push handoffs/global_queue.json after a
successful (exit 0) heartbeat, same as after a claim — an un-pushed
heartbeat is invisible to other workspaces and provides no protection.

Exit codes:
  0 — heartbeat recorded
  1 — error (item not found, wrong workspace lock, or I/O error)
"""

import datetime
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _queue_sync import sync_queue_from_origin  # noqa: E402

QUEUE_FILE = "handoffs/global_queue.json"
LOCK_FILE  = "handoffs/global_queue.lock"


def _utcnow() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _lock_expired(locked_at: str) -> bool:
    try:
        t = datetime.datetime.strptime(locked_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        return (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() / 60 > 120
    except Exception:
        return True


def _acquire_mutex(owner: str) -> bool:
    try:
        fd = os.open(LOCK_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        with os.fdopen(fd, "w") as f:
            json.dump({"owner": owner, "at": _utcnow()}, f)
        return True
    except FileExistsError:
        try:
            with open(LOCK_FILE, encoding="utf-8-sig") as f:
                data = json.load(f)
            if _lock_expired(data.get("at", "")):
                os.remove(LOCK_FILE)
                return _acquire_mutex(owner)
        except Exception:
            pass
        return False


def _release_mutex():
    try:
        os.remove(LOCK_FILE)
    except FileNotFoundError:
        pass


def main() -> int:
    if len(sys.argv) < 3:
        print("Usage: queue_heartbeat.py <issue_id> <workspace_id>", file=sys.stderr)
        return 1

    issue_id = sys.argv[1]
    workspace_id = sys.argv[2]

    for attempt in range(5):
        if _acquire_mutex(workspace_id):
            break
        time.sleep(1 + attempt)
    else:
        print("ERROR: could not acquire queue mutex after 5 attempts", file=sys.stderr)
        return 1

    try:
        with open(QUEUE_FILE, encoding="utf-8-sig") as f:
            local_q = json.load(f)
        q = sync_queue_from_origin(local_q)

        found = False
        for item in q.get("items", []):
            if item["issue_id"] != issue_id:
                continue

            item_lock = item.get("lock") or {}
            if item_lock.get("workspace_id") != workspace_id:
                print(
                    f"ERROR: {issue_id} is locked by '{item_lock.get('workspace_id')}', "
                    f"not '{workspace_id}' — cannot heartbeat a lock you do not hold",
                    file=sys.stderr,
                )
                _release_mutex()
                return 1

            if item.get("status") != "IN_PROGRESS":
                print(
                    f"ERROR: {issue_id} status is '{item.get('status')}', not IN_PROGRESS "
                    "— nothing to heartbeat",
                    file=sys.stderr,
                )
                _release_mutex()
                return 1

            item_lock["heartbeat_at"] = _utcnow()
            item["lock"] = item_lock
            found = True
            heartbeat_at = item_lock["heartbeat_at"]
            break

        if not found:
            print(f"ERROR: issue_id '{issue_id}' not found in queue", file=sys.stderr)
            _release_mutex()
            return 1

        with open(QUEUE_FILE, "w", encoding="utf-8") as f:
            json.dump(q, f, indent=2)
            f.write("\n")

        _release_mutex()
        print(f"{issue_id} heartbeat recorded at {heartbeat_at}")
        return 0

    except Exception as exc:
        _release_mutex()
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
