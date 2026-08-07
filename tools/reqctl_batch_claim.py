#!/usr/bin/env python3
"""reqctl_batch_claim.py — claim the next unclaimed WF-02 requirement batch.

SOURCE OF TRUTH: docs/requirements.yaml (status=DRAFT requirements) via
tools/reqctl_batch_plan.py's ordering.
LOCK REGISTRY:   handoffs/batch_queue.json (same shape/discipline as
handoffs/global_queue.json for GitHub issues — see LOOP_PROTOCOL.md).

Why a separate lock file from global_queue.json: a WF-02 batch has no
GitHub issue to key off, and its own git-setup/git-merge wrapping differs
from a WF-03 issue run (own branch naming: feature/WF02-batch-<N>-<date>).
Reusing the exact same locking DISCIPLINE (fetch-fresh-before-write via
_queue_sync.py, push-immediately-after-claim, per-checkout BPM_WORKSPACE_ID)
avoids re-deriving the GH-542/ISS-0610 fixes for a second queue file from
scratch.

Exit codes:
  0 — batch claimed; JSON of the claimed batch printed to stdout
  2 — no claimable batches (plan is empty, or all batches are claimed/done)
  3 — every unclaimed batch is locked by another workspace
  1 — unexpected error

Usage:
  python3 tools/reqctl_batch_claim.py [<workspace_id>]
"""

from __future__ import annotations

import datetime
import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _queue_sync import sync_queue_from_origin  # noqa: E402
import reqctl_batch_plan  # noqa: E402

BATCH_QUEUE_FILE = "handoffs/batch_queue.json"
LOCK_FILE = "handoffs/batch_queue.lock"
TTL_MINUTES = 120


def _utcnow() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _lock_expired(locked_at: str) -> bool:
    try:
        t = datetime.datetime.strptime(locked_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
        return (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() / 60 > TTL_MINUTES
    except Exception:
        return True


def _acquire_file_mutex(owner: str) -> bool:
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
                return _acquire_file_mutex(owner)
        except Exception:
            pass
        return False


def _release_file_mutex() -> None:
    try:
        os.remove(LOCK_FILE)
    except FileNotFoundError:
        pass


def _read_local_queue() -> dict:
    if not os.path.exists(BATCH_QUEUE_FILE):
        return {"version": "1", "items": []}
    with open(BATCH_QUEUE_FILE, encoding="utf-8-sig") as f:
        return json.load(f)


def _write_queue(data: dict) -> None:
    os.makedirs(os.path.dirname(BATCH_QUEUE_FILE), exist_ok=True)
    with open(BATCH_QUEUE_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def main() -> int:
    workspace_id = sys.argv[1] if len(sys.argv) > 1 else f"{socket.gethostname()}-{os.getpid()}"

    for attempt in range(5):
        if _acquire_file_mutex(workspace_id):
            break
        time.sleep(1 + attempt)
    else:
        print("ERROR: could not acquire batch queue mutex after 5 attempts", file=sys.stderr)
        return 1

    try:
        queue = sync_queue_from_origin(_read_local_queue(), queue_path=BATCH_QUEUE_FILE)

        reqs = reqctl_batch_plan.load_requirements()
        batches = reqctl_batch_plan.build_plan(reqs, "DRAFT")
        if not batches:
            return 2  # nothing left to batch

        active_locks: set[int] = set()
        done_indices: set[int] = set()
        for item in queue.get("items", []):
            idx = item.get("batch_index")
            if idx is None:
                continue
            if item.get("status") == "DONE":
                done_indices.add(idx)
            elif item.get("status") == "IN_PROGRESS":
                lock = item.get("lock") or {}
                if not _lock_expired(lock.get("locked_at", "")):
                    active_locks.add(idx)

        any_actively_locked = False
        for idx, batch_ids in enumerate(batches):
            if idx in done_indices:
                continue
            if idx in active_locks:
                any_actively_locked = True
                continue

            now = _utcnow()
            claimed_item = {
                "batch_index": idx,
                "requirement_ids": batch_ids,
                "status": "IN_PROGRESS",
                "lock": {"workspace_id": workspace_id, "locked_at": now},
                "claimed_at": now,
                "completed_at": None,
                "run_id": None,
            }

            existing = next((i for i in queue["items"] if i.get("batch_index") == idx), None)
            if existing is not None:
                existing.update(claimed_item)
            else:
                queue.setdefault("items", []).append(claimed_item)

            _write_queue(queue)
            print(json.dumps(claimed_item, indent=2))
            return 0

        if any_actively_locked:
            print("All unclaimed batches are locked by other workspaces.", file=sys.stderr)
            return 3
        return 2  # every batch already DONE

    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    finally:
        _release_file_mutex()


if __name__ == "__main__":
    sys.exit(main())
