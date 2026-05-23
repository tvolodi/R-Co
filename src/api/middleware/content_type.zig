//! Content-Type enforcement middleware for the BPM Platform REST API.
//!
//! Call checkContentType() (pure, no allocation) or enforceContentType()
//! (allocating, returns a full HandlerResult on reject) before dispatching
//! POST / PUT / PATCH requests to route handlers.

const std = @import("std");
const errors = @import("../errors.zig");

// ── Public types ──────────────────────────────────────────────────────────────

/// HTTP handler result type (mirrors the definition in each route file).
pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

/// Result of the allocating content-type check.
pub const ContentTypeCheckResult = union(enum) {
    /// Request is valid; proceed to the route handler.
    ok: void,
    /// Request is invalid; return this HandlerResult to the client immediately.
    reject: HandlerResult,
};

/// HTTP methods that require body-related Content-Type enforcement.
pub const BODY_METHODS = [_][]const u8{ "POST", "PUT", "PATCH" };

// ── Pure check (no allocation) ────────────────────────────────────────────────

/// Check Content-Type rules for a request. No allocation — returns a
/// ProblemDetails value on failure, or null if the request passes.
///
/// Decision table (has_body = body byte length > 0):
///   GET / DELETE           → null (not checked)
///   PUT  + !has_body       → HTTP 400 (body required for PUT)
///   POST / PATCH + !has_body + no CT              → HTTP 415
///   POST / PUT / PATCH + has_body + no CT         → HTTP 415
///   POST / PUT / PATCH + has_body + CT ≠ app/json → HTTP 415
///   POST / PUT / PATCH + has_body + CT = app/json → null (ok)
///   POST / PATCH + !has_body + CT = app/json      → null (ok)
///
/// Content-Type matching strips any `;charset=…` or other params before
/// comparison, so "application/json; charset=utf-8" is accepted.
pub fn checkContentType(
    method: []const u8,
    content_type: ?[]const u8,
    has_body: bool,
) ?errors.ProblemDetails {
    const is_post = std.mem.eql(u8, method, "POST");
    const is_put = std.mem.eql(u8, method, "PUT");
    const is_patch = std.mem.eql(u8, method, "PATCH");

    // GET, DELETE, HEAD, OPTIONS — not subject to Content-Type enforcement.
    if (!is_post and !is_put and !is_patch) return null;

    // PUT with no body → HTTP 400 (full replacement requires a body).
    if (is_put and !has_body) {
        return errors.problemBadRequest("body is required for PUT");
    }

    // POST / PATCH with no body: validate Content-Type header presence only.
    // A zero-length body is permitted when the header is correct (e.g. signal POSTs).
    if ((is_post or is_patch) and !has_body) {
        const ct = content_type orelse
            return errors.problemUnsupportedMediaType("Content-Type must be application/json");
        if (!std.mem.eql(u8, stripParams(ct), "application/json")) {
            return errors.problemUnsupportedMediaType("Content-Type must be application/json");
        }
        return null;
    }

    // POST / PUT / PATCH with a body: Content-Type must be application/json.
    const ct = content_type orelse
        return errors.problemUnsupportedMediaType("Content-Type must be application/json");
    if (!std.mem.eql(u8, stripParams(ct), "application/json")) {
        return errors.problemUnsupportedMediaType("Content-Type must be application/json");
    }

    return null;
}

// ── Allocating enforcement ────────────────────────────────────────────────────

/// Enforce Content-Type rules. Serialises a Problem Details body on reject.
///
/// Parameters:
///   allocator    — for serialising the Problem Details JSON body on reject paths
///   method       — HTTP method string, e.g. "POST"
///   content_type — value of the Content-Type header, or null if absent
///   body_len     — byte length of the request body (0 = no body)
///
/// Returns .ok or .reject{ HandlerResult }.
/// On OutOfMemory during rejection serialisation, returns HTTP 500.
pub fn enforceContentType(
    allocator: std.mem.Allocator,
    method: []const u8,
    content_type: ?[]const u8,
    body_len: usize,
) ContentTypeCheckResult {
    const pd = checkContentType(method, content_type, body_len > 0) orelse return .ok;
    const body = errors.serialise(allocator, pd) catch
        return .{ .reject = .{ .status_code = 500, .body = "{\"error\":\"internal server error\"}" } };
    return .{ .reject = .{ .status_code = pd.status, .body = body } };
}

// ── Private helpers ───────────────────────────────────────────────────────────

/// Strip `;` and everything after it from a Content-Type header value,
/// then trim trailing whitespace/tabs from the primary type token.
/// Examples:
///   "application/json; charset=utf-8" → "application/json"
///   "application/json"                → "application/json"
fn stripParams(ct: []const u8) []const u8 {
    if (std.mem.indexOf(u8, ct, ";")) |semi| {
        return std.mem.trimEnd(u8, ct[0..semi], " \t");
    }
    return ct;
}
