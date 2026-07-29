> **Extends:** PD-08, from the process graph to the non-graph versioned artefacts an instance depends on.

> The platform SHALL enumerate and resolve every versioned reference in the definition snapshot at instance start: service catalog references on SERVICE_TASK nodes (REPO-07, SVC-01), the definition's `variable_schema` version, and `module_ref` semver ranges on SUB_PROCESS nodes (PLC-01). Each reference resolves to an entry `{kind, ref, resolved_id, version, source}` with `kind` in `catalog_entry`, `variable_schema`, `module` and `source` in `resolved`, `override`, `inherited`. Resolution completes before the instance row is written.

**Acceptance Criteria:**
- GIVEN a SERVICE_TASK reference that names no catalog entry with an active version, WHEN the instance is started, THEN the platform returns HTTP 422 `UnresolvedCatalogRef` naming the node and the reference, and writes no instance row.
- GIVEN a `module_ref` semver range matching no published module version, WHEN the instance is started, THEN the platform returns HTTP 422 `UnresolvedModuleRef` naming the node, the range and the versions available.
- GIVEN initial variables that violate the resolved `variable_schema` version, WHEN the instance is started, THEN the platform returns HTTP 422 `VariableSchemaViolation` listing each failing field.
- GIVEN `pin_overrides` naming a version that does not exist, WHEN the instance is started, THEN the platform returns HTTP 422 `UnresolvedPinOverride` and writes no partial pin set.
- `pinned_versions[]` is ordered by `kind` then `ref`, so two starts of the same definition against the same catalog produce byte-identical payloads.

**See:** PD-08, REPO-07, SVC-01, PLC-01, PIN-02, PIN-03
