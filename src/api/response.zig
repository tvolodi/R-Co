//! HTTP response builder for the BPM Platform REST API.
//!
//! Provides typed success response constructors so all positive responses
//! consistently use correct HTTP status codes. Defines the canonical
//! HandlerResult type — route files may alias it as:
//!
//!   pub const HandlerResult = @import("../response.zig").HandlerResult;

const std = @import("std");
const errors_mod = @import("errors.zig");

// ── Public types ──────────────────────────────────────────────────────────────

/// Canonical HTTP handler result.
/// Identical to the HandlerResult declared in each route file;
/// this is the single authoritative definition.
pub const HandlerResult = struct {
    /// HTTP response status code.
    status_code: u16,
    /// JSON-encoded response body; owned by the caller allocator.
    body: []const u8,
    /// Response content type; defaults to JSON for existing handlers.
    content_type: []const u8 = CONTENT_TYPE_JSON,
};

/// Content-Type value for all JSON responses.
/// The HTTP server layer reads this constant when writing response headers.
pub const CONTENT_TYPE_JSON = "application/json";

// ── Success response builders (no allocation) ─────────────────────────────────

/// HTTP 200 OK.
/// body must be a pre-serialised JSON slice owned by the caller.
pub fn ok(body: []const u8) HandlerResult {
    return .{ .status_code = 200, .body = body };
}

/// HTTP 201 Created.
/// body must be a pre-serialised JSON slice owned by the caller.
pub fn created(body: []const u8) HandlerResult {
    return .{ .status_code = 201, .body = body };
}

/// HTTP 204 No Content.
/// body is an empty string — callers must not send a body for 204 responses.
pub fn noContent() HandlerResult {
    return .{ .status_code = 204, .body = "" };
}

// ── Error response builder ────────────────────────────────────────────────────

/// Serialise pd to a JSON body and wrap it in a HandlerResult with the
/// correct HTTP status code.
///
/// On allocation failure returns HTTP 500 with a static inline body so that
/// the caller always gets a valid HandlerResult without further error handling.
pub fn problemResponse(
    allocator: std.mem.Allocator,
    pd: errors_mod.ProblemDetails,
) HandlerResult {
    const body = errors_mod.serialise(allocator, pd) catch
        return .{
            .status_code = 500,
            .body = "{\"type\":\"https://bpm.example.com/problems/internal-error\"," ++
                "\"title\":\"Internal Server Error\",\"status\":500," ++
                "\"detail\":\"serialization failed\"}",
        };
    return .{ .status_code = pd.status, .body = body };
}
