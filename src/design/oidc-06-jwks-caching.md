# Module: OIDC-06 JWKS Caching

## Module purpose

This module introduces an in-memory JWKS key-ID cache for the Keycloak adapter so that every token verification no longer makes a fresh HTTP call to the JWKS endpoint. The cache stores the set of `kid` strings returned by a JWKS URI, keyed by URI, with a configurable TTL (default 10 minutes). A rate limiter prevents JWKS-endpoint hammering when multiple requests arrive with unknown key IDs within a short window. On a cache miss or stale entry the adapter fetches once and updates the cache; on an unknown `kid` in an otherwise valid cache it performs one refresh before returning a final failure. No database schema changes are required — all state is held in memory within the `Adapter` instance.

## Scope and non-goals

In scope:
- `JwksCache` struct and its public interface in a new file `src/identity/provider/oidc/jwks_cache.zig`.
- Config additions (`jwks_ttl_seconds`, `jwks_min_refresh_seconds`) in `src/identity/provider/adapters/keycloak/config.zig`.
- `Adapter` field addition and cache-aware JWKS lookup path in `src/identity/provider/adapters/keycloak/provider.zig`.
- Unit tests at `tests/unit/test_oidc06_jwks_cache.zig` covering all acceptance criteria.

Out of scope:
- Persistent or distributed caching (this is a single-process in-memory implementation).
- Discovery document caching (separate concern, outside OIDC-06 scope).
- Database migrations (none required).
- Provider-agnostic JWKS client abstraction changes.

## Public interface

### `src/identity/provider/oidc/jwks_cache.zig`

```zig
const std = @import("std");

/// A single cached JWKS entry for one JWKS URI.
/// `kids` is heap-owned (each slice duped at store time).
/// `fetched_at` is unix seconds at time of the last successful fetch.
pub const JwksCacheEntry = struct {
    kids: [][]u8,         // heap-owned slice of heap-owned kid strings
    fetched_at: i64,      // unix epoch seconds
};

/// In-memory cache of JWKS key IDs, keyed by JWKS URI string.
/// Thread-safety: NOT thread-safe; callers must hold an external mutex
/// if the Adapter is accessed concurrently.
pub const JwksCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(JwksCacheEntry), // key = duped URI string
    ttl_seconds: i64,
    min_refresh_seconds: i64,
    last_refresh_at: i64,  // unix seconds of last fetch across all URIs

    /// Initialise a cache with given TTL and rate-limit window.
    /// `ttl_seconds` must be > 0. `min_refresh_seconds` must be > 0.
    pub fn init(
        allocator: std.mem.Allocator,
        ttl_seconds: i64,
        min_refresh_seconds: i64,
    ) JwksCache;

    /// Free all heap-owned kid strings, URI keys, and the hash map itself.
    pub fn deinit(self: *JwksCache) void;

    /// Look up whether `kid` is present for the given `uri` as of `now` (unix seconds).
    ///
    /// Returns:
    ///   true  — entry is present and valid; kid IS in the set.
    ///   false — entry is present and valid; kid is NOT in the set.
    ///   null  — entry absent OR stale (caller must fetch and call store()).
    pub fn lookupKid(
        self: *JwksCache,
        uri: []const u8,
        kid: []const u8,
        now: i64,
    ) ?bool;

    /// Parse `kid` strings from a raw JWKS JSON body and store them under `uri`.
    /// Replaces any existing entry for `uri` (freeing old memory).
    /// Dups both the URI key and all kid strings into allocator-owned memory.
    /// Returns error.UpstreamProtocolError if the JSON is malformed or
    /// the "keys" array is absent/wrong type.
    /// Returns error.OutOfMemory on allocation failure.
    pub fn store(
        self: *JwksCache,
        uri: []const u8,
        jwks_body: []const u8,
        now: i64,
    ) (error{ UpstreamProtocolError, OutOfMemory })!void;

    /// Returns true if a refresh would be blocked by the rate limiter.
    /// Refresh is rate-limited when `now - last_refresh_at < min_refresh_seconds`.
    pub fn isRateLimited(self: *const JwksCache, now: i64) bool;

    /// Record that a JWKS fetch was just performed. Called after each
    /// successful HTTP fetch regardless of whether the kid was found.
    pub fn markRefreshed(self: *JwksCache, now: i64) void;
};
```

### Changes to `src/identity/provider/adapters/keycloak/config.zig`

Add two fields to `Config`:

```zig
jwks_ttl_seconds: u32,           // default 600  (10 minutes)
jwks_min_refresh_seconds: u32,   // default 10   (rate-limit window)
```

Both fields must be:
- Copied verbatim in `Config.clone()` (scalar values; no allocation needed).
- Validated in `Config.validate()`: each must be `> 0` (return `error.InvalidConfig` otherwise).

Default values MUST be applied by callers before invoking `Config.clone()`. The recommended pattern is a named constant in the config file:

```zig
pub const defaults = struct {
    pub const jwks_ttl_seconds: u32 = 600;
    pub const jwks_min_refresh_seconds: u32 = 10;
};
```

### Changes to `src/identity/provider/adapters/keycloak/provider.zig`

Add one field to `Adapter`:

```zig
jwks_cache: jwks_cache_mod.JwksCache,
```

The field is initialised in `Adapter.init()`:

```zig
const jwks_cache = jwks_cache_mod.JwksCache.init(
    allocator,
    @intCast(owned_config.jwks_ttl_seconds),
    @intCast(owned_config.jwks_min_refresh_seconds),
);
```

The field is deinitialized in `Adapter.deinit()`:

```zig
self.jwks_cache.deinit();
```

The existing `jwksContainsKid` private function is replaced by `jwksContainsKidCached`:

```zig
fn jwksContainsKidCached(
    self: *Adapter,
    allocator: std.mem.Allocator,
    jwks_uri: []const u8,
    kid: []const u8,
) provider_errors.ProviderError!bool;
```

See **Cache-aware lookup algorithm** below for the exact behaviour contract.

`resolveJwksKid` (the vtable shim) is updated to call `jwksContainsKidCached` instead of `jwksContainsKid`.

The original `jwksContainsKid` private helper is retained but renamed to `fetchJwksBody` (or an equivalent that returns the raw response body) so `jwksContainsKidCached` can call it to obtain JWKS data for `store()`.

## Cache-aware lookup algorithm

```
jwksContainsKidCached(uri, kid, now):
  match cache.lookupKid(uri, kid, now):

    case true:                           // cache valid, kid present
      return true

    case false:                          // cache valid, kid NOT present → unknown-kid path
      if cache.isRateLimited(now):
        return false                     // rate-limited: hard failure
      fetch JWKS body for uri            // one refresh attempt
      if fetch fails: propagate error
      cache.store(uri, body, now)
      cache.markRefreshed(now)
      return kidInEntry(cache, uri, kid) // re-check after refresh

    case null:                           // stale or no entry → normal miss path
      fetch JWKS body for uri
      if fetch fails: propagate error
      cache.store(uri, body, now)
      cache.markRefreshed(now)
      return kidInEntry(cache, uri, kid) // check in freshly stored entry
```

`kidInEntry` is a helper that calls `cache.lookupKid(uri, kid, now)` after a fresh `store()` and maps `null` (should not occur immediately after store) to `false`.

### Key invariants

- At most **one** HTTP JWKS fetch is performed per `jwksContainsKidCached` call. The rate limiter blocks a second fetch within `min_refresh_seconds`; there is no retry loop inside a single call.
- `markRefreshed` is called only after a successful HTTP fetch, not on rate-limited paths.
- `store()` always replaces the existing entry for the URI (no partial update).

## Data flow diagram

```
Token verification request
        │
        ▼
standards_verifier.verify()
        │
        │  calls jwks_resolver.containsKid(uri, kid)
        ▼
resolveJwksKid (vtable shim in provider.zig)
        │
        ▼
jwksContainsKidCached(uri, kid, now=clock.nowUnixSeconds())
        │
        ├─► JwksCache.lookupKid(uri, kid, now)
        │       │
        │       ├─ Entry present + not stale ──► ?bool {true | false}
        │       └─ Entry absent or stale    ──► null
        │
        │  [on null OR false-with-no-rate-limit]
        ▼
  HTTP GET jwks_uri  (via existing sendRequest / HttpTransport)
        │
        ▼
  JwksCache.store(uri, response_body, now)
  JwksCache.markRefreshed(now)
        │
        ▼
  Re-check kid in freshly stored entry
        │
        ▼
  return bool result to standards_verifier
```

## Error taxonomy

Errors produced or propagated by the new code paths:

| Error | Source | Meaning |
|---|---|---|
| `error.OutOfMemory` | `JwksCache.store` | Allocator failure during kid dup |
| `error.UpstreamProtocolError` | `JwksCache.store` | JWKS body missing `keys` array or unparseable JSON |
| `error.UpstreamUnavailable` | `jwksContainsKidCached` | HTTP fetch returned non-200 (mapped via existing `mapStatus`) |
| `error.UpstreamTimeout` | `jwksContainsKidCached` | HTTP fetch timed out |
| `error.SignatureVerificationFailed` | `jwksContainsKidCached` | Kid not found after all allowed fetch attempts (rate-limited false case) |

No new error variants are added to `ProviderError` — all cases map to existing variants.

## Dependencies

`jwks_cache.zig` depends on:
- `std` — `StringHashMap`, `json`, `mem`.
- No other BPM modules.

`provider.zig` (modified) gains one new import:
- `const jwks_cache_mod = @import("../../oidc/jwks_cache.zig");`

`jwks_cache.zig` must NOT depend on:
- `provider.zig`, `config.zig`, or any HTTP transport module.
- Any database or I/O module.

`provider.zig` changes must NOT alter function signatures visible outside the file (the vtable shim `resolveJwksKid` signature is unchanged; only its internal call target changes).

## State transitions for a single cache entry

```
[absent]
    │  store() called with valid JWKS body
    ▼
[valid]  ──── now - fetched_at < ttl_seconds ────► lookupKid returns ?bool (non-null)
    │
    │  now - fetched_at >= ttl_seconds
    ▼
[stale]  ──── lookupKid returns null ────► caller fetches, calls store() ──► [valid]
```

Rate-limiter state is a single scalar (`last_refresh_at`) shared across all URIs — it limits global fetch frequency, not per-URI frequency.

## Test approach

All tests are **pure unit tests** — no database, no HTTP server. The `JwksCache` struct is tested directly by constructing it with synthetic `now` timestamps.

| ID | Description | Oracle |
|---|---|---|
| TC-OIDC-06-01 | `store()` a JWKS body with known kids; `lookupKid` returns `true` for a present kid and `false` for an absent kid; no HTTP fetch involved | Correct `?bool` values; `isRateLimited` not consulted |
| TC-OIDC-06-02 | `lookupKid` returns `null` (no entry); caller fetches, calls `store()`, `markRefreshed()`; re-check returns `true` | `null` on first call; `true` after store |
| TC-OIDC-06-03 | Same as TC-OIDC-06-02 but kid absent from fetched JWKS | `null` on first call; `false` after store |
| TC-OIDC-06-04 | Entry stored at `t=0`; TTL is 30 s; checked at `t=29` (valid) then `t=31` (stale) | `?bool` at t=29; `null` at t=31 |
| TC-OIDC-06-05 | Entry stored with kid-A; look up kid-B (returns `false`); `isRateLimited` returns `false` (outside window); simulate fetch of updated JWKS containing kid-B; store + re-check returns `true` | Final result `true`; `markRefreshed` called once |
| TC-OIDC-06-06 | `markRefreshed(t=0)`; `isRateLimited(t=5)` returns `true` (within window); `isRateLimited(t=15)` returns `false` (outside window) | Correct boolean for both checks |
| TC-OIDC-06-07 | Construct `JwksCache` with `ttl_seconds=120`; store at `t=0`; check at `t=119` (valid) and `t=121` (stale) | Non-default TTL respected correctly |

Tests are placed in `tests/unit/test_oidc06_jwks_cache.zig` and registered under the `test-unit` step in `build.zig`.

## Open questions

None. All design points are fully specified by the requirement and existing architecture patterns.
