#!/usr/bin/env python3
"""
queue_claim.py — claim the next available item from the global cross-workspace issue queue.

Exit codes:
  0 — item claimed; prints JSON of the claimed item to stdout
  2 — queue exhausted (no QUEUED items; IN_PROGRESS items are never reclaimed)
  3 — all remaining items are actively locked by other workspaces (caller may retry or stop)
  1 — unexpected error

Usage:
  python3 tools/queue_claim.py [<workspace_id>]

  <workspace_id> defaults to "<hostname>-<pid>" when omitted.

The ORCH loop should:
  exit 0  → run WF-03 for the returned item, then call queue_release.py
  exit 2  → stop the loop (queue is empty)
  exit 3  → stop or retry after a delay
"""

import datetime
import json
import os
import socket
import sys
import time

QUEUE_FILE = "handoffs/global_queue.json"
LOCK_FILE  = "handoffs/global_queue.lock"   # file-level mutex, not the item lock

# TTL for the LOCAL FILE MUTEX (LOCK_FILE) only — a same-machine crash-recovery
# mechanism, unrelated to an item's claim lifetime. An IN_PROGRESS item lock no
# longer expires on wall-clock time at all — a workspace may legitimately
# spend a long time on one item, and a TTL-based reclaim previously let a
# second workspace steal a still-active claim (2026-08-07, GH-526, see
# docs/anti-patterns.md).
MUTEX_TTL_MINUTES = 5


def _utcnow() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _mutex_expired(locked_at: str) -> bool:
    try:
        t = datetime.datetime.strptime(locked_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        return (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() / 60 > MUTEX_TTL_MINUTES
    except Exception:
        return True  # unparseable timestamp → treat as expired


def _acquire_mutex(owner: str) -> bool:
    """Atomically create the file-level mutex. Returns True if acquired."""
    try:
        fd = os.open(LOCK_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        with os.fdopen(fd, "w") as f:
            json.dump({"owner": owner, "at": _utcnow()}, f)
        return True
    except FileExistsError:
        # Remove stale mutex (crashed process left it behind)
        try:
            with open(LOCK_FILE, encoding="utf-8-sig") as f:
                data = json.load(f)
            if _mutex_expired(data.get("at", "")):
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
    workspace_id = sys.argv[1] if len(sys.argv) > 1 else f"{socket.gethostname()}-{os.getpid()}"

    # Retry acquiring the file mutex up to 5 times (another workspace may be mid-write)
    for attempt in range(5):
        if _acquire_mutex(workspace_id):
            break
        time.sleep(1 + attempt)
    else:
        print("ERROR: could not acquire queue mutex after 5 attempts", file=sys.stderr)
        return 1

    try:
        with open(QUEUE_FILE, encoding="utf-8-sig") as f:
            q = json.load(f)

        items = q.get("items", [])
        claimed = None
        has_active_locked = False

        for item in items:
            status = item.get("status")
            if status not in ("QUEUED", "IN_PROGRESS"):
                continue

            if status == "QUEUED":
                # Unclaimed — take it
                now = _utcnow()
                item["status"]     = "IN_PROGRESS"
                item["lock"]       = {"workspace_id": workspace_id, "locked_at": now}
                item["started_at"] = now
                claimed = item
                break

            # status == "IN_PROGRESS" — never reclaimed on wall-clock time alone.
            # The claiming workspace may legitimately still be working this item;
            # only its own queue_release.py call frees it.
            has_active_locked = True

        if claimed is None:
            _release_mutex()
            if has_active_locked:
                print("All remaining items are locked by other workspaces.", file=sys.stderr)
                return 3
            print("Queue is empty.", file=sys.stderr)
            return 2

        with open(QUEUE_FILE, "w", encoding="utf-8") as f:
            json.dump(q, f, indent=2)
            f.write("\n")

        _release_mutex()
        print(json.dumps(claimed, indent=2))
        return 0

    except Exception as exc:
        _release_mutex()
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
