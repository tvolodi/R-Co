import json, yaml, sys

with open("docs/status/requirement_status.json") as f:
    status = json.load(f)

missing = {
    "SIM-09": {"status": "RELEASED", "stage": 11, "priority": "MUST", "title": "Test result storage",
                "release_run": "WF02-stage11-sim05-08-rerun1-20260529", "released_at": "2026-05-29",
                "last_updated": "2026-05-29T12:24:56Z"},
    "SIM-10": {"status": "RELEASED", "stage": 11, "priority": "MUST", "title": "Failure diagnostics",
                "release_run": "WF02-stage11-sim05-08-rerun1-20260529", "released_at": "2026-05-29",
                "last_updated": "2026-05-29T12:24:56Z"},
    "SH-01": {"status": "RELEASED", "stage": "F1", "priority": "MUST", "title": "Authenticated shell",
               "release_run": "WF02-f1-shell", "released_at": "2026-05-27", "last_updated": "2026-05-27T00:00:00Z"},
    "SH-02": {"status": "RELEASED", "stage": "F1", "priority": "MUST", "title": "Navigation",
               "release_run": "WF02-f1-shell", "released_at": "2026-05-27", "last_updated": "2026-05-27T00:00:00Z"},
    "SH-03": {"status": "RELEASED", "stage": "F1", "priority": "MUST", "title": "Login page",
               "release_run": "WF02-f1-shell", "released_at": "2026-05-27", "last_updated": "2026-05-27T00:00:00Z"},
    "SH-04": {"status": "RELEASED", "stage": "F1", "priority": "MUST", "title": "Token storage",
               "release_run": "WF02-f1-shell", "released_at": "2026-05-27", "last_updated": "2026-05-27T00:00:00Z"},
    "SH-05": {"status": "RELEASED", "stage": "F1", "priority": "MUST", "title": "Session expiry",
               "release_run": "WF02-f1-shell", "released_at": "2026-05-27", "last_updated": "2026-05-27T00:00:00Z"},
    "SH-06": {"status": "RELEASED", "stage": "F1", "priority": "MUST", "title": "Role-aware routing",
               "release_run": "WF02-f1-shell", "released_at": "2026-05-27", "last_updated": "2026-05-27T00:00:00Z"},
    "SH-07": {"status": "RELEASED", "stage": "F1", "priority": "MUST", "title": "Global error boundary",
               "release_run": "WF02-f1-shell", "released_at": "2026-05-27", "last_updated": "2026-05-27T00:00:00Z"},
    "PD-UI-01": {"status": "RELEASED", "stage": "F2", "priority": "MUST", "title": "Definition list page",
                  "release_run": "WF02-f2-batch1", "released_at": "2026-05-28", "last_updated": "2026-05-28T00:00:00Z"},
    "PD-UI-02": {"status": "RELEASED", "stage": "F2", "priority": "MUST", "title": "Create definition",
                  "release_run": "WF02-f2-batch1", "released_at": "2026-05-28", "last_updated": "2026-05-28T00:00:00Z"},
    "PD-UI-03": {"status": "RELEASED", "stage": "F2", "priority": "MUST", "title": "Canvas",
                  "release_run": "WF02-f2-batch1", "released_at": "2026-05-28", "last_updated": "2026-05-28T00:00:00Z"},
    "PD-UI-04": {"status": "RELEASED", "stage": "F2", "priority": "MUST", "title": "Add / delete node",
                  "release_run": "WF02-f2-batch1", "released_at": "2026-05-28", "last_updated": "2026-05-28T00:00:00Z"},
    "PD-UI-05": {"status": "RELEASED", "stage": "F2", "priority": "MUST", "title": "Node property panel",
                  "release_run": "WF02-f2-batch1", "released_at": "2026-05-28", "last_updated": "2026-05-28T00:00:00Z"},
    "PD-UI-06": {"status": "RELEASED", "stage": "F2", "priority": "MUST", "title": "Add / delete edge",
                  "release_run": "WF02-f2-batch1", "released_at": "2026-05-28", "last_updated": "2026-05-28T00:00:00Z"},
    "PD-UI-07": {"status": "RELEASED", "stage": "F2", "priority": "MUST", "title": "CEL expression editor",
                  "release_run": "WF02-f2-batch2", "released_at": "2026-05-29", "last_updated": "2026-05-29T00:00:00Z"},
    "PD-UI-08": {"status": "RELEASED", "stage": "F2", "priority": "MUST", "title": "Save definition",
                  "release_run": "WF02-f2-batch2", "released_at": "2026-05-29", "last_updated": "2026-05-29T19:38:00Z"},
    "PD-UI-09": {"status": "RELEASED", "stage": "F2", "priority": "MUST", "title": "Validation feedback",
                  "release_run": "WF02-f2-batch2", "released_at": "2026-05-29", "last_updated": "2026-05-29T00:00:00Z"},
    "PD-UI-10": {"status": "RELEASED", "stage": "F2", "priority": "MUST", "title": "Version list",
                  "release_run": "WF02-f2-batch2", "released_at": "2026-05-29", "last_updated": "2026-05-29T00:00:00Z"},
    "PD-UI-11": {"status": "RELEASED", "stage": "F2", "priority": "MUST", "title": "Activate version",
                  "release_run": "WF02-f2-batch2", "released_at": "2026-05-29", "last_updated": "2026-05-29T00:00:00Z"},
    "PD-UI-12": {"status": "RELEASED", "stage": "F2", "priority": "MUST", "title": "Deprecate version",
                  "release_run": "WF02-f2-batch2", "released_at": "2026-05-29", "last_updated": "2026-05-29T00:00:00Z"},
    "PD-UI-13": {"status": "RELEASED", "stage": "F2", "priority": "SHOULD", "title": "Definition export",
                  "release_run": "WF02-f2-batch3", "released_at": "2026-05-29", "last_updated": "2026-05-29T00:00:00Z"},
    "PD-UI-14": {"status": "RELEASED", "stage": "F2", "priority": "SHOULD", "title": "Definition import",
                  "release_run": "WF02-f2-batch3", "released_at": "2026-05-29", "last_updated": "2026-05-29T00:00:00Z"},
    "PD-UI-15": {"status": "RELEASED", "stage": "F2", "priority": "MUST", "title": "Read-only canvas",
                  "release_run": "WF02-f2-batch3", "released_at": "2026-05-29", "last_updated": "2026-05-29T00:00:00Z"},
    "PD-UI-16": {"status": "RELEASED", "stage": "F2", "priority": "SHOULD", "title": "Diff view",
                  "release_run": "WF02-f2b-shoulds-20260529", "released_at": "2026-05-29", "last_updated": "2026-05-29T19:38:00Z"},
    "PD-UI-17": {"status": "RELEASED", "stage": "F2", "priority": "SHOULD", "title": "Canvas keyboard shortcuts",
                  "release_run": "WF02-f2b-shoulds-20260529", "released_at": "2026-05-29", "last_updated": "2026-05-29T19:38:00Z"},
    "PD-UI-18": {"status": "RELEASED", "stage": "F2", "priority": "COULD", "title": "Auto-layout",
                  "release_run": "WF02-f2b-shoulds-20260529", "released_at": "2026-05-29", "last_updated": "2026-05-29T19:38:00Z"},
    "PD-UI-19": {"status": "RELEASED", "stage": "F2", "priority": "COULD", "title": "Mini-map",
                  "release_run": "WF02-f2b-shoulds-20260529", "released_at": "2026-05-29", "last_updated": "2026-05-29T19:38:00Z"},
    "IN-UI-01": {"status": "TESTED", "stage": "F3", "priority": "MUST", "title": "Instance board",
                  "last_updated": "2026-05-29T00:00:00Z"},
    "IN-UI-02": {"status": "TESTED", "stage": "F3", "priority": "MUST", "title": "Instance filters",
                  "last_updated": "2026-05-29T00:00:00Z"},
    "IN-UI-03": {"status": "TESTED", "stage": "F3", "priority": "MUST", "title": "Start instance",
                  "last_updated": "2026-05-29T00:00:00Z"},
    "IN-UI-04": {"status": "TESTED", "stage": "F3", "priority": "MUST", "title": "Instance detail view",
                  "last_updated": "2026-05-29T00:00:00Z"},
    "IN-UI-05": {"status": "IMPLEMENTED", "stage": "F3", "priority": "MUST", "title": "Event history tab",
                  "last_updated": "2026-05-29T00:00:00Z"},
    "IN-UI-06": {"status": "IMPLEMENTED", "stage": "F3", "priority": "MUST", "title": "Timeline tab",
                  "last_updated": "2026-05-29T00:00:00Z"},
    "IN-UI-07": {"status": "IMPLEMENTED", "stage": "F3", "priority": "MUST", "title": "Cancel instance",
                  "last_updated": "2026-05-29T00:00:00Z"},
    "IN-UI-08": {"status": "PENDING", "stage": "F3", "priority": "SHOULD", "title": "Auto-refresh",
                  "last_updated": "2026-05-29T00:00:00Z"},
    "IN-UI-09": {"status": "PENDING", "stage": "F3", "priority": "SHOULD", "title": "Active token visualisation",
                  "last_updated": "2026-05-29T00:00:00Z"},
    "IN-UI-10": {"status": "PENDING", "stage": "F3", "priority": "SHOULD", "title": "History scrubber",
                  "last_updated": "2026-05-29T00:00:00Z"},
}

for k, v in missing.items():
    status["requirements"][k] = v

status["last_updated"] = "2026-05-29T20:00:00Z"
status["total_requirements"] = len(status["requirements"])

with open("docs/status/requirement_status.yaml", "w", encoding="utf-8") as f:
    yaml.dump(status, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

by_status = {}
for v in status["requirements"].values():
    s = v.get("status", "UNKNOWN")
    by_status[s] = by_status.get(s, 0) + 1

print(f"Total requirements: {len(status['requirements'])}")
for s, c in sorted(by_status.items()):
    print(f"  {s}: {c}")
print("Written: docs/status/requirement_status.yaml")
