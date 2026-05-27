# Module: OIDC-12 Realm-Tenant Binding

## Module purpose

This module defines the data model and service functions that establish and enforce a one-to-one mapping between BPM platform tenants and identity provider realms. Every BPM tenant MUST be associated with exactly one realm at the IdP. The `tenant` table carries an `idp_realm_id` column (added by ADP-04b) that stores the provider's realm identifier. This binding enables tenant-scoped token verification (ADP-03), tenant-scoped realm provisioning (OIDC-14), and tenant-scoped user identity lookups (OIDC-11).

## Public interface

### Data model

```zig
/// Extension to the existing Tenant struct with IdP realm binding.
pub const TenantRealmBinding = struct {
    tenant_id: [36]u8,
    tenant_slug: []const u8,
    display_name: []const u8,
    /// The identity provider realm identifier associated with this tenant.
    /// For the default tenant this is 'bpm-default' (ADP-04b).
    /// Must be non-null for tenants created after the OIDC migration.
    idp_realm_id: []const u8,
    created_at: i64,
    updated_at: i64,
};
```

### Tenant creation (extended)

```zig
/// Input for creating a new tenant with an IdP realm binding.
pub const CreateTenantWithRealmInput = struct {
    tenant_slug: []const u8,
    display_name: []const u8,
    /// The IdP realm identifier. Required (enforced by the API layer).
    /// Must be unique across all tenants.
    idp_realm_id: []const u8,
    /// If true, also provision the realm at the IdP via OIDC-14 adapter.
    provision_realm: bool,
};

/// Create a new tenant with a realm binding.
///
/// Transactional steps:
///   1. Validate idp_realm_id uniqueness (no duplicate binding).
///   2. If provision_realm is true, call IdentityProvider.provisionRealm
///      (OIDC-14) — this may be a remote operation; the adapter handles
///      idempotency via desired_realm_id.
///   3. INSERT into tenant table with the idp_realm_id.
///   4. Return the new tenant record.
///
/// If provision_realm is true and step 2 fails, step 3 is NOT executed
/// (the entire creation is aborted). If step 2 succeeds but step 3 fails,
/// the realm exists at the IdP but has no tenant record — this is an
/// orphan that must be reconciled. The function logs a CRITICAL alert
/// in this case.
///
/// Error cases:
///   - DuplicateRealmBinding: idp_realm_id is already assigned to another tenant.
///   - RealmProvisioningFailed: The IdP rejected or failed to create the realm.
///   - DuplicateTenantSlug: tenant_slug already exists.
///   - PoolExhausted / PersistenceFailed / OutOfMemory: DB errors.
pub fn createTenantWithRealm(
    allocator: std.mem.Allocator,
    pool: *Pool,
    provider_manager: *ProviderManager,
    input: CreateTenantWithRealmInput,
) CreateError!TenantRealmBinding;
```

### Realm-to-tenant lookup

```zig
/// Input for resolving a tenant by its IdP realm identifier.
pub const ResolveTenantByRealmInput = struct {
    /// The realm identifier from the token's resolved issuer context.
    idp_realm_id: []const u8,
};

/// Resolve the BPM tenant associated with a given IdP realm.
///
/// This is called during auth middleware after token verification,
/// to determine which tenant the request should be scoped to.
///
/// Returns null if no tenant is bound to this realm (which is an
/// error — the token's realm should always have a tenant binding).
///
/// Error cases:
///   - PoolExhausted / PersistenceFailed / OutOfMemory: DB errors.
pub fn resolveTenantByRealm(
    allocator: std.mem.Allocator,
    pool: *Pool,
    input: ResolveTenantByRealmInput,
) LookupError!?TenantRealmBinding;
```

### Tenant-to-realm reverse lookup

```zig
/// Resolve the IdP realm identifier for a given tenant.
///
/// This is called during realm provisioning (OIDC-14) and during
/// admin operations that need to address the provider realm.
///
/// Returns null if the tenant has no IdP realm binding.
///
/// Error cases:
///   - PoolExhausted / PersistenceFailed / OutOfMemory: DB errors.
pub fn resolveRealmByTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
) LookupError!?[]const u8;
```

### Error taxonomy

```zig
pub const RealmBindingError = error{
    /// The idp_realm_id is already assigned to another tenant.
    DuplicateRealmBinding,
    /// The IdP rejected realm provisioning.
    RealmProvisioningFailed,
    /// Tenant slug already exists.
    DuplicateTenantSlug,
    /// Database pool exhausted.
    PoolExhausted,
    /// Generic persistence failure.
    PersistenceFailed,
    /// Allocator exhausted.
    OutOfMemory,
};

pub const LookupError = error{
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};
```

## Key invariants

1. **One-to-one binding.** Each tenant has exactly one `idp_realm_id`. Each `idp_realm_id` maps to exactly one tenant. Enforced by a `UNIQUE` constraint on `tenant.idp_realm_id`.

2. **Default tenant binding.** The default tenant (UUID `00000000-0000-0000-0000-000000000000`) has `idp_realm_id = 'bpm-default'` seeded by ADP-04b's migration. This value must never change.

3. **Realm ID is immutable after creation.** Once a tenant is created with an `idp_realm_id`, the binding cannot be changed (unless the old realm is deleted via OIDC-15 and a new one provisioned). This prevents security gaps where a token from realm X could access tenant Y's data.

4. **Tenant creation requires `idp_realm_id`.** After the OIDC migration is active, the tenant creation API MUST reject requests without an `idp_realm_id`. During the migration coexistence period, NULL is allowed for backwards compatibility.

5. **Realm-to-tenant lookup is the authoritative reverse path.** When the auth middleware resolves the issuer from a token, it gets a realm identifier. It must call `resolveTenantByRealm(idp_realm_id)` to determine the tenant context. This is the foundation of ADP-03 tenant scoping.

## DB tables/columns touched

### Migration: extends the `tenant` table (ADP-04b)

```sql
-- ADP-04b (already defined, shown here for reference):
ALTER TABLE tenant
ADD COLUMN IF NOT EXISTS idp_realm_id TEXT NULL;

-- Uniqueness constraint for the one-to-one binding.
CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_idp_realm_id
ON tenant (idp_realm_id)
WHERE idp_realm_id IS NOT NULL;

-- Seed the default tenant binding.
UPDATE tenant
SET idp_realm_id = 'bpm-default'
WHERE tenant_id = '00000000-0000-0000-0000-000000000000'
  AND idp_realm_id IS NULL;
```

### New queries

#### Tenant creation with realm binding

```sql
INSERT INTO tenant (tenant_id, tenant_slug, display_name, idp_realm_id, created_at, updated_at)
VALUES ($1, $2, $3, $4, NOW(), NOW())
ON CONFLICT (tenant_slug) DO NOTHING
RETURNING *;
```

#### Lookup tenant by realm

```sql
SELECT * FROM tenant WHERE idp_realm_id = $1;
```

#### Lookup realm by tenant

```sql
SELECT idp_realm_id FROM tenant WHERE tenant_id = $1;
```

## Cross-module dependencies

### This module calls / depends on:

| Module | Why |
|---|---|
| `src/identity/provider/manager.zig` | `provisionRealm` call when `CreateTenantWithRealmInput.provision_realm` is true (OIDC-14) |
| `src/db/pool.zig` | Database access for tenant CRUD and lookups |
| `src/identity/registry.zig` | Existing `Tenant` type (extended) |

### This module must NOT depend on:

| Module | Why |
|---|---|
| `src/identity/provider/adapters/keycloak/*` | Provider-agnostic — only consumes the `IdentityProvider` interface |
| `src/oidc/jit_provisioning.zig` | Realm binding is a prerequisite for JIT, not a consumer |
| `src/api/middleware/auth.zig` | Auth middleware calls this module, not the other way around |
| Any HTTP or route handler module | Pure lookup and data model logic |

## Identified risks / open questions

1. **Orphan realms at the IdP.** If tenant creation succeeds at the IdP (realm provisioned) but the DB INSERT fails (e.g., connection loss after the remote call), an orphan realm exists at the provider with no tenant record. A cleanup/reconciliation process is needed. Options:
   - A periodic background job that lists realms at the IdP and cross-references with the tenant table.
   - An idempotent "claim realm" step that can detect and reconcile orphans on next tenant creation attempt.

2. **Cross-realm token confusion.** If a token from realm X (bound to tenant A) is presented to a request already scoped to tenant B (e.g., via cookie or URL), the realm-tenant binding check (`resolveTenantByRealm`) should override the request-scoped tenant. This needs clear precedence rules in the auth middleware.

3. **Migration of existing tenants.** Existing tenants (pre-OIDC) have NULL `idp_realm_id`. Their `idp_realm_id` can be set to `'bpm-default'` (the shared default realm) during migration, but this effectively merges all pre-existing tenants into a single realm. If separation is needed, each tenant must get its own realm, requiring a phased migration.
