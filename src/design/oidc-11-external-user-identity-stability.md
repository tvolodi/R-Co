# Module: OIDC-11 External User Identity Stability

## Module purpose

This module defines the invariants, data structures, and verification logic that ensure the OIDC `sub` claim is treated as the stable, immutable identifier for an external user across the platform. Changes to mutable IdP attributes (email, username, display name) MUST NOT change the local `user_id` or break the association between the external identity and the user's task assignments, audit attribution, or process history. The authoritative lookup path is `(external_realm, external_id)` per ADP-04a's unique index — this module hardens that contract and adds runtime verification.

## Public interface

### Identity lookup and verification

```zig
/// Input for resolving a local user from an OIDC token's identity.
/// The caller provides the resolved realm and the `sub` claim value
/// directly — this module does not parse the token.
pub const IdentityLookupInput = struct {
    /// The resolved provider realm name (from token `iss` or adapter config).
    external_realm: []const u8,
    /// The `sub` claim from the verified token.
    external_id: []const u8,
    /// Tenant context that the request is scoped to.
    tenant_id: []const u8,
};

/// Result of resolving a stable external identity.
pub const IdentityLookupResult = struct {
    /// The local user record matched by (external_realm, external_id).
    user: User,
    /// Whether the email or display_name in the token differs from
    /// the stored value (for audit / OIDC-10 sync trigger).
    has_profile_drift: bool,
};

/// Resolve a local user by the authoritative external identity tuple.
///
/// Assumptions:
///   - ADP-04a guarantees at most one user per (external_realm, external_id).
///   - The caller has already verified the token signature and extracted
///     the realm and `sub` from the JWT claims.
///
/// Error cases:
///   - UserNotFound: No local user maps to this (realm, sub) pair.
///   - TenantMismatch: The resolved user's tenant_id does not match
///     the request-scoped tenant_id.
///   - PoolExhausted / PersistenceFailed / OutOfMemory: DB errors.
pub fn resolveByExternalIdentity(
    allocator: std.mem.Allocator,
    pool: *Pool,
    input: IdentityLookupInput,
) LookupError!IdentityLookupResult;
```

### Stability assertion check

```zig
/// Assert that the user's external identity has not drifted.
///
/// This is a safety check called during auth middleware after
/// `resolveByExternalIdentity`. It compares the token's `sub` against
/// the stored `external_id` and logs a CRITICAL audit event if they
/// differ (should never happen — indicates data corruption or a
/// concurrent migration defect).
///
/// This function does NOT mutate any data. It is a pure verification step.
pub fn assertStableIdentity(
    stored_external_id: []const u8,
    token_sub: []const u8,
) StableIdentityError!void;
```

### Configuring the authoritative lookup path (auth middleware integration)

Within `auth.zig`, the OIDC JWT path previously used `principal.provider_subject` directly as `user_id`. After OIDC-11, the path MUST instead call `resolveByExternalIdentity` to obtain the local `user_id`:

```
Before:  user_id = principal.provider_subject
After:   lookup  = identity_stability.resolveByExternalIdentity(
                      allocator, pool, IdentityLookupInput{
                          .external_realm = principal.external_realm.?,
                          .external_id    = principal.provider_subject,
                          .tenant_id      = resolved_tenant_id,
                      })
         user_id  = lookup.user.user_id
```

This change is gated by the JIT-enabled check from OIDC-09: when JIT is enabled, the OIDC-09 orchestrator calls `createOrGetJitOidcUser` (which already uses the ADP-04a unique index), so identity stability is guaranteed by the DB constraint. When JIT is not yet enabled (migration coexistence), the old direct-subject path remains. OIDC-11 adds the explicit `resolveByExternalIdentity` function for code clarity and independent testing.

## Key data structures

No new structs beyond `IdentityLookupInput` and `IdentityLookupResult` above. The function consumes existing types:

| Type | Source | Role |
|---|---|---|
| `User` | `src/identity/registry.zig` | Local user record with `user_id`, `external_id`, `external_realm`, `tenant_id` |
| `Pool` | `src/db/pool.zig` | Database connection pool |
| `VerifiedPrincipal` | `src/identity/provider/types.zig` | Contains `provider_subject`, `external_realm` |

## Key invariants

1. **`sub` is immutable for the lifetime of the external identity.** Keycloak and all conforming OIDC providers guarantee that `sub` never changes for a given user. The platform MUST NOT ever treat `email` or `preferred_username` as a stable identifier.

2. **`(external_realm, external_id)` is unique.** ADP-04a's unique index (`CREATE UNIQUE INDEX ON users (external_realm, external_id) WHERE external_id IS NOT NULL`) enforces this at the DB level. The platform must only query by this tuple, never by email or username.

3. **Email/username changes at the IdP MUST NOT change local `user_id`.** The local `user_id` is a surrogate UUID generated at user creation (IDN-01). The only link to the external identity is `external_id` + `external_realm`. Mutable attributes (email, display_name) are updated in-place via OIDC-10 attribute sync, never by creating a new user.

4. **Renaming at the IdP is transparent.** After a Keycloak user changes their email or username, the next authentication triggers OIDC-10's `syncAttributesFromIdentityContext`, which updates the stored `display_name` and `email` in-place. The local `user_id`, all task assignments, audit attribution, and process history remain unchanged.

5. **No fallback to email-based lookup.** Code paths that resolve users MUST NOT use email or username as a lookup key for OIDC users. The only authoritative lookup is `(external_realm, external_id)`.

## DB tables/columns touched

This module does NOT introduce new migrations. It relies on columns already defined by ADP-04a:

| Table | Column | Type | Role |
|---|---|---|---|
| `users` | `external_id` | `TEXT NULL` | The OIDC `sub` claim value |
| `users` | `external_realm` | `TEXT NULL` | The realm/issuer identifier |
| `users` | `auth_source` | `TEXT NOT NULL DEFAULT 'internal'` | Discriminator: `'internal'` vs `'oidc'` |

### Existing constraints (ADP-04a)

```sql
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_external_identity
ON users (external_realm, external_id)
WHERE external_id IS NOT NULL;
```

## Cross-module dependencies

### This module calls / depends on:

| Module | Why |
|---|---|
| `src/identity/registry.zig` | `User` type, `selectUserByExternalId` registry function |
| `src/db/pool.zig` | Database access for identity lookup |
| `src/obs/audit.zig` | Audit event emission for stability assertion failures |

### This module must NOT depend on:

| Module | Why |
|---|---|
| `src/identity/provider/adapters/keycloak/*` | No Keycloak-specific code — lookup is provider-agnostic |
| `src/oidc/claim_mapping.zig` | Claim mapping is upstream; this module only consumes the extracted `sub` |
| `src/oidc/jit_provisioning.zig` | JIT orchestration calls this module, not the other way around |
| Any HTTP or route handler module | Pure lookup logic, no HTTP awareness |

## Identified risks / open questions

1. **What if `external_realm` is null?** An OIDC user without a realm association cannot be resolved. The auth pipeline should reject such tokens before reaching this module. Consider adding a non-null constraint on `external_realm` for OIDC users (`CHECK (auth_source != 'oidc' OR external_realm IS NOT NULL)`).

2. **Cross-tenant `sub` collision:** Two different Keycloak instances could issue the same `sub` value for different users. The `external_realm` qualifier (which includes the issuer URL) prevents collision. The design assumes `external_realm` is populated from the resolved issuer, not from a user-supplied value.

3. **Attribute drift detection threshold:** `has_profile_drift` in `IdentityLookupResult` is a boolean. For high-traffic realms, the attribute comparison (at every auth) may add overhead. OIDC-10's `syncAttributesFromIdentityContext` already does the comparison — this flag is a hint for the caller to skip OIDC-10 when false. If profiling shows overhead, caching the last-sync timestamp per user could reduce comparisons.
