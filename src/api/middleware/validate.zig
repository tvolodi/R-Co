//! Request body validation middleware for the BPM Platform REST API.
//!
//! Implements API-07 enforcement: validates parsed JSON request bodies
//! against defined schemas BEFORE any business logic executes.
//!
//! Usage:
//!   const createDefSchema = Schema(CreateDefinitionBody){ .fields = &[_]... };
//!   const result = try enforceValidation(
//!       CreateDefinitionBody, allocator, createDefSchema, json_value,
//!   );
//!   switch (result) {
//!       .ok => |body| // proceed with validated body
//!       .reject => |hr| return hr; // return HTTP 422 to client
//!   }

const std = @import("std");
const validation = @import("../validation.zig");
const errors = @import("../errors.zig");

// ── Public types ──────────────────────────────────────────────────────────────

/// HTTP handler result type (mirrors the definition in response.zig).
pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

/// Result of the validation middleware.
/// On .ok: the parsed and validated value of type T.
/// On .reject: an HTTP response to return to the client immediately.
pub fn ValidationMiddlewareResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        reject: HandlerResult,
    };
}

// ── Middleware function ───────────────────────────────────────────────────────

/// Enforce request body validation for a given schema.
///
/// Parameters:
///   comptime T  — the target type to parse the JSON body into
///   allocator   — for allocating validation error messages and the parsed value
///   schema      — the Schema(T) definition to validate against
///   json_value  — the parsed std.json.Value from the request body
///
/// Returns:
///   .ok(T)      — the validated and parsed value; proceed to the handler
///   .reject     — HTTP 422 with RFC 9457 body containing ALL field errors,
///                 or HTTP 400 if the JSON value is not an object
///
/// On allocator exhaustion during error serialisation, returns HTTP 500.
pub fn enforceValidation(
    comptime T: type,
    allocator: std.mem.Allocator,
    schema: validation.Schema(T),
    json_value: std.json.Value,
) !ValidationMiddlewareResult(T) {
    const result = try validation.validate(T, allocator, schema, json_value);

    switch (result) {
        .ok => |value| {
            return .{ .ok = value };
        },
        .errors => |field_errors| {
            defer {
                for (field_errors) |fe| {
                    allocator.free(fe.field);
                    allocator.free(fe.constraint);
                    allocator.free(fe.message);
                    if (fe.received) |r| allocator.free(r);
                }
                allocator.free(field_errors);
            }
            const body = validation.serialiseValidationErrors(allocator, field_errors) catch
                return .{ .reject = .{
                    .status_code = 500,
                    .body = "{\"type\":\"https://bpm.example.com/problems/internal-error\"," ++
                        "\"title\":\"Internal Server Error\",\"status\":500," ++
                        "\"detail\":\"serialization failed\"}",
                } };
            return .{ .reject = .{ .status_code = 422, .body = body } };
        },
    }
}
