# fn:update-requirement-status

**Category:** REQ  
**Used by:** `DOC-UPDATER`, `RELEASE-VALIDATOR`  
**Calls:** —

```
INPUT: requirement_id, new_status, optional metadata (implemented_in, test_ids, released_in)
1. Read docs/status/requirement_status.yaml
2. Find entry for requirement_id (create if absent with status = DRAFT)
3. Validate transition is legal:
   DRAFT → VALIDATED → DESIGNED → IMPLEMENTED → TESTED → RELEASED
   (Only forward transitions allowed; backward only via explicit ORCH escalation)
4. Update the entry fields
5. Set last_updated = now (ISO8601 UTC)
6. Write docs/status/requirement_status.yaml  ← YAML format required
7. Return updated entry
```

```python
import yaml, datetime

with open("docs/status/requirement_status.yaml") as f:
    status = yaml.safe_load(f)

req = status["requirements"].setdefault(requirement_id, {"status": "DRAFT"})
req["status"] = new_status
req["last_updated"] = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
# merge any additional metadata fields passed as input

with open("docs/status/requirement_status.yaml", "w") as f:
    yaml.dump(status, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
```

**⛔ Do NOT write to `requirement_status.json`.** The canonical file is `requirement_status.yaml`.
