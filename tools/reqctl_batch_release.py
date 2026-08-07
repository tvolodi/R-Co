#!/usr/bin/env python3
"""reqctl_batch_release.py — mark a claimed WF-02 requirement batch DONE.

Usage:
  python3 tools/reqctl_batch_release.py <batch_index> <workspace_id> [--run-id RUN_ID]

Exit codes:
  0 — success
  1 — error (batch not found, wrong workspace lock, or I/O error)
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _queue_sync import sync_queue_from_origin  # noqa: E402

BATCH_QUEUE_FILE = "handoffs/batch_queue.json"
LOCK_FILE = "handoffs/batch_queue.lock"


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
        print("Usage: reqctl_batch_release.py <batch_index> <workspace_id> [--run-id RUN_ID]", file=sys.stderr)
        return 1

    batch_index = int(sys.argv[1])
    workspace_id = sys.argv[2]
    run_id = None
    if "--run-id" in sys.argv:
        i = sys.argv.index("--run-id")
        if i + 1 < len(sys.argv):
            run_id = sys.argv[i + 1]

    for attempt in range(5):
        if _acquire_mutex(workspace_id):
            break
        time.sleep(1 + attempt)
    else:
        print("ERROR: could not acquire batch queue mutex after 5 attempts", file=sys.stderr)
        return 1

    try:
        local_q = {"version": "1", "items": []}
        if os.path.exists(BATCH_QUEUE_FILE):
            with open(BATCH_QUEUE_FILE, encoding="utf-8-sig") as f:
                local_q = json.load(f)
        q = sync_queue_from_origin(local_q, queue_path=BATCH_QUEUE_FILE)

        found = False
        for item in q.get("items", []):
            if item.get("batch_index") != batch_index:
                continue
            lock = item.get("lock") or {}
            if lock.get("workspace_id") != workspace_id:
                print(
                    f"ERROR: batch {batch_index} is locked by '{lock.get('workspace_id')}', not '{workspace_id}'",
                    file=sys.stderr,
                )
                _release_mutex()
                return 1
            item["status"] = "DONE"
            item["lock"] = None
            item["completed_at"] = _utcnow()
            if run_id:
                item["run_id"] = run_id
            found = True
            break

        if not found:
            print(f"ERROR: batch_index {batch_index} not found in queue", file=sys.stderr)
            _release_mutex()
            return 1

        os.makedirs(os.path.dirname(BATCH_QUEUE_FILE), exist_ok=True)
        with open(BATCH_QUEUE_FILE, "w", encoding="utf-8") as f:
            json.dump(q, f, indent=2)
            f.write("\n")

        _release_mutex()
        print(f"batch {batch_index} -> DONE")
        return 0

    except Exception as exc:
        _release_mutex()
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
