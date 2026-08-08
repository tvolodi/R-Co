#!/usr/bin/env python3
"""
queue_heartbeat.py — DEPRECATED, calling this is a no-op you don't need to perform.

gh_claim.py no longer expires an IN_PROGRESS claim on wall-clock time at all —
the only way a claim is released is an explicit queue_release.py call. This
tool used to extend a claim's life past the old TTL_MINUTES=120 staleness
window (see the 2026-08-07 GH-526 incident this was built to prevent, in
docs/anti-patterns.md); that window no longer applies to issue claims, so
there is nothing left to extend. Left in place only because older handoffs
may reference it by name — do not add new call sites.

Usage (still functions, harmlessly, if called):
  python3 tools/queue_heartbeat.py <issue_id> <workspace_id>

Exit codes:
  0 — heartbeat recorded (has no effect on claim expiry — there is none)
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
