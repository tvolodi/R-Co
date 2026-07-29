#!/usr/bin/env python3
"""
reqctl -- single write path for docs/requirements.yaml, the canonical
requirements registry for the BPM Platform.

Why this exists: the project accumulated multiple divergent requirement
stores over several waves of work (a consolidated prose doc, a frontend
prose doc, ~150 individual per-requirement files, two backlog docs, and a
status tracker) that drifted out of sync with each other and with reality.
docs/requirements.yaml replaces all of them as the single source of truth
for requirement content AND status, migrated 2026-07-22.

docs/status/requirement_status.yaml is now a GENERATED export for backward
compatibility with pipeline agents that read it directly -- never hand-edit
it; run `reqctl render-status` instead.

The old prose docs (docs/BPM_Platform_Functional_Requirements.md,
docs/BPM_Platform_Frontend_Requirements.md) and the ~150 individual files
under docs/requirements/ are now FROZEN historical references, not inputs.
This tool does not regenerate them -- new or changed requirement content
goes into docs/requirements.yaml via `reqctl add` / editing the body field,
not into those files.

Usage:
  reqctl validate                          Run consistency checks; exit 1 on BLOCKER
  reqctl list [--status S] [--stage N] [--priority P] [--type T]
  reqctl show <id>
  reqctl set-status <id> <status> [--note TEXT] [--implemented-in FILE ...]
  reqctl add <id> --title T --stage S --priority P [--body-file F] [--type T]
  reqctl stats
  reqctl render-status                     Regenerate docs/status/requirement_status.yaml
  reqctl timestamp                         Print the real current UTC time (use this,
                                            never invent a timestamp)

All commands operate on docs/requirements.yaml relative to the repo root
(found by walking up from this script's location).
"""
import argparse
import datetime
import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
REQ_FILE = REPO_ROOT / "docs" / "requirements.yaml"
STATUS_EXPORT_FILE = REPO_ROOT / "docs" / "status" / "requirement_status.yaml"

VALID_STATUSES = {
    "DRAFT", "VALIDATED", "PENDING", "IN_PROGRESS", "IMPLEMENTED",
    "TESTED", "RELEASED", "UNTRACKED", "INFORMATIONAL", "DEPRECATED",
}
VALID_PRIORITIES = {"MUST", "SHOULD", "COULD"}
ID_RE = re.compile(r"^[A-Z]{2,8}(?:-[A-Z]+)?-[0-9]{1,4}[a-z]?$")
VAGUE_WORDS = re.compile(
    r"\b(reasonably|as needed|appropriately|as appropriate|sensible|typically|generally)\b",
    re.IGNORECASE,
)


class LiteralStr(str):
    pass


def _literal_str_representer(dumper, data):
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")


yaml.add_representer(LiteralStr, _literal_str_representer)


def now_utc() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load() -> dict:
    if not REQ_FILE.exists():
        sys.exit(f"error: {REQ_FILE} not found")
    with open(REQ_FILE) as f:
        return yaml.safe_load(f)


def save(data: dict) -> None:
    data["generated_at"] = now_utc()
    out = dict(data)
    reqs = {}
    for rid, e in out["requirements"].items():
        e = dict(e)
        if e.get("body"):
            e["body"] = LiteralStr(e["body"])
        reqs[rid] = e
    out["requirements"] = reqs
    with open(REQ_FILE, "w") as f:
        yaml.dump(out, f, sort_keys=False, allow_unicode=True, width=100)


# ---------------------------------------------------------------- validate

def cmd_validate(args):
    data = load()
    reqs = data["requirements"]
    issues = []  # (severity, id, message)

    ids = set(reqs.keys())
    for rid, e in reqs.items():
        if not ID_RE.match(rid):
            issues.append(("MAJOR", rid, "ID does not match the expected PREFIX-NNN pattern"))

        if e.get("type", "requirement") == "requirement":
            if not e.get("title"):
                issues.append(("BLOCKER", rid, "missing title"))
            if e.get("priority") and e["priority"] not in VALID_PRIORITIES:
                issues.append(("MAJOR", rid, f"unrecognised priority {e['priority']!r}"))
            if e.get("backlog_tier") and not re.match(r"^P[0-3]$", e["backlog_tier"]):
                issues.append(("MAJOR", rid, f"unrecognised backlog_tier {e['backlog_tier']!r}"))
            if e.get("status") not in VALID_STATUSES:
                issues.append(("MAJOR", rid, f"unrecognised status {e.get('status')!r}"))
            if not e.get("body"):
                issues.append(("MINOR", rid, "no prose body recovered (title/status only)"))
            body = e.get("body") or ""
            vague = VAGUE_WORDS.findall(body)
            if vague:
                issues.append(("MAJOR", rid, f"vague language in body: {sorted(set(v.lower() for v in vague))}"))

        # cross-reference resolution: look for a "See:" line and check cited IDs exist
        body = e.get("body") or ""
        see_match = re.search(r"\*\*See:\*\*(.+)", body)
        if see_match:
            cited = set(re.findall(r"\b([A-Z]{2,8}(?:-[A-Z]+)?-[0-9]{1,4}[a-z]?)\b", see_match.group(1)))
            for cid in cited:
                # NFR-*/FNFR-* live in non-functional-requirement tables, not ### blocks --
                # known parser limitation, not a real dangling reference.
                if cid not in ids and not cid.startswith(("NFR-", "FNFR-")):
                    issues.append(("MAJOR", rid, f"cross-reference to unknown ID {cid!r}"))

    blockers = [i for i in issues if i[0] == "BLOCKER"]
    majors = [i for i in issues if i[0] == "MAJOR"]
    minors = [i for i in issues if i[0] == "MINOR"]

    for sev, rid, msg in issues:
        print(f"{sev:8s} {rid:12s} {msg}")

    print()
    print(f"BLOCKER: {len(blockers)}  MAJOR: {len(majors)}  MINOR: {len(minors)}  (total requirements: {len(reqs)})")
    if blockers:
        print("FAIL")
        sys.exit(1)
    print("PASS" + (" (with issues -- see above)" if issues else ""))


# ---------------------------------------------------------------- list / show

def cmd_list(args):
    data = load()
    rows = []
    for rid, e in sorted(data["requirements"].items()):
        if args.status and e.get("status") != args.status:
            continue
        if args.stage is not None and str(e.get("stage")) != str(args.stage):
            continue
        if args.priority and e.get("priority") != args.priority:
            continue
        if args.type and e.get("type", "requirement") != args.type:
            continue
        rows.append((rid, e.get("stage"), e.get("priority"), e.get("status"), e.get("title")))
    for rid, stage, prio, status, title in rows:
        print(f"{rid:14s} stage={str(stage):5s} {str(prio):7s} {status:14s} {title}")
    print(f"\n{len(rows)} matching")


def cmd_show(args):
    data = load()
    e = data["requirements"].get(args.id)
    if not e:
        sys.exit(f"error: {args.id} not found")
    print(yaml.dump({args.id: e}, sort_keys=False, allow_unicode=True, width=100))


# ---------------------------------------------------------------- mutation

def cmd_set_status(args):
    data = load()
    e = data["requirements"].get(args.id)
    if not e:
        sys.exit(f"error: {args.id} not found")
    if args.status not in VALID_STATUSES:
        sys.exit(f"error: {args.status!r} is not a recognised status ({sorted(VALID_STATUSES)})")
    e["status"] = args.status
    if args.note:
        e["note"] = args.note
    if args.implemented_in:
        e["implemented_in"] = args.implemented_in
    if args.status == "RELEASED":
        e.setdefault("released_at", now_utc())
    e["last_updated"] = now_utc()
    save(data)
    print(f"{args.id} -> {args.status} (last_updated={e['last_updated']})")


def cmd_add(args):
    data = load()
    if args.id in data["requirements"]:
        sys.exit(f"error: {args.id} already exists -- use set-status to change it")
    if not ID_RE.match(args.id):
        sys.exit(f"error: {args.id!r} does not match the expected PREFIX-NNN pattern")
    body = None
    if args.body_file:
        body = Path(args.body_file).read_text().strip()
    entry = {
        "id": args.id,
        "title": args.title,
        "stage": args.stage,
        "priority": args.priority,
        "status": args.status or "DRAFT",
        "body": body,
        "body_source": "reqctl-add",
        "alt_sources": [],
        "type": args.type or "requirement",
        "last_updated": now_utc(),
    }
    data["requirements"][args.id] = entry
    save(data)
    print(f"added {args.id}")


# ---------------------------------------------------------------- reporting

def cmd_stats(args):
    data = load()
    reqs = [e for e in data["requirements"].values() if e.get("type", "requirement") == "requirement"]
    from collections import Counter
    by_status = Counter(e.get("status") for e in reqs)
    by_priority = Counter(e.get("priority") for e in reqs)
    by_stage = Counter(str(e.get("stage")) for e in reqs)
    print("By status:")
    for k, v in by_status.most_common():
        print(f"  {k:14s} {v}")
    print("\nBy priority:")
    for k, v in by_priority.most_common():
        print(f"  {str(k):8s} {v}")
    print(f"\nTotal requirements: {len(reqs)}")
    print(f"Total stages represented: {len(by_stage)}")
    open_items = [e for e in reqs if e.get("status") not in ("RELEASED", "DEPRECATED")]
    print(f"\nOpen (not RELEASED): {len(open_items)}")
    for e in sorted(open_items, key=lambda e: (str(e.get("stage")), e["id"])):
        print(f"  {e['id']:14s} stage={str(e.get('stage')):5s} {str(e.get('priority')):7s} {e.get('status'):12s} {e.get('title')}")


# ---------------------------------------------------------------- render

def cmd_render_status(args):
    data = load()
    out_reqs = {}
    for rid, e in data["requirements"].items():
        if e.get("type", "requirement") != "requirement":
            continue
        entry = {"status": e.get("status")}
        for k in ["stage", "priority", "title", "implemented_in", "test_spec", "test_run",
                  "tested_at", "released_at", "release_run", "release_decision", "note"]:
            if e.get(k) is not None:
                entry[k] = e[k]
        out_reqs[rid] = entry
    out = {
        "schema_version": "1.0",
        "generated_by": "tools/reqctl.py render-status -- do not hand-edit this file, edit docs/requirements.yaml",
        "last_updated": now_utc(),
        "requirements": out_reqs,
    }
    with open(STATUS_EXPORT_FILE, "w") as f:
        yaml.dump(out, f, sort_keys=False, allow_unicode=True, width=100)
    print(f"regenerated {STATUS_EXPORT_FILE} ({len(out_reqs)} entries)")


def cmd_timestamp(args):
    print(now_utc())


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("validate").set_defaults(func=cmd_validate)

    sp = sub.add_parser("list")
    sp.add_argument("--status")
    sp.add_argument("--stage")
    sp.add_argument("--priority")
    sp.add_argument("--type")
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("show")
    sp.add_argument("id")
    sp.set_defaults(func=cmd_show)

    sp = sub.add_parser("set-status")
    sp.add_argument("id")
    sp.add_argument("status")
    sp.add_argument("--note")
    sp.add_argument("--implemented-in", nargs="*")
    sp.set_defaults(func=cmd_set_status)

    sp = sub.add_parser("add")
    sp.add_argument("id")
    sp.add_argument("--title", required=True)
    sp.add_argument("--stage", required=True)
    sp.add_argument("--priority")
    sp.add_argument("--status")
    sp.add_argument("--type")
    sp.add_argument("--body-file")
    sp.set_defaults(func=cmd_add)

    sub.add_parser("stats").set_defaults(func=cmd_stats)
    sub.add_parser("render-status").set_defaults(func=cmd_render_status)
    sub.add_parser("timestamp").set_defaults(func=cmd_timestamp)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
