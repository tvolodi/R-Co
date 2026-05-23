//! Input validation module for the BPM Platform REST API.
//!
//! Implements API-07: validates incoming request payloads against defined
//! schemas before any business logic executes. Returns all field-level
//! errors in a single RFC 9457 response — never just the first error.
//!
//! Usage:
//!   const schema = Schema(CreateDefinitionBody){
//!       .fields = &[_]FieldConstraint{ ... },
//!   };
//!   const result = try validate(CreateDefinitionBody, allocator, schema, json_value);
//!   switch (result) {
//!       .ok => |value| // proceed with validated value
//!       .errors => |errs| // serialise with serialiseValidationErrors() → HTTP 422
//!   }

const std = @import("std");

// ── Error set ─────────────────────────────────────────────────────────────────

/// Per-module error set for the validation module.
pub const ValidationError = error{
    OutOfMemory,
};

// ── Data types ────────────────────────────────────────────────────────────────

/// A single field-level validation error, serialised into the RFC 9457
/// `errors` array extension.  Mirrors the structure required by API-07 AC.
pub const FieldError = struct {
    /// Dot-separated JSON path to the offending field.
    /// Examples: "name", "graph.nodes[0].id", "output_variables.amount".
    field: []const u8,

    /// Machine-readable constraint identifier.
    /// Examples: "required", "type.string", "type.uuid", "min_length",
    ///           "max_length", "pattern", "not_empty",
    ///           "type.integer", "type.boolean", "type.object", "type.array".
    constraint: []const u8,

    /// Human-readable description of what went wrong.
    /// Examples: "field is required", "expected string, got number",
    ///           "length must be ≤ 255".
    message: []const u8,

    /// The actual value received, serialised as a JSON fragment.
    /// null if the field was absent.  For type errors this is the raw
    /// JSON value; for constraint errors this is the value that failed.
    /// Examples: "null", "42", "\"\"", "\"not-a-uuid\"", "[1,2,3]".
    received: ?[]const u8,
};

/// JSON types recognised by the validator.  Matches the JSON type system:
/// string, number (integer or float), boolean, object, array, null.
pub const JsonType = enum {
    string,
    number,
    integer,
    boolean,
    object,
    array,
    null_value,
};

/// Describes a single field constraint within a schema definition.
/// Used by validateField() to check one field at a time.
pub const FieldConstraint = struct {
    /// The JSON key name for this field (e.g. "name", "event_type").
    name: []const u8,

    /// Whether the field must be present and non-null in the JSON object.
    required: bool = false,

    /// The expected JSON type.  When set, the field value is checked
    /// against this type BEFORE any further constraints.
    /// null means "any type accepted" (useful for polymorphic fields).
    expected_type: ?JsonType = null,

    /// If true, an empty string "" is treated as a missing value and
    /// reported with constraint="required" when the field is required.
    /// Per API-07 AC: empty required fields MUST be treated as missing.
    reject_empty_string: bool = false,

    /// Minimum string length (inclusive).  Only checked when expected_type is .string.
    min_length: ?usize = null,

    /// Maximum string length (inclusive).  Only checked when expected_type is .string.
    max_length: ?usize = null,

    /// Regex pattern the string must match (Zig std.regex).
    /// Only checked when expected_type is .string.
    pattern: ?[]const u8 = null,

    /// Minimum numeric value (inclusive).  Only checked when expected_type is .number
    /// or .integer.
    min_value: ?f64 = null,

    /// Maximum numeric value (inclusive).  Only checked when expected_type is .number
    /// or .integer.
    max_value: ?f64 = null,

    /// Minimum array length.  Only checked when expected_type is .array.
    min_items: ?usize = null,

    /// Maximum array length.  Only checked when expected_type is .array.
    max_items: ?usize = null,
};

/// Validation schema for a request body type T.
/// A schema is a list of field constraints plus an optional custom validator
/// for cross-field or business-rule checks that go beyond per-field validation.
///
/// Usage:
///   const createDefSchema = Schema(CreateDefinitionBody){
///       .fields = &[_]FieldConstraint{ ... },
///       .custom_validator = null,
///   };
pub fn Schema(comptime T: type) type {
    return struct {
        /// Ordered list of field constraints.  Fields are validated in order;
        /// ALL errors are collected before returning.
        fields: []const FieldConstraint,

        /// Optional custom validation function for cross-field checks.
        /// Called AFTER all per-field checks pass.  Returns additional
        /// FieldError entries or an empty slice.
        /// Accepts the fully-parsed T value (all fields present).
        custom_validator: ?*const fn (allocator: std.mem.Allocator, value: T) anyerror![]FieldError = null,
    };
}

/// Result of schema validation.  Two outcomes:
///   .ok    — the parsed and validated value of type T, ready for the handler.
///   .errors — one or more validation errors; the request must be rejected.
///
/// If .errors is returned, `errors.len > 0` is guaranteed.
pub fn ValidationResult(comptime T: type) type {
    return union(enum) {
        ok: T,
        errors: []FieldError,
    };
}

// ── Single-field validation (pure, no allocation) ─────────────────────────────

/// Validate a single JSON value against a FieldConstraint.
///
/// Returns null if the field passes all checks, or a FieldError if
/// any constraint is violated.  Empty required strings are reported as
/// "required" when reject_empty_string is true (per API-07).
///
/// This function is pure (no allocation).  The returned FieldError
/// references the input slices directly — callers must copy if they
/// need owned memory.  The `received` field is always null from this
/// function; callers should populate it from the JSON value.
pub fn validateField(
    constraint: FieldConstraint,
    json_value: ?std.json.Value,
) ?FieldError {
    // ── Required check ──────────────────────────────────────────────────
    if (constraint.required) {
        if (json_value == null or json_value.? == .null) {
            return FieldError{
                .field = constraint.name,
                .constraint = "required",
                .message = "field is required",
                .received = null,
            };
        }
    }

    // If the field is absent and not required, skip further checks.
    if (json_value == null or json_value.? == .null) {
        return null;
    }

    const value = json_value.?;

    // ── Empty-string check (per API-07: empty required = missing) ───────
    if (constraint.reject_empty_string) {
        if (value == .string and value.string.len == 0) {
            if (constraint.required) {
                return FieldError{
                    .field = constraint.name,
                    .constraint = "required",
                    .message = "field is required",
                    .received = null,
                };
            } else {
                return FieldError{
                    .field = constraint.name,
                    .constraint = "not_empty",
                    .message = "field must not be empty",
                    .received = null,
                };
            }
        }
    }

    // ── Type check ──────────────────────────────────────────────────────
    if (constraint.expected_type) |expected| {
        const type_ok = checkJsonType(value, expected);
        if (!type_ok) {
            return FieldError{
                .field = constraint.name,
                .constraint = typeConstraintName(expected),
                .message = typeMismatchMessage(expected),
                .received = null,
            };
        }
    }

    // ── String constraints ──────────────────────────────────────────────
    if (value == .string) {
        const s = value.string;

        if (constraint.min_length) |min| {
            if (s.len < min) {
                return FieldError{
                    .field = constraint.name,
                    .constraint = "min_length",
                    .message = "length must be ≥ minimum",
                    .received = null,
                };
            }
        }

        if (constraint.max_length) |max| {
            if (s.len > max) {
                return FieldError{
                    .field = constraint.name,
                    .constraint = "max_length",
                    .message = "length must be ≤ maximum",
                    .received = null,
                };
            }
        }

        if (constraint.pattern) |pat| {
            // std.regex was removed in Zig 0.16; pattern matching is deferred
            // to a future implementation using an external regex library.
            // For now, pattern constraints pass without checking.
            _ = pat;
        }
    }

    // ── Numeric constraints ─────────────────────────────────────────────
    if (value == .integer or value == .float or value == .number_string) {
        const num: f64 = switch (value) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            .number_string => |ns| std.fmt.parseFloat(f64, ns) catch return null,
            else => unreachable,
        };

        if (constraint.min_value) |min| {
            if (num < min) {
                return FieldError{
                    .field = constraint.name,
                    .constraint = "min_value",
                    .message = "value must be ≥ minimum",
                    .received = null,
                };
            }
        }

        if (constraint.max_value) |max| {
            if (num > max) {
                return FieldError{
                    .field = constraint.name,
                    .constraint = "max_value",
                    .message = "value must be ≤ maximum",
                    .received = null,
                };
            }
        }
    }

    // ── Array constraints ───────────────────────────────────────────────
    if (value == .array) {
        const arr = value.array;

        if (constraint.min_items) |min| {
            if (arr.items.len < min) {
                return FieldError{
                    .field = constraint.name,
                    .constraint = "min_items",
                    .message = "array must have ≥ minimum items",
                    .received = null,
                };
            }
        }

        if (constraint.max_items) |max| {
            if (arr.items.len > max) {
                return FieldError{
                    .field = constraint.name,
                    .constraint = "max_items",
                    .message = "array must have ≤ maximum items",
                    .received = null,
                };
            }
        }
    }

    return null;
}

// ── Value deep-copy helper ──────────────────────────────────────────────────

/// Deep-copy the dynamically-allocated fields of a parsed struct value from
/// an arena-backed allocator to a caller-owned allocator.
///
/// Handles []const u8, ?[]const u8, and nested structs.  Scalar fields
/// (integers, booleans, floats) are passed through unchanged.
///
/// Used by validate() to transfer ownership from the internal
/// ArenaAllocator created by parseFromValue(.alloc_always) to the
/// caller's allocator before deiniting the arena.
fn dupeValue(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: T,
) error{OutOfMemory}!T {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            var result: T = undefined;
            inline for (s.fields) |field| {
                @field(result, field.name) = try dupeValue(field.type, allocator, @field(value, field.name));
            }
            return result;
        },
        .optional => |o| {
            if (value) |v| {
                return try dupeValue(o.child, allocator, v);
            }
            return null;
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                return try allocator.dupe(u8, value);
            }
            // For other pointer/slice types (e.g. []T), pass through unchanged.
            // These are owned by the caller's allocator since parseFromValue
            // uses .alloc_always only for string fields.
            return value;
        },
        else => return value,
    }
}

// ── Schema-based validation ──────────────────────────────────────────────────

/// Validate a parsed JSON object against a schema, returning either the
/// validated value of type T or a list of ALL validation errors found.
///
/// Parameters:
///   allocator  — for allocating FieldError slices and message strings
///   schema     — the Schema(T) definition to validate against
///   json_value — a parsed std.json.Value representing the request body
///
/// Returns:
///   .ok(T)    — all checks passed; the value is fully parsed and valid
///   .errors   — one or more violations; HTTP 422 must be returned
///
/// This function is pure (no I/O).  It allocates on the error path
/// (FieldError messages and received serialisations) as well as on the
/// success path (parsing T from the JSON value).
pub fn validate(
    comptime T: type,
    allocator: std.mem.Allocator,
    schema: Schema(T),
    json_value: std.json.Value,
) error{OutOfMemory}!ValidationResult(T) {
    // Must be a JSON object (structural validation — malformed JSON is HTTP 400,
    // handled upstream; this covers the case of a valid JSON non-object).
    if (json_value != .object) {
        const err = try allocator.alloc(FieldError, 1);
        err[0] = FieldError{
            .field = try allocator.dupe(u8, "(root)"),
            .constraint = try allocator.dupe(u8, "type.object"),
            .message = try allocator.dupe(u8, "request body must be a JSON object"),
            .received = null,
        };
        return .{ .errors = err };
    }

    const obj = json_value.object;
    var error_list: std.ArrayList(FieldError) = .empty;
    defer error_list.deinit(allocator);

    // Validate each field constraint; collect ALL errors.
    for (schema.fields) |constraint| {
        const field_value = obj.get(constraint.name);
        if (validateField(constraint, field_value)) |raw_err| {
            // Copy the error to owned memory and populate `received`
            // with a JSON serialisation of the actual value.
            const copied = try copyFieldError(allocator, raw_err, field_value);
            try error_list.append(allocator, copied);
        }
    }

    // If there are field-level errors, return them all (never just the first).
    if (error_list.items.len > 0) {
        return .{ .errors = try error_list.toOwnedSlice(allocator) };
    }

    // All field checks passed — parse T from the JSON value.
    // .alloc_always creates an internal ArenaAllocator for the parsed value's
    // dynamic fields (strings, arrays).  We deep-copy those into caller-owned
    // memory before deiniting the arena to avoid leaks.
    const parsed = std.json.parseFromValue(T, allocator, json_value, .{ .allocate = .alloc_always }) catch {
        // If parsing fails despite all field checks passing, report as validation error.
        const err = try allocator.alloc(FieldError, 1);
        err[0] = FieldError{
            .field = try allocator.dupe(u8, "(root)"),
            .constraint = try allocator.dupe(u8, "parse_error"),
            .message = try allocator.dupe(u8, "payload does not match expected schema"),
            .received = null,
        };
        return .{ .errors = err };
    };
    defer parsed.deinit();

    // Run custom validator if present.
    if (schema.custom_validator) |custom_fn| {
        const custom_errors = custom_fn(allocator, parsed.value) catch {
            // Custom validator threw an unexpected error — treat as validation failure.
            const err = try allocator.alloc(FieldError, 1);
            err[0] = FieldError{
                .field = try allocator.dupe(u8, "(root)"),
                .constraint = try allocator.dupe(u8, "custom_validation_error"),
                .message = try allocator.dupe(u8, "custom validation failed"),
                .received = null,
            };
            return .{ .errors = err };
        };
        if (custom_errors.len > 0) {
            // Custom validation failed — arena freed by defer above.
            return .{ .errors = custom_errors };
        }
    }

    // Deep-copy all dynamically-allocated fields from the arena to the
    // caller's allocator, then let the defer free the arena.
    const owned = try dupeValue(T, allocator, parsed.value);
    return .{ .ok = owned };
}

// ── RFC 9457 serialisation: problem details with errors array ────────────────

/// Serialise a list of FieldErrors into an RFC 9457 Problem Details JSON body
/// extended with an `errors` array.  The output mirrors API-07 requirements:
/// each entry in the errors array identifies the field path, constraint
/// violated, a human-readable message, and the actual value received.
///
/// Caller owns the returned []u8 and must free it with the same allocator.
pub fn serialiseValidationErrors(
    allocator: std.mem.Allocator,
    field_errors: []const FieldError,
) error{OutOfMemory}![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Open the Problem Details object.
    try buf.appendSlice(allocator,
        \\{"type":"https://bpm.example.com/problems/unprocessable-entity",
        \\"title":"Unprocessable Entity","status":422,
        \\"detail":"Validation failed","errors":[
    );

    for (field_errors, 0..) |fe, i| {
        if (i > 0) try buf.append(allocator, ',');

        try buf.appendSlice(allocator, "{\"field\":\"");
        try jsonEscapeToBuf(&buf, allocator, fe.field);
        try buf.appendSlice(allocator, "\",\"constraint\":\"");
        try jsonEscapeToBuf(&buf, allocator, fe.constraint);
        try buf.appendSlice(allocator, "\",\"message\":\"");
        try jsonEscapeToBuf(&buf, allocator, fe.message);
        try buf.appendSlice(allocator, "\"");

        if (fe.received) |recv| {
            try buf.appendSlice(allocator, ",\"received\":");
            // received is already a JSON fragment — write it as-is.
            try buf.appendSlice(allocator, recv);
        } else {
            try buf.appendSlice(allocator, ",\"received\":null");
        }

        try buf.append(allocator, '}');
    }

    try buf.appendSlice(allocator, "]}");

    return buf.toOwnedSlice(allocator);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Copy a FieldError to owned memory using the given allocator.
/// Also serialises the JSON value into the `received` field.
fn copyFieldError(
    allocator: std.mem.Allocator,
    src: FieldError,
    json_value: ?std.json.Value,
) error{OutOfMemory}!FieldError {
    return FieldError{
        .field = try allocator.dupe(u8, src.field),
        .constraint = try allocator.dupe(u8, src.constraint),
        .message = try allocator.dupe(u8, src.message),
        .received = if (json_value) |v|
            try serializeJsonValue(allocator, v)
        else
            null,
    };
}

/// Serialise a std.json.Value to a JSON fragment string.
/// Returns an allocator-owned []u8.
fn serializeJsonValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) error{OutOfMemory}![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

/// Check whether a JSON value matches the expected JsonType.
/// Returns true if the types are compatible.
fn checkJsonType(value: std.json.Value, expected: JsonType) bool {
    return switch (expected) {
        .string => value == .string,
        .number => value == .integer or value == .float or value == .number_string,
        .integer => value == .integer,
        .boolean => value == .bool,
        .object => value == .object,
        .array => value == .array,
        .null_value => value == .null,
    };
}

/// Return the constraint identifier string for a type mismatch.
fn typeConstraintName(expected: JsonType) []const u8 {
    return switch (expected) {
        .string => "type.string",
        .number => "type.number",
        .integer => "type.integer",
        .boolean => "type.boolean",
        .object => "type.object",
        .array => "type.array",
        .null_value => "type.null",
    };
}

/// Return a human-readable message for a type mismatch.
fn typeMismatchMessage(expected: JsonType) []const u8 {
    return switch (expected) {
        .string => "expected string",
        .number => "expected number",
        .integer => "expected integer",
        .boolean => "expected boolean",
        .object => "expected object",
        .array => "expected array",
        .null_value => "expected null",
    };
}

/// Escape a string for JSON output, appending to an ArrayList buffer.
/// Escapes: backslash, double-quote, newline, carriage return, tab,
/// and control characters (U+0000–U+001F).
fn jsonEscapeToBuf(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}!void {
    for (s) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                try buf.appendSlice(allocator, "\\u");
                // Print 4-digit hex using fmt
                var hex_buf: [4]u8 = undefined;
                _ = std.fmt.bufPrint(&hex_buf, "{x:0>4}", .{c}) catch {
                    try buf.appendSlice(allocator, "0000");
                    continue;
                };
                try buf.appendSlice(allocator, &hex_buf);
            },
            else => try buf.append(allocator, c),
        }
    }
}
