# Module: api_conventions

**Covers:** API-01 (REST conventions, RFC 9457 Problem Details, Content-Type enforcement)
**Files:** `src/api/errors.zig`, `src/api/middleware/content_type.zig`, `src/api/response.zig`
**Depends on:** No DB dependencies. No I/O. All functions are pure or allocator-based.

---

## Module purpose

This module implements the cross-cutting HTTP API conventions required by API-01:

1. **`errors.zig`** — Builds RFC 9457 Problem Details responses for all error cases. Provides typed constructor helpers for each HTTP error class the platform emits.
2. **`middleware/content_type.zig`** — Enforces `Content-Type: application/json` on request bodies. Rejects non-conforming requests before they reach route handlers.
3. **`response.zig`** — Standardised HTTP response builder for success paths. Ensures all responses carry `Content-Type: application/json` and use correct success status codes.

These three files have no dependencies on each other and introduce no circular imports. All existing route handler files (`definitions.zig`, `instances.zig`, `tasks.zig`) use `HandlerResult{status_code, body}` as their output type. The new modules align with that type without requiring handler signature changes.

---

## API-01 Acceptance Criterion Mapping

| AC | Satisfied by |
|---|---|
| Resource noun paths + standard HTTP verbs | Existing route registrations (no new code needed) |
| All bodies use `Content-Type: application/json` | `response.zig` sets header on all success responses; `content_type.zig` rejects non-conforming requests |
| Requests with body and wrong/absent `Content-Type` → HTTP 415 | `content_type.zig` `enforceContentType()` |
| All error responses use RFC 9457 Problem Details | `errors.zig` `ProblemDetails` + constructor helpers |
| RFC 9457 fields: `type`, `title`, `status`, `detail` | `ProblemDetails` struct fields |
| HTTP 200, 201, 204 for successes | `response.zig` `ok()`, `created()`, `noContent()` |
| PUT with no body → HTTP 400 | `content_type.zig` `enforceContentType()` returns 400 for PUT with no body |
| POST to non-existent resource → HTTP 404 | Existing route handlers already return 404 (confirmed); no new code needed |

---

## Section 1: `src/api/errors.zig`

### 1.1 Data types

```zig
/// RFC 9457 Problem Details object.
/// All fields are required in the serialised JSON output.
pub const ProblemDetails = struct {
    /// Absolute URI identifying the problem type.
    /// Format: "https://bpm.example.com/problems/<slug>"
    type: []const u8,
    /// Human-readable summary of the problem type.
    title: []const u8,
    /// HTTP status code (mirrors the HTTP response status).
    status: u16,
    /// Specific message describing this occurrence.
    detail: []const u8,
};
```

**Extension fields** — API-07 adds `errors: []ValidationError`; API-09 adds `trace_id: []const u8`. These are NOT added in this module. The struct is designed to be embedded or extended by those later modules without modifying `errors.zig`.

### 1.2 Problem type URI slugs

| Slug | HTTP status | title |
|---|---|---|
| `bad-request` | 400 | "Bad Request" |
| `not-found` | 404 | "Not Found" |
| `conflict` | 409 | "Conflict" |
| `unprocessable-entity` | 422 | "Unprocessable Entity" |
| `unsupported-media-type` | 415 | "Unsupported Media Type" |
| `internal-error` | 500 | "Internal Server Error" |
| `service-unavailable` | 503 | "Service Unavailable" |

Base URI: `https://bpm.example.com/problems/`

### 1.3 Public interface

```zig
const std = @import("std");

/// Allocate and serialise a ProblemDetails value to a JSON []u8.
/// Caller owns the returned slice and must free it.
/// Output format:
///   {"type":"https://bpm.example.com/problems/<slug>",
///    "title":"<title>","status":<N>,"detail":"<detail>"}
pub fn serialise(allocator: std.mem.Allocator, p: ProblemDetails) ![]const u8;

// ── Constructor helpers ──────────────────────────────────────────────────────
// Each returns a ProblemDetails value (stack allocated, no allocator needed).
// The caller passes it to serialise() to get a JSON []u8.

pub fn problemBadRequest(detail: []const u8) ProblemDetails;
pub fn problemNotFound(detail: []const u8) ProblemDetails;
pub fn problemConflict(detail: []const u8) ProblemDetails;
pub fn problemUnprocessable(detail: []const u8) ProblemDetails;
pub fn problemUnsupportedMediaType(detail: []const u8) ProblemDetails;
pub fn problemInternalError(detail: []const u8) ProblemDetails;
pub fn problemServiceUnavailable(detail: []const u8) ProblemDetails;
```

### 1.4 Integration with HandlerResult

Existing route handlers use a private `errorResult(allocator, code, ...)` helper. That helper should be updated to use `errors.zig` constructors:

```zig
// Pattern used in existing handlers (to be updated):
fn errorResult(allocator: std.mem.Allocator, code: u16, detail: []const u8) HandlerResult {
    const p = switch (code) {
        400 => errors.problemBadRequest(detail),
        404 => errors.problemNotFound(detail),
        409 => errors.problemConflict(detail),
        415 => errors.problemUnsupportedMediaType(detail),
        422 => errors.problemUnprocessable(detail),
        503 => errors.problemServiceUnavailable(detail),
        else => errors.problemInternalError(detail),
    };
    const body = errors.serialise(allocator, p) catch return .{ .status_code = 500, .body = "{}" };
    return .{ .status_code = p.status, .body = body };
}
```

This pattern change is non-breaking: `HandlerResult` type signature is unchanged.

---

## Section 2: `src/api/middleware/content_type.zig`

### 2.1 Purpose

Called before any route handler for `POST`, `PUT`, and `PATCH` requests. Returns a `HandlerResult` if the request fails the check; the router short-circuits and never calls the route handler.

### 2.2 Public interface

```zig
const std = @import("std");
const errors = @import("../errors.zig");

/// HTTP methods that require a body.
pub const BODY_METHODS = [_][]const u8{ "POST", "PUT", "PATCH" };

/// Result of the content-type check.
pub const ContentTypeCheckResult = union(enum) {
    /// Request is valid; proceed to handler.
    ok: void,
    /// Request is invalid; return this HandlerResult immediately.
    reject: HandlerResult,
};

/// HandlerResult is imported from any route file or defined locally here.
pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

/// Check Content-Type enforcement rules for a request.
///
/// Rules:
///   1. POST / PATCH with `Content-Length: 0` or no body: checked for
///      Content-Type header presence; if absent, returns 415.
///   2. PUT with no body (body_len == 0): returns HTTP 400.
///   3. POST / PUT / PATCH with body_len > 0 and Content-Type ≠
///      "application/json": returns HTTP 415.
///   4. All other cases: returns .ok.
///
/// Parameters:
///   allocator    — for serialising the Problem Details body
///   method       — HTTP method string, e.g. "POST"
///   content_type — value of the Content-Type header, or null if absent
///   body_len     — byte length of the request body (0 = no body)
pub fn enforceContentType(
    allocator: std.mem.Allocator,
    method: []const u8,
    content_type: ?[]const u8,
    body_len: usize,
) ContentTypeCheckResult;
```

### 2.3 Decision table

| Method | body_len | Content-Type present | Content-Type value | Result |
|---|---|---|---|---|
| GET / DELETE | any | any | any | `.ok` (not checked) |
| PUT | 0 | any | any | `.reject` HTTP 400 "body required for PUT" |
| POST / PATCH | 0 | absent | — | `.reject` HTTP 415 (no Content-Type) |
| POST / PUT / PATCH | > 0 | absent | — | `.reject` HTTP 415 |
| POST / PUT / PATCH | > 0 | present | not `application/json` | `.reject` HTTP 415 |
| POST / PUT / PATCH | > 0 | present | `application/json` | `.ok` |
| POST / PATCH | 0 | present | `application/json` | `.ok` (empty body, valid CT) |

**Note:** `Content-Type` matching strips any `;charset=…` suffix before comparison, i.e. `application/json; charset=utf-8` is accepted.

### 2.4 No I/O

This function is pure: no DB access, no logging, no syscalls. It only allocates for the Problem Details JSON body on the reject path.

---

## Section 3: `src/api/response.zig`

### 3.1 Purpose

Provides typed success response builders so that all positive responses consistently set `Content-Type: application/json` and use correct HTTP status codes. Removes repeated `return .{ .status_code = 200, .body = ... }` boilerplate from route handlers.

### 3.2 Public interface

```zig
const std = @import("std");

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

/// HTTP 200 OK — body is a pre-serialised JSON []u8 owned by caller.
/// Returned HandlerResult.body is the same slice (no copy).
pub fn ok(body: []const u8) HandlerResult;

/// HTTP 201 Created — body is a pre-serialised JSON []u8 owned by caller.
pub fn created(body: []const u8) HandlerResult;

/// HTTP 204 No Content — body is an empty slice "".
/// Callers must NOT send a body for 204 responses.
pub fn noContent() HandlerResult;
```

**`Content-Type` header:** This module defines the expected response `Content-Type` as a compile-time constant:
```zig
pub const CONTENT_TYPE_JSON = "application/json";
```
The HTTP server layer (`server.zig`) reads this constant when writing response headers. `HandlerResult` itself does not carry headers (this aligns with existing route file conventions).

### 3.3 HandlerResult sharing

`HandlerResult` is defined identically in `definitions.zig`, `instances.zig`, and `tasks.zig`. The long-term goal is to have all three import it from a single source. `response.zig` defines the canonical version. BACKEND-DEV may alias it in route files as:

```zig
pub const HandlerResult = @import("../response.zig").HandlerResult;
```

This is a non-breaking change: the struct fields are identical. Existing usage compiles unchanged.

---

## Data flow diagram

```
HTTP Request
     │
     ▼
┌─────────────────────────────────────┐
│  middleware/content_type.zig        │
│  enforceContentType(method,         │
│    content_type, body_len)          │
│                                     │
│  .reject ──► errors.zig            │
│              problemUnsupportedMT() │
│              or problemBadRequest() │
│              → HandlerResult(415)   │
│              or HandlerResult(400)  │
│                                     │
│  .ok ──────────────────────────────┼──► Route handler
└─────────────────────────────────────┘         │
                                                 │
                                    ┌────────────┴────────────┐
                                    │  Success path           │ Error path
                                    │  response.zig           │ errors.zig
                                    │  ok() / created() /     │ problemNotFound()
                                    │  noContent()            │ problemConflict()
                                    │  → HandlerResult(2xx)   │ etc.
                                    └─────────────────────────┘
                                                 │
                                                 ▼
                                     HTTP Response (server.zig)
                                     Content-Type: application/json
```

---

## Error taxonomy

### `errors.zig`
| Error | Condition |
|---|---|
| `error.OutOfMemory` | Returned by `serialise()` if allocator fails |

All other "errors" are encoded as `ProblemDetails` values and serialised to the response body — they are not Zig errors.

### `content_type.zig`
| Error | Condition |
|---|---|
| `error.OutOfMemory` | Returned via `enforceContentType()` if Problem Details serialisation fails — caller must handle by returning HTTP 500 |

### `response.zig`

No error returns. All functions are infallible (no allocation).

---

## Dependencies

| File | Imports | Must NOT import |
|---|---|---|
| `errors.zig` | `std` only | Any route file, DB, engine |
| `middleware/content_type.zig` | `std`, `../errors.zig` | Any route file, DB, engine |
| `response.zig` | `std` only | Any route file, DB, engine |

No new migrations required. No DB schema changes.

---

## Key invariants

1. Every `HandlerResult` with `status_code >= 400` MUST have a body that is valid RFC 9457 JSON (produced by `errors.zig`).
2. Every `HandlerResult` with `status_code < 300` (except 204) MUST have a non-empty body.
3. `HandlerResult` with `status_code == 204` MUST have an empty body (`""`).
4. `Content-Type: application/json` is set on all responses by the server layer — it is a server-level invariant, not per-handler.
5. `enforceContentType` is stateless: same inputs always produce same output.

---

## Open questions

1. **`HandlerResult` consolidation:** Should BACKEND-DEV perform the migration of all route files to import `HandlerResult` from `response.zig` as part of API-01, or defer to a separate cleanup task? Recommendation: do it in API-01 since the struct is identical and the change is mechanical.
2. **Server header injection:** `server.zig` is responsible for writing `Content-Type: application/json` on all responses. The current `server.zig` stub needs to be confirmed as Stage 4 scope before BACKEND-DEV touches it. If `server.zig` is out of scope, `HandlerResult` may need a `headers` field — flag for ORCH.
3. **`Content-Length: 0` vs absent body:** The decision table treats `body_len == 0` as "no body". If the HTTP layer can distinguish between "Content-Length: 0 explicitly set" and "no Content-Length header", the middleware may need an additional parameter. For now, `body_len == 0` is sufficient.
