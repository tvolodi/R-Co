# Module: plc-01-process-module-catalog

**Requirement IDs:** PLC-01
**Run ID:** WF02-plc-batch-a-20260815 (Stage 15)
**Type:** Type E — novel cross-cutting design

---

## Module purpose

Maintains a process module catalog — a versioned registry of reusable sub-process definitions
publishable across tenants. A `SUB_PROCESS` node in a parent definition may reference a catalog
entry via `module_ref: {module_id, version_constraint}` instead of a tenant-local
`child_definition_id`. Resolution is tenant-scoped: only ACTIVE versions visible to the
resolving tenant are considered.

---

## Data model

### Table: `process_module_catalog`

Canonical home: `process_module_catalog` in the global registry schema (same scope as `service_catalog`).

| Column | Type | Constraints | Description |
|---|---|---|---|
| `module_id` | `VARCHAR(255)` | `NOT NULL` | Stable name, unique per owning tenant |
| `version` | `VARCHAR(32)` | `NOT NULL` | Semver string (e.g. `1.2.0`) |
| `owning_tenant_id` | `UUID` | `NOT NULL` | Tenant that owns and can version this module |
| `owning_definition_id` | `UUID` | `NOT NULL` | The concrete definition this version resolves to |
| `interface_schema` | `JSONB` | `NOT NULL DEFAULT '{}'` | SPC-01 contract; mirrors `interface` on a SUB_PROCESS node |
| `exportable` | `BOOLEAN` | `NOT NULL DEFAULT TRUE` | Governs SOL-01 pack export inlining |
| `status` | `VARCHAR(32)` | `NOT NULL CHECK (status IN ('DRAFT', 'ACTIVE', 'DEPRECATED'))` | Lifecycle state |
| `created_at` | `TIMESTAMPTZ` | `NOT NULL DEFAULT CURRENT_TIMESTAMP` | |
| `updated_at` | `TIMESTAMPTZ` | `NOT NULL DEFAULT CURRENT_TIMESTAMP` | |

**Primary key:** `UNIQUE (module_id, version)` — a `module_id` may have multiple versions.

### Table: `process_module_catalog_share`

Grants cross-tenant visibility. One row per `(granting_tenant_id, module_id, receiving_tenant_id)`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| `grant_id` | `UUID` | `PRIMARY KEY DEFAULT gen_random_uuid()` | |
| `granting_tenant_id` | `UUID` | `NOT NULL` | Publishing tenant |
| `module_id` | `VARCHAR(255)` | `NOT NULL` | Module being shared |
| `receiving_tenant_id` | `UUID` | `NOT NULL` | Subscriber tenant |
| `granted_at` | `TIMESTAMPTZ` | `NOT NULL DEFAULT CURRENT_TIMESTAMP` | |
| `granted_by` | `UUID` | `NOT NULL` | Platform admin who authorised |

**Unique constraint:** `UNIQUE (granting_tenant_id, module_id, receiving_tenant_id)`.

---

## Public interface

### Zig types

```zig
pub const ModuleStatus = enum { draft, active, deprecated };

pub const ProcessModuleCatalogEntry = struct {
    module_id: []const u8,
    version: []const u8,
    owning_tenant_id: []const u8,
    owning_definition_id: []const u8,
    interface_schema: std.json.Value,
    exportable: bool,
    status: ModuleStatus,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const ModuleRef = struct {
    module_id: []const u8,
    version_constraint: []const u8,
};

pub const ModuleRefResolution = struct {
    resolved: bool,
    entry: ?ProcessModuleCatalogEntry,
    error_code: ?[]const u8,
};
```

### Service functions

```zig
pub fn registerModule(allocator, tx, input) ModuleCatalogError!ProcessModuleCatalogEntry;
pub fn publishModule(allocator, tx, module_id, version, actor_id) ModuleCatalogError!ProcessModuleCatalogEntry;
pub fn resolveModuleRef(allocator, tx, module_ref, requesting_tenant_id) ModuleCatalogError!ModuleRefResolution;
pub fn grantModuleVisibility(allocator, tx, input) ModuleCatalogError!void;
pub fn revokeModuleVisibility(allocator, tx, grant_id, actor_id) ModuleCatalogError!void;
pub fn listVisibleModules(allocator, tx, requesting_tenant_id, pagination) ModuleCatalogError!Page(ProcessModuleCatalogEntry);
```

### ModuleCatalogError variants

```zig
pub const ModuleCatalogError = error{
    DuplicateModuleVersion,    // 409
    ModuleNotFound,            // 404
    UnresolvedModuleRef,       // 422
    InterfaceNotDeclared,       // 422
    SharingGrantNotFound,      // 404
    SharingGrantAlreadyExists,  // 409
    InsufficientPermissions,   // 403
    InvalidVersionConstraint,  // 422
};
```

---

## Data flow

```
[Definition Author]
       │  POST /api/v1/modules  (registerModule)
       ▼
[process_module_catalog]  status=DRAFT
       │
       │  PUT /api/v1/modules/{id}/publish  (publishModule)
       ▼
   PLC-02 gate check: interface declared?
       │  No  → HTTP 422 InterfaceNotDeclared
       │  Yes → status := ACTIVE
       ▼
[process_module_catalog_share]  (optional)
       │  PLATFORM_ADMIN grants tenant B access
       ▼
[Subscriber tenant resolves module_ref]
       │
       ▼
   resolveModuleRef(module_ref, requesting_tenant_id)
       │
       ├── Visibility check: owning_tenant_id == requesting_tenant_id
       │       OR share grant exists?
       │
       ├── Semver range check: highest ACTIVE version satisfying constraint
       │
       └── Return: owning_definition_id  ──▶ child instantiation
```

---

## Visibility and resolution rules

1. **Owning tenant always sees its own modules.** Any module where `owning_tenant_id == requesting_tenant_id` is visible regardless of share grants.
2. **Cross-tenant visibility requires an explicit share grant.** A grant row `(granting_tenant_id=A, module_id=X, receiving_tenant_id=B)` makes module `X` owned by `A` visible to `B`.
3. **No grant → resolution fails silently.** `resolveModuleRef` returns `UnresolvedModuleRef` — same error used when the `module_id` does not exist at all. This is intentional: no information about other tenants' catalogs is leaked.
4. **Grant revocation is not retroactive.** A running child instance started from a granted module continues to completion. Only future activations of that module by the revoked tenant are blocked.
5. **Only ACTIVE versions are resolvable.** DRAFT and DEPRECATED versions are not returned by `resolveModuleRef`.

---

## Error taxonomy

| Error | HTTP | When |
|---|---|---|
| `DuplicateModuleVersion` | 409 | Register module with same module_id + version |
| `ModuleNotFound` | 404 | Direct lookup by module_id + version with no visibility |
| `UnresolvedModuleRef` | 422 | No ACTIVE version satisfies version_constraint |
| `InterfaceNotDeclared` | 422 | Publication attempted without declared interface |
| `SharingGrantNotFound` | 404 | Revoke non-existent grant |
| `SharingGrantAlreadyExists` | 409 | Duplicate grant for same tuple |
| `InsufficientPermissions` | 403 | Caller lacks PROCESS_DESIGNER or PLATFORM_ADMIN |
| `InvalidVersionConstraint` | 422 | Malformed semver range string |

---

## State transitions

```
DRAFT ────▶ ACTIVE
   │           │
   │           ▼
   └───▶ DEPRECATED
```

- `DRAFT → ACTIVE`: via `publishModule` after PLC-02 interface check.
- `DRAFT → DEPRECATED`: via `deprecateModule` (administrative withdraw, no interface check).
- `ACTIVE → DEPRECATED`: via `deprecateModule` (no new activations; existing running children are unaffected).

---

## Dependencies

- **SPC-01 / SPC-02:** `interface_schema` on the catalog entry mirrors the SUB_PROCESS `interface` object; validation of that schema at definition-creation time (SPC-02) must already be in place.
- **PLC-02:** The publication gate depends on SPC-01 interface declaration being present.
- **PLC-03:** Compatibility warning is computed at publication time against the immediately preceding ACTIVE version.
- **PLC-04:** Cross-tenant sharing is implemented via `process_module_catalog_share`.
- **PIN-01:** `resolveModuleRef` is the runtime resolution function called by the instance-start path when a `SUB_PROCESS` node carries a `module_ref`.
- **SOL-01:** The `exportable` flag on each entry is read by the pack export logic to decide whether a module can be inlined into a solution pack.

---

## Open questions

1. **Who can register a module?** The owning tenant's `PROCESS_DESIGNER` role — same pattern as REPO-07. Confirm this is the intended RBAC scope.
2. **Is `module_id` globally unique or per-tenant?** PLC-01 AC text says "unique per publishing tenant", implying `module_id` can repeat across tenants. Primary key is `(module_id, version)` but `module_id` alone may not be globally unique. Confirm: should `module_id` be globally unique (enforced by DB constraint) or per-tenant-scoped?
3. **Deletion:** Is an established module ever hard-deleted, or does it only transition to DEPRECATED? The current model only supports deprecation.
4. **Semver library:** The codebase currently has no semver parsing library. `version_constraint` parsing and range matching needs a library decision (existing Zig std library or vendor package).
