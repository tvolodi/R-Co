#!/usr/bin/env python3
"""
queue_add.py — add an issue to the global cross-workspace issue queue.

Usage:
  python3 tools/queue_add.py <issue_id> --severity BLOCKER|MAJOR|MINOR
                             [--title "<text>"] [--github-issue "<url>"]

Exit codes:
  0 — added
  4 — duplicate (issue_id already present in queue with any status)
  1 — error
"""

import datetime
import json
import os
import sys
import time

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
    if len(sys.argv) < 2:
        print(
            "Usage: queue_add.py <issue_id> --severity BLOCKER|MAJOR|MINOR "
            "[--title '...'] [--github-issue '...']",
            file=sys.stderr,
        )
        return 1

    issue_id     = sys.argv[1]
    severity     = "MAJOR"
    title        = ""
    github_issue = ""

    i = 2
    while i < len(sys.argv):
        if sys.argv[i] == "--severity" and i + 1 < len(sys.argv):
            severity = sys.argv[i + 1]; i += 2
        elif sys.argv[i] == "--title" and i + 1 < len(sys.argv):
            title = sys.argv[i + 1]; i += 2
        elif sys.argv[i] == "--github-issue" and i + 1 < len(sys.argv):
            github_issue = sys.argv[i + 1]; i += 2
        else:
            i += 1

    owner = f"queue_add-{os.getpid()}"
    for attempt in range(5):
        if _acquire_mutex(owner):
            break
        time.sleep(1 + attempt)
    else:
        print("ERROR: could not acquire queue mutex after 5 attempts", file=sys.stderr)
        return 1

    try:
        with open(QUEUE_FILE, encoding="utf-8-sig") as f:
            q = json.load(f)

        for item in q.get("items", []):
            if item["issue_id"] == issue_id:
                print(f"DUPLICATE: {issue_id} already in queue (status={item['status']})")
                _release_mutex()
                return 4

        q.setdefault("items", []).append({
            "issue_id":        issue_id,
            "github_issue":    github_issue,
            "title":           title,
            "severity":        severity,
            "status":          "QUEUED",
            "lock":            None,
            "added_at":        _utcnow(),
            "started_at":      None,
            "completed_at":    None,
            "run_id":          None,
            "deferred_reason": None,
        })

        with open(QUEUE_FILE, "w", encoding="utf-8") as f:
            json.dump(q, f, indent=2)
            f.write("\n")

        _release_mutex()
        print(f"Added: {issue_id} ({severity})")
        return 0

    except Exception as exc:
        _release_mutex()
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
