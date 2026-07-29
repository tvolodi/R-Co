#!/usr/bin/env python3
"""
patch_reqctl_workflow -- teach tools/reqctl.py about the `workflow` field.

Run once. Idempotent: if the marker is already present it exits 0 and changes
nothing, so an agent may run it unconditionally.

What it changes in tools/reqctl.py:

  1. `add` gains `--workflow PW-nn`, stored on the entry as `workflow`.
  2. `set-workflow <id> <PW-nn>` is added, for requirements that already exist.
  3. `validate` gains two checks:
       - a `workflow` value must match the PW-nn shape, and must resolve
         against docs/workflows.yaml when that file exists   (MAJOR)
       - a requirement whose ID is claimed by a workflow but which carries no
         `workflow` field                                     (MAJOR)
  4. `render-status` carries `workflow` through into
     docs/status/requirement_status.yaml, so pipeline agents that read the
     generated status export can group by workflow without loading
     requirements.yaml.

Nothing else is touched. A timestamped backup is written next to the original.

Usage:
  python3 tools/patch_reqctl_workflow.py [--check]

  --check   report whether the patch is applied; exit 1 if it is not.
"""
import argparse
import datetime
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TARGET = REPO_ROOT / "tools" / "reqctl.py"
MARKER = "# --- wfctl integration: workflow field ---"

# ---------------------------------------------------------------- fragments

VALIDATE_BLOCK = '''
        # --- wfctl integration: workflow field ---
        wid = e.get("workflow")
        if wid is not None:
            if not WORKFLOW_ID_RE.match(str(wid)):
                issues.append(("MAJOR", rid, f"workflow {wid!r} does not match the PW-nn pattern"))
            elif _WORKFLOW_IDS and wid not in _WORKFLOW_IDS:
                issues.append(("MAJOR", rid, f"workflow {wid!r} is not in docs/workflows.yaml"))
        elif rid in _WORKFLOW_CLAIMS:
            issues.append(("MAJOR", rid,
                           f"claimed by {_WORKFLOW_CLAIMS[rid]} in docs/workflows.yaml "
                           f"but carries no workflow field"))
'''

HELPERS = '''

# --- wfctl integration: workflow field ---
# A requirement may name the PLATFORM WORKFLOW (PW-nn) it helps deliver.
# docs/workflows.yaml is the catalogue; tools/wfctl.py is its read/verify path.
# reqctl stays the only writer of requirement content and status.
WORKFLOW_ID_RE = re.compile(r"^PW-[0-9]{2,3}$")
WORKFLOW_FILE = REPO_ROOT / "docs" / "workflows.yaml"


def _load_workflow_index():
    """Return (set_of_workflow_ids, {requirement_id: workflow_id}).

    Returns empty structures when docs/workflows.yaml is absent, so reqctl
    keeps working standalone.
    """
    if not WORKFLOW_FILE.exists():
        return set(), {}
    try:
        data = yaml.safe_load(WORKFLOW_FILE.read_text(encoding="utf-8")) or {}
    except Exception:
        return set(), {}
    workflows = data.get("workflows") or {}
    claims = {}
    for wid, wf in workflows.items():
        for rid in (wf.get("requirements") or []):
            claims[rid] = wid
    return set(workflows), claims


_WORKFLOW_IDS, _WORKFLOW_CLAIMS = _load_workflow_index()


def cmd_set_workflow(args):
    data = load()
    e = data["requirements"].get(args.id)
    if not e:
        sys.exit(f"error: {args.id} not found")
    if not WORKFLOW_ID_RE.match(args.workflow):
        sys.exit(f"error: {args.workflow!r} does not match the PW-nn pattern")
    if _WORKFLOW_IDS and args.workflow not in _WORKFLOW_IDS:
        sys.exit(f"error: {args.workflow} is not in docs/workflows.yaml")
    e["workflow"] = args.workflow
    e["last_updated"] = now_utc()
    save(data)
    print(f"{args.id} -> workflow {args.workflow}")
'''

SUBPARSER = '''
    # --- wfctl integration: workflow field ---
    sp = sub.add_parser("set-workflow")
    sp.add_argument("id")
    sp.add_argument("workflow")
    sp.set_defaults(func=cmd_set_workflow)
'''


def apply_patch(src: str) -> str:
    if MARKER in src:
        return src

    # 1. helpers + set-workflow command, inserted just before the validate section
    anchor = "# ---------------------------------------------------------------- validate"
    if anchor not in src:
        sys.exit("error: could not find the validate section header in reqctl.py")
    src = src.replace(anchor, HELPERS.rstrip() + "\n\n\n" + anchor, 1)

    # 2. validate checks, appended to the per-requirement loop
    val_anchor = (
        '        # cross-reference resolution: look for a "See:" line and check cited IDs exist'
    )
    if val_anchor not in src:
        sys.exit("error: could not find the cross-reference block in cmd_validate")
    src = src.replace(val_anchor, VALIDATE_BLOCK.rstrip() + "\n\n" + val_anchor, 1)

    # 3. --workflow on add
    add_anchor = '''        "type": args.type or "requirement",
        "last_updated": now_utc(),
    }'''
    if add_anchor not in src:
        sys.exit("error: could not find the add() entry literal")
    src = src.replace(
        add_anchor,
        '''        "type": args.type or "requirement",
        "last_updated": now_utc(),
    }
    if getattr(args, "workflow", None):  # --- wfctl integration: workflow field ---
        if not WORKFLOW_ID_RE.match(args.workflow):
            sys.exit(f"error: {args.workflow!r} does not match the PW-nn pattern")
        if _WORKFLOW_IDS and args.workflow not in _WORKFLOW_IDS:
            sys.exit(f"error: {args.workflow} is not in docs/workflows.yaml")
        entry["workflow"] = args.workflow''',
        1,
    )

    # 4. carry `workflow` into the generated status export
    render_anchor = ('        for k in ["stage", "priority", "title", "implemented_in", '
                     '"test_spec", "test_run",')
    if render_anchor not in src:
        sys.exit("error: could not find the render-status field list")
    src = src.replace(
        render_anchor,
        ('        for k in ["workflow", "stage", "priority", "title", "implemented_in", '
         '"test_spec", "test_run",'),
        1,
    )

    # 5. --workflow argument on the add subparser
    argp_anchor = '''    sp.add_argument("--body-file")
    sp.set_defaults(func=cmd_add)'''
    if argp_anchor not in src:
        sys.exit("error: could not find the add subparser")
    src = src.replace(
        argp_anchor,
        '''    sp.add_argument("--body-file")
    sp.add_argument("--workflow", help="platform workflow this requirement delivers (PW-nn)")
    sp.set_defaults(func=cmd_add)''',
        1,
    )

    # 6. set-workflow subparser
    sub_anchor = '''    sub.add_parser("stats").set_defaults(func=cmd_stats)'''
    if sub_anchor not in src:
        sys.exit("error: could not find the stats subparser")
    src = src.replace(sub_anchor, SUBPARSER.rstrip() + "\n\n" + sub_anchor, 1)

    return src


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="report whether the patch is applied; exit 1 if not")
    args = ap.parse_args()

    if not TARGET.exists():
        sys.exit(f"error: {TARGET} not found")
    src = TARGET.read_text(encoding="utf-8")

    if args.check:
        if MARKER in src:
            print("reqctl.py: workflow field patch APPLIED")
            sys.exit(0)
        print("reqctl.py: workflow field patch NOT applied")
        sys.exit(1)

    if MARKER in src:
        print("reqctl.py already patched -- nothing to do")
        return

    patched = apply_patch(src)
    compile(patched, str(TARGET), "exec")  # refuse to write a file that will not parse

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = TARGET.with_suffix(f".py.bak-{stamp}")
    shutil.copy2(TARGET, backup)
    TARGET.write_text(patched, encoding="utf-8")
    print(f"patched  {TARGET}")
    print(f"backup   {backup}")
    print("added    reqctl add --workflow PW-nn")
    print("added    reqctl set-workflow <id> <PW-nn>")
    print("added    validate: workflow resolves against docs/workflows.yaml")
    print("added    render-status: carries `workflow` into requirement_status.yaml")


if __name__ == "__main__":
    main()
