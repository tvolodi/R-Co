import json
from pathlib import Path
import yaml

updates = {
    "SIM-09": [
        "src/simulation/scenario_runner.zig",
        "src/api/routes/simulation_test.zig",
    ],
    "SIM-10": [
        "src/simulation/scenario_runner.zig",
        "src/simulation/types.zig",
        "src/api/routes/simulation_test.zig",
    ],
    "SH-01": ["web/src/components/layout/AppShell.tsx"],
    "SH-02": ["web/src/components/layout/AppShell.tsx"],
    "SH-03": ["web/src/pages/LoginPage.tsx"],
    "SH-04": ["web/src/auth/tokenUtils.ts", "web/src/auth/AuthProvider.tsx"],
    "SH-05": ["web/src/auth/tokenUtils.ts", "web/src/auth/OidcManager.ts"],
    "SH-06": ["web/src/router.tsx", "web/src/auth/ProtectedRoute.tsx"],
    "SH-07": ["web/src/components/layout/ErrorBoundary.tsx"],
    "PD-UI-01": ["web/src/pages/definitions/DefinitionListPage.tsx"],
    "PD-UI-02": ["web/src/pages/definitions/DefinitionListPage.tsx", "web/src/pages/definitions/DefinitionEditorPage.tsx"],
    "PD-UI-03": ["web/src/components/canvas/ProcessCanvas.tsx"],
    "PD-UI-04": ["web/src/components/canvas/ProcessCanvas.tsx", "web/src/components/canvas/NodePalette.tsx"],
    "PD-UI-05": ["web/src/components/canvas/PropertyPanel.tsx"],
    "PD-UI-06": ["web/src/components/canvas/ProcessCanvas.tsx", "web/src/components/canvas/edges/ConditionEdge.tsx"],
    "PD-UI-07": ["web/src/components/canvas/CelExpressionEditor.tsx"],
    "PD-UI-08": ["web/src/pages/definitions/DefinitionEditorPage.tsx", "web/src/api/definitions.ts"],
    "PD-UI-09": ["web/src/components/canvas/ValidationSummaryBar.tsx"],
    "PD-UI-10": ["web/src/pages/definitions/DefinitionListPage.tsx"],
    "PD-UI-11": ["web/src/pages/definitions/DefinitionListPage.tsx"],
    "PD-UI-12": ["web/src/pages/definitions/DefinitionListPage.tsx"],
    "PD-UI-13": ["web/src/pages/definitions/DefinitionListPage.tsx", "web/src/api/definitions.ts"],
    "PD-UI-14": ["web/src/pages/definitions/DefinitionListPage.tsx", "web/src/api/definitions.ts"],
    "PD-UI-15": ["web/src/pages/definitions/DefinitionEditorPage.tsx", "web/src/components/canvas/ProcessCanvas.tsx"],
    "PD-UI-16": ["web/src/components/ui/JsonDiffView.tsx"],
    "PD-UI-17": ["web/src/components/canvas/ProcessCanvas.tsx"],
    "PD-UI-18": ["web/src/components/canvas/ProcessCanvas.tsx"],
    "PD-UI-19": ["web/src/components/canvas/ProcessCanvas.tsx"],
    "IN-UI-09": ["web/src/components/instances/ProcessGraphWithTokens.tsx"],
    "IN-UI-10": ["web/src/components/instances/HistoryScrubber.tsx"],
}

yaml_path = Path("docs/status/requirement_status.yaml")
json_path = Path("docs/status/requirement_status.json")

yaml_data = yaml.safe_load(yaml_path.read_text(encoding="utf-8")) or {}
json_data = json.loads(json_path.read_text(encoding="utf-8"))

for label, data in (("YAML", yaml_data), ("JSON", json_data)):
    reqs = data.get("requirements", {})
    missing_ids = [rid for rid in updates if rid not in reqs]
    if missing_ids:
        raise SystemExit(f"{label}: missing requirement IDs: {', '.join(missing_ids)}")
    for rid, paths in updates.items():
        entry = reqs[rid]
        if not isinstance(entry, dict):
            raise SystemExit(f"{label}: requirement {rid} is not an object")
        entry["implemented_in"] = list(paths)

yaml_path.write_text(yaml.safe_dump(yaml_data, sort_keys=False, allow_unicode=False), encoding="utf-8")
json_path.write_text(json.dumps(json_data, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")

reqs = yaml_data.get("requirements", {})
missing_implemented = []
status_counts = {}
for rid, entry in reqs.items():
    st = entry.get("status") if isinstance(entry, dict) else None
    status_counts[st] = status_counts.get(st, 0) + 1
    impl = entry.get("implemented_in") if isinstance(entry, dict) else None
    if (
        not isinstance(entry, dict)
        or "implemented_in" not in entry
        or not isinstance(impl, list)
        or not any(isinstance(x, str) and x.strip() for x in impl)
    ):
        missing_implemented.append(rid)

print("UPDATED_IDS", len(updates))
print("TOTAL_REGISTERED", len(reqs))
print("COUNT_BY_STATUS", json.dumps(status_counts, sort_keys=True))
print("MISSING_IMPLEMENTED_IN_COUNT", len(missing_implemented))
print("MISSING_IMPLEMENTED_IN_IDS", ",".join(missing_implemented))
