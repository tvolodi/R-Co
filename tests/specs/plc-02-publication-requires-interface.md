# Test Spec: PLC-02 — Catalog entry publication requires a declared interface

**Requirement:** PLC-02 — verbatim requirement text:
> A process module MAY be published to the catalog (status DRAFT → ACTIVE) only if the
> SUB_PROCESS entry point it exposes has a fully declared SPC-01 interface. A module without
> a declared interface cannot be published as a catalog entry; it remains usable only as an
> ordinary tenant-local sub-process via direct `child_definition_id`.

**Priority:** SHOULD
**Test layer:** integration
**Scored test-tier (test_developer_guide.md §2.1):** DB schema (2, `process_module_catalog.status`
transition) + cross-module (1, calls `interfaceDeclared()`) = 3 points → unit + integration.

## Test Cases

### TC-PLC-02-01: publish succeeds when interface schema declares inputs
**Given:** a DRAFT module with `interface_schema = {"inputs": [{"name": "param1", "type": "string"}]}`  
**When:** `publishModule` is called  
**Then:** publication succeeds, status transitions to ACTIVE, and the entry is resolvable via `resolveModuleRef`  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-02 AC2 — publication with declared interface succeeds

### TC-PLC-02-02: publish succeeds when interface schema declares outputs
**Given:** a DRAFT module with `interface_schema = {"outputs": [{"name": "result", "type": "string"}]}`  
**When:** `publishModule` is called  
**Then:** publication succeeds and status transitions to ACTIVE  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-02 AC2 — publication with declared interface succeeds

### TC-PLC-02-03: publish fails when interface schema is empty object `{}`
**Given:** a DRAFT module with `interface_schema = {}` (empty object, no declared interface)  
**When:** `publishModule` is called  
**Then:** `InterfaceNotDeclared` error is returned and status remains DRAFT  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-02 AC1 — publication without interface rejected

### TC-PLC-02-04: publish fails when interface schema is absent (empty string / "{}")
**Given:** a DRAFT module registered with `interface_schema_json = "{}"`  
**When:** `publishModule` is called  
**Then:** `InterfaceNotDeclared` error is returned  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-02 AC1 — empty schema rejected at publish time

### TC-PLC-02-05: publish fails when module is already ACTIVE
**Given:** an ACTIVE module  
**When:** `publishModule` is called a second time  
**Then:** `ModuleAlreadyActive` error is returned  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-02 — idempotent publish protection

### TC-PLC-02-06: publish fails when module does not exist
**Given:** no module with the given `module_id` and `version` exists  
**When:** `publishModule` is called  
**Then:** `ModuleNotFound` error is returned  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-02 — pre-condition check
