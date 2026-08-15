# Module: plc-03-cross-version-compatibility

**Requirement IDs:** PLC-03
**Run ID:** WF02-plc-batch-a-20260815 (Stage 15)
**Type:** Type E — compatibility-analysis design

---

## Module purpose

When a new version of an already-catalogued module is published (DRAFT → ACTIVE), the
platform compares the new version's declared SPC-01 interface against the **immediately
preceding ACTIVE version's** interface and returns a `COMPATIBILITY_WARNING` without blocking
publication. This informs the publisher that downstream tenants using the module may break on
upgrade, so they can communicate the change before it propagates.

---

## Compatibility rules

The comparison is one-directional: it analyses whether the **new version** introduces
breaking changes **relative to the previous version**. It does not block publication and does
not analyse forward compatibility (whether the previous version is compatible with the new
one — this is symmetric for removals but not for additions).

### Breaking changes (flagged)

| Change | Rule |
|---|---|
| **Required input added** | New version marks as `required: true` an input that was `required: false` or absent in the previous version |
| **Required output removed** | An output that was `required: true` in the previous version is absent or `required: false` in the new version |

### Non-breaking changes (not flagged)

| Change | Rule |
|---|---|
| Optional input added | New optional input not present in previous version — safe for callers |
| Optional output added | New optional output — callers not relying on it are unaffected |
| Required input removed | Removing an input is safe — callers may ignore the unused input |
| Optional output removed | Removing an optional output is safe |
| Required input made optional | Widening the contract — safe |
| Optional output made required | **Breaking** — callers relying on optional output will break |
| `json_schema` type changed | Flagged if the input/output was required in the previous version |

---

## Algorithm

```
computeCompatibilityWarning(newEntry, previousEntry) -> ?CompatibilityWarning:
    warnings = []

    // Check inputs
    for each input in newEntry.interface.inputs:
        prev = previousEntry.interface.inputs.findByName(input.name)
        if prev == null:
            if input.required:
                warnings.push("REQUIRED_INPUT_ADDED: " + input.name)
        else if input.required == true and (prev.required == false or prev.required == absent):
            warnings.push("REQUIRED_INPUT_ADDED: " + input.name)

    // Check outputs
    for each output in previousEntry.interface.outputs:
        curr = newEntry.interface.outputs.findByName(output.name)
        if curr == null:
            if output.required:
                warnings.push("REQUIRED_OUTPUT_REMOVED: " + output.name)
        else if output.required == true and curr.required == false:
            warnings.push("REQUIRED_OUTPUT_NOW_OPTIONAL: " + output.name)

    if warnings.length > 0:
        return CompatibilityWarning { changes: warnings }
    return null
```

Note: outputs are iterated in the **reverse** direction (previous version outputs → new
version lookup) to detect removals. Inputs are iterated forward (new version → previous
version lookup) to detect required-input additions.

---

## Data model

### `CompatibilityWarning` response object

```zig
pub const CompatibilityWarning = struct {
    module_id: []const u8,
    new_version: []const u8,
    previous_version: []const u8,
    breaking_changes: []const []const u8,  // array of human-readable change descriptions
};

pub const PublishModuleResult = struct {
    entry: ProcessModuleCatalogEntry,
    compatibility_warning: ?CompatibilityWarning,
};
```

### Database changes

No new tables. The `process_module_catalog` table (PLC-01) already stores `interface_schema`
as JSONB. The comparison is a read-only analytical operation between two existing rows.

A `module_version_history` view (optional, not required) could assist the query:

```sql
CREATE VIEW module_version_history AS
SELECT module_id, version, status, owning_tenant_id,
       interface_schema,
       ROW_NUMBER() OVER (
         PARTITION BY module_id, owning_tenant_id
         ORDER BY semver_sort(version) DESC
       ) AS version_rank
FROM process_module_catalog
WHERE status = 'ACTIVE';
```

---

## HTTP response shape

```
PUT /api/v1/modules/{module_id}/versions/{version}/publish
```

**Success (202 or 200):**

```json
{
  "type": "https://bpm.platform/errors/publish-success",
  "title": "Module published",
  "status": 200,
  "entry": {
    "module_id": "order-processing",
    "version": "1.1.0",
    "status": "ACTIVE",
    ...
  },
  "compatibility_warning": {
    "module_id": "order-processing",
    "new_version": "1.1.0",
    "previous_version": "1.0.0",
    "breaking_changes": [
      "REQUIRED_INPUT_ADDED: customer_region",
      "REQUIRED_OUTPUT_REMOVED: shipping_label"
    ]
  }
}
```

When there are no breaking changes, `compatibility_warning` is `null`.

---

## Interaction with PLC-02

PLC-02 runs **before** this check in the publication flow:

```
publishModule:
    1. PLC-02 gate: interface declared? → 422 if not
    2. PLC-03 check: compute compatibility vs. preceding ACTIVE → attach warning
    3. Set status = ACTIVE, persist
    4. Return result with warning
```

Steps 1 and 2 are sequential within the same transaction. If the PLC-02 gate fails,
publication does not proceed and PLC-03 is never invoked.

---

## Dependencies

- **PLC-01:** Catalog table and `publishModule` function.
- **PLC-02:** Interface declaration gate runs first.
- **SPC-01:** Interface structure (inputs/outputs arrays with `name`, `json_schema`, `required`).

---

## Open questions

All open questions are resolved (per ORCH handoff):
- **OQ-1 (predecessor selection):** Predecessor = highest ACTIVE version with semver strictly less than the new version (full semver comparison, not same-major-only). E.g., given `1.0.0`, `1.1.0`, `2.0.0`, `2.0.1` already ACTIVE, publishing `3.0.0` uses `2.0.1` as predecessor.
- **OQ-2 (null predecessor):** If the new version is the first ACTIVE version for this `module_id`, `computeCompatibilityWarning` returns `null` — no warning is produced and no error is raised.
- **OQ-3 (required flag default):** Absent `required` is treated as `false` (optional). The algorithm checks `input.required == true and (prev.required == false or prev.required == absent)` for inputs.
