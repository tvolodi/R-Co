# Module: rate_limit

**Covers:** API-10 (Per-token rate limiting)
**Files:**
- `src/api/middleware/rate_limit.zig` — rate limit middleware (new)
- `src/api/middleware/auth.zig` — extend `AuthContext` with `token_id` field
- `src/api/errors.zig` — add `problemRateLimited` constructor

**Depends on:**
- `src/api/middleware/auth.zig` (`AuthContext`, `HandlerResult`)
- `src/api/errors.zig` (`serialise`, `ProblemDetails`)
- `src/config.zig` (env var reading pattern via `std.posix.getenv`)
- `std.StringHashMap`, `std.Thread.Mutex`, `std.time`

---

## Module purpose

This module implements per-token sliding-window rate limiting as required by API-10. Every authenticated request is counted against the requesting token's limit. Requests that exceed the limit receive HTTP 429 with a `Retry-After` header and are short-circuited before any route handler runs. Unauthenticated requests (rejected by auth middleware before reaching this middleware) are not counted.

The sliding window uses a simple fixed-bucket approach: each token has a `bucket_start` timestamp (Unix seconds) and a `count`. When `now >= bucket_start + 60`, the bucket resets. This is O(1) per check with no sweep required.

---

## Auth context extension

`AuthContext` in `src/api/middleware/auth.zig` must be extended with a `token_id` field so the rate limiter can bucket requests by token without re-reading any headers or DB state:

```zig
/// The authenticated caller's identity and permissions.
/// Route handlers receive this via the request context.
pub const AuthContext = struct {
    /// UUID of the user row in the `users` table.
    user_id: []const u8,
    /// The highest-privilege role assigned to this user.
    role: Role,
    /// True if this request used the bootstrap token.
    is_bootstrap: bool,
    /// Stable identifier for the token used in this request.
    /// For DB-validated tokens: the UUID primary key from `api_tokens.id`.
    /// For bootstrap tokens: the string literal "bootstrap".
    /// Used as the key for per-token rate limiting (API-10).
    /// Caller owns this string; freed with the same allocator passed to authenticate().
    token_id: []const u8,
};
```

The `authenticate()` function already resolves the token row during DB lookup; it must populate `token_id` from `api_tokens.id` (a UUID). For bootstrap auth, populate with the literal `"bootstrap"` (allocated copy).

---

## errors.zig extension

Add a `problemRateLimited` constructor to `src/api/errors.zig`:

```zig
/// HTTP 429 — Too Many Requests.
/// The caller MUST set the Retry-After response header separately;
/// this constructor only produces the RFC 9457 Problem Details body.
pub fn problemRateLimited(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "rate-limited",
        .title = "Too Many Requests",
        .status = 429,
        .detail = detail,
    };
}
```

---

## Public types

### `TokenBucket` (internal — not exported)

```zig
/// Sliding-window state for a single token.
/// Protected by module-level mutex.
const TokenBucket = struct {
    /// Unix timestamp (seconds) when the current 60-second window started.
    bucket_start: i64,
    /// Number of requests counted in the current window.
    count: u64,
};
```

### `RateLimitedInfo`

```zig
/// Information returned when a request exceeds its token's rate limit.
pub const RateLimitedInfo = struct {
    /// Seconds until the current window resets.
    /// 0 if the window has just reset (caller may retry immediately).
    retry_after: u32,
    /// Pre-built HTTP 429 response body (RFC 9457 JSON, allocated by check()).
    /// Caller owns this slice and must free it with the same allocator
    /// passed to check().
    body: []const u8,
};
```

### `RateLimitResult`

```zig
/// Result of the rate limit check.
/// The HTTP server switches on this to either proceed or return a 429 response.
pub const RateLimitResult = union(enum) {
    /// Request is within the token's limit for the current window; proceed.
    allowed: void,
    /// Request exceeds the limit.
    /// The server must:
    ///   1. Set HTTP status 429.
    ///   2. Set response header: Retry-After: {info.retry_after}
    ///   3. Set response header: Content-Type: application/problem+json
    ///   4. Return info.body as the response body.
    ///   5. NOT invoke any route handler.
    rate_limited: RateLimitedInfo,
};
```

---

## Public functions

### `init`

```zig
/// Initialise the rate limit module. MUST be called once at startup,
/// before the HTTP server begins accepting connections, and before
/// any call to check().
///
/// Reads from the environment:
///   BPM_RATE_LIMIT_DEFAULT — global default limit (req/min).
///     Parsed as u64. Falls back to DEFAULT_LIMIT (1000) if absent
///     or unparseable.
///
/// Per-token overrides are read lazily in check(), not at init time,
/// so that dynamically added or changed env vars are respected.
///
/// allocator is used for all subsequent map key allocations and is
/// retained in module-level state. It MUST outlive deinit().
pub fn init(allocator: std.mem.Allocator) RateLimitError!void
```

### `deinit`

```zig
/// Free all module-level state. Call once at shutdown, after the HTTP
/// server has stopped accepting connections.
///
/// Safe to call even if init() returned an error.
/// After deinit(), check() MUST NOT be called.
pub fn deinit() void
```

### `check`

```zig
/// Check whether the token identified by token_id is within its rate limit.
///
/// Parameters:
///   allocator  — used to allocate the RFC 9457 body if the limit is exceeded.
///                The caller owns the returned body slice (RateLimitedInfo.body)
///                and must free it with the same allocator.
///   token_id   — stable string key for this token; matches AuthContext.token_id.
///                Must be non-empty. The function copies the key on first
///                insertion; subsequent calls for the same token_id reuse
///                the stored key.
///   now_unix   — current time as Unix seconds (pass std.time.timestamp()).
///
/// Returns:
///   .allowed          — request is within limit; proceed to next middleware.
///   .rate_limited     — limit exceeded; caller must short-circuit with HTTP 429.
///
/// Thread safety: acquires mutex for the duration of map read + update.
pub fn check(
    allocator: std.mem.Allocator,
    token_id: []const u8,
    now_unix: i64,
) RateLimitError!RateLimitResult
```

### `limitForToken` (internal helper — documented for implementors)

```zig
/// Resolve the effective request-per-minute limit for token_id.
///
/// Algorithm:
///   1. Build env var name: "BPM_RATE_LIMIT_TOKEN_" ++ token_id
///      (stack-allocate: max token_id len is 36 chars for a UUID,
///       so buf size = 20 + 36 = 56 bytes).
///   2. Call std.posix.getenv(name). If set and parseable as u64: return it.
///   3. Otherwise: return module-level default_limit.
///
/// Not exported; called from check() while NOT holding the mutex
/// (pure env read, no shared state modified).
fn limitForToken(token_id: []const u8) u64
```

---

## Error set

```zig
pub const RateLimitError = error{
    /// Allocator exhausted during check() (building the 429 body)
    /// or during init() (map initialisation).
    OutOfMemory,
};
```

---

## Module-level state

```zig
// ── Module-level state ────────────────────────────────────────────────────────

/// Default request limit per 1-minute window.
/// Overridden at init() time by BPM_RATE_LIMIT_DEFAULT.
const DEFAULT_LIMIT: u64 = 1000;

/// Window size in seconds.
const WINDOW_SECONDS: i64 = 60;

/// Mutex protecting `buckets` and `default_limit`.
var mutex: std.Thread.Mutex = .{};

/// Per-token sliding-window buckets.
/// Key: owned copy of token_id (allocated by state_allocator).
/// Value: TokenBucket (inline in the map).
/// Initialised by init(); freed by deinit().
var buckets: std.StringHashMap(TokenBucket) = undefined;

/// Resolved global default limit (read from BPM_RATE_LIMIT_DEFAULT at init).
var default_limit: u64 = DEFAULT_LIMIT;

/// Allocator used for map key copies. Retained from init() call.
var state_allocator: std.mem.Allocator = undefined;

/// Guards against check() being called before init().
var initialized: bool = false;
```

---

## Sliding window algorithm

The fixed-bucket algorithm implemented in `check()`:

```
acquire mutex
  entry = buckets.get(token_id)
  now = now_unix

  if entry == null:
    // First request for this token — start a new window
    allocate key copy
    insert TokenBucket{ .bucket_start = now, .count = 1 } into buckets
    release mutex
    return .allowed

  if now >= entry.bucket_start + WINDOW_SECONDS:
    // Window has expired — reset
    entry.bucket_start = now
    entry.count = 1
    buckets.put(key, entry)  // update in-place
    release mutex
    return .allowed

  entry.count += 1
  limit = limitForToken(token_id)   // reads env var, no shared state

  if entry.count > limit:
    retry_after = @intCast(u32, @max(0, entry.bucket_start + WINDOW_SECONDS - now))
    body = serialise(allocator, problemRateLimited("rate limit exceeded"))
    release mutex
    return .rate_limited{ .retry_after = retry_after, .body = body }

  buckets.put(key, entry)  // update count
  release mutex
  return .allowed
```

**Note on `getOrPut`:** The implementation SHOULD use `buckets.getOrPut(key)` to avoid double-lookup. If `getOrPut` reports a new entry, initialise the value and return `.allowed`. If it reports an existing entry, apply the reset-or-increment logic above.

**Key copy strategy:** Only allocate a new key copy when `getOrPut` reports a new entry (`.found_existing == false`). Existing keys are already owned by the map. On `deinit()`, iterate `buckets.iterator()` and free every key before calling `buckets.deinit()`.

---

## Thread-safety approach

A single `std.Thread.Mutex` (`mutex`) protects the `buckets` map and all reads/writes to `TokenBucket` values. The mutex is acquired at the start of `check()` and released before returning. `limitForToken()` reads only process environment variables (no shared mutable state) and is called while holding the mutex for simplicity; this is acceptable because `std.posix.getenv` is thread-safe.

`init()` and `deinit()` are not protected by the mutex; they must be called from the main goroutine before/after the HTTP server is started/stopped.

---

## HTTP 429 response shape

Status: `429 Too Many Requests`

Response headers set by the HTTP server integration layer (not by this module):
```
Retry-After: {retry_after}        (integer seconds; 0 = window just reset)
Content-Type: application/problem+json
```

Body (RFC 9457 Problem Details JSON, produced by `errors.serialise()`):
```json
{
  "type": "https://bpm.example.com/problems/rate-limited",
  "title": "Too Many Requests",
  "status": 429,
  "detail": "rate limit exceeded",
  "trace_id": "{current trace id}"
}
```

---

## Environment variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `BPM_RATE_LIMIT_DEFAULT` | u64 | `1000` | Global default limit (req/min) |
| `BPM_RATE_LIMIT_TOKEN_{token_id}` | u64 | (uses default) | Per-token override; `{token_id}` is the value from `AuthContext.token_id` (UUID string from `api_tokens.id`, or `"bootstrap"`) |

Example:
```
BPM_RATE_LIMIT_DEFAULT=500
BPM_RATE_LIMIT_TOKEN_3a7f8b21-0000-4000-8000-000000000001=10000
BPM_RATE_LIMIT_TOKEN_bootstrap=0   # 0 = effectively unlimited (no entry inserted above limit)
```

> **Note:** The env var lookup in `limitForToken` must build the variable name on the stack to avoid heap allocation on the hot path. The maximum token_id length is 36 characters (UUID v4), so a `[56]u8` stack buffer suffices for `"BPM_RATE_LIMIT_TOKEN_" ++ token_id`.

---

## Integration notes

### Middleware chain order

```
[request arrives]
   │
   ▼
trace.extractOrGenerate()          ← API-09 — assigns trace_id, runs FIRST
   │
   ▼
auth.authenticate()                ← API-08 — resolves AuthContext (token_id, user_id, role)
   │                                           short-circuits with HTTP 401/403 if invalid
   ▼
rate_limit.check()                 ← API-10 — checks per-token bucket
   │                                           short-circuits with HTTP 429 if exceeded
   ▼
[RBAC / route handler]
```

Rate limiting runs **after** auth because only authenticated requests are counted. An unauthenticated request never reaches `check()`.

### Integration in the HTTP server dispatch loop

The HTTP server (currently stubbed; will be in `src/api/server.zig`) must apply the middleware in the order above. Pseudocode for the request dispatch function:

```zig
// 1. Trace middleware
const trace_result = try trace.extractOrGenerate(arena, req.header("X-Trace-Id"));
defer arena.free(trace_result.trace_id);
trace_context.set(trace_result.trace_id);
defer trace_context.clear();

// 2. Auth middleware
const auth_result = auth.authenticate(arena, req.header("Authorization"), &pool);
const ctx: auth.AuthContext = switch (auth_result) {
    .authenticated => |c| c,
    .unauthenticated => |hr| return respond(res, hr.status_code, hr.body),
    .forbidden      => |hr| return respond(res, hr.status_code, hr.body),
};
defer arena.free(ctx.user_id);
defer arena.free(ctx.token_id);

// 3. Rate limit middleware
const rl_result = try rate_limit.check(arena, ctx.token_id, std.time.timestamp());
switch (rl_result) {
    .allowed => {},
    .rate_limited => |info| {
        defer arena.free(info.body);
        res.setHeader("Retry-After", info.retry_after);
        res.setHeader("Content-Type", "application/problem+json");
        return respond(res, 429, info.body);
    },
}

// 4. Route handler ...
```

### `src/main.zig` export

Add to `src/main.zig`:

```zig
pub const api_rate_limit = @import("api/middleware/rate_limit.zig");
```

### `src/api/api_mod.zig` export

Add:

```zig
pub const rate_limit = @import("middleware/rate_limit.zig");
```

---

## Key invariants

1. A request that receives HTTP 429 MUST NOT reach any route handler.
2. Unauthenticated requests (no valid token) are never counted.
3. `retry_after` is always `>= 0`; it is 0 when the window has just reset.
4. The bucket map is never written from outside `check()` or `init()`/`deinit()`.
5. `limitForToken` never modifies shared state; it only reads environment variables.
6. `deinit()` frees every key copy allocated during `check()`; no memory is leaked.

---

## External dependencies

- `std.StringHashMap` — per-token bucket storage (Zig stdlib)
- `std.Thread.Mutex` — concurrency control (Zig stdlib)
- `std.time.timestamp()` — wall-clock seconds (Zig stdlib)
- `std.posix.getenv` — env var reads (Zig stdlib)
- `src/api/errors.zig` — `serialise()`, `problemRateLimited()` (new constructor)
- `src/api/middleware/auth.zig` — `AuthContext.token_id` (new field)

---

## Open questions

None. All design decisions are resolved.
