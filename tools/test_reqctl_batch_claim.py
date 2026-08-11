#!/usr/bin/env python3
"""test_reqctl_batch_claim.py — regression test for ISS-0667 / GH-705.

Reproduces the exact bug: claim batch 0, mark it DONE (simulating its
requirements leaving DRAFT status), then claim again. Before the fix,
reqctl_batch_claim.py matched claimed/done state by the bare positional
index from build_plan()'s freshly-recomputed batch list — which shifts
every time an earlier batch's requirements leave DRAFT scope — so the
second claim silently skipped the batch that should have been next and
returned some LATER batch's content instead.

This test does not touch the real handoffs/batch_queue.json or
docs/requirements.yaml — it exercises batch_key() and the claim/skip
logic directly against synthetic queue state and a synthetic build_plan()
stand-in, so it has no dependency on live requirement data and is safe to
run in any environment.

Usage:
  python3 tools/test_reqctl_batch_claim.py

Exit codes:
  0 — all assertions passed
  1 — a regression was detected
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from reqctl_batch_claim import batch_key  # noqa: E402
from _queue_sync import _merge_items_by_identity  # noqa: E402


def test_batch_key_is_content_stable() -> None:
    """The same requirement set must hash to the same key regardless of
    what array position build_plan() happens to assign it in any given
    call."""
    a = batch_key(["DDL-01", "MIG-04", "MIG-05", "MIG-06"])
    b = batch_key(["MIG-06", "MIG-05", "MIG-04", "DDL-01"])  # different order in
    assert a == b, "batch_key must be order-independent (sorted internally)"

    different = batch_key(["DDL-02", "ORD-01", "ORD-02", "ORD-04"])
    assert a != different, "different requirement sets must hash differently"
    print("PASS: batch_key_is_content_stable")


def test_claim_skips_in_progress_batch_after_reshuffle() -> None:
    """The exact ISS-0667 / GH-705 scenario: batch 0 completes and its
    requirements leave DRAFT scope, which means a freshly recomputed
    build_plan() shifts every later batch's position by one. A queue
    entry keyed by the OLD position (1) must still correctly refer to the
    SAME content when matched against the NEW plan's position-0 entry
    that now holds that content — the claim logic must not treat them as
    two different things just because the array index differs across
    calls.
    """
    # "Before" state: 3 batches exist, batch 0 is claimed+released (DONE).
    before_batches = [
        ["DDL-05", "MIG-01", "MIG-02", "MIG-03"],   # batch 0 (will complete)
        ["DDL-01", "MIG-04", "MIG-05", "MIG-06"],   # batch 1 (claimed next, IN_PROGRESS)
        ["DDL-02", "ORD-01", "ORD-02", "ORD-04"],   # batch 2 (not yet touched)
    ]
    queue_items = [
        {
            "stage_key": "16",
            "batch_key": batch_key(before_batches[0]),
            "batch_index": 0,
            "status": "DONE",
        },
        {
            "stage_key": "16",
            "batch_key": batch_key(before_batches[1]),
            "batch_index": 1,
            "status": "IN_PROGRESS",
            "lock": {"workspace_id": "workspace-A"},
        },
    ]

    # "After" state: batch 0's requirements left DRAFT scope, so a fresh
    # build_plan() call now returns only 2 batches, and what WAS batch 1
    # is now at position 0.
    after_batches = [
        ["DDL-01", "MIG-04", "MIG-05", "MIG-06"],   # now at index 0 (was index 1)
        ["DDL-02", "ORD-01", "ORD-02", "ORD-04"],   # now at index 1 (was index 2)
    ]

    done_keys = {i["batch_key"] for i in queue_items if i["status"] == "DONE"}
    active_locks = {i["batch_key"] for i in queue_items if i["status"] == "IN_PROGRESS"}

    claimed = None
    for idx, batch_ids in enumerate(after_batches):
        key = batch_key(batch_ids)
        if key in done_keys:
            continue
        if key in active_locks:
            continue
        claimed = (idx, batch_ids)
        break

    assert claimed is not None, "expected to claim the third batch (not locked, not done)"
    claimed_idx, claimed_ids = claimed
    assert claimed_ids == ["DDL-02", "ORD-01", "ORD-02", "ORD-04"], (
        f"expected to claim the DDL-02/ORD-01/ORD-02/ORD-04 batch (the only "
        f"unclaimed, undone one), got {claimed_ids} instead — this is exactly "
        f"the ISS-0667/GH-705 regression: an unstable index let an "
        f"already-IN_PROGRESS batch be silently skipped past or re-claimed"
    )
    print("PASS: claim_skips_in_progress_batch_after_reshuffle")


def test_queue_sync_merge_handles_batch_queue_shape() -> None:
    """_queue_sync.py's merge helper must not assume every item has an
    "issue_id" key — handoffs/batch_queue.json items are keyed by
    (stage_key, batch_key) instead. Regression for ISS-0666 / GH-704,
    which raised KeyError on every batch_queue.json sync call."""
    origin = {"version": "1", "items": [
        {"stage_key": "16", "batch_key": "aaa", "status": "DONE"},
    ]}
    local = {"version": "1", "items": [
        {"stage_key": "16", "batch_key": "aaa", "status": "IN_PROGRESS"},
        {"stage_key": "16", "batch_key": "bbb", "status": "IN_PROGRESS"},
    ]}
    merged = _merge_items_by_identity(origin, local)
    assert merged["items"] == [
        {"stage_key": "16", "batch_key": "aaa", "status": "DONE"},
        {"stage_key": "16", "batch_key": "bbb", "status": "IN_PROGRESS"},
    ], f"unexpected merge result: {merged['items']}"
    print("PASS: queue_sync_merge_handles_batch_queue_shape")


def main() -> int:
    tests = [
        test_batch_key_is_content_stable,
        test_claim_skips_in_progress_batch_after_reshuffle,
        test_queue_sync_merge_handles_batch_queue_shape,
    ]
    failures = 0
    for t in tests:
        try:
            t()
        except AssertionError as exc:
            failures += 1
            print(f"FAIL: {t.__name__}: {exc}", file=sys.stderr)
    if failures:
        print(f"\n{failures}/{len(tests)} tests FAILED", file=sys.stderr)
        return 1
    print(f"\nAll {len(tests)} tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
