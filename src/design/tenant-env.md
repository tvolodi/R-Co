# Module: tenant-env (ENV-01 / ENV-02 / ENV-03 / ENV-05)

> **Scope:** Stage 14 — Test-tenant environment.  
> **Produced by:** CODE-DESIGNER (WF02-env-batch1-20260610, Step 01)  
> **Requirements:** ENV-01 (DB + API), ENV-02 (isolation policy), ENV-03 (definition promotion), ENV-05 (reset + delete lifecycle)

---

## Module Purpose

The `tenant-env` module extends the BPM Platform's multi-tenancy foundation to support test-tenant environments. It adds a `tenant_type` field (and linked `production_tenant_id` FK) to the `tenant` table to distinguish production tenants from linked test tenants (ENV-01), enforces schema-level isolation between them (ENV-02), provides a definition promotion workflow that copies process definitions from a test tenant to its linked production tenant (ENV-03), and manages the full lifecycle of test tenants including data reset (truncate all business data while preserving identity tables) and full decommission (drop schema, delete Keycloak realm, and remove public rows) operations (ENV-05).

---

## ENV-01 — API changes for tenant_type and production_tenant_id

The migration (`GBL-080_env01_tenant_type_field.sql`) adds the columns and constraint directly
to `tenant`; see `templates/specs/env-01.migration.yaml` for the full schema specification.
The API changes are in two existing modules:

### 1.1 `src/identity/onboarding.zig` — extended OnboardingInput

Add two new optional fields to `OnboardingInput`:

```zig
pub const OnboardingInput = struct {
    slug: []const u8,
    display_name: []const u8,
    admin_email: []const u8,
    admin_username: []const u8,
    admin_display_name: []const u8,
    hostname: []const u8,
    realm_config: ?RealmConfigOverrides,
    client_config: ?ClientConfigOverrides,
    // NEW — ENV-01
    tenant_type: TenantType,               // required; defaults to .production in parser
    production_tenant_id: ?[36]u8,         // UUID string; required when tenant_type = .test
};

pub const TenantType = enum {
    production,
    test,

    /// Returns null for unrecognised strings.
    pub fn fromString(s: []const u8) ?TenantType;
    pub fn asString(self: TenantType) []const u8;
};
```

Add to `OnboardingError`:

```zig
pub const OnboardingError = error{
    // ... existing variants ...
    // NEW — ENV-01
    TestTenantMissingProductionRef,    // → HTTP 422
    ProductionTenantMustNotHaveRef,    // → HTTP 422
    InvalidProductionTenantRef,        // production_tenant_id does not exist → HTTP 422
};
```

### 1.2 Validation in `onboard()` function

After parsing input, before calling `db_provisioning.provisionTenant()`, execute:

```
if tenant_type = 'test':
    if production_tenant_id IS NULL → return TestTenantMissingProductionRef
    verify production_tenant_id EXISTS in tenant with tenant_type='production'
        → if not: return InvalidProductionTenantRef
if tenant_type = 'production':
    if production_tenant_id IS NOT NULL → return ProductionTenantMustNotHaveRef
```

### 1.3 INSERT in onboarding

The `INSERT INTO tenant (...)` statement must include the two new columns:

```sql
INSERT INTO tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id, created_at)
VALUES ($1, $2, $3, 'ACTIVE', $4, $5, $6, now())
```

Parameters $5 = `tenant_type`, $6 = `production_tenant_id` (NULL for production).
All queries use parameterised form — no string interpolation of user values.

### 1.4 `src/api/routes/admin_tenants.zig` (or equivalent) — extended response

`GET /api/v1/admin/tenants` returns a JSON array of tenant records. Add two fields to the
serialisation struct:

```zig
pub const AdminTenantRow = struct {
    id: []const u8,
    slug: []const u8,
    display_name: []const u8,
    status: []const u8,
    idp_realm_id: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
    // NEW — ENV-01
    tenant_type: []const u8,
    production_tenant_id: ?[]const u8,
};
```

SQL projection must include both new columns.

### 1.5 `PATCH /api/v1/tenants/:id` — immutability guard

In the PATCH handler, before applying any field changes, check whether the request body
contains `tenant_type` or `production_tenant_id` as keys:

```
if body contains "tenant_type" or "production_tenant_id":
    return HTTP 422, { "error": "immutable_field",
                       "detail": "tenant_type and production_tenant_id cannot be changed after creation" }
```

This must be a key-presence check, not a value-equality check. Even supplying the same
value as the current value MUST return 422 (immutability is unconditional).

---

## ENV-02 — Isolation policy (no new code)

ENV-02 requires **no new platform code**. Isolation is already guaranteed by two existing
mechanisms:

| Mechanism | Where enforced | Covers AC |
|---|---|---|
| `search_path = tenant_<uuid>, public` | `src/db/pool.zig` (TNT-03) — set per connection | Unqualified queries in T-test cannot resolve T's tables |
| Per-realm Keycloak token scope | `src/api/middleware/auth.zig` — rejects tokens whose `iss` does not match the request tenant's realm | T-test tokens rejected on T's endpoints and vice versa |

### 2.1 Test coverage required

The TEST-DESIGNER MUST add an integration test that directly verifies cross-schema
access is impossible at the DB level:

```
arrange:
  - Provision tenant T (production) and tenant T-test (test, linked to T)
  - Obtain a connection pool connection scoped to T-test (search_path = tenant_<T-test-uuid>, public)

act:
  - Execute: SELECT * FROM process_definitions
    (unqualified — resolves to tenant_<T-test-uuid>.process_definitions)
  - Execute: SELECT * FROM tenant_<T-uuid-no-dashes>.process_definitions
    (qualified — should fail if DB user has no cross-schema grant)

assertions:
  - Unqualified query returns only T-test rows
  - Qualified query raises pg error code 42501 (insufficient_privilege) OR
    42P01 (undefined_table) — either is acceptable; the platform MUST NOT grant
    cross-schema access, and the test asserts no error code 00000 (success).
```

### 2.2 Documentation note (operator warning)

The platform documentation (README or admin guide) MUST include the following warning:

> **Warning:** Do not grant PostgreSQL cross-schema SELECT or INSERT privileges
> to the BPM database user. Each tenant's schema is accessible only by the
> platform's own connection via its `search_path`. Granting cross-schema
> privileges would break tenant isolation in a way the platform cannot detect
> or prevent.

This documentation update is the responsibility of DOC-UPDATER after ENV-02 is released.

---

## ENV-03 — Definition promotion endpoint

**Route:** `POST /api/v1/tenants/:test_tenant_id/promote/:definition_name`

### 3.1 Module location

New handler: `src/api/routes/promotion.zig`  
New domain function: `src/definition/promotion.zig`

### 3.2 Public interface

```zig
// src/definition/promotion.zig

pub const PromotionError = error{
    TestTenantNotFound,            // :test_tenant_id does not exist
    NotATestTenant,                // tenant_type != 'test' → HTTP 422
    ProductionTenantInactive,      // linked production tenant status != 'ACTIVE' → HTTP 409
    ActiveDefinitionNotFound,      // no ACTIVE definition with given name in test schema → HTTP 404
    MissingDesignerRoleOnTest,     // caller lacks PROCESS_DESIGNER on test tenant → HTTP 403
    MissingDesignerRoleOnProd,     // caller lacks PROCESS_DESIGNER on production tenant → HTTP 403
    ExportFailed,                  // PD-09 export serialisation failure → HTTP 500
    ImportFailed,                  // PD-09 import failure → HTTP 500
    AuditWriteFailed,              // audit entry could not be written → HTTP 500
    PoolExhausted,
    OutOfMemory,
};

pub const PromotionResult = struct {
    definition_id: []const u8,         // new definition_id on production tenant
    version: u32,
    status: []const u8,                // always "DRAFT"
    warnings: []const []const u8,      // empty or list of unresolved service reference names
};

/// Promote the ACTIVE definition named `definition_name` from
/// `test_tenant_id`'s schema to the linked production tenant.
/// Caller must supply both tenant IDs (from path param + DB lookup) and
/// the actor's user_id (from request context) for role verification.
pub fn promoteDefinition(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    test_tenant_id: []const u8,
    definition_name: []const u8,
    actor_id: []const u8,
) PromotionError!PromotionResult
```

### 3.3 Data flow

```
Client
  │  POST /api/v1/tenants/:test_tenant_id/promote/:definition_name
  │  Authorization: Bearer <token>
  ▼
auth.zig middleware         — validate token, populate ctx.actor
rbac.zig middleware         — no static route guard here (promotion.zig checks roles dynamically)
  │
  ▼
handlePromotion()           — in src/api/routes/promotion.zig
  │  1. parse :test_tenant_id, :definition_name from path
  │  2. call domain.promoteDefinition(...)
  ▼
promoteDefinition()         — in src/definition/promotion.zig
  │  3. BEGIN TRANSACTION
  │  4. SELECT tenant_type, production_tenant_id FROM tenant WHERE id = test_tenant_id
  │       → NotATestTenant if tenant_type != 'test'
  │  5. SELECT status FROM tenant WHERE id = production_tenant_id
  │       → ProductionTenantInactive if status != 'ACTIVE'
  │  6. checkRole(actor_id, test_tenant_id, PROCESS_DESIGNER)
  │       → MissingDesignerRoleOnTest if not held
  │  7. checkRole(actor_id, production_tenant_id, PROCESS_DESIGNER)
  │       → MissingDesignerRoleOnProd if not held
  │  8. SELECT * FROM tenant_<test_uuid>.process_definitions
  │       WHERE name = $1 AND status = 'ACTIVE' LIMIT 1
  │       → ActiveDefinitionNotFound if no row
  │  9. export_import.exportDefinition(test_conn, definition_id)
  │       → ExportFailed on any error
  │ 10. export_import.importDefinition(prod_conn, export_payload, target_schema)
  │       (PD-09 import logic: version = current_max+1, status = DRAFT)
  │       → ImportFailed on any error
  │ 11. collectUnresolvedServiceRefs(prod_conn, new_definition_id)
  │       → warnings list (tenant-scoped services of test tenant not present on prod)
  │ 12. writeAuditEntry(test_conn, action=DEFINITION_PROMOTED,
  │       resource_id=source_definition_id, detail={target_definition_id, production_tenant_id})
  │ 13. writeAuditEntry(prod_conn, action=DEFINITION_PROMOTED,
  │       resource_id=new_definition_id, detail={source_definition_id, test_tenant_id})
  │ 14. COMMIT
  │ 15. return PromotionResult{definition_id, version, status="DRAFT", warnings}
  ▼
handlePromotion()           — respond HTTP 201, JSON body
```

### 3.4 Role check pattern

`checkRole` is a helper that queries the per-tenant schema's `roles` table to verify the
actor holds the `PROCESS_DESIGNER` role. Reuse the existing role-check pattern from
`src/identity/registry.zig`. The check is done within the open transaction (same connection).

```sql
-- Executed against the relevant tenant schema's connection:
SELECT EXISTS (
    SELECT 1 FROM roles
     WHERE user_id = $1
       AND role_name = 'PROCESS_DESIGNER'
) AS has_role;
```

### 3.5 Unresolved service reference detection

After import, query the production tenant's `service_catalog` to find service names that appear in the
promoted definition's node configuration but have no matching `scope='tenant'` entry owned by the
production tenant:

```sql
-- Pseudo-logic (implementer resolves exact column names from SVC-01 schema):
SELECT DISTINCT node_config->>'service_name' AS svc_name
FROM process_definitions
WHERE id = $1
  AND node_config->>'service_name' NOT IN (
      SELECT name FROM service_catalog
       WHERE (scope = 'global')
          OR (scope = 'tenant' AND owner_tenant_id = $2)
  )
  AND node_config->>'service_name' IS NOT NULL;
```

These names become the `warnings` array in the response.

### 3.6 Error → HTTP mapping

| Error | HTTP status |
|---|---|
| `NotATestTenant` | 422 |
| `ProductionTenantInactive` | 409 |
| `ActiveDefinitionNotFound` | 404 |
| `MissingDesignerRoleOnTest` | 403 |
| `MissingDesignerRoleOnProd` | 403 |
| `TestTenantNotFound` | 404 |
| `ExportFailed`, `ImportFailed`, `AuditWriteFailed` | 500 |
| `PoolExhausted` | 503 |

### 3.7 Response body (HTTP 201)

```json
{
  "definition_id": "<uuid>",
  "version": 2,
  "status": "DRAFT",
  "warnings": ["payment-gateway-v2"]
}
```

`warnings` is an empty array when no unresolved service references exist.

### 3.8 Route registration

Add to `src/main.zig` route dispatch (alongside existing `/admin/tenants/...` routes):

```zig
// POST /api/v1/tenants/{test_tenant_id}/promote/{definition_name}  (ENV-03)
if (std.mem.startsWith(u8, path, "/api/v1/tenants/") and
    std.mem.indexOf(u8, path, "/promote/") != null and
    std.mem.eql(u8, method, "POST"))
{
    // extract test_tenant_id and definition_name from path
    try promotion.handlePromotion(ctx);
    return;
}
```

### 3.9 Key invariants

- Promotion is append-only: no existing production definition is deleted or replaced.
- Promotion never activates: the imported definition always lands as `DRAFT` regardless of
  what status it had on the test tenant.
- Audit entries on both tenants are written in the same transaction as the import;
  if audit write fails, the entire promotion rolls back.
- The endpoint is idempotent in the sense that calling it N times produces N DRAFT versions
  (all with different `version` numbers and different `definition_id` values).

---

## ENV-05 — Test tenant lifecycle endpoints

### 5.1 Reset — `POST /api/v1/admin/tenants/:test_tenant_id/reset`

**Authorization:** platform-admin token only.

**Module:** `src/admin/tenant_lifecycle.zig`

#### Public interface

```zig
pub const TenantLifecycleError = error{
    TenantNotFound,             // :test_tenant_id does not exist → HTTP 404
    NotATestTenant,             // tenant_type != 'test' → HTTP 422
    TenantHasActiveInstances,   // active process instances exist → HTTP 409
    SchemaDropFailed,           // DROP SCHEMA CASCADE failed → HTTP 500 (delete only)
    RealmDeleteFailed,          // Keycloak realm deletion failed → HTTP 500 (delete only)
    PublicRowDeleteFailed,      // could not remove from tenant + related tables → HTTP 500
    PoolExhausted,
    OutOfMemory,
};

pub const ResetResult = struct {
    reset_at: []const u8,         // ISO 8601 UTC timestamp
    tables_truncated: []const []const u8,
};

/// Truncate all business data tables in the test tenant's schema,
/// preserving identity/config tables.
pub fn resetTestTenant(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    test_tenant_id: []const u8,
) TenantLifecycleError!ResetResult
```

#### Data flow — reset

```
handleReset()
  │  1. verify platform-admin role (middleware or early check in handler)
  │  2. SELECT tenant_type FROM tenant WHERE id = $1
  │       → TenantNotFound if no row
  │       → NotATestTenant if tenant_type != 'test'
  │  3. SELECT count(*) FROM tenant_<uuid>.instance_projections
  │       WHERE status NOT IN ('COMPLETED','CANCELLED','FAILED')
  │       → TenantHasActiveInstances if count > 0
  │  4. BEGIN TRANSACTION (on tenant schema connection)
  │  5. TRUNCATE in fixed order (respects FK constraints within schema):
  │       tokens, timers, tasks,
  │       dead_letter_items, webhook_subscriptions,
  │       audit_entries, audit_log,
  │       instance_projections, events_archive, events,
  │       process_definitions
  │  6. COMMIT
  │  7. return ResetResult{ reset_at=now(), tables_truncated=[...] }
```

**Tables TRUNCATED** (all in `tenant_<uuid>` schema):

| Table | Reason truncated |
|---|---|
| `events` | Process events — business data |
| `events_archive` | Archived event data |
| `instance_projections` | Process instance state |
| `tasks` | Human task records |
| `tokens` | Engine token state |
| `timers` | Timer records |
| `audit_entries` | Audit event records |
| `audit_log` | Audit log entries |
| `dead_letter_items` | DLQ entries |
| `webhook_subscriptions` | Webhook subscription records |
| `process_definitions` | Process definition versions |

**Tables PRESERVED** (identity and schema config):

| Table | Reason preserved |
|---|---|
| `users` | User accounts survive reset |
| `groups` | Group memberships survive reset |
| `roles` | Role assignments survive reset |
| `api_tokens` | API credentials survive reset |
| `event_type_registry` | Event type catalog survives reset |
| `repository_form_schemas` | Form schema definitions survive reset |

**TRUNCATE order note:** Use `TRUNCATE ... CASCADE` within the tenant schema, or truncate
in reverse FK dependency order. Since all FKs are within the tenant schema and the tables
are truncated together, `TRUNCATE events, events_archive, instance_projections, tasks,
tokens, timers, audit_entries, audit_log, dead_letter_items, webhook_subscriptions,
process_definitions CASCADE` in a single statement is safest.

**Atomicity:** The entire TRUNCATE set runs in one transaction. On any failure, the
transaction is rolled back; the tenant schema is left unmodified.

#### Response body (HTTP 200)

```json
{
  "reset_at": "2026-06-11T14:22:00Z",
  "tables_truncated": [
    "events", "events_archive", "instance_projections", "tasks", "tokens",
    "timers", "audit_entries", "audit_log", "dead_letter_items",
    "webhook_subscriptions", "process_definitions"
  ]
}
```

#### Error → HTTP mapping (reset)

| Error | HTTP status |
|---|---|
| `TenantNotFound` | 404 |
| `NotATestTenant` | 422, `"reset is only allowed for test tenants"` |
| `TenantHasActiveInstances` | 409, `"tenant has active instances; stop or cancel them before resetting"` |
| `PoolExhausted` | 503 |
| others | 500 |

---

### 5.2 Delete — `DELETE /api/v1/admin/tenants/:test_tenant_id`

**Authorization:** platform-admin token only.

#### Public interface

```zig
/// Fully decommission a test tenant:
/// 1. Validate tenant_type = 'test'
/// 2. DROP SCHEMA tenant_<uuid> CASCADE
/// 3. Delete Keycloak realm
/// 4. Remove rows from tenant, tenant_schemas,
///    tenant_hostnames, tenant_realm_binding
/// Returns nothing on success (HTTP 204).
pub fn deleteTestTenant(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    idp: *identity_provider.Manager,
    test_tenant_id: []const u8,
) TenantLifecycleError!void
```

#### Data flow — delete

```
handleDeleteTenant()
  │  1. verify platform-admin role
  │  2. SELECT tenant_type, idp_realm_id FROM tenant WHERE id = $1
  │       → TenantNotFound if no row
  │       → NotATestTenant (HTTP 422) if tenant_type != 'test'
  │  3. schema_name = "tenant_" ++ uuid_no_dashes($1)
  │  4. EXECUTE format('DROP SCHEMA %I CASCADE', schema_name)
  │       → SchemaDropFailed on error (log details; return HTTP 500; do NOT remove tenant row)
  │  5. idp.deleteRealm(idp_realm_id)
  │       → RealmDeleteFailed on error (log; return HTTP 500; tenant row NOT removed)
  │  6. BEGIN TRANSACTION (public schema connection)
  │       DELETE FROM tenant_realm_binding WHERE tenant_id = $1
  │       DELETE FROM tenant_hostnames WHERE tenant_id = $1
  │       DELETE FROM tenant_schemas WHERE tenant_id = $1
  │       DELETE FROM tenant WHERE id = $1
  │  7. COMMIT
  │  8. return void  →  HTTP 204 No Content
```

**ON DELETE RESTRICT note:** The `production_tenant_id` FK is `ON DELETE RESTRICT` pointing
from child (test) → parent (production). Deleting the test tenant (child) is always allowed.
The restrict fires only when attempting to delete the production tenant (parent) while
test children still reference it.

**Partial failure handling:**
- If `DROP SCHEMA` fails: return HTTP 500 immediately; do not proceed to Keycloak or tenant deletion. The tenant record is preserved for operator investigation.
- If Keycloak realm deletion fails after schema drop: return HTTP 500; tenant row is preserved. Operator must manually clean the orphaned realm. Log the realm ID prominently.
- If public row deletion fails: return HTTP 500; schema and realm are already gone. Operator must manually remove the stale tenant row.

#### Response

HTTP 204 No Content — empty body.

#### Error → HTTP mapping (delete)

| Error | HTTP status |
|---|---|
| `TenantNotFound` | 404 |
| `NotATestTenant` | 422, `"production tenants cannot be deleted via this endpoint; use decommission procedure"` |
| `SchemaDropFailed` | 500 |
| `RealmDeleteFailed` | 500 |
| `PublicRowDeleteFailed` | 500 |
| `PoolExhausted` | 503 |

---

### 5.3 Route registration (ENV-05)

Add to `src/main.zig` route dispatch alongside existing `/admin/tenants/` routes:

```zig
// POST /api/v1/admin/tenants/{test_tenant_id}/reset   (ENV-05)
if (std.mem.startsWith(u8, path, "/api/v1/admin/tenants/") and
    std.mem.endsWith(u8, path, "/reset") and
    std.mem.eql(u8, method, "POST"))
{
    try tenant_lifecycle.handleReset(ctx);
    return;
}

// DELETE /api/v1/admin/tenants/{test_tenant_id}   (ENV-05)
// Note: must not conflict with import/export pattern which uses sub-paths
if (std.mem.startsWith(u8, path, "/api/v1/admin/tenants/") and
    std.mem.eql(u8, method, "DELETE") and
    // ensure path is exactly /api/v1/admin/tenants/{id} with no sub-path
    std.mem.count(u8, path["/api/v1/admin/tenants/".len..], "/") == 0)
{
    try tenant_lifecycle.handleDelete(ctx);
    return;
}
```

---

---

## Error Taxonomy

All error types produced by this module, consolidated for reference. HTTP status mappings are also listed inline in the relevant subsections.

### OnboardingError extensions (ENV-01)

New variants added to `src/identity/onboarding.zig`:

| Variant | HTTP | Condition |
|---|---|---|
| `TestTenantMissingProductionRef` | 422 | `tenant_type = 'test'` but `production_tenant_id` is absent |
| `ProductionTenantMustNotHaveRef` | 422 | `tenant_type = 'production'` but `production_tenant_id` is present |
| `InvalidProductionTenantRef` | 422 | `production_tenant_id` references a non-existent or non-production tenant |

### PromotionError (ENV-03)

Defined in `src/definition/promotion.zig`:

| Variant | HTTP | Condition |
|---|---|---|
| `TestTenantNotFound` | 404 | `:test_tenant_id` does not exist |
| `NotATestTenant` | 422 | `tenant_type != 'test'` |
| `ProductionTenantInactive` | 409 | Linked production tenant `status != 'ACTIVE'` |
| `ActiveDefinitionNotFound` | 404 | No ACTIVE definition with the given name in test schema |
| `MissingDesignerRoleOnTest` | 403 | Actor lacks `PROCESS_DESIGNER` on test tenant |
| `MissingDesignerRoleOnProd` | 403 | Actor lacks `PROCESS_DESIGNER` on production tenant |
| `ExportFailed` | 500 | PD-09 export serialisation failure |
| `ImportFailed` | 500 | PD-09 import failure |
| `AuditWriteFailed` | 500 | Audit entry could not be written |
| `PoolExhausted` | 503 | Connection pool exhausted |
| `OutOfMemory` | 500 | Allocator out of memory |

### TenantLifecycleError (ENV-05)

Defined in `src/admin/tenant_lifecycle.zig`:

| Variant | HTTP | Condition |
|---|---|---|
| `TenantNotFound` | 404 | `:test_tenant_id` does not exist |
| `NotATestTenant` | 422 | `tenant_type != 'test'` (reset or delete on a production tenant) |
| `TenantHasActiveInstances` | 409 | Active process instances exist (reset only) |
| `SchemaDropFailed` | 500 | `DROP SCHEMA CASCADE` failed (delete only) |
| `RealmDeleteFailed` | 500 | Keycloak realm deletion failed (delete only) |
| `PublicRowDeleteFailed` | 500 | Could not remove rows from public tables (delete only) |
| `PoolExhausted` | 503 | Connection pool exhausted |
| `OutOfMemory` | 500 | Allocator out of memory |

---

## Key invariants (cross-cutting)

1. `tenant_type` and `production_tenant_id` are immutable after row creation — enforced at both DB (CHECK constraint) and API (PATCH guard) levels.
2. Production tenants with linked test children cannot be deleted — enforced by `ON DELETE RESTRICT`.
3. All SQL uses parameterised queries (`$1`, `$2`, etc.) — no string interpolation of user-supplied values.
4. All multi-step operations (promotion, reset, delete) are wrapped in transactions; any step failure causes a full rollback of that step's transaction.
5. `src/engine/transition.zig` is not modified by any ENV requirement.

## External dependencies

| Dependency | Used by |
|---|---|
| `src/identity/onboarding.zig` | ENV-01 (extended input + validation) |
| `src/definition/export_import.zig` (PD-09) | ENV-03 promotion |
| `src/identity/registry.zig` (role check pattern) | ENV-03 role verification |
| `src/api/middleware/auth.zig` | All endpoints (token validation) |
| `identity_provider.Manager` (Keycloak) | ENV-05 realm deletion |
| `tenant`, `tenant_schemas`, `tenant_hostnames`, `tenant_realm_binding` | ENV-01 schema, ENV-05 delete |

## Open questions

1. **ENV-03 role check scope:** The requirement says "tenant-admin with PROCESS_DESIGNER role on both tenants". Does the platform's identity model already store per-tenant role assignments in the per-tenant schema's `roles` table, or is it in `public`? Assumption: per-tenant schema `roles` table — consistent with TNT-03 isolation. Clarify with REQ-ANALYST if incorrect.
2. **ENV-05 Keycloak realm ID lookup:** The `idp_realm_id` column in `tenant` stores the Keycloak realm identifier. Confirm `provider_manager_mod.deleteRealm` accepts this as its identifier, or whether a realm name vs. realm ID distinction applies.
3. **ENV-05 reset and `webhook_subscriptions`:** The requirement says "subscriptions recreated from scratch" — this means TRUNCATE removes them. Operators must re-register webhooks after a reset. No platform-level re-seeding of subscriptions is required.
