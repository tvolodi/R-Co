#!/usr/bin/env python3
"""
wfctl -- read/verify path for docs/workflows.yaml, the canonical catalogue of
PLATFORM WORKFLOWS (PW-nn).

Why this exists: docs/requirements.yaml (via reqctl) is the single store for
functional requirements, but a requirement is too small a unit to sign off with
a business owner. A PLATFORM WORKFLOW is the unit above it: an end-to-end
capability the platform executes, documented as a process map under
docs/processes/system/, delivered by a set of requirements, and signed off as a
whole by a WF-05 UAT run.

    PW-nn (docs/workflows.yaml)
      |-- process_map    -> docs/processes/system/<slug>.md
      |-- requirements[] -> docs/requirements.yaml        (reqctl owns status)
      +-- uat_scenarios[]-> tests/simulation/scenarios/**  (UAT-RUNNER consumes)

Division of ownership -- do not blur it:
  * reqctl owns requirement CONTENT and STATUS. wfctl never writes to
    docs/requirements.yaml.
  * wfctl owns the workflow CATALOGUE and DERIVES workflow status from the
    requirement statuses reqctl maintains.

PW-nn is deliberately distinct from WF-0n. WF-0n are DEVELOPMENT workflows run
by the agent pipeline (docs/agents/workflows/). PW-nn are PRODUCT workflows
executed by the running platform.

Usage:
  wfctl list [--status S] [--stage N] [--priority P]
  wfctl show <PW-id>
  wfctl validate                  Structural checks; exit 1 on BLOCKER
  wfctl status [<PW-id>]          Derived roll-up of requirement statuses
  wfctl uat-ready <PW-id>         Exit 0 if the workflow may be sent to WF-05
  wfctl next                      Workflows whose dependencies are satisfied
  wfctl render                    Refresh derived fields + write the status export
  wfctl requirements <PW-id>      Print just the requirement IDs (for scripting)

Exit codes: 0 ok, 1 blocker/not-ready, 2 usage error.
"""
import argparse
import datetime
import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
WF_FILE = REPO_ROOT / "docs" / "workflows.yaml"
REQ_FILE = REPO_ROOT / "docs" / "requirements.yaml"
STATUS_EXPORT = REPO_ROOT / "docs" / "status" / "workflow_status.yaml"
SCENARIO_ROOTS = [
    REPO_ROOT / "tests" / "simulation" / "scenarios",
    REPO_ROOT / "tests" / "simulation" / "scenarios" / "platform",
]

PW_ID_RE = re.compile(r"^PW-[0-9]{2,3}$")

# A workflow is only as done as its gating requirements -- its MUST entries, or
# all of its entries when it declares no MUST (see derive()).
DONE_STATUSES = {"TESTED", "RELEASED"}
STARTED_STATUSES = {"IN_PROGRESS", "IMPLEMENTED", "TESTED", "RELEASED"}

VALID_WF_STATUS = [
    "DRAFT", "READY", "IN_PROGRESS", "IMPLEMENTED", "UAT_PASSED", "RELEASED",
]
VALID_UAT_SURFACE = {"gui", "mixed", "system"}


def now_utc() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_workflows() -> dict:
    if not WF_FILE.exists():
        sys.exit(f"error: {WF_FILE} not found")
    return yaml.safe_load(WF_FILE.read_text(encoding="utf-8"))


def load_requirements() -> dict:
    if not REQ_FILE.exists():
        sys.exit(f"error: {REQ_FILE} not found")
    return yaml.safe_load(REQ_FILE.read_text(encoding="utf-8"))["requirements"]


def save_workflows(data: dict) -> None:
    data["generated_at"] = now_utc()
    WF_FILE.write_text(
        yaml.dump(data, sort_keys=False, allow_unicode=True, width=100),
        encoding="utf-8",
    )


def find_scenario(scenario_id: str):
    for root in SCENARIO_ROOTS:
        p = root / f"{scenario_id}.yaml"
        if p.exists():
            return p
    return None


def get_wf(data: dict, pw_id: str) -> dict:
    wf = data["workflows"].get(pw_id)
    if not wf:
        sys.exit(f"error: {pw_id} not found in {WF_FILE.name}")
    return wf


# ------------------------------------------------------------------ derive

def derive(wf: dict, reqs: dict) -> dict:
    """Derive a workflow's real state from the requirements reqctl maintains."""
    ids = wf.get("requirements") or []
    known = [i for i in ids if i in reqs]
    missing = [i for i in ids if i not in reqs]

    must = [i for i in known if reqs[i].get("priority") == "MUST"]
    # A workflow with no MUST requirement is gated by ALL of its requirements.
    # Without this, a wholly-SHOULD workflow would report 0/0 complete and sail
    # through the UAT gate with nothing implemented.
    gating = must if must else known
    gating_label = "MUST" if must else "ALL"
    must_done = [i for i in gating if reqs[i].get("status") in DONE_STATUSES]
    all_done = [i for i in known if reqs[i].get("status") in DONE_STATUSES]
    started = [i for i in known if reqs[i].get("status") in STARTED_STATUSES]
    released = [i for i in known if reqs[i].get("status") == "RELEASED"]

    scenarios = wf.get("uat_scenarios") or []
    scen_missing = [s for s in scenarios if find_scenario(s) is None]

    if missing:
        status = "DRAFT"
    elif gating and len(must_done) == len(gating):
        if released and len(released) == len(known):
            status = "RELEASED"
        elif wf.get("uat_status") == "PASS":
            status = "UAT_PASSED"
        else:
            status = "IMPLEMENTED"
    elif started:
        status = "IN_PROGRESS"
    elif wf.get("status") == "DRAFT":
        status = "DRAFT"
    else:
        status = "READY"

    return {
        "derived_status": status,
        "requirement_total": len(ids),
        "requirement_missing": missing,
        "must_total": len(gating),
        "must_done": len(must_done),
        "gating_label": gating_label,
        "done_total": len(all_done),
        "scenario_total": len(scenarios),
        "scenario_missing": scen_missing,
    }


# ------------------------------------------------------------------ commands

def cmd_list(args):
    data = load_workflows()
    reqs = load_requirements()
    rows = []
    for pw_id, wf in sorted(data["workflows"].items()):
        d = derive(wf, reqs)
        if args.status and d["derived_status"] != args.status:
            continue
        if args.stage is not None and str(wf.get("stage")) != str(args.stage):
            continue
        if args.priority and wf.get("priority") != args.priority:
            continue
        rows.append((pw_id, wf, d))
    for pw_id, wf, d in rows:
        prog = f"{d['must_done']}/{d['must_total']} {d['gating_label']}"
        print(
            f"{pw_id:6s} stage={str(wf.get('stage')):5s} {str(wf.get('priority')):7s} "
            f"{d['derived_status']:12s} {prog:14s} {wf.get('title')}"
        )
    print(f"\n{len(rows)} matching")


def cmd_show(args):
    data = load_workflows()
    reqs = load_requirements()
    wf = get_wf(data, args.id)
    d = derive(wf, reqs)

    print(f"{wf['id']}  {wf['title']}")
    print(f"  status (derived) : {d['derived_status']}   (catalogue says: {wf.get('status')})")
    print(f"  stage / priority : {wf.get('stage')} / {wf.get('priority')}")
    print(f"  process map      : {wf.get('process_map')}")
    print(f"  process id       : {wf.get('process_id')}")
    print(f"  uat surface      : {wf.get('uat_surface')}   tenant: {wf.get('tenant_context')}")
    print(f"  depends on       : {', '.join(wf.get('depends_on') or []) or '(none)'}")
    print(f"  borrow source    : {wf.get('borrow_source')}")
    print(f"\n  goal: {' '.join((wf.get('goal') or '').split())}")
    print(f"\n  requirements ({d['must_done']}/{d['must_total']} {d['gating_label']} complete):")
    for rid in wf.get("requirements") or []:
        e = reqs.get(rid)
        if not e:
            print(f"    {rid:12s} -- NOT IN requirements.yaml")
            continue
        print(f"    {rid:12s} {str(e.get('priority')):7s} {str(e.get('status')):12s} {e.get('title')}")
    print("\n  uat scenarios:")
    for s in wf.get("uat_scenarios") or []:
        p = find_scenario(s)
        print(f"    {s:52s} {'ok' if p else 'MISSING'}")


def cmd_requirements(args):
    data = load_workflows()
    wf = get_wf(data, args.id)
    for rid in wf.get("requirements") or []:
        print(rid)


def cmd_validate(args):
    data = load_workflows()
    reqs = load_requirements()
    issues = []  # (severity, subject, message)

    claimed = {}
    for pw_id, wf in data["workflows"].items():
        if not PW_ID_RE.match(pw_id):
            issues.append(("MAJOR", pw_id, "workflow id does not match PW-nn"))
        if wf.get("id") != pw_id:
            issues.append(("MAJOR", pw_id, f"id field {wf.get('id')!r} does not match its key"))
        if wf.get("status") not in VALID_WF_STATUS:
            issues.append(("MAJOR", pw_id, f"unrecognised status {wf.get('status')!r}"))
        if wf.get("uat_surface") not in VALID_UAT_SURFACE:
            issues.append(("MAJOR", pw_id, f"unrecognised uat_surface {wf.get('uat_surface')!r}"))
        for field in ("title", "goal", "process_id", "process_map", "borrow_source"):
            if not wf.get(field):
                issues.append(("BLOCKER", pw_id, f"missing {field}"))

        pm = wf.get("process_map")
        if pm and not (REPO_ROOT / pm).exists():
            issues.append(("BLOCKER", pw_id, f"process map not found: {pm}"))

        ids = wf.get("requirements") or []
        if not ids:
            issues.append(("BLOCKER", pw_id, "workflow has no requirements"))
        for rid in ids:
            if rid in claimed and claimed[rid] != pw_id:
                issues.append(("BLOCKER", rid, f"claimed by both {claimed[rid]} and {pw_id}"))
            claimed[rid] = pw_id
            e = reqs.get(rid)
            if not e:
                issues.append(("BLOCKER", pw_id, f"requirement {rid} is not in requirements.yaml"))
                continue
            back = e.get("workflow")
            if back is None:
                issues.append(("MAJOR", rid, f"requirement has no workflow field (expected {pw_id})"))
            elif back != pw_id:
                issues.append(("BLOCKER", rid, f"requirement points at {back}, catalogue says {pw_id}"))

        if not (wf.get("uat_scenarios") or []):
            issues.append(("MAJOR", pw_id, "workflow has no uat_scenarios -- it cannot be signed off"))
        for s in wf.get("uat_scenarios") or []:
            if find_scenario(s) is None:
                issues.append(("MAJOR", pw_id, f"uat scenario file not found: {s}.yaml"))

        for dep in wf.get("depends_on") or []:
            if dep not in data["workflows"]:
                issues.append(("BLOCKER", pw_id, f"depends_on unknown workflow {dep}"))
            elif dep == pw_id:
                issues.append(("BLOCKER", pw_id, "workflow depends on itself"))

    # requirements that name a workflow the catalogue does not claim
    for rid, e in reqs.items():
        wid = e.get("workflow")
        if wid and claimed.get(rid) != wid:
            issues.append(("MAJOR", rid, f"names workflow {wid} but that workflow does not list it"))

    for sev, subj, msg in issues:
        print(f"{sev:8s} {subj:12s} {msg}")
    blockers = [i for i in issues if i[0] == "BLOCKER"]
    majors = [i for i in issues if i[0] == "MAJOR"]
    print()
    print(f"BLOCKER: {len(blockers)}  MAJOR: {len(majors)}  (workflows: {len(data['workflows'])}, "
          f"requirements claimed: {len(claimed)})")
    if blockers:
        print("FAIL")
        sys.exit(1)
    print("PASS" + (" (with issues -- see above)" if issues else ""))


def cmd_status(args):
    data = load_workflows()
    reqs = load_requirements()
    targets = [args.id] if args.id else sorted(data["workflows"])
    for pw_id in targets:
        wf = get_wf(data, pw_id)
        d = derive(wf, reqs)
        bar_done = d["must_done"]
        bar_total = max(d["must_total"], 1)
        filled = int(round(20 * bar_done / bar_total))
        bar = "#" * filled + "." * (20 - filled)
        print(f"{pw_id:6s} [{bar}] {bar_done}/{d['must_total']} {d['gating_label']:5s} "
              f"{d['derived_status']:12s} {wf.get('title')}")
        if d["requirement_missing"]:
            print(f"        not yet in requirements.yaml: {', '.join(d['requirement_missing'])}")
        if d["scenario_missing"]:
            print(f"        uat scenarios missing: {', '.join(d['scenario_missing'])}")


def cmd_uat_ready(args):
    """The gate. Exit 0 means: hand this workflow to WF-05."""
    data = load_workflows()
    reqs = load_requirements()
    wf = get_wf(data, args.id)
    d = derive(wf, reqs)
    blockers = []

    if d["requirement_missing"]:
        blockers.append(f"requirements not registered: {', '.join(d['requirement_missing'])}")
    ids = wf.get("requirements") or []
    has_must = any(reqs.get(i, {}).get("priority") == "MUST" for i in ids)
    for rid in ids:
        e = reqs.get(rid)
        if not e:
            continue
        gates = (e.get("priority") == "MUST") if has_must else True
        if gates and e.get("status") not in DONE_STATUSES:
            blockers.append(f"{rid} is {e.get('status')}, needs TESTED or RELEASED")
    if d["scenario_missing"]:
        blockers.append(f"uat scenario files missing: {', '.join(d['scenario_missing'])}")
    for dep in wf.get("depends_on") or []:
        dep_wf = data["workflows"].get(dep)
        if dep_wf:
            dd = derive(dep_wf, reqs)
            if dd["derived_status"] not in ("IMPLEMENTED", "UAT_PASSED", "RELEASED"):
                blockers.append(f"dependency {dep} is {dd['derived_status']}")

    print(f"{wf['id']}  {wf['title']}")
    print(f"  gating requirements ({d['gating_label']}) : {d['must_done']}/{d['must_total']}")
    print(f"  uat scenarios present      : {d['scenario_total'] - len(d['scenario_missing'])}"
          f"/{d['scenario_total']}")
    if blockers:
        print("\nNOT READY:")
        for b in blockers:
            print(f"  - {b}")
        sys.exit(1)

    print("\nREADY FOR UAT. Dispatch WF-05 with:")
    print(f"  run_id           : WF05-{wf['id'].lower()}-<YYYYMMDD>")
    print(f"  platform_workflow: {wf['id']}")
    print(f"  process_id       : {wf['process_id']}")
    print(f"  uat_surface      : {wf['uat_surface']}")
    print(f"  tenant_context   : {wf['tenant_context']}")
    print(f"  requirement_ids  : {', '.join(wf['requirements'])}")
    print("  scenarios        :")
    for s in wf["uat_scenarios"]:
        print(f"    - {find_scenario(s)}")
    sys.exit(0)


def cmd_next(args):
    """Workflows that can be started now: dependencies satisfied, not yet done."""
    data = load_workflows()
    reqs = load_requirements()
    out = []
    for pw_id, wf in sorted(data["workflows"].items()):
        d = derive(wf, reqs)
        if d["derived_status"] in ("UAT_PASSED", "RELEASED"):
            continue
        blocked_by = []
        for dep in wf.get("depends_on") or []:
            dd = derive(data["workflows"][dep], reqs)
            if dd["derived_status"] not in ("IMPLEMENTED", "UAT_PASSED", "RELEASED"):
                blocked_by.append(dep)
        if not blocked_by:
            out.append((pw_id, wf, d))
    for pw_id, wf, d in out:
        print(f"{pw_id:6s} {str(wf.get('priority')):7s} stage={str(wf.get('stage')):5s} "
              f"{d['derived_status']:12s} {wf.get('title')}")
    print(f"\n{len(out)} startable")


def cmd_render(args):
    data = load_workflows()
    reqs = load_requirements()
    export = {}
    for pw_id, wf in sorted(data["workflows"].items()):
        d = derive(wf, reqs)
        wf["status"] = d["derived_status"]
        wf["requirement_progress"] = f"{d['must_done']}/{d['must_total']} {d['gating_label']}"
        export[pw_id] = {
            "title": wf.get("title"),
            "status": d["derived_status"],
            "stage": wf.get("stage"),
            "priority": wf.get("priority"),
            "process_id": wf.get("process_id"),
            "process_map": wf.get("process_map"),
            "uat_surface": wf.get("uat_surface"),
            "tenant_context": wf.get("tenant_context"),
            "gating_rule": d["gating_label"],
            "gating_total": d["must_total"],
            "gating_done": d["must_done"],
            "requirements": wf.get("requirements"),
            "uat_scenarios": wf.get("uat_scenarios"),
            "scenario_missing": d["scenario_missing"],
            "depends_on": wf.get("depends_on"),
        }
    save_workflows(data)
    STATUS_EXPORT.parent.mkdir(parents=True, exist_ok=True)
    STATUS_EXPORT.write_text(
        yaml.dump(
            {
                "schema_version": "1.0",
                "generated_by": "tools/wfctl.py render -- do not hand-edit; edit docs/workflows.yaml",
                "last_updated": now_utc(),
                "workflows": export,
            },
            sort_keys=False, allow_unicode=True, width=100,
        ),
        encoding="utf-8",
    )
    print(f"refreshed {WF_FILE}")
    print(f"regenerated {STATUS_EXPORT} ({len(export)} workflows)")


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = p.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("list")
    sp.add_argument("--status")
    sp.add_argument("--stage")
    sp.add_argument("--priority")
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("show")
    sp.add_argument("id")
    sp.set_defaults(func=cmd_show)

    sp = sub.add_parser("requirements")
    sp.add_argument("id")
    sp.set_defaults(func=cmd_requirements)

    sub.add_parser("validate").set_defaults(func=cmd_validate)

    sp = sub.add_parser("status")
    sp.add_argument("id", nargs="?")
    sp.set_defaults(func=cmd_status)

    sp = sub.add_parser("uat-ready")
    sp.add_argument("id")
    sp.set_defaults(func=cmd_uat_ready)

    sub.add_parser("next").set_defaults(func=cmd_next)
    sub.add_parser("render").set_defaults(func=cmd_render)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # `wfctl list | head` closes the pipe early. Exit quietly rather than
        # printing a traceback an agent would read as a failure.
        try:
            sys.stdout.close()
        except Exception:
            pass
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
