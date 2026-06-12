# Module: ISS-403 OIDC Rate-Limit Keying

**Covers:** ISS-403 (Rate-limit keying for OIDC principals)
**Files:**
- `src/api/middleware/auth.zig` — expose OIDC principal for rate-limit key (extend or adjust AuthContext)
- `src/api/middleware/rate_limit.zig` — consume OIDC principal key (already designed in ISS-401)

**Depends on:**
- ISS-401 (shared-store rate limiter — must accept `(tenant_id, principal)` key).
- ISS-402 (OIDC token validation cache — must resolve realm and sub from validated tokens).

---

## Module purpose

This module defines how the ISS-401 shared-store rate limiter keys OIDC-authenticated requests independently from local-token-authenticated requests.

The key insight: the rate limiter needs a stable, unique identifier per authenticated principal. For local API tokens this is simply `api_token.id` (a UUID). For OIDC tokens there is no `api_tokens` row, so the key must be derived from the OIDC identity claims — specifically `(realm, sub)`, scoped by `tenant_id`.

This design also ensures **independent rate limits**: an OIDC principal hitting its limit does not throttle local token users, and vice versa. Each principal namespace has separate buckets in the shared store.

## Scope and non-goals

**In scope:**
- Definition of the `principal` string format for OIDC tokens: `"{realm}:{sub}"`.
- Integration point in `auth.zig` where the OIDC principal is constructed after successful token verification.
- Integration point in `rate_limit.zig` where the principal is consumed (handled by ISS-401 design).
- `AuthContext` extension (if needed) to carry OIDC `principal` alongside or in place of `token_id`.

**Out of scope:**
- Changing the rate-limit algorithm (ISS-401's responsibility).
- Changing the OIDC token validation flow (ISS-402's responsibility).
- Per-realm or per-principal rate-limit overrides (global `BPM_RATE_LIMIT_MAX_RPM` applies uniformly).
- Separation of rate limits between different OIDC realms (initially all OIDC principals share the same global limit; per-realm overrides are future work).

---

## Principal key definition

### Local API tokens
```
principal = token_id
```
Where `token_id` is the UUID primary key from `api_tokens.id`, as already stored in `AuthContext.token_id`.

### OIDC tokens
```
principal = "{realm}:{sub}"
```
Where:
- `realm` = the OIDC realm slug (e.g. `"bpm-default"`, `"keycloak"`). This is the realm as resolved by the identity provider during verification.
- `sub` = the `sub` claim from the verified OIDC token (the stable subject identifier within the realm).

The colon (`:`) is used as a separator. Neither `realm` nor `sub` is expected to contain a colon (realm slugs are alphanumeric/dash; `sub` values from standard OIDC providers are UUIDs or alphanumeric strings).

### Full rate-limit key
```
rate_limit_key = "{tenant_id}:{principal}"
```
The `tenant_id` prefix ensures tenant isolation: a principal in tenant A has a separate bucket from the same principal in tenant B.

---

## Integration: OIDC principal resolution in `authenticate()`

In `src/api/middleware/auth.zig`, the OIDC authentication path currently builds an `AuthContext` with:
- `user_id` = `principal.provider_subject`
- `token_id` = `principal.token_id_hint orelse "oidc"`

For ISS-403, the `principal` string for rate-limiting must be computed from the verified principal after successful OIDC token verification:

```
After identity_provider_manager.verifyBearerToken() succeeds:
  realm = principal.external_realm orelse "bpm-default"
  sub   = principal.provider_subject
  oidc_principal = std.fmt.allocPrint(allocator, "{s}:{s}", .{realm, sub})

  // Store in AuthContext for downstream use.
  AuthContext now carries:
    .token_id = oidc_principal   // for rate-limit keying by rate_limit.zig
    // OR
    .principal = oidc_principal  // new field, preferred
```

### Recommended AuthContext extension

Rather than overloading `token_id`, add an explicit `principal` field:

```zig
pub const AuthContext = struct {
    user_id: []const u8,
    role: Role,
    is_bootstrap: bool,
    token_id: []const u8,
    /// Principal key for rate limiting. Populated by auth middleware.
    /// For local tokens: same as token_id (api_tokens.id UUID).
    /// For OIDC tokens: "{realm}:{sub}" composite.
    /// For bootstrap: "bootstrap".
    /// Caller owns this string; freed with the same allocator.
    principal: []const u8,
    tenant_id: [36]u8,
    tenant_source: TenantContextSource,
};
```

**Population rules:**

| Auth path | `principal` value |
|---|---|
| Local `api_tokens` lookup | `token_id` (UUID from `api_tokens.id`) |
| OIDC token verification | `"{realm}:{sub}"` |
| Bootstrap token | `"bootstrap"` |

The `rate_limit.check()` function uses `AuthContext.principal` directly as the principal parameter.

---

## Independent rate limits guarantee

Because local token principals (UUIDs like `"3a7f8b21-0000-4000-8000-000000000001"`) and OIDC principals (composite strings like `"keycloak:abc123-def456"`) occupy disjoint namespaces, the rate-limit buckets for each are completely independent.

A malicious OIDC user cannot exhaust a local token user's rate limit, and vice versa. The only way to collide would be for a principal string to be lexically identical, which the disjoint formats prevent.

---

## Data flow

```
OIDC token arrives
        │
        ▼
authenticate() — OIDC path
        │
        ▼
identity_provider_manager.verifyBearerToken()
        │
        ├─ SUCCESS → principal = VerifiedPrincipal with external_realm, provider_subject
        │
        ▼
Construct oidc_principal = "{external_realm}:{provider_subject}"
        │
        ▼
AuthContext.principal = oidc_principal
        │
        ▼
rate_limit.check(allocator, tenant_id, AuthContext.principal, now, pool)
        │
        ├─ Key in shared store = (tenant_id, "{realm}:{sub}")
        └─ Counted independently from local token keys
```

For local token path:
```
AuthContext.principal = token_id (UUID)
  → rate_limit key = (tenant_id, UUID)
  → separate bucket space
```

---

## Error taxonomy

No new error types. The OIDC principal construction can fail with `OutOfMemory` (allocation failure), which is already handled in the existing auth error paths (returns 500 or `unauthenticated`).

---

## Key invariants

1. OIDC principal strings always follow the format `"{realm}:{sub}"` with no colons in realm or sub values.
2. Local token principal strings are always UUIDs (36 chars with hyphens).
3. The rate limiter treats all principals identically — there is no special-casing for OIDC vs local.
4. A change to `user_roles` does not affect the OIDC principal (the `sub` claim is from the IdP, not from the BPM user registry).
5. The `realm` in the principal is the external realm as reported by the identity provider, not a BPM-internal identifier.

---

## Dependencies

- `src/api/middleware/rate_limit.zig` — ISS-401 rate limiter (consumes principal).
- `src/api/middleware/auth.zig` — `AuthContext` (produces principal).
- `src/identity/provider/types.zig` — `VerifiedPrincipal` (source of realm + sub).

---

## Open questions

None. The key format is deterministic and stable given the OIDC `sub` claim.

