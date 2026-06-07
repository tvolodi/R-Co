# ISS-0068: Onboarding Schema Provisioning Fix — Design Artefact

**Issue:** ISS-0068  
**Requirement:** SPT-01  
**Type:** E (novel cross-cutting fix — touches onboarding saga, startup path, and migration tooling)  
**Status:** DESIGN  

---

## 1. Module Purpose

`executeSaga()` in `src/identity/onboarding.zig` creates a `tenant` row and then provisions Keycloak (realm, user, roles, client, hostname), but it never calls `provisionTenantSchema()` from `src/db/provisioning.zig`. This fix inserts a schema-provisioning step between DB row creation and Keycloak provisioning, extends the `SagaState` with a `schema_provisioned` flag so the compensating path can drop the schema on failure, adds a startup idempotent call for the default tenant in `src/main.zig`, and retroactively provisions schemas for all pre-existing tenants via a new migration.

---

## 2. Public Interface Changes

### 2.1 `src/identity/onboarding.zig`

#### `SagaState` (private struct — modified)

```zig
const SagaState = struct {
    tenant_created:    bool = false,
    schema_provisioned: bool = false,   // NEW — guards compensation teardown
    realm_provisioned: bool = false,
    user_provisioned:  bool = false,
    roles_granted:     bool = false,
    client_provisioned: bool = false,
    hostname_bound:    bool = false,
    tenant_id:   ?[]const u8 = null,
    tenant_slug: ?[]const u8 = null,
    realm_id:    ?[]const u8 = null,
    admin_user_id: ?[]const u8 = null,
    client_id:   ?[]const u8 = null,
};
```

No other fields are added or removed. The new `schema_provisioned` flag follows the same pattern as the existing boolean flags.

#### `executeSaga()` — modified signature

```zig
pub fn executeSaga(
    allocator: std.mem.Allocator,
    manager: provider_manager_mod.Manager,
    pool: *pool_mod.Pool,
    input: OnboardingInput,
    registry_onboarding_id: ?[]const u8,
    migrations_dir: []const u8,          // NEW — passed through to provisionTenantSchema
) (OnboardingError || provider_errors.ProviderError)!OnboardingResult
```

`migrations_dir` is a compile-time-baked absolute path or runtime environment path. It is forwarded to `db_provisioning.provisionTenantSchema()`. The return type and all other parameters are unchanged.

#### New private helper — `dropTenantSchemaInDb()`

```zig
fn dropTenantSchemaInDb(
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
) void
```

Calls `SELECT bpm_drop_tenant_schema($1::uuid)` with `tenant_id` as the parameter. Errors are silently swallowed (same pattern as other compensation helpers). Used exclusively in `compensate()`.

**Important:** this helper MUST be defined only if `bpm_drop_tenant_schema` is present in the DB (it is defined by migration 061 — see §5). The function executes the SQL via `pool.acquire()` / `pool.release()` / `conn.exec()`. On `PoolError.ExhaustedPool` or any other error, the function returns without panicking — compensation is best-effort.

#### `compensate()` — modified

Add the following block **before** the `tenant_created` / `deleteTenantInDb` block, so the schema is dropped before the tenant row:

```zig
// Drop tenant schema if it was provisioned.
if (saga.schema_provisioned and saga.tenant_id != null) {
    dropTenantSchemaInDb(pool, saga.tenant_id.?);
    saga.schema_provisioned = false;
}
```

The full compensation order (reverse of success order) is:
1. Unbind hostname (if `hostname_bound`)
2. _(no client delete — not implemented in manager)_
3. _(no user delete — not implemented in manager)_
4. Delete Keycloak realm (if `realm_provisioned`)
5. **Drop tenant schema** (if `schema_provisioned`) ← NEW, inserted here
6. Delete tenant DB row (if `tenant_created`)

Schema drop is placed after Keycloak realm deletion and before tenant row deletion so that if `bpm_drop_tenant_schema` fails (e.g. the schema has dependent objects from partial Keycloak provisioning), the tenant row can still be deleted.

### 2.2 `src/api/routes/onboarding.zig`

#### `SagaContext` — modified

```zig
const SagaContext = struct {
    pool:           *pool_mod.Pool,
    manager:        identity_provider.manager.Manager,
    onboarding_id:  []u8,
    input:          onboarding_mod.OnboardingInput,
    migrations_dir: []const u8,   // NEW — compile-time constant, no allocation needed
};
```

`migrations_dir` is not heap-allocated; it points to the compile-time `build_options.migrations_dir` string literal. No `dupe` or `free` is needed for it in `SagaContext` creation or cleanup.

#### `handleOnboarding()` — modified (SagaContext initialisation)

```zig
const build_options = @import("build_options");

// ...inside the `.fresh` branch where saga_ctx is created:
saga_ctx.* = SagaContext{
    .pool           = service.registry.pool,
    .manager        = auth.getIdentityProviderManager(),
    .onboarding_id  = gpa.dupe(u8, onboarding_id) catch { ... },
    .input          = dupeOnboardingInput(gpa, input.value) catch { ... },
    .migrations_dir = build_options.migrations_dir,   // NEW
};
```

No other changes to `handleOnboarding()`.

#### `runSagaBackground()` — modified

```zig
const result = onboarding_mod.executeSaga(
    gpa,
    ctx.manager,
    ctx.pool,
    ctx.input,
    ctx.onboarding_id,
    ctx.migrations_dir,   // NEW — forwarded to executeSaga
) catch |err| { ... };
```

### 2.3 `src/main.zig` — startup default-tenant schema provisioning

After `Pool.init()` succeeds (inside `runApiServer()`), add a call to provision the default-tenant schema before the HTTP server begins accepting connections. Call `db_provisioning.provisionTenantSchema` with a hardcoded default-tenant UUID and `build_options.migrations_dir`. On error: log at WARN level via `obs_logger.log` with `"error"` and `"tenant_id"` fields, then continue — non-fatal. On success: no log (the call is idempotent).

```zig
// Placement: inside runApiServer(), after pool.init(), before server.listen()
const default_tenant_id = "00000000-0000-0000-0000-000000000000";
db_provisioning.provisionTenantSchema(
    allocator, &pool, default_tenant_id, build_options.migrations_dir,
) catch |err| {
    // Log WARN via obs_logger with keys "error" and "tenant_id"; non-fatal.
    _ = err; // suppress unused-var; actual obs_logger.log call goes here
};
// On success: silent (provisionTenantSchema is idempotent).
```

**Placement:** immediately after:
```zig
var pool = try db_pool.Pool.init(io, allocator, .{ .url = config.db_url, .pool_size = 10 });
defer pool.deinit();
```

and before the `var def_store = ...` lines.

**Why non-fatal:** the startup provisioning is a belt-and-suspenders guard. The retroactive migration 061 is the authoritative backfill. If the pool is available but provisioning fails (e.g. `bpm_provision_tenant_schema` not yet deployed), the server should still start and serve requests — the default-tenant schema may already exist from a prior run.

---

## 3. Data Flow Diagram

**Onboarding request path (`executeSaga` saga steps):**

```
POST /api/v1/tenants → handleOnboarding() → runSagaBackground()
    │
    ▼
executeSaga(allocator, manager, pool, input, onboarding_id, migrations_dir)
    │
    ├─ Step 1 : createTenantInDb()           → saga.tenant_created = true
    │
    ├─ Step 1b: provisionTenantSchema()       → saga.schema_provisioned = true  [NEW]
    │            (idempotency check → bpm_provision_tenant_schema → runForSchema)
    │
    ├─ Step 2 : provisionRealm()              → saga.realm_provisioned = true
    ├─ Step 3 : provisionUser()               → saga.user_provisioned = true
    ├─ Step 4 : grantRoles()                  → saga.roles_granted = true
    ├─ Step 5 : provisionClient()             → saga.client_provisioned = true
    ├─ Step 6 : bindHostname()                → saga.hostname_bound = true
    └─ Step 7 : verifyDiscovery()             → OnboardingResult (success)
```

**Compensation order and auxiliary paths:**

```
On any step failure → compensate() in reverse:
  unbindHostname → deleteRealm → dropTenantSchemaInDb [NEW] → deleteTenantInDb

Startup (main.zig, after Pool.init()):
  provisionTenantSchema("00000000-…-0000", migrations_dir)  — idempotent

Retroactive (migration 061, zig build migrate):
  FOR each tenant NOT IN tenant_schemas:
    SAVEPOINT → bpm_provision_tenant_schema(id) → RELEASE/ROLLBACK
```

---

## 4. Error Taxonomy

### 4.1 New failure modes in `executeSaga()`

| Error | Condition | Returned as |
|---|---|---|
| `ProvisionError.InvalidTenantId` | `tenant.tenant_id` is empty or not 36 chars. Should never occur after `createTenantInDb()` succeeds — if it does, it is a DB bug. | `OnboardingError.PersistenceFailed` |
| `ProvisionError.PoolExhausted` | Cannot acquire a DB connection during idempotency check, schema creation, or migration run. | `OnboardingError.PoolExhausted` |
| `ProvisionError.SchemaCreationFailed` | `bpm_provision_tenant_schema()` SQL call failed (e.g. insufficient privileges, unexpected DB error). | `OnboardingError.PersistenceFailed` |
| `ProvisionError.MigrationFailed` | `Migrations.runForSchema()` returned any `MigrationError` variant. | `OnboardingError.PersistenceFailed` |
| `ProvisionError.RegistryUpdateFailed` | `UPDATE tenant_schemas SET migrations_applied_at` failed. | `OnboardingError.PersistenceFailed` |
| `ProvisionError.QueryFailed` | Idempotency check query failed. | `OnboardingError.PersistenceFailed` |

All `ProvisionError` variants are mapped to `OnboardingError.PersistenceFailed` unless the variant is `PoolExhausted`, which maps to `OnboardingError.PoolExhausted`. The `OutOfMemory` path from Zig stdlib allocations remains `OnboardingError.OutOfMemory`.

**Error mapping (step 1b placement):** The `catch |err|` block maps `PoolExhausted → PoolExhausted`, `OutOfMemory → OutOfMemory`, and all other variants → `PersistenceFailed`. On success, `saga.schema_provisioned = true` is set. No Keycloak has been touched at this point, so no Keycloak compensation is needed on schema failure. The `errdefer compensate(...)` at the top of `executeSaga()` will fire on the returned error; `compensate()` will see `saga.schema_provisioned = true` and call `dropTenantSchemaInDb()` correctly.

### 4.2 `dropTenantSchemaInDb()` — no new errors exposed

`dropTenantSchemaInDb()` swallows all errors. It uses `pool.acquire()` / `conn.exec()` / `pool.release()`. If the pool is exhausted or the SQL fails, the schema is not dropped but the function returns silently. This is consistent with the other compensation helpers (`deleteTenantInDb`, `unbindHostname`). A log line at WARN level should be emitted on failure.

The function executes `SELECT bpm_drop_tenant_schema($1::uuid)` with `tenant_id` as the bound parameter. It returns `void` — no error propagation. Implementation follows the same pattern as `deleteTenantInDb` in the same file.

### 4.3 Startup provisioning — non-fatal

The `provisionTenantSchema` call in `main.zig` at startup logs a WARN on failure but does not crash the server. See §2.3.

---

## 5. New Migration — 061_retroactive_tenant_schema_provision.sql

**File:** `migrations/061_retroactive_tenant_schema_provision.sql`  
**Sequence:** 061 — the next after `060_schema_per_tenant_bootstrap.sql`  

**Purpose:** (a) Define `bpm_drop_tenant_schema()` for compensation use. (b) Retroactively provision schemas for every tenant in `tenant` not already present in `tenant_schemas`.

**Statement 1 — `bpm_drop_tenant_schema(p_tenant_id UUID)` function:**

`CREATE OR REPLACE FUNCTION` in PL/pgSQL. Derives the schema name using the same convention as `bpm_provision_tenant_schema` (UUID with hyphens removed, prefixed with `tenant_`; all-zeros UUID maps to `tenant_default`). Executes `DROP SCHEMA IF EXISTS <name> CASCADE` then `DELETE FROM tenant_schemas WHERE tenant_id = $1`. Always returns void. Idempotent — safe if the schema or registry row is already absent.

**Statement 2 — Retroactive `DO` block:**

Iterates all rows in `tenant` whose `id` does not yet appear in `tenant_schemas`, ordered by `created_at`. For each such tenant, wraps `PERFORM bpm_provision_tenant_schema(r.id)` in a named per-tenant SAVEPOINT. On exception, rolls back to the SAVEPOINT and emits a `RAISE WARNING` — the loop continues with the next tenant. On success, releases the SAVEPOINT.

**Idempotency guarantee:**
- `CREATE OR REPLACE FUNCTION` is always safe to re-run.
- The `WHERE id NOT IN (SELECT tenant_id FROM tenant_schemas)` predicate means tenants already provisioned are skipped.
- `bpm_provision_tenant_schema()` itself uses `ON CONFLICT DO NOTHING` and `CREATE SCHEMA IF NOT EXISTS`, so calling it twice is harmless.

---

## 6. State Transitions

The onboarding saga has one new state node: `SCHEMA_PROVISIONED`.

```
PENDING
  ├─ createTenantInDb() → TENANT_CREATED
  │       └─ failure → FAILED (compensate: nothing done yet)
  ├─ provisionTenantSchema() → SCHEMA_PROVISIONED          ← NEW
  │       └─ failure → FAILED (compensate: delete tenant row)
  ├─ provisionRealm() → REALM_PROVISIONED
  │       └─ failure → FAILED (compensate: drop schema, delete tenant row)
  ├─ ... (existing states unchanged)
  └─ COMPLETED
```

---

## 7. Invariants

**Invariant I-1 (data consistency):**  
After `executeSaga()` returns `OnboardingResult` (success), exactly one row exists in `tenant_schemas` for `tenant.tenant_id`, and a physical PostgreSQL schema named `tenant_<uuid_no_dashes>` (or `tenant_default` for the all-zeros UUID) exists in the database.

**Invariant I-2 (compensation completeness):**  
After `compensate()` completes for a failed saga that reached the `SCHEMA_PROVISIONED` state, the row in `tenant_schemas` for the tenant is absent and the physical schema has been dropped (best-effort; DB errors during drop are logged but not propagated).

---

## 8. Dependencies

| Dependency | Direction | Note |
|---|---|---|
| `src/db/provisioning.zig` | onboarding → provisioning | `executeSaga()` calls `provisionTenantSchema()`. Import as `const db_provisioning = @import("db/provisioning.zig")` — verify alias matches `build.zig` imports for `onboarding.zig` module. |
| `src/db/pool.zig` | provisioning → pool | Unchanged — `provisionTenantSchema` already uses `Pool`. |
| `src/db/migrations.zig` | provisioning → migrations | Unchanged — `provisionTenantSchema` already calls `Migrations.runForSchema`. |
| `build_options` | onboarding routes, main.zig → build | `migrations_dir` is a compile-time string literal embedded via `build_options.addOption`. Import: `const build_options = @import("build_options");`. |
| Migration 060 | 061 depends on 060 | `bpm_provision_tenant_schema()` must exist before 061 runs its retroactive DO block. |

**Must NOT depend on:**
- Any HTTP handler or auth middleware (provisioning is pure DB).
- Any Keycloak / identity-provider module (provisioning is DB-only).
- Any per-request allocator — the startup call in `main.zig` uses the global `allocator`.

---

## 9. Open Questions

None. All design decisions derive directly from the issue evidence, existing codebase conventions, and the fix plan in ISS-0068.

---

## 10. Checklist for BACKEND-DEV

- [ ] Add `schema_provisioned: bool = false` to `SagaState` in `src/identity/onboarding.zig`
- [ ] Add `migrations_dir: []const u8` parameter to `executeSaga()`
- [ ] Insert schema provisioning step 1b with error mapping (§4.1)
- [ ] Set `saga.schema_provisioned = true` on success
- [ ] Add `dropTenantSchemaInDb()` private helper (§4.2)
- [ ] Update `compensate()` to call `dropTenantSchemaInDb()` when `schema_provisioned` (§2.1)
- [ ] Add `migrations_dir: []const u8` to `SagaContext` in `src/api/routes/onboarding.zig`
- [ ] Pass `build_options.migrations_dir` into `SagaContext` in `handleOnboarding()`
- [ ] Pass `ctx.migrations_dir` to `executeSaga()` in `runSagaBackground()`
- [ ] Add startup provisioning call in `src/main.zig` (§2.3)
- [ ] Create `migrations/061_retroactive_tenant_schema_provision.sql` (§5)
- [ ] `zig build` exits 0
- [ ] `zig build test` exits 0
- [ ] `zig build migrate` exits 0 (applies migration 061)
- [ ] After migrate: `SELECT count(*) FROM tenant_schemas` ≥ number of rows in `tenant`
