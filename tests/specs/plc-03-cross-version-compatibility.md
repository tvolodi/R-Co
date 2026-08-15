# Test Spec: PLC-03 — Cross-version compatibility check on publish

**Requirement:** PLC-03 — verbatim requirement text:
> When a new version of an already-cataloged module is published, the platform SHOULD compare
> its declared interface against the immediately preceding ACTIVE version and flag — without
> blocking — breaking changes: an input that was optional and is now required, or an output that
> was previously required and has been removed.

**Priority:** SHOULD
**Test layer:** integration
**Scored test-tier (test_developer_guide.md §2.1):** DB schema (2, new version published against
prior ACTIVE) + cross-module (1, `findPredecessorActive` + `computeCompatibilityWarning`) = 3
points → unit + integration.

## Test Cases

### TC-PLC-03-01: publish new version with no predecessor produces no warning
**Given:** a module with no prior ACTIVE version  
**When:** the first version is published  
**Then:** `PublishModuleResult.compatibility_warning` is `null`  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-03 — no predecessor means no comparison needed

### TC-PLC-03-02: publish new version with prior ACTIVE version returns warning
**Given:** a module at ACTIVE "1.0.0" with interface `{"inputs": [{"name": "x", "type": "string"}]}`  
**When:** version "1.1.0" is published with `interface_schema` containing `"required":true`  
**Then:** `compatibility_warning` is returned with `previous_version: "1.0.0"` and `new_version: "1.1.0"`  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-03 — breaking change flagged without blocking

### TC-PLC-03-03: compatibility_warning does not block publication
**Given:** a module at ACTIVE "1.0.0"  
**When:** version "2.0.0" is published with an incompatible interface  
**Then:** the call succeeds (no error) AND a `compatibility_warning` is present in the result  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-03 — SHOULD, not MUST; warning without blocking

### TC-PLC-03-04: predecessor is the immediately prior semver (highest ACTIVE below current)
**Given:** ACTIVE versions "1.0.0" and "2.0.0"; registering "3.0.0"  
**When:** "3.0.0" is published  
**Then:** `compatibility_warning.previous_version` refers to "2.0.0" (the highest ACTIVE below "3.0.0")  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-03 — immediately preceding ACTIVE version used for comparison

### TC-PLC-03-05: module without interface_schema comparison still returns no warning
**Given:** ACTIVE "1.0.0" with no interface  
**When:** "1.1.0" (also no interface) is published  
**Then:** `compatibility_warning` is `null` (no change to compare)  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-03 — both absent interface means no change detected
