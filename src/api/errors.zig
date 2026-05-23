//! RFC 9457 Problem Details builder for the BPM Platform REST API.
//!
//! Usage:
//!   const pd = errors.problemNotFound("definition not found");
//!   const body = try errors.serialise(allocator, pd);
//!   defer allocator.free(body);
//!   return .{ .status_code = pd.status, .body = body };

const std = @import("std");

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
};

// ── Serialiser ────────────────────────────────────────────────────────────────

/// Serialise a ProblemDetails value to a JSON []u8.
/// Caller owns the returned slice and must free it with the same allocator.
/// Returns error.OutOfMemory if the allocator fails.
///
/// Output format:
///   {"type":"https://bpm.example.com/problems/<slug>",
///    "title":"<title>","status":<N>,"detail":"<detail>"}
pub fn serialise(allocator: std.mem.Allocator, p: ProblemDetails) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"{s}\",\"title\":\"{s}\",\"status\":{d},\"detail\":\"{s}\"}}",
        .{ p.type, p.title, p.status, p.detail },
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

/// HTTP 503 — Service Unavailable.
pub fn problemServiceUnavailable(detail: []const u8) ProblemDetails {
    return .{
        .type = BASE ++ "service-unavailable",
        .title = "Service Unavailable",
        .status = 503,
        .detail = detail,
    };
}
