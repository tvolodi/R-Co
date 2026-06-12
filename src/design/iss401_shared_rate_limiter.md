# Module: ISS-401 Shared-Store Rate Limiter

**Covers:** ISS-401 (Shared-store, globally-enforced rate limiter), ISS-403 (OIDC principal keying)
**Files:**
- `src/api/middleware/rate_limit.zig` — sliding-window rate limit middleware (replaces per-node bucket)
- `src/config/rate_limit.zig` — rate-limit config validation (new)
- `migrations/NNN_rate_limit_buckets.sql` — Postgres-backed counter table (new)

**Depends on:**
- ISS-403 for OIDC principal keying (see `iss403_oidc_rate_limit_keying.md`)
- `src/api/middleware/auth.zig` (`AuthContext.token_id`, tenant context)
- RFC 6585/7231 HTTP 429 + Retry-After

---

## Module purpose

This module replaces the existing in-memory per-node rate limiter (`src/api/middleware/rate_limit.zig` — currently does not exist; the design in `src/design/api-rate-limit.md` describes the legacy per-node approach) with a shared-store sliding-window rate limiter that enforces the configured RPM limit globally across all nodes in a multi-node deployment.

The core insight: the old per-node in-memory counter meant the true limit was approximately N x RPM in an HA cluster. The new design stores counter state in a shared backend (Postgres by default, with a Redis code path as future extension point) so every node sees the same aggregate count.

## Scope and non-goals

**In scope:**
- `rate_limit_buckets` table (Postgres) for sliding-window counter storage.
- Migration creating the table (idempotent, additive).
- Rewritten `rate_limit.zig` middleware with Postgres backend.
- Config module `src/config/rate_limit.zig` that validates `BPM_RATE_LIMIT_BACKEND`, `BPM_RATE_LIMIT_MAX_RPM` at startup.
- HTTP 429 response with `Retry-After` header (integer seconds).
- Per-tenant + per-principal keying: key = `(tenant_id, principal)`.

**Out of scope:**
- Redis backend implementation (code path accepted by config; actual Redis client is future work).
- Per-principal rate-limit overrides (only global `BPM_RATE_LIMIT_MAX_RPM` is used initially).
- Rate-limit bypass for specific roles (PLATFORM_ADMIN is not exempt; rule is uniform).
- Dynamic config changes at runtime (config is loaded at startup and cached).

---

## Public interface

### `src/api/middleware/rate_limit.zig`

### Core types

```zig
pub const RateLimitBackend = enum { postgres, redis };

pub const RateLimitConfig = struct {
    backend: RateLimitBackend,
    max_rpm: u64,
    window_seconds: u32,
    pub fn fromEnv(allocator: std.mem.Allocator) (RateLimitConfigError || std.fmt.ParseIntError)!RateLimitConfig;
};
```

### Result types

```zig
pub const RateLimitResult = union(enum) {
    allowed: void,
    rate_limited: RateLimitedInfo,
};

pub const RateLimitedInfo = struct {
    retry_after: u32,
    body: []const u8,
};
```

### Public functions

```zig
// Init / deinit
pub fn init(allocator: std.mem.Allocator, config: RateLimitConfig) RateLimitError!void;
pub fn deinit() void;

// Core check — called from HTTP middleware chain after auth.
// tenant_id: 36-char UUID of resolved tenant context.
// principal:  For local tokens = api_tokens.id UUID; for OIDC = "{realm}:{sub}".
// now_unix:   wall-clock Unix seconds (std.time.timestamp()).
// db_pool:    connection pool for Postgres backend.
// Returns .allowed or .rate_limited with retry info.
pub fn check(
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    principal: []const u8,
    now_unix: i64,
    db_pool: *pool_mod.Pool,
) RateLimitError!RateLimitResult;
```

### `src/config/rate_limit.zig` (new)

```zig
const std = @import("std");

pub const RateLimitConfig = struct {
    backend: RateLimitBackend,
    max_rpm: u64,
    window_seconds: u32,

    pub fn validate(self: *const RateLimitConfig) RateLimitConfigError!void;
};

pub const RateLimitBackend = enum {
    postgres,
    redis,
};

pub const RateLimitConfigError = error{
    BackendNotSupported,
    MaxRpmZero,
    WindowSecondsZero,
};
```

### Migration `migrations/NNN_rate_limit_buckets.sql`

```sql
-- ISS-401: Shared-store sliding-window rate limiter buckets.
-- Postgres-backed. One row per (tenant_id, principal) per window.
-- Idempotent: CREATE TABLE IF NOT EXISTS.

CREATE TABLE IF NOT EXISTS rate_limit_buckets (
    id              BIGSERIAL PRIMARY KEY,
    tenant_id       UUID    NOT NULL,
    principal       TEXT    NOT NULL,
    window_start    BIGINT  NOT NULL,  -- Unix seconds at which this window began
    count           BIGINT  NOT NULL DEFAULT 0,
    UNIQUE (tenant_id, principal, window_start)
);

CREATE INDEX IF NOT EXISTS idx_rate_limit_buckets_lookup
    ON rate_limit_buckets (tenant_id, principal, window_start DESC);

-- Periodic cleanup: remove rows older than 2 complete windows.
-- Run by the background cleanup in rate_limit.zig or a cron/pg_cron.
CREATE INDEX IF NOT EXISTS idx_rate_limit_buckets_window_start
    ON rate_limit_buckets (window_start);
```

---

## Sliding-window algorithm (Postgres)

The algorithm uses a fixed-size window (default 60 seconds). Each bucket is a row in `rate_limit_buckets` keyed by `(tenant_id, principal, window_start)`.

```
check(tenant_id, principal, now_unix, pool):
  window_start = (now_unix / window_seconds) * window_seconds   // floor to window boundary

  BEGIN TRANSACTION
    // Upsert: increment count or insert with count=1.
    // ON CONFLICT (tenant_id, principal, window_start) DO UPDATE count = count + 1
    INSERT INTO rate_limit_buckets (tenant_id, principal, window_start, count)
    VALUES ($1, $2, $3, 1)
    ON CONFLICT (tenant_id, principal, window_start)
    DO UPDATE SET count = rate_limit_buckets.count + 1
    RETURNING count

    new_count = result.count

    // Also delete stale rows (older than 2 windows) — best-effort
    DELETE FROM rate_limit_buckets
    WHERE window_start < $4   // $4 = now - 2 * window_seconds

    if new_count > max_rpm:
      retry_after = window_start + window_seconds - now_unix
      if retry_after < 0: retry_after = 0   // edge case: window just rolled
      COMMIT
      return .rate_limited{ retry_after, body }

    COMMIT
    return .allowed
```

**Key properties:**
- The upsert is atomic (INSERT ... ON CONFLICT DO UPDATE). Two concurrent requests for the same key will both see correct counts because Postgres serialises at the unique-index level.
- Stale-row cleanup happens inline during `check()`, best-effort. No background sweeper is required at this stage.
- `retry_after` is always >= 0; it is computed as integer seconds until the next window boundary.
- The transaction is short-lived (single upsert + optional delete), so it does not hold locks for longer than needed.

---

## Error taxonomy

| Error | Source | HTTP | Meaning |
|---|---|---|---|
| `OutOfMemory` | `check()` body allocation | 500 | Cannot allocate 429 response body |
| `PoolExhausted` | DB pool acquire | 503 | No connection available |
| `PersistenceFailed` | DB query failure | 500 | Postgres returned an error |
| `InvalidBackend` | Config validation at startup | fatal | `BPM_RATE_LIMIT_BACKEND` not `postgres` or `redis` |
| `MaxRpmZero` | Config validation at startup | fatal | `BPM_RATE_LIMIT_MAX_RPM` must be > 0 |

---

## HTTP 429 response shape

Status: `429 Too Many Requests`

Response headers:
```
Retry-After: {retry_after}                 (integer seconds)
Content-Type: application/problem+json
```

Body (RFC 9457 Problem Details):
```json
{
  "type": "https://bpm.example.com/problems/rate-limited",
  "title": "Too Many Requests",
  "status": 429,
  "detail": "rate limit exceeded",
  "trace_id": "{current trace_id}"
}
```

---

## Module-level state

```zig
// ── Module-level state ──────────────────────────────────────────────

/// Default window size in seconds.
const DEFAULT_WINDOW_SECONDS: u32 = 60;

/// Resolved configuration from init().
var global_config: RateLimitConfig = undefined;

/// Guards calls to check() before init().
var initialized: bool = false;
```

No per-node in-memory map. All state lives in the shared store.

---

## Environment variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `BPM_RATE_LIMIT_BACKEND` | string | `postgres` | Backend: `postgres` or `redis` (future) |
| `BPM_RATE_LIMIT_MAX_RPM` | u64 | (required) | Maximum requests per minute per (tenant_id, principal) |
| `BPM_RATE_LIMIT_WINDOW_SECONDS` | u32 | `60` | Window size in seconds |

Validation at startup:
- `BPM_RATE_LIMIT_BACKEND` must be `"postgres"` (only supported backend initially; `"redis"` accepted but returns error `BackendNotSupported`).
- `BPM_RATE_LIMIT_MAX_RPM` must be > 0.
- `BPM_RATE_LIMIT_WINDOW_SECONDS` must be > 0.

If any validation fails, the server refuses to start with a clear log message.

---

## Integration: middleware chain

```
[request arrives]
   │
   ▼
trace.extractOrGenerate()          ← API-09
   │
   ▼
auth.authenticate()                ← API-08 — resolves tenant_id, principal (token_id or OIDC key)
   │
   ▼
rate_limit.check(tenant_id, principal)   ← ISS-401/403 — shared-store window
   │                                            short-circuits 429 if exceeded
   ▼
[rbac / route handler]
```

Rate limiting runs **after** auth (only authenticated requests are counted). The principal is resolved by auth:
- Local tokens: `principal = AuthContext.token_id` (UUID from `api_tokens.id`).
- OIDC tokens: `principal = "{realm}:{sub}"` (composite string, see ISS-403).

---

## Key invariants

1. A request that receives HTTP 429 MUST NOT reach any route handler.
2. Unauthenticated requests are never counted (they are short-circuited by the auth middleware before reaching rate_limit).
3. The rate limit is global: two nodes checking the same key see the same aggregate count because state is in the shared Postgres store.
4. `retry_after` is always >= 0.
5. The window_start is floored to the configured window boundary (`(now / window_seconds) * window_seconds`) so all nodes agree on window alignment.
6. Config is validated once at startup and never reloaded at runtime.

---

## Dependencies

- `src/api/middleware/auth.zig` — `AuthContext` (token_id, tenant_id, OIDC realm+sub).
- `src/db/pool.zig` — connection pool for Postgres-backed checks.
- `src/api/errors.zig` — `problemRateLimited`, `serialise`.
- `std.Thread.Mutex` — (only for `initialized` guard; the shared store provides its own concurrency control via Postgres transactions).
- `migrations/NNN_rate_limit_buckets.sql` — creates the counter table.

---

## Open questions

None. All design points resolve to the Postgres-backed sliding window described above.

