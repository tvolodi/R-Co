import json
from pathlib import Path
import yaml


def summarize(path, is_yaml):
    if is_yaml:
        data = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}
    else:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    reqs = data.get("requirements", {}) or {}
    missing = []
    counts = {}
    for rid, entry in reqs.items():
        st = entry.get("status") if isinstance(entry, dict) else None
        counts[st] = counts.get(st, 0) + 1
        impl = entry.get("implemented_in") if isinstance(entry, dict) else None
        if (
            not isinstance(entry, dict)
            or "implemented_in" not in entry
            or not isinstance(impl, list)
            or not any(isinstance(x, str) and x.strip() for x in impl)
        ):
            missing.append(rid)
    return reqs, missing, counts

y_reqs, y_missing, y_counts = summarize("docs/status/requirement_status.yaml", True)
j_reqs, j_missing, j_counts = summarize("docs/status/requirement_status.json", False)

print("YAML_TOTAL", len(y_reqs))
print("YAML_STATUS_COUNTS", json.dumps(y_counts, sort_keys=True))
print("YAML_MISSING_COUNT", len(y_missing))
print("YAML_MISSING_IDS", ",".join(sorted(y_missing)))
print("JSON_TOTAL", len(j_reqs))
print("JSON_STATUS_COUNTS", json.dumps(j_counts, sort_keys=True))
print("JSON_MISSING_COUNT", len(j_missing))
print("JSON_MISSING_IDS", ",".join(sorted(j_missing)))

ys = set(y_reqs.keys())
js = set(j_reqs.keys())
print("IN_YAML_NOT_JSON_COUNT", len(ys - js))
print("IN_JSON_NOT_YAML_COUNT", len(js - ys))
