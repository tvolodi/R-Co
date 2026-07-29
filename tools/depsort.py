#!/usr/bin/env python3
"""
depsort -- order requirements by implementation dependency rather than by ID.

docs/requirements.yaml is a mapping keyed by requirement ID, so reading it in
file order groups requirements by function prefix (all API-*, then all DB-*,
...). That is not a build order. This tool derives one.

There is no explicit `depends_on` field on a requirement, so the order is
derived from the signals that do exist, in descending order of trust:

  1. `> **Extends:** X` in a requirement body        -- HARD edge, X first.
     Verified acyclic across the whole register.
  2. `depends_on` between platform workflows          -- HARD edge, expanded to
     every requirement pair across the two workflows. From docs/workflows.yaml.
  3. `stage`                                          -- the author's own
     sequencing intent. Used only to break ties WITHIN a wave, never to create
     an edge, because stage numbers were assigned per feature area and do not
     form a global order.
  4. `**See:**` cross-references                      -- NOT used as edges.
     `See:` means "related", not "depends on": it contains genuine cycles
     (TD-UI-01 <-> TD-UI-02, OIDC-F-05 <-> OIDC-F-06, ...). It is reported as
     advisory "review together" context instead.

A requirement whose status is RELEASED or DEPRECATED is treated as a satisfied
prerequisite: it is not scheduled, and edges pointing at it are dropped.

Output is a series of WAVES. Everything in wave N has all of its prerequisites
in waves < N, so a wave can be handed to WF-02 in any internal order, or in
parallel. Waves are not stages -- a wave is "what is unblocked now".

Usage:
  depsort order [--all] [--wave N] [--stage S] [--priority P]
  depsort path <ID>        What must be built before <ID>, and what it unblocks
  depsort check            Cycle and dangling-reference report; exit 1 on cycle
  depsort render           Regenerate docs/status/implementation_order.md
  depsort stats            Wave sizes and critical-path depth

  --all      include RELEASED/DEPRECATED requirements (default: open only)

Exit codes: 0 ok, 1 cycle detected, 2 usage error.
"""
import argparse
import collections
import datetime
import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
REQ_FILE = REPO_ROOT / "docs" / "requirements.yaml"
WF_FILE = REPO_ROOT / "docs" / "workflows.yaml"
ORDER_FILE = REPO_ROOT / "docs" / "status" / "implementation_order.md"

DONE_STATUSES = {"RELEASED", "DEPRECATED"}
PRIORITY_RANK = {"MUST": 0, "SHOULD": 1, "COULD": 2, None: 3}
ID_RE = re.compile(r"\b([A-Z]{2,8}(?:-[A-Z]+)?-[0-9]{1,4}[a-z]?)\b")


def now_utc() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def stage_key(stage):
    """Sort key for a stage value. Numeric stages first, then F-stages, then the
    handful of free-text stages inherited from earlier waves of work."""
    s = str(stage)
    try:
        return (0, float(s), "")
    except ValueError:
        pass
    m = re.fullmatch(r"F(\d+)", s)
    if m:
        return (1, float(m.group(1)), "")
    return (2, 0.0, s)


def load():
    if not REQ_FILE.exists():
        sys.exit(f"error: {REQ_FILE} not found")
    raw = yaml.safe_load(REQ_FILE.read_text(encoding="utf-8"))["requirements"]
    reqs = {k: v for k, v in raw.items() if v.get("type", "requirement") == "requirement"}

    workflows = {}
    if WF_FILE.exists():
        workflows = (yaml.safe_load(WF_FILE.read_text(encoding="utf-8")) or {}).get(
            "workflows", {}
        ) or {}
    return reqs, workflows


def extract_refs(body, marker):
    if not body:
        return set()
    m = re.search(rf"\*\*{marker}:\*\*(.+)", body)
    if not m:
        return set()
    return set(ID_RE.findall(m.group(1)))


def build_graph(reqs, workflows, include_done=False):
    """Return (nodes, prereqs, advisory, dangling).

    prereqs[x] = set of requirement IDs that must be built before x.
    advisory[x] = set of related IDs from See:, for context only.
    """
    scheduled = {
        k for k, e in reqs.items()
        if include_done or e.get("status") not in DONE_STATUSES
    }

    prereqs = {k: set() for k in scheduled}
    advisory = {k: set() for k in scheduled}
    dangling = collections.defaultdict(set)

    # 1. Extends -- hard edges
    for k in scheduled:
        body = reqs[k].get("body")
        for ref in extract_refs(body, "Extends"):
            if ref == k:
                continue
            if ref not in reqs:
                if not ref.startswith(("NFR-", "FNFR-")):
                    dangling[k].add(ref)
                continue
            if ref in scheduled:
                prereqs[k].add(ref)
            # a RELEASED prerequisite is already satisfied -- drop the edge

        for ref in extract_refs(body, "See"):
            if ref != k and ref in reqs and ref in scheduled:
                advisory[k].add(ref)

    # 2. workflow depends_on -- hard edges, expanded requirement to requirement
    wf_of = {}
    for wid, wf in workflows.items():
        for rid in wf.get("requirements") or []:
            wf_of[rid] = wid
    members = collections.defaultdict(set)
    for rid, wid in wf_of.items():
        if rid in scheduled:
            members[wid].add(rid)
    for wid, wf in workflows.items():
        for dep in wf.get("depends_on") or []:
            for target in members.get(wid, ()):
                prereqs[target] |= members.get(dep, set())

    for k in scheduled:
        prereqs[k].discard(k)
    return scheduled, prereqs, advisory, dangling


def find_cycles(prereqs):
    colour = collections.defaultdict(int)  # 0 white, 1 grey, 2 black
    found = []

    def visit(u, stack):
        colour[u] = 1
        stack.append(u)
        for v in sorted(prereqs.get(u, ())):
            if colour[v] == 1:
                found.append(stack[stack.index(v):] + [v])
            elif colour[v] == 0:
                visit(v, stack)
        stack.pop()
        colour[u] = 2

    for n in sorted(prereqs):
        if colour[n] == 0:
            visit(n, [])
    return found


def waves(reqs, scheduled, prereqs):
    """Kahn's algorithm, levelled. Returns [[ids], [ids], ...]."""
    remaining = dict(prereqs)
    out = []
    placed = set()
    while remaining:
        ready = [k for k, p in remaining.items() if not (p - placed)]
        if not ready:
            break  # cycle; `check` reports it
        ready.sort(key=lambda k: (
            stage_key(reqs[k].get("stage")),
            PRIORITY_RANK.get(reqs[k].get("priority"), 3),
            k,
        ))
        out.append(ready)
        placed |= set(ready)
        for k in ready:
            del remaining[k]
    return out


def fmt_row(reqs, k, wf_of):
    e = reqs[k]
    wf = wf_of.get(k, "")
    return (f"{k:12s} {str(e.get('stage')):8s} {str(e.get('priority')):7s} "
            f"{str(e.get('status')):12s} {wf:6s} {e.get('title')}")


def wf_index(workflows):
    out = {}
    for wid, wf in workflows.items():
        for rid in wf.get("requirements") or []:
            out[rid] = wid
    return out


# ------------------------------------------------------------------ commands

def cmd_order(args):
    reqs, workflows = load()
    scheduled, prereqs, advisory, _ = build_graph(reqs, workflows, args.all)
    cyc = find_cycles(prereqs)
    if cyc:
        print("error: dependency cycle detected -- run `depsort check`", file=sys.stderr)
        sys.exit(1)
    wf_of = wf_index(workflows)
    ws = waves(reqs, scheduled, prereqs)
    total = 0
    for i, wave in enumerate(ws, 1):
        if args.wave and i != args.wave:
            continue
        rows = wave
        if args.stage:
            rows = [k for k in rows if str(reqs[k].get("stage")) == str(args.stage)]
        if args.priority:
            rows = [k for k in rows if reqs[k].get("priority") == args.priority]
        if not rows:
            continue
        print(f"\n=== WAVE {i}  ({len(rows)} requirements, no unbuilt prerequisites)")
        print(f"{'ID':12s} {'STAGE':8s} {'PRIO':7s} {'STATUS':12s} {'WF':6s} TITLE")
        for k in rows:
            print(fmt_row(reqs, k, wf_of))
            if prereqs[k]:
                print(f"{'':12s} after: {', '.join(sorted(prereqs[k]))}")
        total += len(rows)
    print(f"\n{total} requirements in {len(ws)} waves"
          f"{' (open only; --all to include RELEASED)' if not args.all else ''}")


def cmd_path(args):
    reqs, workflows = load()
    if args.id not in reqs:
        sys.exit(f"error: {args.id} not found")
    scheduled, prereqs, advisory, _ = build_graph(reqs, workflows, include_done=True)
    wf_of = wf_index(workflows)

    # transitive prerequisites
    seen, stack = set(), [args.id]
    while stack:
        u = stack.pop()
        for p in prereqs.get(u, ()):
            if p not in seen:
                seen.add(p)
                stack.append(p)
    # transitive dependents
    rev = collections.defaultdict(set)
    for k, ps in prereqs.items():
        for p in ps:
            rev[p].add(k)
    dep, stack = set(), [args.id]
    while stack:
        u = stack.pop()
        for c in rev.get(u, ()):
            if c not in dep:
                dep.add(c)
                stack.append(c)

    e = reqs[args.id]
    print(f"{args.id}  {e.get('title')}")
    print(f"  stage {e.get('stage')} / {e.get('priority')} / {e.get('status')}"
          f"{' / ' + wf_of[args.id] if args.id in wf_of else ''}")
    print(f"\n  must be built first ({len(seen)}):")
    for k in sorted(seen, key=lambda k: (stage_key(reqs[k].get('stage')), k)):
        mark = "done" if reqs[k].get("status") in DONE_STATUSES else "OPEN"
        print(f"    [{mark}] {fmt_row(reqs, k, wf_of)}")
    print(f"\n  blocked by this ({len(dep)}):")
    for k in sorted(dep, key=lambda k: (stage_key(reqs[k].get('stage')), k)):
        print(f"           {fmt_row(reqs, k, wf_of)}")
    rel = advisory.get(args.id) or set()
    if rel:
        print(f"\n  advisory -- related via See:, review together, not a dependency:")
        print(f"    {', '.join(sorted(rel))}")


def cmd_check(args):
    reqs, workflows = load()
    scheduled, prereqs, advisory, dangling = build_graph(reqs, workflows, args.all)
    cyc = find_cycles(prereqs)
    for c in cyc:
        print(f"CYCLE    {' -> '.join(c)}")
    for k, refs in sorted(dangling.items()):
        for r in sorted(refs):
            print(f"DANGLING {k:12s} Extends -> {r} (not a known requirement)")
    ws = waves(reqs, scheduled, prereqs)
    placed = sum(len(w) for w in ws)
    unplaced = sorted(set(prereqs) - {k for w in ws for k in w})
    for k in unplaced:
        print(f"UNPLACED {k} (in a cycle)")
    print()
    print(f"cycles: {len(cyc)}  dangling: {sum(len(v) for v in dangling.values())}  "
          f"scheduled: {len(scheduled)}  placed: {placed}  waves: {len(ws)}")
    if cyc or unplaced:
        print("FAIL")
        sys.exit(1)
    print("PASS")


def cmd_stats(args):
    reqs, workflows = load()
    scheduled, prereqs, advisory, _ = build_graph(reqs, workflows, args.all)
    ws = waves(reqs, scheduled, prereqs)
    print(f"{'WAVE':6s} {'COUNT':6s} {'MUST':6s} STAGES")
    for i, w in enumerate(ws, 1):
        must = sum(1 for k in w if reqs[k].get("priority") == "MUST")
        stages = sorted({str(reqs[k].get("stage")) for k in w}, key=stage_key)
        print(f"{i:<6d} {len(w):<6d} {must:<6d} {', '.join(stages)}")
    blocked = sum(1 for k in scheduled if prereqs[k])
    print(f"\ncritical path depth: {len(ws)} waves")
    print(f"requirements with at least one unbuilt prerequisite: {blocked}/{len(scheduled)}")


def cmd_render(args):
    reqs, workflows = load()
    scheduled, prereqs, advisory, dangling = build_graph(reqs, workflows, include_done=False)
    if find_cycles(prereqs):
        sys.exit("error: cycle detected; run `depsort check` before rendering")
    wf_of = wf_index(workflows)
    ws = waves(reqs, scheduled, prereqs)
    done = sum(1 for e in reqs.values() if e.get("status") in DONE_STATUSES)

    L = []
    A = L.append
    A("# BPM Platform -- Implementation Order")
    A("")
    A("**Version:** 1.0 (generated)  ")
    A(f"**Generated:** {now_utc()}  ")
    A("**Generated by:** `tools/depsort.py render` -- do not hand-edit this file.  ")
    A("**Source of truth:** `docs/requirements.yaml` (via `reqctl`) and "
      "`docs/workflows.yaml` (via `wfctl`).")
    A("")
    A("---")
    A("")
    A("## How this order is derived")
    A("")
    A("`docs/requirements.yaml` is keyed by requirement ID, so reading it in file")
    A("order groups requirements by function prefix. That is not a build order.")
    A("This file is the build order, derived from the dependency signals that")
    A("actually exist in the register:")
    A("")
    A("| Signal | Trust | Use |")
    A("|---|---|---|")
    A("| `> **Extends:** X` in a body | hard | X must be built first. Verified acyclic. |")
    A("| `depends_on` between platform workflows | hard | expanded to every requirement pair across the two workflows |")
    A("| `stage` | ordering intent | breaks ties **within** a wave only; stage numbers were assigned per feature area and do not form a global order |")
    A("| `**See:**` | related, not dependent | **not** used as an edge -- it contains real cycles. Reported as advisory context by `depsort path`. |")
    A("")
    A("A requirement that is `RELEASED` or `DEPRECATED` counts as a satisfied")
    A(f"prerequisite and is not scheduled here ({done} of {len(reqs)} requirements).")
    A("")
    A("## How to read a wave")
    A("")
    A("Everything in wave N has all of its prerequisites in waves below N. A wave")
    A("is **not** a stage -- it is \"what is unblocked now\". Within a wave there is")
    A("no ordering constraint, so its requirements may be batched to WF-02 in any")
    A("order, or in parallel, subject to the WF-02 batch cap of 4.")
    A("")
    A("```bash")
    A("python3 tools/depsort.py order          # this file, live")
    A("python3 tools/depsort.py path MIG-03    # what must precede a requirement")
    A("python3 tools/depsort.py check          # cycles and dangling references")
    A("python3 tools/wfctl.py next             # the same question at workflow level")
    A("```")
    A("")
    A("---")
    A("")

    for i, wave in enumerate(ws, 1):
        must = sum(1 for k in wave if reqs[k].get("priority") == "MUST")
        A(f"## Wave {i}")
        A("")
        A(f"_{len(wave)} requirements, {must} MUST. No unbuilt prerequisites._")
        A("")
        A("| ID | Stage | Priority | Status | Workflow | Title | After |")
        A("|---|---|---|---|---|---|---|")
        for k in wave:
            e = reqs[k]
            after = ", ".join(f"`{p}`" for p in sorted(prereqs[k])) or "--"
            A(f"| `{k}` | {e.get('stage')} | {e.get('priority')} | {e.get('status')} | "
              f"{wf_of.get(k, '--')} | {e.get('title')} | {after} |")
        A("")

    if dangling:
        A("---")
        A("")
        A("## Dangling references")
        A("")
        A("An `Extends:` naming an ID that is not a known requirement. These do not")
        A("affect the order, but they mean a body cites something that does not exist.")
        A("")
        for k, refs in sorted(dangling.items()):
            A(f"- `{k}` extends `{', '.join(sorted(refs))}`")
        A("")

    ORDER_FILE.parent.mkdir(parents=True, exist_ok=True)
    ORDER_FILE.write_text("\n".join(L) + "\n", encoding="utf-8")
    print(f"regenerated {ORDER_FILE} ({sum(len(w) for w in ws)} requirements, {len(ws)} waves)")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("order")
    sp.add_argument("--all", action="store_true")
    sp.add_argument("--wave", type=int)
    sp.add_argument("--stage")
    sp.add_argument("--priority")
    sp.set_defaults(func=cmd_order)

    sp = sub.add_parser("path")
    sp.add_argument("id")
    sp.set_defaults(func=cmd_path)

    sp = sub.add_parser("check")
    sp.add_argument("--all", action="store_true")
    sp.set_defaults(func=cmd_check)

    sp = sub.add_parser("stats")
    sp.add_argument("--all", action="store_true")
    sp.set_defaults(func=cmd_stats)

    sub.add_parser("render").set_defaults(func=cmd_render)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except Exception:
            pass
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
