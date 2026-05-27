# Test Spec: OIDC-06 — JWKS caching

**Requirement:** OIDC-06 — The platform MUST cache JWKS keys per realm with a configurable TTL (default 10 minutes). On verification failure due to an unknown key ID (kid), the cache MUST be refreshed once before final failure. Cache refresh MUST be rate-limited to prevent JWKS-endpoint hammering.
**Priority:** MUST
**Test layer:** unit, integration

---

## Acceptance Criteria

1. Key rotation at the provider is picked up within TTL plus one refresh cycle.
2. Pathological refresh storms are bounded by the rate limiter.
3. TTL is configurable via platform configuration.

---

## Test Cases

### TC-OIDC-06-01: Cache hit — present kid returns true without HTTP fetch

**Given:**
- A `JwksCache` is initialised with `ttl_seconds=600`, `min_refresh_seconds=10`.
- `store` has been called for `https://idp.example.com/jwks` with a JWKS body containing `kid=key-1` and `kid=key-2`.

**When:**
- `lookupKid` is called for `key-1` and `key-2` at the same timestamp used for `store`.
- `lookupKid` is called for `absent-kid` at the same timestamp.

**Then:**
- `lookupKid("key-1")` returns `true`.
- `lookupKid("key-2")` returns `true`.
- `lookupKid("absent-kid")` returns `false`.
- No external HTTP call is made.

**Layer:** unit
**Acceptance criterion mapped:** Cache serves known kids from in-memory state; a kid not in the set is reported `false` without a network round-trip.
**Implemented by:** `tests/unit/test_oidc06_jwks_cache.zig` — `TC-OIDC-06-01`.

---

### TC-OIDC-06-02: Cache miss — null before store; true after store with matching kid

**Given:**
- A `JwksCache` is initialised with `ttl_seconds=600`, `min_refresh_seconds=10`.
- No `store` call has been made for the URI.

**When:**
- `lookupKid` is called for `key-1` before any `store` call.
- `store` is then called with a JWKS body containing `kid=key-1`.
- `lookupKid` is called again for `key-1`.

**Then:**
- First `lookupKid` returns `null` (no cached entry exists).
- Second `lookupKid` returns `true`.

**Layer:** unit
**Acceptance criterion mapped:** Cache correctly signals a cold-cache state (`null`) so the caller knows to fetch JWKS.
**Implemented by:** `tests/unit/test_oidc06_jwks_cache.zig` — `TC-OIDC-06-02`.

---

### TC-OIDC-06-03: Cache miss — null before store; false after store with absent kid

**Given:**
- A `JwksCache` is initialised with `ttl_seconds=600`, `min_refresh_seconds=10`.
- No `store` call has been made for the URI.

**When:**
- `lookupKid` is called for `absent` before any `store` call.
- `store` is called with a JWKS body containing only `kid=key-1`.
- `lookupKid` is called again for `absent`.

**Then:**
- First `lookupKid` returns `null`.
- Second `lookupKid` returns `false` (cache valid; kid not in set).

**Layer:** unit
**Acceptance criterion mapped:** Distinguishes "no cached data" (`null`) from "cached, kid definitively absent" (`false`), enabling the caller to decide between fetch-and-retry vs. hard rejection.
**Implemented by:** `tests/unit/test_oidc06_jwks_cache.zig` — `TC-OIDC-06-03`.

---

### TC-OIDC-06-04: TTL respected — valid at t=29, stale (null) at t=31 (ttl=30s)

**Given:**
- A `JwksCache` is initialised with `ttl_seconds=30`, `min_refresh_seconds=10`.
- `store` is called for the URI at `stored_at=1000` with a JWKS body containing `kid=key-1`.

**When:**
- `lookupKid` is called at `stored_at + 29` (age = 29 s < 30 s).
- `lookupKid` is called at `stored_at + 31` (age = 31 s ≥ 30 s).

**Then:**
- At `stored_at + 29`: returns `true` (cache valid).
- At `stored_at + 31`: returns `null` (cache expired; caller must re-fetch).

**Layer:** unit
**Acceptance criterion mapped:** TTL expiry triggers cache miss, forcing a refresh cycle so key rotation is picked up within TTL + one refresh cycle.
**Implemented by:** `tests/unit/test_oidc06_jwks_cache.zig` — `TC-OIDC-06-04`.

---

### TC-OIDC-06-05: Unknown kid in valid cache triggers refresh; kid found in refreshed JWKS → true

**Given:**
- A `JwksCache` is initialised with `ttl_seconds=600`, `min_refresh_seconds=10`.
- Cache holds a JWKS with only `kid=key-A`, last refreshed at `t=0`.
- Current time is `t=100` (rate limiter is not active: `100 - 0 = 100 ≥ 10`).

**When:**
- `lookupKid("key-B", now=100)` is called → returns `false` (valid cache; kid absent).
- `isRateLimited(now=100)` is checked → returns `false`.
- The caller re-fetches JWKS, obtains a body with both `kid=key-A` and `kid=key-B`, calls `store`, and calls `markRefreshed(100)`.
- `lookupKid("key-B", now=100)` is called again.

**Then:**
- After re-store: `lookupKid("key-B")` returns `true`.

**Layer:** unit
**Acceptance criterion mapped:** Key rotation at the provider is picked up within TTL plus one refresh cycle; the rate-limiter gate is correctly open before the refresh.
**Implemented by:** `tests/unit/test_oidc06_jwks_cache.zig` — `TC-OIDC-06-05`.

---

### TC-OIDC-06-06: Rate limiter — markRefreshed(t=0); isRateLimited(t=5)=true; isRateLimited(t=15)=false

**Given:**
- A `JwksCache` is initialised with `ttl_seconds=600`, `min_refresh_seconds=10`.
- `markRefreshed(0)` is called (last refresh recorded at `t=0`).

**When:**
- `isRateLimited(5)` is evaluated (5 - 0 = 5 < 10).
- `isRateLimited(15)` is evaluated (15 - 0 = 15 ≥ 10).

**Then:**
- `isRateLimited(5)` returns `true`.
- `isRateLimited(15)` returns `false`.

**Layer:** unit
**Acceptance criterion mapped:** Cache refresh is rate-limited to prevent JWKS-endpoint hammering; minimum refresh window is honoured.
**Implemented by:** `tests/unit/test_oidc06_jwks_cache.zig` — `TC-OIDC-06-06`.

---

### TC-OIDC-06-07: Non-default TTL (120 s) respected — valid at t=119, stale at t=121

**Given:**
- A `JwksCache` is initialised with `ttl_seconds=120`, `min_refresh_seconds=10`.
- `store` is called at `stored_at=5000` with a JWKS body containing `kid=key-1`.

**When:**
- `lookupKid` is called at `stored_at + 119` (age 119 s < 120 s).
- `lookupKid` is called at `stored_at + 121` (age 121 s ≥ 120 s).

**Then:**
- At `stored_at + 119`: returns `true`.
- At `stored_at + 121`: returns `null`.

**Layer:** unit
**Acceptance criterion mapped:** TTL is configurable via platform configuration; non-default values are enforced correctly.
**Implemented by:** `tests/unit/test_oidc06_jwks_cache.zig` — `TC-OIDC-06-07`.

---

### TC-OIDC-06-08: Warm cache — JWKS endpoint called 0 times for token with known kid

**Given:**
- A Keycloak adapter is instantiated with a counting `HttpTransport` (records call count per URL, returns a fixed JWKS body).
- The JWKS cache is pre-warmed via `store` with `kid=known-key` for the adapter's JWKS URI.

**When:**
- `verifyToken` is called with a token whose `kid` header is `known-key`.

**Then:**
- The token verification succeeds.
- The counting transport records **0** calls to the JWKS endpoint.

**Layer:** integration
**Acceptance criterion mapped:** Cached JWKS is served without a network round-trip; warm-cache path never contacts the IdP.
**Implemented by:** `tests/integration/test_oidc06_jwks_cache_integration.zig` — `TC-OIDC-06-08`.

---

### TC-OIDC-06-09: Cold cache — JWKS endpoint called once; kid found → auth success

**Given:**
- A Keycloak adapter is instantiated with a counting `HttpTransport`.
- The JWKS cache is empty (cold).
- The transport returns a JWKS body containing `kid=new-key`.

**When:**
- `verifyToken` is called with a token whose `kid` header is `new-key`.

**Then:**
- The counting transport records **exactly 1** call to the JWKS endpoint.
- Token verification succeeds.

**Layer:** integration
**Acceptance criterion mapped:** On a cold cache the adapter fetches JWKS exactly once and populates the cache.
**Implemented by:** `tests/integration/test_oidc06_jwks_cache_integration.zig` — `TC-OIDC-06-09`.

---

### TC-OIDC-06-10: Stale cache — JWKS endpoint called once on refresh for rotated kid

**Given:**
- A Keycloak adapter is instantiated with a counting `HttpTransport`.
- The cache holds an entry for the JWKS URI that was stored at `t=0` with `ttl_seconds=30`; current time is `t=35` (stale).
- The transport returns an updated JWKS body containing `kid=rotated-key`.

**When:**
- `verifyToken` is called at `t=35` with a token whose `kid` header is `rotated-key`.

**Then:**
- The counting transport records **exactly 1** call to the JWKS endpoint (one refresh).
- Token verification succeeds (rotated key is found in the refreshed JWKS).

**Layer:** integration
**Acceptance criterion mapped:** Key rotation at the provider is picked up within TTL plus one refresh cycle.
**Implemented by:** `tests/integration/test_oidc06_jwks_cache_integration.zig` — `TC-OIDC-06-10`.

---

### TC-OIDC-06-11: Rate-limited refresh — second unknown-kid request within window does NOT call JWKS endpoint

**Given:**
- A Keycloak adapter is instantiated with a counting `HttpTransport`.
- The cache is warm but does not contain `kid=unknown-key`.
- `markRefreshed` was called at `t=0`; `min_refresh_seconds=10`.
- First `verifyToken` call at `t=2` with `kid=unknown-key`: rate limiter is **active** (`2 - 0 = 2 < 10`).
- Second `verifyToken` call at `t=3` with `kid=unknown-key`.

**When:**
- Both `verifyToken` calls are issued within the rate-limit window.

**Then:**
- The counting transport records **0** calls to the JWKS endpoint (refresh is suppressed by rate limiter for both calls).
- Both `verifyToken` calls return an appropriate "kid unknown / refresh rate-limited" error.

**Layer:** integration
**Acceptance criterion mapped:** Cache refresh is rate-limited to prevent JWKS-endpoint hammering; a refresh storm cannot occur within the minimum refresh window.
**Implemented by:** `tests/integration/test_oidc06_jwks_cache_integration.zig` — `TC-OIDC-06-11`.
