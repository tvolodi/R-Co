# Module: ISS-402 OIDC Token Validation Cache Keying & Revocation

**Covers:** ISS-402 (OIDC token validation cache keying & revocation)
**Files:**
- `src/oidc/jwks.zig` — JWKS validation + token cache + jti denylist (new/replacement module)
- `src/api/middleware/auth.zig` — integrate OIDC cache lookup into `authenticate()` path

**Depends on:**
- Existing `src/identity/provider/oidc/jwks_cache.zig` (in-memory JWKS key-ID cache — OIDC-06)
- Existing `src/identity/provider/manager.zig` (provider manager that dispatches `verifyBearerToken`)
- `src/identity/provider/interface.zig` (provider interface)
- `src/identity/provider/types.zig` (`VerifiedPrincipal` struct)

---

## Module purpose

This module introduces a two-layer cache for OIDC token validation and a jti-based revocation mechanism. The architecture document v1.1 (sec.12.1) identified that OIDC access tokens have no `api_tokens` row, so the existing LRU token cache and `LISTEN/NOTIFY` revocation channel do not cover them.

The design adds:
1. **Validation result cache** keyed by `(realm, jti)` with TTL bounded by the token's `exp` claim.
2. **jti denylist** (in-memory HashMap with per-entry TTL) for revocation.
3. **Realm logout** support that adds all active jti for a realm to the denylist.

No database schema changes are required — all cache state is in-memory, mirroring the existing `JwksCache` approach.

## Scope and non-goals

**In scope:**
- New module `src/oidc/jwks.zig` containing:
  - `TokenValidationCache` — `(realm, jti)` to validation result, TTL capped at token expiry.
  - `JtiDenylist` — in-memory set of revoked jti with per-entry expiry.
- Integration into `auth.zig` OIDC path: check cache before full JWKS verification; check denylist after cache hit.
- Realm logout: public API to bulk-revoke all active jti for a realm.
- Periodic cleanup of expired cache entries and denylist entries.

**Out of scope:**
- Persisting the cache or denylist to the database (purely in-memory).
- Cluster-wide revocation signal (LISTEN/NOTIFY for OIDC). Each node maintains its own denylist; cross-node consistency is eventual.
- Changes to the existing `JwksCache` (JWKS key-ID cache in `src/identity/provider/oidc/jwks_cache.zig`). ISS-402 adds a separate cache layer for *validation results*, not for key-IDs.

---

## Public interface

### `src/oidc/jwks.zig` (new file)

### Core constants and key types

```zig
pub const MAX_CACHE_TTL_SECONDS: i64 = 300; // 5 minutes

pub const TokenCacheKey = struct {
    realm: []const u8,  // OIDC realm slug (e.g. "bpm-default")
    jti: []const u8,    // JWT ID claim (unique per token)
};

pub const CachedValidation = struct {
    valid: bool,
    principal_json: []const u8,  // serialised VerifiedPrincipal (only meaningful if valid)
    expires_at: i64,
};
```

### TokenValidationCache — public interface

```zig
pub const TokenValidationCache = struct {
    pub fn init(allocator: std.mem.Allocator) TokenValidationCache;
    pub fn deinit(self: *TokenValidationCache) void;

    // Look up cached result. null = miss or expired.
    pub fn get(self: *TokenValidationCache, realm: []const u8, jti: []const u8, now: i64) ?CachedValidation;

    // Store result. TTL = min(exp - now, MAX_CACHE_TTL_SECONDS), clamped >= 1.
    pub fn put(self: *TokenValidationCache, realm: []const u8, jti: []const u8, valid: bool, principal_json: []const u8, exp: i64, now: i64) error{OutOfMemory}!void;

    // Remove all expired entries.
    pub fn evictExpired(self: *TokenValidationCache, now: i64) void;
};
```

### JtiDenylist — public interface

```zig
pub const JtiDenylist = struct {
    pub fn init(allocator: std.mem.Allocator) JtiDenylist;
    pub fn deinit(self: *JtiDenylist) void;

    // Add a jti to the denylist. expires_at = token.exp, bounded by now + MAX_CACHE_TTL_SECONDS.
    pub fn add(self: *JtiDenylist, allocator: std.mem.Allocator, realm: []const u8, jti: []const u8, expires_at: i64) error{OutOfMemory}!void;

    // Check if (realm, jti) is actively revoked (now < expires_at).
    pub fn isRevoked(self: *const JtiDenylist, realm: []const u8, jti: []const u8, now: i64) bool;

    // Bulk-revoke all active tokens for a realm. Called on realm logout.
    pub fn revokeRealm(self: *JtiDenylist, allocator: std.mem.Allocator, cache: *TokenValidationCache, realm: []const u8, now: i64) error{OutOfMemory}!void;

    // Remove expired entries.
    pub fn evictExpired(self: *JtiDenylist, now: i64) void;
};
```
};
```

---

## OIDC token validation flow (revised)

The `authenticate()` function in `src/api/middleware/auth.zig` currently dispatches OIDC tokens to `identity_provider_manager.verifyBearerToken()`, which performs full JWKS signature verification on every request. The revised flow inserts a cache layer:

```
authenticate() for oidc_jwt tokens:
  1. Extract realm from the token (via provider's resolveRealm or default).
  2. Extract jti from the token payload (JWT ID claim).
  3. Compute now = std.time.timestamp().

  4. Check denylist: if jtiDenylist.isRevoked(realm, jti, now):
       return 401 (token_revoked).

  5. Check validation cache: if tokenCache.get(realm, jti, now):
       case valid=true:  rebuild AuthContext from cached principal_json → return .authenticated.
       case valid=false: return 401 (previously known invalid).

  6. Cache miss: perform full verification via identity_provider_manager.verifyBearerToken().
     - On success: cache with valid=true, TTL=min(exp-now, 5min).
     - On failure: cache with valid=false, TTL=60s (shorter, to allow recovery if upstream becomes available).
     - Return the result (authenticated or error).

  7. If verification succeeds, return AuthContext as normal.
```

---

## Realm logout

When a realm logout is triggered (via admin API or Keycloak admin event):

```
realmLogout(realm):
  // 1. Bulk-revoke all active tokens for the realm.
  jtiDenylist.revokeRealm(realm, cache, now):
    for each entry in tokenCache.entries:
      if entry.key.realm == realm and entry.valid:
        jtiDenylist.add(realm, entry.key.jti, entry.value.expires_at)

  // 2. Invalidate cache entries for the realm.
  tokenCache.evictRealm(realm):
    for each entry in tokenCache.entries:
      if entry.key.realm == realm:
        remove entry
```

After realm logout, all subsequent requests with tokens from that realm will hit the denylist and return 401, even if the token is still within its `exp`.

---

## Error taxonomy

| Error | Source | HTTP | Meaning |
|---|---|---|---|
| `OutOfMemory` | Cache put / denylist add | 500 | Allocator exhausted |
| Existing auth errors | `authenticate()` | 401/403 | Unchanged; cache miss falls through to full verification |

No new error types are added to the auth module — cache operations are best-effort and always fall through to full verification on failure.

---

## Data flow diagram

```
OIDC token arrives at authenticate()
        │
        ▼
Extract (realm, jti) from token
        │
        ▼
denylist.isRevoked(realm, jti, now)?
        │
        ├─ YES → 401 (token_revoked)
        │
        └─ NO
              │
              ▼
        tokenCache.get(realm, jti, now)?
              │
              ├─ HIT (valid=true)  → rebuild AuthContext → .authenticated
              ├─ HIT (valid=false) → 401 (cached invalid)
              │
              └─ MISS
                    │
                    ▼
              Full JWKS verification (via identity_provider_manager)
                    │
                    ├─ SUCCESS → cache.put(valid=true, TTL) → .authenticated
                    └─ FAILURE → cache.put(valid=false, TTL=60s) → 401
```

---

## Module-level state

Both `TokenValidationCache` and `JtiDenylist` are owned by the auth middleware module via a `std.Thread.Mutex`-protected global struct in `src/oidc/jwks.zig`:

```zig
/// Module-level cache and denylist state.
var oidc_cache: ?TokenValidationCache = null;
var oidc_denylist: ?JtiDenylist = null;
var cache_mutex: std.Thread.Mutex = .{};
var cache_initialized: bool = false;
```

Public wrappers:
```zig
pub fn initCache(allocator: std.mem.Allocator) error{OutOfMemory}!void;
pub fn deinitCache() void;
pub fn checkCache(realm: []const u8, jti: []const u8, now: i64) ?CachedValidation;  // acquires mutex
pub fn putCache(realm: []const u8, jti: []const u8, valid: bool, principal_json: []const u8, exp: i64) error{OutOfMemory}!void;
pub fn isRevoked(realm: []const u8, jti: []const u8, now: i64) bool;
pub fn revokeToken(realm: []const u8, jti: []const u8, expires_at: i64) error{OutOfMemory}!void;
pub fn revokeRealm(realm: []const u8, now: i64) error{OutOfMemory}!void;
pub fn evictExpired(now: i64) void;
```

---

## Key invariants

1. No OIDC token validation enters `api_tokens` table lookups — OIDC tokens have no row there.
2. Cache entries expire at `min(token.exp, now + MAX_CACHE_TTL_SECONDS)`. No cache entry lives longer than 5 minutes regardless of token lifetime.
3. The denylist uses the same TTL bound as the cache. A revoked token naturally expires from the denylist when it would have expired from the cache.
4. A cache hit for `valid=false` returns 401 immediately without re-verifying — this avoids hammering the upstream IdP with known-bad tokens.
5. Cache miss always falls through to full verification — the cache is an optimisation, never a gate.
6. Revocation is per-node (in-memory). Cross-node propagation of realm logout is best-effort and eventual. For immediate cross-node consistency, the admin must trigger logout on every node.
7. `evictExpired()` is called inline before each `get()` and `put()` to bound memory growth.

---

## Dependencies

- `src/identity/provider/manager.zig` — `verifyBearerToken()` for full verification on cache miss.
- `src/identity/provider/types.zig` — `VerifiedPrincipal` for cache value.
- `src/api/middleware/auth.zig` — `authenticate()` OIDC path (call site).
- `std.StringHashMap`, `std.ArrayList`, `std.Thread.Mutex` — standard library data structures.
- No database dependencies.

---

## Open questions

None. The design is fully specified per the architecture document v1.1 section 12.1.

