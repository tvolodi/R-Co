#!/usr/bin/env python3
"""reqctl_batch_plan.py — compute WF-02 implementation batch order for DRAFT
requirements in docs/requirements.yaml.

Ordering rules (in priority order):
  1. Strict precedence from "**Extends:** <ID>" in a requirement's body — a
     requirement never appears in an earlier or same batch as something it
     extends. This is a genuine directed dependency (unlike "**See:**",
     which is symmetric cross-referencing and carries no ordering meaning
     the way this codebase writes it — verified by cycle-checking: the See:
     graph has 34+ mutual-reference cycles among these 92 requirements,
     while the Extends: graph is a clean DAG).
  2. Requirements sharing the same `workflow` field (PW-01..PW-16) are kept
     together / adjacent — they are typically sequential steps of one
     feature, and splitting them across distant batches produces
     integration churn (a later batch needing an interface the earlier one
     didn't yet define).
  3. Within a tie: stage (ascending), then priority (MUST before SHOULD),
     then id (alphabetical) for determinism.
  4. Batches capped at 4 requirements (ORCHESTRATOR.md's WF-02 hard limit —
     "the strongest predictor of WF-03 rework loops" per that doc).

Usage:
  python3 tools/reqctl_batch_plan.py                 # print the plan
  python3 tools/reqctl_batch_plan.py --status DRAFT   # only DRAFT reqs (default)
  python3 tools/reqctl_batch_plan.py --json           # machine-readable output
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
REQ_FILE = REPO_ROOT / "docs" / "requirements.yaml"
BATCH_SIZE = 4

EXTENDS_RE = re.compile(r"\*\*Extends:\*\*\s*([A-Z0-9-]+)")


def load_requirements() -> dict:
    with open(REQ_FILE, encoding="utf-8-sig") as f:
        return yaml.safe_load(f)["requirements"]


def build_extends_graph(reqs: dict, scope_ids: set[str]) -> dict[str, str | None]:
    """id -> the single id it Extends (if that id is also in scope), else None."""
    extends: dict[str, str | None] = {}
    for rid in scope_ids:
        body = reqs[rid].get("body") or ""
        m = EXTENDS_RE.search(body)
        if m and m.group(1) in scope_ids:
            extends[rid] = m.group(1)
        else:
            extends[rid] = None
    return extends


def topo_order(scope_ids: set[str], extends: dict[str, str | None]) -> list[str]:
    """Kahn's algorithm; raises on cycle (should not happen — see module docstring)."""
    from collections import deque

    in_degree = {rid: 0 for rid in scope_ids}
    children: dict[str, list[str]] = {rid: [] for rid in scope_ids}
    for rid, parent in extends.items():
        if parent is not None:
            in_degree[rid] += 1
            children[parent].append(rid)

    queue = deque(sorted(rid for rid in scope_ids if in_degree[rid] == 0))
    order = []
    while queue:
        node = queue.popleft()
        order.append(node)
        for child in sorted(children[node]):
            in_degree[child] -= 1
            if in_degree[child] == 0:
                queue.append(child)

    if len(order) != len(scope_ids):
        remaining = scope_ids - set(order)
        raise RuntimeError(f"Extends: graph has a cycle involving: {sorted(remaining)}")
    return order


def stage_sort_key(stage) -> tuple:
    s = str(stage)
    try:
        return (0, int(s))
    except ValueError:
        return (1, s)


def priority_sort_key(priority: str) -> int:
    return {"MUST": 0, "SHOULD": 1, "COULD": 2}.get(priority, 3)


def build_plan(reqs: dict, status_filter: str) -> list[list[str]]:
    scope_ids = {rid for rid, e in reqs.items() if e.get("status") == status_filter}
    if not scope_ids:
        return []

    extends = build_extends_graph(reqs, scope_ids)
    topo_order(scope_ids, extends)  # raises on cycle; result unused, order rebuilt below

    def sort_key(rid: str):
        e = reqs[rid]
        return (
            stage_sort_key(e.get("stage")),
            priority_sort_key(e.get("priority", "MUST")),
            rid,
        )

    in_degree = {rid: 0 for rid in scope_ids}
    children: dict[str, list[str]] = {rid: [] for rid in scope_ids}
    for rid, parent in extends.items():
        if parent is not None:
            in_degree[rid] += 1
            children[parent].append(rid)

    ready = set(rid for rid in scope_ids if in_degree[rid] == 0)
    placed: set[str] = set()
    batches: list[list[str]] = []
    current_workflow: str | None = None

    def release(node: str) -> None:
        for child in children[node]:
            in_degree[child] -= 1
            if in_degree[child] == 0:
                ready.add(child)

    while len(placed) < len(scope_ids):
        batch: list[str] = []
        batch_set: set[str] = set()
        deferred: set[str] = set()  # ready this round, but Extends-parent already in THIS batch
        while len(batch) < BATCH_SIZE and (ready - deferred):
            # Prefer continuing the batch's current workflow cluster (keeps
            # a feature's requirements adjacent instead of scattered); only
            # cross into a different workflow when nothing in the current
            # one is eligible right now.
            eligible = (ready - deferred)
            candidates = [r for r in eligible if str(reqs[r].get("workflow") or "") == current_workflow] if current_workflow else []
            if not candidates:
                candidates = list(eligible)
            candidates.sort(key=sort_key)
            pick = candidates[0]

            # A requirement never shares a batch with the thing it Extends —
            # WF-02's own rule is that a batch is designed/implemented as one
            # unit, and CODE-DESIGNER needs the extended requirement's design
            # settled first, not concurrent. If its parent is in this batch,
            # this requirement waits for the NEXT batch even though the
            # dependency graph says it's technically "ready" now.
            parent = extends.get(pick)
            if parent is not None and parent in batch_set:
                deferred.add(pick)
                continue

            ready.discard(pick)
            placed.add(pick)
            batch.append(pick)
            batch_set.add(pick)
            release(pick)
            current_workflow = str(reqs[pick].get("workflow") or "")

        if not batch:
            # Nothing ready but scope not exhausted — should be impossible
            # given the upfront cycle check, but fail loudly rather than
            # loop forever if it ever happens.
            remaining = scope_ids - placed
            raise RuntimeError(f"scheduling stalled with unplaced requirements: {sorted(remaining)}")

        batches.append(batch)
        current_workflow = None  # each new batch may open a fresh cluster

    return batches


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--status", default="DRAFT", help="requirement status to include (default: DRAFT)")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    reqs = load_requirements()
    try:
        batches = build_plan(reqs, args.status)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps({"batches": batches}, indent=2))
        return 0

    if not batches:
        print(f"No requirements with status={args.status!r} to batch.")
        return 0

    print(f"{sum(len(b) for b in batches)} requirements in {len(batches)} batches (status={args.status!r}):\n")
    for i, batch in enumerate(batches, 1):
        print(f"Batch {i}:")
        for rid in batch:
            e = reqs[rid]
            print(f"  {rid:14s} stage={e.get('stage'):>4} pri={e.get('priority'):6s} wf={e.get('workflow') or '-':6s} {e.get('title')}")
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
