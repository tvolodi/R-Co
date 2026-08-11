//! RFC 9457 Problem Details builder for the BPM Platform REST API.
//!
//! Usage:
//!   const pd = errors.problemNotFound("definition not found");
//!   const body = try errors.serialise(allocator, pd);
//!   defer allocator.free(body);
//!   return .{ .status_code = pd.status, .body = body };

const std = @import("std");
const trace_context = @import("trace_context.zig");

const BASE = "https://bpm.example.com/problems/";

// ── Data types ────────────────────────────────────────────────────────────────

/// RFC 9457 Problem Details object.
/// All fields are required in the serialised JSON output.
/// Values are either compile-time string literals or caller-supplied slices.
/// No heap allocation — pass to serialise() to obtain a JSON []u8.
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
    /// Trace ID for this request.  Defaults to "" for backward compatibility.
    /// serialise() resolves the effective value automatically:
    ///   1. If trace_id is non-empty: use trace_id.
    ///   2. Else: use trace_context.get() (the thread-local for this request).
    ///   3. If both are empty: emit trace_id as "".
    /// Callers SHOULD leave this at the default; setting it explicitly
    /// overrides the thread-local (useful in tests).
    trace_id: []const u8 = "",
};

// ── Serialiser ────────────────────────────────────────────────────────────────

/// Serialise a ProblemDetails value to a JSON []u8.
/// Caller owns the returned slice and must free it with the same allocator.
/// Returns error.OutOfMemory if the allocator fails.
///
/// Output format:
///   {"type":"...","title":"...","status":N,"detail":"...","trace_id":"..."}
///
/// The trace_id field is resolved as:
///   1. If p.trace_id is non-empty: use p.trace_id.
///   2. Else: use trace_context.get() (the thread-local for this request).
///   3. If both are empty: emit trace_id as "".
pub fn serialise(allocator: std.mem.Allocator, p: ProblemDetails) error{OutOfMemory}![]const u8 {
    const effective_trace_id = if (p.trace_id.len > 0) p.trace_id else trace_context.get();
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"{s}\",\"title\":\"{s}\",\"status\":{d},\"detail\":\"{s}\",\"trace_id\":\"{s}\"}}",
        .{ p.type, p.title, p.status, p.detail, effective_trace_id },
    );
}

// ── Constructor helpers ───────────────────────────────────────────────────────
// Each returns a ProblemDetails value (stack-allocated, no allocator needed).
// Pass the returned value to serialise() to obtain a JSON body.

/// HTTP 400 — Bad Request.
pub fn problemBadRequest(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "bad-request",
        .title = "Bad Request",
        .status = 400,
        .detail = detail,
    };
}

/// HTTP 404 — Not Found.
pub fn problemNotFound(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "not-found",
        .title = "Not Found",
        .status = 404,
        .detail = detail,
    };
}

/// HTTP 409 — Conflict.
pub fn problemConflict(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "conflict",
        .title = "Conflict",
        .status = 409,
        .detail = detail,
    };
}

/// HTTP 422 — Unprocessable Entity.
pub fn problemUnprocessable(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "unprocessable-entity",
        .title = "Unprocessable Entity",
        .status = 422,
        .detail = detail,
    };
}

/// HTTP 415 — Unsupported Media Type.
pub fn problemUnsupportedMediaType(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "unsupported-media-type",
        .title = "Unsupported Media Type",
        .status = 415,
        .detail = detail,
    };
}

/// HTTP 500 — Internal Server Error.
pub fn problemInternalError(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "internal-error",
        .title = "Internal Server Error",
        .status = 500,
        .detail = detail,
    };
}

/// HTTP 401 — Unauthorized.
/// The caller MUST set the WWW-Authenticate: Bearer header separately;
/// this constructor only produces the RFC 9457 Problem Details body.
pub fn problemUnauthorized(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "unauthorized",
        .title = "Unauthorized",
        .status = 401,
        .detail = detail,
    };
}

/// HTTP 403 — Forbidden.
pub fn problemForbidden(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "forbidden",
        .title = "Forbidden",
        .status = 403,
        .detail = detail,
    };
}

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

/// HTTP 503 — Service Unavailable.
pub fn problemServiceUnavailable(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "service-unavailable",
        .title = "Service Unavailable",
        .status = 503,
        .detail = detail,
    };
}

/// HTTP 503 — Service Unavailable, specifically for
/// `event_store.StoreError.PartitionMissingForWrite` (PAR-01 AC4): an append
/// whose `created_at` falls in a calendar month with no attached partition
/// on `events`/`events_ephemeral`. 503 rather than 422 because this is not a
/// client input error — the request is well-formed and will succeed once
/// `plat_partition_maintenance` (PAR-02) attaches the missing partition, so
/// it is transient/retryable, not a permanent rejection of the payload.
pub fn problemPartitionMissingForWrite(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "partition-missing-for-write",
        .title = "Partition Missing For Write",
        .status = 503,
        .detail = detail,
    };
}

/// HTTP 422 — a SERVICE_TASK's service_id names no catalog entry with an
/// active version (PIN-01 AC1).
pub fn problemUnresolvedCatalogRef(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "unresolved-catalog-ref",
        .title = "Unresolved Catalog Ref",
        .status = 422,
        .detail = detail,
    };
}

/// HTTP 422 — a module_ref semver range matches no published module version
/// (PIN-01 AC2).
pub fn problemUnresolvedModuleRef(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "unresolved-module-ref",
        .title = "Unresolved Module Ref",
        .status = 422,
        .detail = detail,
    };
}

/// HTTP 422 — initial variables violate the resolved variable_schema version
/// (PIN-01 AC3).
pub fn problemVariableSchemaViolation(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "variable-schema-violation",
        .title = "Variable Schema Violation",
        .status = 422,
        .detail = detail,
    };
}

/// HTTP 422 — pin_overrides names a version that does not exist (PIN-01 AC4).
pub fn problemUnresolvedPinOverride(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "unresolved-pin-override",
        .title = "Unresolved Pin Override",
        .status = 422,
        .detail = detail,
    };
}
