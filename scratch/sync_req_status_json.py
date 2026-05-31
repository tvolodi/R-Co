import json
from pathlib import Path
import yaml

yaml_path = Path("docs/status/requirement_status.yaml")
json_path = Path("docs/status/requirement_status.json")

data = yaml.safe_load(yaml_path.read_text(encoding="utf-8")) or {}

out = {
    "schema_version": data.get("schema_version"),
    "last_updated": data.get("last_updated"),
    "requirements": data.get("requirements", {}),
}

json_path.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

# Verification block

y_reqs = data.get("requirements", {}) or {}
j_data = json.loads(json_path.read_text(encoding="utf-8"))
j_reqs = j_data.get("requirements", {}) or {}

def status_counts(reqs):
    c = {}
    for _rid, entry in reqs.items():
        st = entry.get("status") if isinstance(entry, dict) else None
        c[st] = c.get(st, 0) + 1
    return c

missing_impl_json = []
for rid, entry in j_reqs.items():
    impl = entry.get("implemented_in") if isinstance(entry, dict) else None
    if (
        not isinstance(entry, dict)
        or "implemented_in" not in entry
        or not isinstance(impl, list)
        or not any(isinstance(x, str) and x.strip() for x in impl)
    ):
        missing_impl_json.append(rid)

ys = set(y_reqs.keys())
js = set(j_reqs.keys())

print("YAML_TOTAL", len(y_reqs))
print("YAML_STATUS_COUNTS", json.dumps(status_counts(y_reqs), sort_keys=True))
print("JSON_TOTAL", len(j_reqs))
print("JSON_STATUS_COUNTS", json.dumps(status_counts(j_reqs), sort_keys=True))
print("IDS_MISSING_JSON_FROM_YAML", ",".join(sorted(ys - js)))
print("IDS_MISSING_YAML_FROM_JSON", ",".join(sorted(js - ys)))
print("JSON_MISSING_IMPLEMENTED_IN_COUNT", len(missing_impl_json))
print("JSON_MISSING_IMPLEMENTED_IN_IDS", ",".join(sorted(missing_impl_json)))
