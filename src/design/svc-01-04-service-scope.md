# Module: svc-01-04 — Service Catalog and Plugin Tenant Scoping

**Requirements covered:** SVC-01, SVC-02, SVC-03, SVC-04
**Stage:** 13
**Classification:**
- SVC-01: Type C (schema migration — `templates/specs/svc-01-scope-migration.migration.yaml`) + Type E (API filtering logic)
- SVC-02: Type E (in-process plugin registry struct extension)
- SVC-03: Type E (cross-module activation validator)
- SVC-04: Type E (API with conflict/referential guards) + Type B (UI page — `templates/specs/svc-04-services-admin-page.list-page.yaml`)

**Related artefacts:**
- `templates/specs/svc-01-scope-migration.migration.yaml` — Type C migration
- `templates/specs/svc-04-services-admin-page.list-page.yaml` — Type B UI page
- `src/design/adp-08-service-capability-validation-layer.md` — ADP-08 runtime catalog reference
- `src/design/ext03-global-registry-allocator-leak.md` — EXT-03 plugin interface contract
- `src/repository/service_catalog.zig` — existing catalog store (extended here)
- `src/engine/plugin_registry.zig` — existing plugin registry (extended here)
- `src/definition/store.zig` — `activate()` method (SVC-03 hook added here)

---

## 1. Module purpose

Stage 13 adds **tenant-scoping** to two existing registries — the database-backed
service catalog and the in-process plugin registry — and introduces a new
cross-module **activation validator** that rejects process definitions that
reference a service or plugin the activating tenant is not permitted to use.

- **SVC-01** extends the `service_catalog` table with a `scope` column
  (`global` | `tenant`) and a nullable `owner_tenant_id` FK, then updates
  `GET /api/v1/services` to return only entries visible to the calling tenant.
- **SVC-02** adds a `PluginScope` enum and `owner_tenant_id` to
  `PluginRegistration`; dispatch is filtered to eligible handlers;
  `freezePluginRegistry()` gains a duplicate-tenant-scope check.
- **SVC-03** introduces `ServiceScopeValidator`, called inside
  `definition/store.zig` `activate()` before the SQL state transition.
  It verifies every SERVICE_TASK node's `service_id` and `plugin_handler`
  are accessible to the activating tenant.
- **SVC-04** adds five HTTP routes in a new `src/api/routes/services.zig`
  handler file and registers them in the router. The PATCH and DELETE routes
  have mid-flight conflict/referential guards that prevent breaking active
  definitions.

---

## 2. Public interface

### 2.1 Service catalog data types — `src/repository/service_catalog.zig`

```zig
pub const ServiceScope = enum { global, tenant };

pub const ServiceCatalogRecord = struct {
    service_id:      []const u8,
    endpoint_url:    []const u8,
    request_schema:  []const u8,
    response_schema: []const u8,
    required_auth:   AuthMethod,
    timeout_ms:      u32,
    retry_policy:    []const u8,
    scope:           ServiceScope,
    owner_tenant_id: ?[16]u8,   // null when scope = global
    created_at:      i64,
    updated_at:      i64,
};

pub const RegisterServiceParams = struct {
    service_id:      []const u8,
    endpoint_url:    []const u8,
    request_schema:  []const u8,
    response_schema: []const u8,
    required_auth:   AuthMethod,
    timeout_ms:      u32,
    retry_policy:    ?[]const u8,
    scope:           ServiceScope,
    owner_tenant_id: ?[16]u8,
};

pub const UpdateServiceScopeParams = struct {
    scope:           ServiceScope,
    owner_tenant_id: ?[16]u8,
};
```

### 2.2 Service catalog store methods — `src/repository/service_catalog.zig`

All existing methods retain their signatures. The following methods are added
or altered:

```zig
/// List services visible to the given tenant.
/// caller_tenant_id = null means platform-admin: returns all entries.
pub fn listServicesForTenant(
    self: *ServiceCatalog,
    allocator: std.mem.Allocator,
    caller_tenant_id: ?[16]u8,
    after_id: ?[]const u8,
    limit: u32,
) CatalogError![]ServiceCatalogRecord;

/// Register a new service (admin-only path, validates scope constraint).
pub fn registerService(
    self: *ServiceCatalog,
    allocator: std.mem.Allocator,
    params: RegisterServiceParams,
) CatalogError!ServiceCatalogRecord;

/// Update scope and owner_tenant_id for an existing service.
/// Returns ConflictingActiveDefinitions if changing global→tenant while
/// other tenants' ACTIVE definitions reference the service.
pub fn updateServiceScope(
    self: *ServiceCatalog,
    allocator: std.mem.Allocator,
    service_id: []const u8,
    params: UpdateServiceScopeParams,
) CatalogError!ServiceCatalogRecord;

/// Delete a service. Returns ServiceInUse if any ACTIVE definition
/// references it (call lastInUseDefinitionIds() for details).
pub fn deleteService(
    self: *ServiceCatalog,
    allocator: std.mem.Allocator,
    service_id: []const u8,
) CatalogError!void;
```

Conflict-context accessors (valid immediately after a failing deleteService / updateServiceScope call):

```zig
/// UUIDs of active definitions that reference the service (set on ServiceInUse).
pub fn lastInUseDefinitionIds(self: *const ServiceCatalog) []const [16]u8;

/// Tenant UUIDs that conflict (set on ConflictingActiveDefinitions).
pub fn lastConflictingTenantIds(self: *const ServiceCatalog) []const [16]u8;

/// Fetch one service visible to tenant_id (scope check applied).
/// Returns ServiceNotFound if absent OR if scope excludes the tenant.
pub fn getServiceForTenant(
    self: *ServiceCatalog,
    allocator: std.mem.Allocator,
    service_id: []const u8,
    tenant_id: [16]u8,
) CatalogError!ServiceCatalogRecord;
```

### 2.3 Updated error set — `src/repository/service_catalog.zig`

```zig
pub const CatalogError = error{
    // existing
    PoolExhausted,
    ServiceIdTooLong,
    ServiceIdEmpty,
    ServiceIdInvalid,
    ServiceNotFound,
    DuplicateService,
    InvalidAuthMethod,
    InvalidSchema,
    EndpointUrlInvalid,
    TimeoutInvalid,
    TransactionFailed,
    OutOfMemory,
    InvalidJson,
    // new (SVC-01, SVC-04)
    InvalidScopeConstraint,       // scope=tenant with no owner_tenant_id, or scope=global with owner
    TenantNotFound,               // owner_tenant_id does not resolve to a known tenant
    ServiceInUse,                 // DELETE blocked by active definitions
    ConflictingActiveDefinitions, // PATCH scope change blocked by other tenants' active defs
};
```

### 2.4 Plugin registry extensions — `src/engine/plugin_registry.zig`

```zig
pub const PluginScope = enum { global, tenant };

// Added to PluginRegistration:
pub const PluginRegistration = struct {
    node_type:       []const u8,
    handler:         plugin_interface.PluginNodeHandlerPtr,
    plugin_name:     []const u8,
    plugin_version:  []const u8,
    target_api:      plugin_interface.PluginApiVersion,
    scope:           PluginScope,          // new
    owner_tenant_id: ?[16]u8,             // new; null when scope = .global
};

// Added to RegisterPluginHandlerInput:
pub const RegisterPluginHandlerInput = struct {
    node_type:       []const u8,
    handler:         ?plugin_interface.PluginNodeHandlerPtr,
    plugin_name:     []const u8,
    plugin_version:  []const u8,
    target_api:      plugin_interface.PluginApiVersion,
    scope:           PluginScope,          // new; default .global
    owner_tenant_id: ?[16]u8,             // new; default null
};
```

New and modified functions:

```zig
// registerPluginHandler gains two additional pre-registration checks:
//   1. scope=.tenant AND owner_tenant_id=null → error.TenantScopedPluginRequiresOwnerId
//   2. scope=.global AND owner_tenant_id != null → error.GlobalPluginMustNotHaveOwnerId (MINOR guard)

// freezePluginRegistry gains duplicate-tenant-scope validation:
//   For all tenant-scoped entries: if two entries share (node_type, owner_tenant_id) → panic/fatal

/// Resolve the highest-priority eligible handler for node_type for tenant.
/// Priority: tenant-scoped plugin > global plugin > nil (builtin falls through).
pub fn resolvePluginHandlerForTenant(
    registry: *const PluginRegistry,
    node_type: []const u8,
    tenant_id: [16]u8,
) ?PluginRegistration;

pub const PluginRegistrationError = error{
    DuplicateNodeType,
    InvalidNodeType,
    InvalidHandler,
    RegistryLocked,
    IncompatibleApiVersion,
    OutOfMemory,
    TenantScopedPluginRequiresOwnerId, // new
    GlobalPluginMustNotHaveOwnerId,    // new
};
```

### 2.5 Service scope activation validator — `src/definition/service_scope_validator.zig` (new file)

```zig
pub const ServiceScopeError = error{
    ServiceNotRegistered,        // HTTP 422: service_id has no catalog entry
    ServiceNotAvailableToTenant, // HTTP 422: tenant-scoped service owned by other tenant
    PluginNotAvailableToTenant,  // HTTP 422: tenant-scoped plugin owned by other tenant
    OutOfMemory,
    PoolExhausted,
    TransactionFailed,
};

/// Violation returned when validation fails, enabling detailed HTTP 422 body.
pub const ScopeViolation = struct {
    node_id: []const u8,
    kind:    enum { service, plugin },
    ref_id:  []const u8, // service_id or plugin_handler value
    reason:  []const u8, // e.g. "service X is not available to tenant T"
};
```

```zig
pub const ServiceScopeValidator = struct {
    allocator:       std.mem.Allocator,
    catalog:         *ServiceCatalog,
    plugin_registry: *const PluginRegistry,

    pub fn init(
        allocator: std.mem.Allocator,
        catalog: *ServiceCatalog,
        plugin_registry: *const PluginRegistry,
    ) ServiceScopeValidator;

    /// Walk every SERVICE_TASK node in graph. Check scope for each
    /// service_id / plugin_handler reference against the activating tenant.
    /// Returns on the first violation (atomic rejection). Stores the
    /// violation detail for lastViolation(). Returns void on full pass.
    pub fn validateServiceTaskReferences(
        self: *ServiceScopeValidator,
        graph: DefinitionGraph,
        tenant_id: [16]u8,
    ) ServiceScopeError!void;

    /// Returns the violation from the most recent failing call.
    /// Pointer is valid until the next validateServiceTaskReferences call.
    pub fn lastViolation(self: *const ServiceScopeValidator) ?ScopeViolation;
};
```

**Hook in `definition/store.zig` `activate()` — signature unchanged:**

The validator is injected into `Store` as an optional pointer field:

```zig
// In definition/store.zig Store struct:
service_scope_validator: ?*ServiceScopeValidator = null,
```

Inside `activate()`, after existing graph validation passes and before the SQL
`BEGIN` transaction block, the store calls:

```
if (self.service_scope_validator) |v| {
    v.validateServiceTaskReferences(graph, tenant_id) catch |err| switch (err) {
        error.ServiceNotRegistered,
        error.ServiceNotAvailableToTenant,
        error.PluginNotAvailableToTenant => return DefinitionError.ServiceScopeViolation,
        else => return DefinitionError.TransactionFailed,
    };
}
```

`DefinitionError.ServiceScopeViolation` is a new variant (HTTP 422) that the
activate handler maps to a body containing `v.lastViolation()`.

`tenant_id` is threaded from the auth context into the `activate()` call via
a new optional parameter on `ActivateParams`:

```zig
pub const ActivateParams = struct {
    id:        Uuid,
    tenant_id: ?[16]u8,   // null = platform-admin bypass
};
```

### 2.6 API route handlers — `src/api/routes/services.zig` (new file)

```zig
/// GET /api/v1/services  — tenant-scoped list (SVC-01, SVC-04)
pub fn handleListServices(
    allocator: std.mem.Allocator,
    catalog: *ServiceCatalog,
    actor: auth.AuthContext,
    query: struct { after_id: ?[]const u8, limit: ?u32 },
) HandlerResult;

/// GET /api/v1/admin/services  — all entries (platform-admin only)
pub fn handleAdminListServices(
    allocator: std.mem.Allocator,
    catalog: *ServiceCatalog,
    actor: auth.AuthContext,
    query: struct { after_id: ?[]const u8, limit: ?u32 },
) HandlerResult;

/// POST /api/v1/admin/services  — register new service (platform-admin only)
pub fn handleAdminRegisterService(
    allocator: std.mem.Allocator,
    catalog: *ServiceCatalog,
    actor: auth.AuthContext,
    body: []const u8,
) HandlerResult;

/// PATCH /api/v1/admin/services/:service_id  — update scope (platform-admin only)
pub fn handleAdminUpdateService(
    allocator: std.mem.Allocator,
    catalog: *ServiceCatalog,
    actor: auth.AuthContext,
    service_id: []const u8,
    body: []const u8,
) HandlerResult;

/// DELETE /api/v1/admin/services/:service_id  — deregister service (platform-admin only)
pub fn handleAdminDeleteService(
    allocator: std.mem.Allocator,
    catalog: *ServiceCatalog,
    actor: auth.AuthContext,
    service_id: []const u8,
) HandlerResult;
```

### 2.7 Authorization policy additions — `src/api/authorization.zig`

Two new `EndpointPolicyKey` variants are added:

```zig
// existing enum — two new variants:
ServicesRead,         // GET /api/v1/services — any authenticated role
AdminServicesManage,  // POST/PATCH/DELETE /api/v1/admin/services — PLATFORM_ADMIN only
AdminServicesRead,    // GET /api/v1/admin/services — PLATFORM_ADMIN only
```

`endpointPolicyKey()` gains matching branches. Role enforcement is applied at
handler entry — non-admin callers on admin routes receive HTTP 403 before any
store method is called.

---

## 3. Data flow

### 3.1 Service listing (SVC-01, SVC-04)

```
Caller ──GET /api/v1/services──► handleListServices
          │                          │
          │   auth.AuthContext        ▼
          │   tenant_id present?   ServiceCatalog.listServicesForTenant(caller_tenant_id)
          │                          │
          │   platform-admin?        ▼
          └── yes → caller_tenant_id=nil → SQL: SELECT * FROM service_catalog
                                                (returns all)
              no  → caller_tenant_id=T  → SQL: SELECT * FROM service_catalog
                                                WHERE scope='global'
                                                   OR (scope='tenant' AND owner_tenant_id=$1)
```

### 3.2 Plugin dispatch tenant filter (SVC-02)

```
SERVICE_TASK execution
    │
    ▼
resolvePluginHandlerForTenant(registry, node_type, tenant_id)
    │
    ├── scan entries for node_type
    │     ├── if scope=.tenant AND owner_tenant_id==tenant_id → return (highest priority)
    │     ├── if scope=.global → candidate global
    │     └── skip scope=.tenant with owner ≠ tenant_id
    │
    └── return tenant-scoped match if found, else global match, else nil
```

### 3.3 Definition activation scope validation (SVC-03)

```
Store.activate(params)
    │
    ├── [existing] graph structural validation
    ├── [existing] node attribute validation (PD-05)
    ├── [existing] edge condition validation
    │
    ├── [NEW SVC-03] ServiceScopeValidator.validateServiceTaskReferences(graph, tenant_id)
    │       │
    │       ├── for each SERVICE_TASK node:
    │       │     ├── service_id present?
    │       │     │     ├── catalog lookup → scope check
    │       │     │     │     GLOBAL → PASS
    │       │     │     │     TENANT + owner==T → PASS
    │       │     │     │     TENANT + owner≠T → FAIL ServiceNotAvailableToTenant
    │       │     │     └── not found → FAIL ServiceNotRegistered
    │       │     └── plugin_handler present?
    │       │           ├── registry lookup → scope check
    │       │           │     GLOBAL → PASS
    │       │           │     TENANT + owner==T → PASS
    │       │           │     TENANT + owner≠T → FAIL PluginNotAvailableToTenant
    │       │           └── not found → skip (PD-05 already validates handler existence)
    │       └── all nodes pass → return void
    │
    ├── [existing] SQL BEGIN + DEPRECATED transition + ACTIVE transition + COMMIT
    └── return updated Definition
```

### 3.4 Admin service PATCH conflict guard (SVC-04)

```
handleAdminUpdateService (scope change global→tenant)
    │
    ├── parse body; validate scope constraint (scope=tenant → owner_tenant_id required)
    │
    ├── ServiceCatalog.updateServiceScope(service_id, params)
    │     │
    │     ├── SELECT current scope and id
    │     ├── if scope changes global→tenant:
    │     │     SELECT DISTINCT pd.tenant_id FROM process_definitions pd
    │     │     JOIN (node scan) WHERE service_id=$1 AND pd.status='ACTIVE'
    │     │       AND pd.tenant_id != $2   ($2 = new owner_tenant_id)
    │     │     → any rows? → return ConflictingActiveDefinitions
    │     └── UPDATE service_catalog SET scope=$1, owner_tenant_id=$2
    │
    └── HTTP 200 with updated record, or HTTP 409 with conflicting tenant IDs
```

---

## 4. Error taxonomy

### ServiceCatalog errors (SVC-01, SVC-04)

| Error variant | HTTP | Trigger |
|---|---|---|
| `InvalidScopeConstraint` | 422 | `scope=tenant` without `owner_tenant_id`, or `scope=global` with `owner_tenant_id` |
| `TenantNotFound` | 422 | `owner_tenant_id` does not exist in `tenant` table |
| `DuplicateService` | 409 | `service_id` already registered |
| `ServiceNotFound` | 404 | `service_id` not in catalog, or scope excludes calling tenant |
| `ServiceInUse` | 409 | DELETE blocked by ≥1 ACTIVE definition referencing the service |
| `ConflictingActiveDefinitions` | 409 | PATCH global→tenant blocked by other tenants' ACTIVE definitions |
| `InvalidAuthMethod` | 422 | `auth_method` not in allowed set |
| `TimeoutInvalid` | 422 | `timeout_ms` outside 1..3_600_000 |
| `EndpointUrlInvalid` | 422 | URL does not parse as HTTPS |
| `PoolExhausted` | 503 | DB connection pool exhausted |
| `TransactionFailed` | 500 | Unexpected DB error |

### PluginRegistration errors (SVC-02)

| Error variant | Trigger |
|---|---|
| `TenantScopedPluginRequiresOwnerId` | `scope=.tenant` with `owner_tenant_id=null` at register time |
| `GlobalPluginMustNotHaveOwnerId` | `scope=.global` with non-null `owner_tenant_id` |
| `DuplicateNodeType` | two tenant-scoped plugins with same `(node_type, owner_tenant_id)` detected during freeze |

### ServiceScopeError (SVC-03) — HTTP 422 family

| Error variant | Message template | Trigger |
|---|---|---|
| `ServiceNotRegistered` | `"service {id} is not registered"` | No catalog entry for service_id |
| `ServiceNotAvailableToTenant` | `"service {id} is not available to this tenant"` | Catalog entry exists but scope excludes activating tenant |
| `PluginNotAvailableToTenant` | `"plugin {id} is not available to this tenant"` | Plugin registry entry scope excludes activating tenant |

### DefinitionError additions (SVC-03)

| Error variant | HTTP | Trigger |
|---|---|---|
| `ServiceScopeViolation` | 422 | Any `ServiceScopeError` returned during activation; body includes `ScopeViolation` detail |

---

## 5. Dependencies

| Module | Direction | Reason |
|---|---|---|
| `src/repository/service_catalog.zig` | extended | SVC-01 scope fields; SVC-04 admin CRUD |
| `src/engine/plugin_registry.zig` | extended | SVC-02 PluginScope enum + dispatch filter |
| `src/definition/store.zig` | caller of ServiceScopeValidator | SVC-03 activation hook |
| `src/definition/graph.zig` | read-only | ServiceScopeValidator walks DefinitionGraph nodes |
| `src/api/routes/services.zig` | new | SVC-04 route handlers |
| `src/api/authorization.zig` | extended | SVC-04 new endpoint policy keys |
| `src/api/middleware/auth.zig` | read-only | AuthContext tenant_id extraction |
| `migrations/GBL-078_svc01_service_catalog_scope.sql` | new | SVC-01 schema changes |

**Dependency order for implementation:**

1. Apply migration (adds schema columns) — no Zig changes yet
2. Extend `service_catalog.zig` types and store methods (SVC-01, SVC-04 backend)
3. Extend `plugin_registry.zig` (SVC-02)
4. Implement `service_scope_validator.zig` (SVC-03) — depends on 2 and 3
5. Extend `definition/store.zig` `activate()` with validator hook (SVC-03) — depends on 4
6. Implement `api/routes/services.zig` + extend `authorization.zig` (SVC-04)
7. Wire routes in `src/api/router.zig` / `src/main.zig`

**Must NOT depend on:** tenant-schema tables. `service_catalog` is a public-schema
routing/registry table (TNT-01 confirmed). The validator never sets `search_path`
to a tenant schema.

---

## 6. Open questions

None — all acceptance criteria are fully specified. The composite CHECK constraint
`((scope='global' AND owner_tenant_id IS NULL) OR (scope='tenant' AND owner_tenant_id IS NOT NULL))`
is expressed in the migration YAML as a table-level constraint and documented
in the SQL comment. If the Type C codegen does not emit table-level ALTER TABLE
ADD CONSTRAINT in the dry-run output, BACKEND-DEV must add it manually in
the `-- CUSTOM:` block of the generated migration file.
