#!/usr/bin/env python3
"""
apply_borrow_backlog -- register the ASCOA-GO borrow backlog into the R-Co
requirement register, and wire it to the platform-workflow catalogue.

Run this ONCE, from the repo root, after copying the delivered artefacts into
place. It is idempotent: requirements that already exist are skipped, so a
re-run after a partial failure is safe.

What it does, in order:

  0. Preflight   -- confirms every input file is present and that no requirement
                    ID in the backlog collides with an existing entry.
  1. Patch       -- runs tools/patch_reqctl_workflow.py (no-op if already applied).
  2. Register    -- for every entry in backlog/meta-*.yaml, runs
                    `reqctl add <ID> --title ... --stage ... --priority ...
                     --status DRAFT --body-file backlog/bodies/<ID>.md
                     --workflow PW-nn`.
  3. Validate    -- runs `reqctl validate`, then `wfctl validate`.
  4. Render      -- runs `reqctl render-status` and `wfctl render`.

Everything is executed through reqctl, never by editing docs/requirements.yaml
directly, so reqctl stays the single write path.

Usage:
  python3 tools/apply_borrow_backlog.py [--dry-run] [--backlog DIR]

  --dry-run   print the exact reqctl commands without running them, and run the
              preflight checks. Nothing is written.
  --backlog   directory holding meta-*.yaml and bodies/ (default: ./backlog)

Exit codes: 0 success, 1 a step failed, 2 preflight failed.
"""
import argparse
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
REQCTL = REPO_ROOT / "tools" / "reqctl.py"
WFCTL = REPO_ROOT / "tools" / "wfctl.py"
PATCHER = REPO_ROOT / "tools" / "patch_reqctl_workflow.py"
REQ_FILE = REPO_ROOT / "docs" / "requirements.yaml"
WF_FILE = REPO_ROOT / "docs" / "workflows.yaml"

REQUIRED_META_FIELDS = ("title", "stage", "priority", "workflow")


def run(cmd, *, check=True, capture=False):
    printable = " ".join(str(c) for c in cmd)
    print(f"  $ {printable}")
    r = subprocess.run(
        [str(c) for c in cmd],
        cwd=REPO_ROOT,
        text=True,
        capture_output=capture,
    )
    if capture and r.stdout:
        for line in r.stdout.rstrip().split("\n"):
            print(f"    {line}")
    if capture and r.stderr:
        for line in r.stderr.rstrip().split("\n"):
            print(f"    {line}")
    if check and r.returncode != 0:
        print(f"\nFAILED: {printable} (exit {r.returncode})")
        sys.exit(1)
    return r


def load_meta(backlog: Path) -> dict:
    meta = {}
    files = sorted(backlog.glob("meta-*.yaml"))
    if not files:
        sys.exit(f"preflight: no meta-*.yaml found in {backlog}")
    for f in files:
        chunk = yaml.safe_load(f.read_text(encoding="utf-8")) or {}
        overlap = set(chunk) & set(meta)
        if overlap:
            sys.exit(f"preflight: {f.name} redefines {sorted(overlap)}")
        meta.update(chunk)
    return meta


def preflight(backlog: Path, meta: dict) -> None:
    print("== 0. preflight")
    problems = []

    for p in (REQCTL, WFCTL, PATCHER, REQ_FILE, WF_FILE):
        if not p.exists():
            problems.append(f"missing file: {p.relative_to(REPO_ROOT)}")

    bodies = backlog / "bodies"
    if not bodies.is_dir():
        problems.append(f"missing directory: {bodies}")

    existing = {}
    if REQ_FILE.exists():
        existing = (yaml.safe_load(REQ_FILE.read_text(encoding="utf-8")) or {}).get(
            "requirements", {}
        )

    wf_ids, wf_claims = set(), {}
    if WF_FILE.exists():
        wfdata = yaml.safe_load(WF_FILE.read_text(encoding="utf-8")) or {}
        wf_ids = set(wfdata.get("workflows") or {})
        for wid, wf in (wfdata.get("workflows") or {}).items():
            for rid in wf.get("requirements") or []:
                wf_claims[rid] = wid

    for rid, m in sorted(meta.items()):
        for field in REQUIRED_META_FIELDS:
            if not m.get(field):
                problems.append(f"{rid}: meta is missing {field}")
        if not (bodies / f"{rid}.md").exists():
            problems.append(f"{rid}: body file bodies/{rid}.md not found")
        if m.get("workflow") not in wf_ids:
            problems.append(f"{rid}: workflow {m.get('workflow')} not in docs/workflows.yaml")
        if wf_claims.get(rid) != m.get("workflow"):
            problems.append(
                f"{rid}: meta says {m.get('workflow')}, workflows.yaml says {wf_claims.get(rid)}"
            )

    # every requirement the catalogue claims must be in this backlog or already registered
    for rid, wid in sorted(wf_claims.items()):
        if rid not in meta and rid not in existing:
            problems.append(f"{wid} claims {rid}, which is neither in the backlog nor registered")

    already = sorted(set(meta) & set(existing))
    if already:
        print(f"  note: {len(already)} requirement(s) already registered, will be skipped:")
        print(f"        {', '.join(already)}")

    if problems:
        print("\npreflight FAILED:")
        for p in problems:
            print(f"  - {p}")
        sys.exit(2)

    print(f"  ok: {len(meta)} requirements, {len(wf_ids)} workflows, "
          f"{len(meta) - len(already)} to register")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--backlog", default=str(REPO_ROOT / "backlog"))
    args = ap.parse_args()

    backlog = Path(args.backlog)
    if not backlog.is_absolute():
        backlog = REPO_ROOT / backlog

    meta = load_meta(backlog)
    preflight(backlog, meta)

    existing = (yaml.safe_load(REQ_FILE.read_text(encoding="utf-8")) or {}).get(
        "requirements", {}
    )

    print("\n== 1. patch reqctl for the workflow field")
    if args.dry_run:
        print(f"  $ python3 {PATCHER.relative_to(REPO_ROOT)}")
    else:
        run([sys.executable, PATCHER], capture=True)

    print("\n== 2. register requirements")
    added = skipped = 0
    for rid, m in sorted(meta.items(), key=lambda kv: (str(kv[1]["workflow"]), kv[0])):
        if rid in existing:
            print(f"  skip {rid} (already registered)")
            skipped += 1
            continue
        cmd = [
            sys.executable, REQCTL, "add", rid,
            "--title", m["title"],
            "--stage", str(m["stage"]),
            "--priority", m["priority"],
            "--status", m.get("status", "DRAFT"),
            "--body-file", str((backlog / "bodies" / f"{rid}.md")),
            "--workflow", m["workflow"],
        ]
        if args.dry_run:
            print("  $ " + " ".join(f'"{c}"' if " " in str(c) else str(c) for c in cmd))
        else:
            run(cmd, capture=True)
        added += 1
    print(f"  {added} added, {skipped} skipped")

    if args.dry_run:
        print("\n== 3./4. skipped (dry run)")
        print("\nDRY RUN COMPLETE -- nothing was written.")
        return

    print("\n== 3. validate")
    r = run([sys.executable, REQCTL, "validate"], check=False, capture=True)
    req_ok = r.returncode == 0
    r = run([sys.executable, WFCTL, "validate"], check=False, capture=True)
    wf_ok = r.returncode == 0

    print("\n== 4. render")
    run([sys.executable, REQCTL, "render-status"], capture=True)
    run([sys.executable, WFCTL, "render"], capture=True)

    print("\n== summary")
    print(f"  requirements registered : {added}")
    print(f"  reqctl validate         : {'PASS' if req_ok else 'FAIL -- see above'}")
    print(f"  wfctl validate          : {'PASS' if wf_ok else 'FAIL -- see above'}")
    print("\nNext: `python3 tools/wfctl.py next` lists the workflows that can start now.")
    print("See docs/agents/RUNBOOK_platform_workflows.md for the dispatch procedure.")
    if not (req_ok and wf_ok):
        sys.exit(1)


if __name__ == "__main__":
    main()
