# Module: plc-02-catalog-publication-requires-interface

**Requirement IDs:** PLC-02
**Run ID:** WF02-plc-batch-a-20260815 (Stage 15)
**Type:** Type E — policy-gate design

---

## Module purpose

Enforces that a process module may only transition from DRAFT → ACTIVE (i.e., be published to
the catalog) if its designated entry point exposes a fully declared SPC-01 interface. The
interface acts as the module's public contract; a module without one cannot be resolved via
`module_ref` because callers have no machine-readable description of required inputs and expected
outputs.

---

## Context and relationship to PLC-01

PLC-01 defines the catalog table, the `registerModule` and `publishModule` entry points, and
the `interface_schema` column. PLC-02 specifies the **validation logic inside `publishModule`**
that gates the DRAFT → ACTIVE transition.

This design is intentionally narrow: it does not re-specify the catalog schema, error types,
or resolution logic — those are PLC-01's scope.

---

## Policy rule

```
publishModule(module_id, version, actor_id):
    entry = loadCatalogEntry(module_id, version)
    if entry.interface_schema == {} or entry.interface_schema is absent:
        return InterfaceNotDeclared  // HTTP 422
    if not isProcessDesignerOrAbove(actor_id):
        return InsufficientPermissions  // HTTP 403
    entry.status = ACTIVE
    entry.updated_at = now()
    return entry
```

The `interface_schema` being an empty JSON object `{}` is **not** a declared interface — it
represents the absence of a declaration. A declared interface must have at least one of
`inputs` or `outputs` arrays (possibly empty arrays, which is valid — SPC-01 AC: "empty
array means the child starts with an empty initial variable map").

---

## SPC-01 interface shape (reference)

For reference, the SPC-01 `interface` object on a SUB_PROCESS node:

```json
{
  "interface": {
    "inputs": [
      { "name": "customer_id", "json_schema": { "type": "string" }, "required": true },
      { "name": "amount",     "json_schema": { "type": "number" }, "required": false }
    ],
    "outputs": [
      { "name": "order_id", "json_schema": { "type": "string" }, "required": true }
    ]
  }
}
```

The `interface_schema` stored in `process_module_catalog` is the **same structure** — the
platform stores the node's `interface` object directly as the catalog entry's contract. The
catalog entry's `owning_definition_id` points to the definition that **defines** the entry
point node; that node carries the `interface` attribute which is copied into the catalog entry
on registration.

---

## Validation of "fully declared"

For PLC-02, an interface is **fully declared** if:

1. `interface.inputs` is present and is an array (may be empty).
2. `interface.outputs` is present and is an array (may be empty).
3. Each element in `inputs` has a non-empty `name` and a `json_schema` that is a valid JSON
   Schema object (validated separately by SPC-02 at definition-creation time).
4. Each element in `outputs` has a non-empty `name` and a `json_schema` that is a valid JSON
   Schema object.

Note: SPC-02 already validates the schema well-formedness at the point the **definition** is
created or updated. By the time `publishModule` is called, the schemas are already known to be
well-formed. PLC-02 does not re-validate the JSON Schema internals — it only checks that the
`interface` object is present and non-empty.

---

## HTTP response on InterfaceNotDeclared

```json
{
  "type": "https://bpm.platform/errors/module-interface-not-declared",
  "title": "Module publication requires a declared interface",
  "status": 422,
  "code": "INTERFACE_NOT_DECLARED",
  "detail": "Module 'order-processing' version '1.0.0' may not be published because its entry point has no declared SPC-01 interface. Add an interface to the SUB_PROCESS entry point node and try again.",
  "module_id": "order-processing",
  "version": "1.0.0",
  "trace_id": "<trace-id>"
}
```

---

## Effects on other requirements

- **PLC-01** `publishModule` service function must call this gate before setting `status = ACTIVE`.
- **PLC-03** compatibility check runs **after** PLC-02 gate passes (the new version is already
  ACTIVE before the comparison against the previous version is made).
- **PIN-01** resolution only ever sees ACTIVE entries, so by construction every resolvable module
  has passed this gate.
- **SOL-01** pack export only inlines modules that are ACTIVE, so this gate is a prerequisite
  for distribution.

---

## Edge cases

| Case | Expected behaviour |
|---|---|
| `interface_schema = {}` | HTTP 422 `InterfaceNotDeclared` |
| `interface_schema` key absent | HTTP 422 `InterfaceNotDeclared` |
| `interface.inputs = []`, `interface.outputs = []` | Valid — empty arrays are valid declared interfaces |
| `interface.inputs = [{name: "", ...}]` | SPC-02 would have rejected this at definition-creation time |
| Attempting to publish ACTIVE again | HTTP 409 `ModuleAlreadyActive` (handled by PLC-01) |
| `owning_definition_id` points to a deleted definition | Undefined — treated as a data integrity issue; `publishModule` should return 422 with `ModuleDefinitionNotFound` |

---

## Dependencies

- SPC-01 (interface contract definition)
- SPC-02 (schema well-formedness validation at definition-creation time)
- PLC-01 (catalog entry shape, `publishModule` function)

---

## Open questions

None — the requirement text and SPC-01 / SPC-02 together provide sufficient specificity.
