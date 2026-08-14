# Module: sol-batch1-solution-pack

**Requirement IDs:** SOL-01 (MUST), SOL-02 (MUST), SOL-03 (MUST)
**Run ID:** WF02-sol-batch1-20260814 (Stage 15)
**Step:** 01 (CODE-DESIGNER)

**Extends:**
- `src/definition/export_import.zig` (PD-09 — single-definition export; generalised here to a
  multi-definition closure)
- `src/definition/promotion.zig` (ENV-03 — `promoteDefinition()`)
- `src/repository/service_catalog.zig` (REPO-07 — `ServiceCatalogRecord`, `ServiceCatalog`)
- `src/identity/role_registry.zig` (IDN-05 — `tenant_role` table, role-binding queries)
- `migrations/1154_idn05_tenant_role_registry.sql` — prerequisite (must already exist)

---

## Classification rationale

Applying `templates/lego-catalog.md` selection rules:

1. **Type C?** Two new per-tenant-schema tables are required: `solution_pack_installs`
   (installation metadata — SOL-02) and `solution_pack_role_map` (per-pack role-binding
   checklist — SOL-03). Both are Type C components. However, both tables are tightly
   interlocked with the installation and activation gate algorithms, so the migrations are
   specified here and BACKEND-DEV produces the SQL from these specifications.

2. **Type A?** Both HTTP endpoints (`POST .../export` and `POST .../install`) call
   multi-step coordinated logic (dependency closure traversal, upsert-with-conflict
   detection, activation gate check) rather than a single store method. Neither qualifies
   as pure Type A.

3. **Type E — yes.** The dependency-closure algorithm (SOL-01), the transactional upsert
   pipeline with conflict semantics (SOL-02), and the activation gate hook (SOL-03) are
   each novel multi-step flows with no structural analogue in the current Lego catalog.

**Final classification:** Type E (prose design, this document). No standalone Type A/C
parameter files are produced — the migration DDL and endpoint shapes are fully specified
below for direct BACKEND-DEV consumption.

---

## Module purpose

Stage 15 introduces solution packs: self-contained JSON bundles that carry one or more
process definitions together with every artefact those definitions depend on — service
catalog entries, variable schemas, and `module_ref` PLC-01 modules — plus a manifest
listing the business-domain ROLE names that the installing tenant must bind before any
bundled definition can go live.

Three capabilities are implemented in this module:

1. **SOL-01 — Export**: given a set of definition IDs, the platform assembles a
   dependency-closure JSON document (`SolutionPackDocument`) and returns it to the caller.
   The document is suitable for storage and later transport to a different tenant or
   environment.

2. **SOL-02 — Install**: given a `SolutionPackDocument` and a target tenant, the platform
   idempotently applies the bundle — creating DRAFT definitions, registering or matching
   service catalog entries, registering or matching variable schemas — and returns a
   role-mapping checklist so the tenant administrator knows which roles still need binding
   before activation.

3. **SOL-03 — Activation gate**: before any definition created by SOL-02 can transition
   from DRAFT to ACTIVE, every ROLE name from the originating pack's manifest must have a
   binding in the target tenant's `tenant_role` table (IDN-05). Activation attempts with
   unbound roles are rejected with HTTP 422.

This module adds new files in `src/solution/`. It does not modify the engine kernel,
the event store, the base OIDC/auth flow, any migration ≤ 1157, or the existing
`src/definition/export_import.zig`.

---

## Dependencies

| Dependency | Kind | Notes |
|---|---|---|
| `src/definition/export_import.zig` | Code (read) | `ExportDocument`, `ExportImportStore.exportDefinition()` — SOL-01 calls this per definition |
| `src/definition/store.zig` | Code (read) | `Store.create()` with status DRAFT — SOL-02 calls this per bundled definition |
| `src/repository/service_catalog.zig` | Code (read/write) | `ServiceCatalog.getById()`, `ServiceCatalog.register()` — SOL-02 upsert path |
| `src/repository/mod.zig` | Code (read) | `ServiceCatalogRecord`, `AuthMethod` — used in pack document |
| `src/identity/role_registry.zig` | Code (read) | `RoleRegistry.listUnbound()` — SOL-02/03 query |
| `src/db/pool.zig` | Code (read) | `db.Pool`, `db.Conn` |
| `src/api/middleware/rbac.zig` | Code (read) | PLATFORM_ADMIN / PROCESS_DESIGNER guards |
| `migrations/1154_idn05_tenant_role_registry.sql` | DB prerequisite | `tenant_role` table must exist; new migrations must run after it |
| `src/event_store/store.zig` | Code (read) | `Store.append()` — installation and gate-rejection audit events |

**Must NOT depend on:**
- `src/definition/promotion.zig` directly — SOL-02 is a generalised install, not a
  test-to-prod promotion; it must not reuse the linked-tenant pairing logic
- `src/simulation/scenario_runner.zig` — install is not a simulation
- Any migration numbered ≤ 1157 — all sealed

---

## Public interface

**New module:** `src/solution/`

### Types

**`SolutionPackDocument`** — the JSON payload produced by export (SOL-01) and consumed by
install (SOL-02):

```
SolutionPackDocument {
    pack_id:                  string   // generated UUID at export time
    version:                  string   // semver, default "1.0.0"
    bpm_export_schema_version: string  // always "bpm/solution-pack/v1"
    exported_at:              string   // UTC ISO8601
    definitions:              []PackedDefinition
    service_catalog_entries:  []PackedCatalogEntry
    variable_schemas:         []PackedVariableSchema
    manifest:                 PackManifest
}
```

**Sub-types embedded in `SolutionPackDocument`:**

```
PackedDefinition {
    definition_id:  string   // source UUID (informational; re-assigned on install)
    process_key:    string
    name:           string
    version:        string
    graph:          object   // full DefinitionGraph JSON
    variable_schema: string  // JSON Schema bytes
}

PackedCatalogEntry {
    service_id:      string
    endpoint_url:    string
    request_schema:  string
    response_schema: string
    required_auth:   string  // "NONE" | "API_KEY" | "OAUTH2" | "MUTUAL_TLS"
    timeout_ms:      integer
    retry_policy:    string | null
}

PackedVariableSchema {
    definition_id:  string   // informational
    schema_name:    string   // match key for upsert on install
    schema_content: string   // JSON Schema bytes
}

PackManifest {
    required_roles: []string  // sorted alphabetically
}
```

**`InstallResult`** — returned by install (SOL-02):

```
InstallResult {
    pack_id:               string
    version:               string
    installed_definitions: []InstalledDefinition
    role_mapping_checklist: []RoleChecklistEntry
    warnings:              []string   // e.g. re-install idempotent skips
}

InstalledDefinition {
    source_definition_id: string   // from pack
    new_definition_id:    string   // assigned by this tenant
    process_key:          string
    status:               string   // always "DRAFT"
}

RoleChecklistEntry {
    role_name: string
    bound:     bool    // true if tenant_role binding exists for this name
}
```

**`SolutionPackStore`** — main store type in `src/solution/store.zig`:

```
pub fn exportPack(
    self: *SolutionPackStore,
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    definition_ids: []const []const u8,
) SolutionPackError!SolutionPackDocument

pub fn installPack(
    self: *SolutionPackStore,
    allocator: std.mem.Allocator,
    target_tenant_id: []const u8,
    doc: SolutionPackDocument,
    actor_id: []const u8,
) SolutionPackError!InstallResult

pub fn checkRoleGate(
    self: *SolutionPackStore,
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    definition_id: []const u8,
) SolutionPackError!RoleGateResult

pub const RoleGateResult = struct {
    allowed: bool,
    unbound_roles: []const []const u8,  // empty when allowed = true
}
```

---

## HTTP endpoints

### SOL-01 — Export

```
POST /api/v1/tenants/{tenant_id}/solution-packs/export
```

**Authorization:** PLATFORM_ADMIN or PROCESS_DESIGNER on `{tenant_id}`.

**Request body:**
```json
{
  "definition_ids": ["<uuid>", ...],
  "version": "1.0.0"
}
```
`version` is optional; defaults to `"1.0.0"`.

**Response 200:** `SolutionPackDocument` JSON.

**Response 422:** one or more `definition_ids` not found in the tenant, or a referenced
`module_ref` is non-exportable (see error taxonomy `ModuleNonExportable`).

**Response 403:** caller lacks required role.

### SOL-02 — Install

```
POST /api/v1/tenants/{tenant_id}/solution-packs/install
```

**Authorization:** PLATFORM_ADMIN, or PROCESS_DESIGNER with install rights on
`{tenant_id}`.

**Request body:** `SolutionPackDocument` JSON.

**Response 200:** `InstallResult` JSON.

**Response 409:** target tenant inactive (`TenantInactive`), or service catalog conflict
(`CatalogConflict` — same `service_id`, different schema).

**Response 422:** pack document fails schema validation (`InvalidPackDocument`).

### SOL-03 — Activation guard (not a new endpoint)

SOL-03 is enforced inside the existing `POST /api/v1/tenants/{tenant_id}/definitions/{process_key}/activate`
handler (REPO-08). No new endpoint is added. The handler calls `checkRoleGate()` before
executing the normal atomic activation. If `allowed = false`, HTTP 422 is returned
immediately without modifying definition status.

---

## DB schema

### New table: `solution_pack_installs`

**Migration file:** `1158_sol02_solution_pack_installs.sql`
**Kind:** per-tenant-schema table (no `tenant_id` column; schema search-path provides isolation)

```
solution_pack_installs

  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid()
  pack_id        TEXT        NOT NULL
  pack_version   TEXT        NOT NULL
  schema_version TEXT        NOT NULL     -- bpm_export_schema_version from document
  installed_by   UUID        NOT NULL     -- actor_id
  installed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()

  CONSTRAINT uq_sol_pack_installs_pack_version
    UNIQUE (pack_id, pack_version)
    -- Re-installing the same pack+version is idempotent; existing row is left
    -- untouched and a warning is returned (not an error).
```

### New table: `solution_pack_role_map`

**Migration file:** `1159_sol03_solution_pack_role_map.sql`
**Kind:** per-tenant-schema table

```
solution_pack_role_map

  id          UUID  PRIMARY KEY DEFAULT gen_random_uuid()
  install_id  UUID  NOT NULL
                      REFERENCES solution_pack_installs(id) ON DELETE CASCADE
  role_name   TEXT  NOT NULL
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()

  CONSTRAINT uq_sol_pack_role_map_install_role
    UNIQUE (install_id, role_name)
```

**Index:** `idx_sol_pack_role_map_role ON solution_pack_role_map(role_name)` — fast
lookup at activation gate time.

### New column: `process_definitions.solution_pack_install_id`

**Migration file:** `1160_sol_definition_install_fk.sql`
**Scope:** per-tenant schema (same schema as `process_definitions`)

```sql
ALTER TABLE process_definitions
  ADD COLUMN IF NOT EXISTS solution_pack_install_id UUID
    REFERENCES solution_pack_installs(id) ON DELETE SET NULL;
```

NULL for definitions not installed via a solution pack. The activation gate in SOL-03
only fires when this column is non-NULL. Definitions created via PD-01 have NULL here and
are never subject to the SOL-03 gate.

**Index:** `idx_proc_def_pack_install ON process_definitions(solution_pack_install_id)` —
fast lookup for "list all definitions from this install".

---

## Data flow

### SOL-01 Export flow

```
Caller
  │
  ▼
POST /api/v1/tenants/{tenant_id}/solution-packs/export
  │
  ▼
Handler: validate auth (PROCESS_DESIGNER or PLATFORM_ADMIN on tenant)
  │
  ▼
SolutionPackStore.exportPack(tenant_id, definition_ids, version)
  │
  ├─► For each definition_id:
  │     ExportImportStore.exportDefinition(definition_id)
  │       → ExportDocument { graph, variable_schema, ... }
  │     Walk graph nodes for SERVICE_TASK nodes → collect service_ids
  │     Walk graph nodes for HUMAN_TASK with assignee_type=ROLE → collect role names
  │     Walk graph nodes for SUB_PROCESS with module_ref → collect module_refs
  │
  ├─► For each collected service_id:
  │     ServiceCatalog.getById(service_id) → PackedCatalogEntry
  │
  ├─► For each collected module_ref:
  │     Check PLC-04 sharing grant / non-exportable flag
  │     If non-exportable → return ModuleNonExportable error (named)
  │     If exportable → inline module definition into pack
  │
  ├─► Deduplicate role names → sorted []string for manifest.required_roles
  │
  └─► Assemble SolutionPackDocument { pack_id=newUUID(), version, ... }
          → return to handler → HTTP 200
```

### SOL-02 Install flow

Pre-transaction guards:

```
Handler: validate auth (PROCESS_DESIGNER+install or PLATFORM_ADMIN on tenant)
  │
  ▼
SolutionPackStore.installPack(target_tenant_id, doc, actor_id)
  │
  ├─► Validate bpm_export_schema_version = "bpm/solution-pack/v1"
  │     otherwise → InvalidPackDocument (422)
  │
  ├─► Check tenant status = ACTIVE
  │     otherwise → TenantInactive (409)
  │
  └─► Check UNIQUE (pack_id, pack_version):
        IF existing row → return idempotent warning, skip transaction
```

Transactional install steps:

```
BEGIN TRANSACTION
  │
  ├─► INSERT INTO solution_pack_installs → install_id
  │
  ├─► For each service_catalog_entries entry:
  │     Existing + same schemas → skip (reuse)
  │     Existing + different schemas → ROLLBACK → CatalogConflict (409)
  │     Absent → INSERT
  │
  ├─► For each variable_schemas entry:
  │     Existing + same content → skip (reuse)
  │     Existing + different content → ROLLBACK → VariableSchemaConflict (409)
  │     Absent → INSERT
  │
  ├─► For each definitions entry:
  │     store.create(definition) → DRAFT
  │     SET solution_pack_install_id = install_id
  │
  ├─► For each manifest.required_roles:
  │     INSERT INTO solution_pack_role_map ON CONFLICT DO NOTHING
  │
COMMIT
  │
  └─► Build role_mapping_checklist from tenant_role lookups
      Return InstallResult
```

### SOL-03 Activation gate flow

```
Caller
  │
  ▼
POST /api/v1/tenants/{tenant_id}/definitions/{process_key}/activate   (REPO-08)
  │
  ▼
Handler: existing auth check
  │
  ▼
SELECT solution_pack_install_id
  FROM process_definitions
  WHERE process_key = $1 AND status = 'DRAFT'

  IF solution_pack_install_id IS NULL:
    → proceed with normal REPO-08 activation (no gate)

  IF solution_pack_install_id IS NOT NULL:
    → SolutionPackStore.checkRoleGate(tenant_id, definition_id)
        SELECT r.role_name
          FROM solution_pack_role_map r
         WHERE r.install_id = solution_pack_install_id
           AND NOT EXISTS (
             SELECT 1 FROM tenant_role tr WHERE tr.name = r.role_name
           )

        IF unbound_roles is empty → allowed=true → proceed with REPO-08 activation
        IF unbound_roles is non-empty → allowed=false
           → HTTP 422 { "error": "UNBOUND_ROLES", "unbound_roles": [...] }
           → append audit event SOLUTION_PACK_ACTIVATION_BLOCKED
```

---

## Error taxonomy

| Error | HTTP | Triggered by | Notes |
|---|---|---|---|
| `DefinitionNotFound` | 422 | exportPack | One or more `definition_ids` not found in the exporting tenant |
| `ModuleNonExportable` | 422 | exportPack | A `module_ref` dependency is marked non-exportable by its publishing tenant (PLC-04) |
| `ModuleShareGrantMissing` | 422 | exportPack | A cross-tenant `module_ref` has no PLC-04 sharing grant to the installing tenant; module is inlined |
| `InvalidPackDocument` | 422 | installPack | `bpm_export_schema_version` unknown, missing required fields, or malformed JSON |
| `TenantInactive` | 409 | installPack | Target tenant status is not ACTIVE |
| `CatalogConflict` | 409 | installPack | `service_id` already exists in target with different request/response schema |
| `VariableSchemaConflict` | 409 | installPack | `schema_name` already exists in target with different schema content |
| `UnboundRoles` | 422 | checkRoleGate | One or more manifest roles have no `tenant_role` binding; lists the role names |
| `PoolExhausted` | 503 | any | DB connection pool exhausted |
| `TransactionFailed` | 500 | installPack | DB transaction failed to commit |
| `OutOfMemory` | 500 | any | Allocator failure |

---

## State transitions

### Definition status (SOL-02/03)

```
(not installed)
      │
      │  SOL-02 install
      ▼
    DRAFT ─────────────────────────────────────────────────────────► ACTIVE
      │    all manifest roles bound (SOL-03 gate passes)               │
      │                                                                 │
      │    any manifest role unbound → HTTP 422 (gate blocks)          │
      │    (definition remains DRAFT until all roles bound)            │
      └─────────────────────────────────────────────────────────────►ARCHIVED/DEPRECATED
                                                          (via normal PD lifecycle)
```

### Solution pack install record

```
(no record)
    │
    │  POST .../install
    ▼
 solution_pack_installs row created (install_id)
    │
    ├─► solution_pack_role_map rows created (one per manifest role)
    ├─► process_definitions rows created (DRAFT, solution_pack_install_id set)
    └─► record is permanent; no delete/archive path in this stage
```

---

## Files to create

| File | Description |
|---|---|
| `src/solution/store.zig` | `SolutionPackStore` — export, install, checkRoleGate |
| `src/solution/types.zig` | `SolutionPackDocument`, `InstallResult`, all sub-types |
| `src/solution/pack_builder.zig` | Dependency-closure walker used by exportPack |
| `src/api/routes/solution_packs.zig` | HTTP handlers for export and install endpoints |
| `migrations/1158_sol02_solution_pack_installs.sql` | `solution_pack_installs` table |
| `migrations/1159_sol03_solution_pack_role_map.sql` | `solution_pack_role_map` table |
| `migrations/1160_sol_definition_install_fk.sql` | `process_definitions.solution_pack_install_id` column |

---

## Files NOT to change

| File | Reason |
|---|---|
| `src/definition/export_import.zig` | Consumed as-is; do not modify the single-definition export logic |
| `src/definition/promotion.zig` | SOL-02 install is not a test-to-prod promotion; do not reuse or modify |
| `src/repository/service_catalog.zig` | Called read-only from install; upsert is done through existing register() |
| `src/identity/role_registry.zig` | Role lookup only; role creation is the tenant admin's responsibility |
| `src/engine/instance.zig` | Engine is not aware of solution packs; gate is at activation, not at runtime |
| Any migration ≤ 1157 | Sealed; do not modify |
| `src/definition/store.zig` | Called for definition creation only; no modification needed |

---

## Open questions

1. **`module_ref` inline vs. error boundary (PLC-04 not yet implemented):** SOL-01 must
   handle the case where a `module_ref` is cross-tenant but no PLC-04 sharing grant exists
   for the installing tenant. The requirement says "inline into the pack" in this case. If
   the module is also marked non-exportable, export fails with a named error. PLC-04 itself
   is a SHOULD requirement (Stage 15) and may not be present at implementation time.
   **BACKEND-DEV action:** if `module_ref` lookup finds no PLC-04 grant, treat as
   `ModuleShareGrantMissing` and inline the module's full graph; if the module record has
   `non_exportable = true`, return `ModuleNonExportable` and abort. If the PLC-04 table
   does not yet exist in the schema, skip the sharing-grant check and always inline.

2. **`variable_schemas` table shape:** The install flow matches variable schemas by
   `schema_name`. The existing `variable_schemas` table schema should be verified by
   BACKEND-DEV before implementation — in particular, confirm the column name for the
   human-readable label used as the match key.

3. **Activation endpoint location:** SOL-03 injects the role gate into the existing
   REPO-08 activation handler. If that handler does not yet exist as a dedicated route
   (i.e., activation is done through the promotion endpoint), BACKEND-DEV must identify
   the correct injection point and flag it in the implementation handoff.
