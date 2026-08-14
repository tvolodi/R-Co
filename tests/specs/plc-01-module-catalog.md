# Test Spec: PLC-01 — Process module catalog

**Requirement:** PLC-01 — verbatim requirement text:
> **Extends:** the REPO-07 service catalog pattern, applied to reusable sub-process definitions instead
> of external services.
>
> The platform SHALL maintain a process module catalog registering reusable sub-process definitions
> with: `module_id` (stable name, unique per publishing tenant), `version` (semver string),
> `owning_definition_id` (the definition this version resolves to), `interface_schema` (the SPC-01
> contract declared at the module's entry point), `exportable` (boolean, default true — governs
> whether SOL-01 may inline this module's content into a solution pack), and `status` (DRAFT |
> ACTIVE | DEPRECATED). A SUB_PROCESS node MAY reference a catalog entry via `module_ref:
> {module_id, version_constraint}` instead of a tenant-local `child_definition_id`.

**Priority:** SHOULD
**Test layer:** integration
**Scored test-tier (test_developer_guide.md §2.1):** DB schema (2, `process_module_catalog`
table) + tenant isolation (2, per-tenant `owning_tenant_id` + share grants) = 4 points → unit +
integration.

## Test Cases

### TC-PLC-01-01: register a new module version in DRAFT status
**Given:** a tenant with a valid definition UUID  
**When:** `registerModule` is called with `module_id`, semver `version`, and an empty interface schema  
**Then:** the entry is created with status DRAFT and visible only to the owning tenant  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-01 — catalog entry created with correct fields

### TC-PLC-01-02: registerModule rejects duplicate (module_id, version)
**Given:** a module version already exists in the catalog  
**When:** `registerModule` is called with the same `module_id` and `version`  
**Then:** `DuplicateModuleVersion` error is returned and no new row is inserted  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-01 — duplicate rejected

### TC-PLC-01-03: registerModule rejects empty module_id
**Given:** a valid tenant context  
**When:** `registerModule` is called with an empty `module_id` string  
**Then:** `UnresolvedModuleRef` error is returned  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-01 — validation of required fields

### TC-PLC-01-04: registerModule rejects empty version
**Given:** a valid tenant context  
**When:** `registerModule` is called with a non-empty `module_id` but empty `version` string  
**Then:** `InvalidVersionConstraint` error is returned  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-01 — validation of required fields

### TC-PLC-01-05: resolveModuleRef resolves own tenant's ACTIVE module
**Given:** tenant A owns an ACTIVE module version "1.0.0"  
**When:** `resolveModuleRef` is called with `module_id` and version constraint `*` for tenant A  
**Then:** resolution succeeds and the entry for "1.0.0" is returned  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-01 AC1 — resolution of highest ACTIVE version

### TC-PLC-01-06: resolveModuleRef returns unresolved when no matching version
**Given:** tenant A has an ACTIVE module at "1.0.0" only  
**When:** `resolveModuleRef` is called with version constraint `>=2.0.0`  
**Then:** resolution returns `{resolved: false, error_code: "UNRESOLVED_MODULE_REF"}`  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-01 AC2 — no ACTIVE version satisfies constraint

### TC-PLC-01-07: resolveModuleRef prefers highest semver when multiple ACTIVE
**Given:** tenant A has ACTIVE versions "1.0.0", "1.1.0", and "2.0.0"  
**When:** `resolveModuleRef` is called with version constraint `*`  
**Then:** resolution returns "2.0.0" (the highest semver)  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-01 — highest ACTIVE version satisfying constraint

### TC-PLC-01-08: module_id is globally unique (not per-tenant)
**Given:** tenant A attempts to register module_id = "shared-module"  
**When:** tenant B then attempts to register the same module_id = "shared-module"  
**Then:** the second registration fails with `DuplicateModuleVersion` (unique index across tenants)  
**Layer:** integration  
**Acceptance criterion mapped:** PLC-01 — `module_id` globally unique per publishing tenant
