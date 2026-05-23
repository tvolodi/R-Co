//! Minimal JSON Schema validator — EE-09 (OQ-EE09-1)
//!
//! Validates a `std.json.Value` against a JSON Schema object.
//! Covers the constraint keywords required for EE-09:
//!   - `type`      (string or array of strings)
//!   - `minimum`   (number, inclusive)
//!   - `maximum`   (number, inclusive)
//!   - `maxLength` (integer)
//!   - `enum`      (array of allowed values)
//!
//! Full JSON Schema draft-07 compliance is NOT required (OQ-EE09-1).
//! Unknown keywords are silently ignored.
//!
//! Security: no I/O; pure in-memory validation only.
const std = @import("std");

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Result of validating a value against a schema.
pub const ValidationResult = struct {
    /// true → value satisfies the schema.
    valid: bool,
    /// Human-readable description of the first constraint violation.
    /// Empty string when valid == true.
    message: []const u8,
};

/// Validate `value` against `schema` (a JSON object).
///
/// Returns a `ValidationResult`. The `message` field points into static
/// string literals (no allocation needed).
///
/// If `schema` is not a JSON object, the value is considered valid
/// (no schema to enforce).
pub fn validate(value: std.json.Value, schema: std.json.Value) ValidationResult {
    // Schema must be an object; anything else is treated as an empty schema
    // (no constraints — all values are valid).
    if (schema != .object) return .{ .valid = true, .message = "" };
    const s = schema.object;

    // ── `type` constraint ────────────────────────────────────────────────────
    if (s.get("type")) |type_val| {
        const type_ok = checkType(value, type_val);
        if (!type_ok) return .{ .valid = false, .message = typeMessage(value, type_val) };
    }

    // ── `enum` constraint ────────────────────────────────────────────────────
    if (s.get("enum")) |enum_val| {
        if (enum_val == .array) {
            var found = false;
            for (enum_val.array.items) |allowed| {
                if (jsonValuesEqual(value, allowed)) {
                    found = true;
                    break;
                }
            }
            if (!found) return .{ .valid = false, .message = "value is not in the allowed enum set" };
        }
    }

    // ── `minimum` constraint (numbers only) ──────────────────────────────────
    if (s.get("minimum")) |min_val| {
        const schema_min = jsonToFloat(min_val) orelse std.math.floatMin(f64);
        const val_num = jsonToFloat(value);
        if (val_num) |v| {
            if (v < schema_min) return .{ .valid = false, .message = "value is below minimum" };
        }
        // Non-numeric values: `minimum` only applies to numbers; ignore for other types.
    }

    // ── `maximum` constraint (numbers only) ──────────────────────────────────
    if (s.get("maximum")) |max_val| {
        const schema_max = jsonToFloat(max_val) orelse std.math.floatMax(f64);
        const val_num = jsonToFloat(value);
        if (val_num) |v| {
            if (v > schema_max) return .{ .valid = false, .message = "value exceeds maximum" };
        }
    }

    // ── `maxLength` constraint (strings only) ─────────────────────────────────
    if (s.get("maxLength")) |ml_val| {
        if (ml_val == .integer and value == .string) {
            const max_len: usize = if (ml_val.integer >= 0)
                @intCast(ml_val.integer)
            else
                0;
            // Count Unicode code-points (UTF-8 scalar values).
            const char_count = std.unicode.utf8CountCodepoints(value.string) catch value.string.len;
            if (char_count > max_len) return .{ .valid = false, .message = "string exceeds maxLength" };
        }
    }

    return .{ .valid = true, .message = "" };
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Check whether `value` satisfies the `type` keyword.
/// `type_val` may be a string ("integer", "number", "string", "boolean",
/// "object", "array", "null") or an array of strings (union type).
fn checkType(value: std.json.Value, type_val: std.json.Value) bool {
    switch (type_val) {
        .string => return matchesTypeName(value, type_val.string),
        .array => {
            for (type_val.array.items) |t| {
                if (t == .string and matchesTypeName(value, t.string)) return true;
            }
            return false;
        },
        else => return true, // malformed type keyword → ignore
    }
}

/// Check whether `value` matches a JSON Schema type name string.
fn matchesTypeName(value: std.json.Value, type_name: []const u8) bool {
    if (std.mem.eql(u8, type_name, "string")) return value == .string;
    if (std.mem.eql(u8, type_name, "boolean")) return value == .bool;
    if (std.mem.eql(u8, type_name, "null")) return value == .null;
    if (std.mem.eql(u8, type_name, "object")) return value == .object;
    if (std.mem.eql(u8, type_name, "array")) return value == .array;
    if (std.mem.eql(u8, type_name, "integer")) {
        return switch (value) {
            .integer => true,
            .float => |f| @mod(f, 1.0) == 0.0,
            else => false,
        };
    }
    if (std.mem.eql(u8, type_name, "number")) {
        return value == .integer or value == .float;
    }
    return true; // unknown type name → ignore
}

/// Return a human-readable message for a `type` violation.
/// Falls back to a generic message when type_val is not a plain string.
fn typeMessage(value: std.json.Value, type_val: std.json.Value) []const u8 {
    _ = value;
    return switch (type_val) {
        .string => "value does not match required type",
        else => "value does not match required type",
    };
}

/// Extract a float64 from a JSON number value.  Returns null for non-numbers.
fn jsonToFloat(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

/// Deep equality check for two JSON values.
/// Used for `enum` validation.
fn jsonValuesEqual(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .string => std.mem.eql(u8, a.string, b.string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |ai, bi| {
                if (!jsonValuesEqual(ai, bi)) break :blk false;
            }
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const bv = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValuesEqual(entry.value_ptr.*, bv)) break :blk false;
            }
            break :blk true;
        },
    };
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "type: string" {
    const schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"string\"}", .{});
    defer schema.deinit();
    const val_ok = std.json.Value{ .string = "hello" };
    const val_bad = std.json.Value{ .integer = 42 };
    try std.testing.expect(validate(val_ok, schema.value).valid);
    try std.testing.expect(!validate(val_bad, schema.value).valid);
}

test "type: integer" {
    const schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"integer\"}", .{});
    defer schema.deinit();
    const val_ok = std.json.Value{ .integer = 5 };
    const val_bad = std.json.Value{ .string = "five" };
    try std.testing.expect(validate(val_ok, schema.value).valid);
    try std.testing.expect(!validate(val_bad, schema.value).valid);
}

test "minimum" {
    const schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"number\",\"minimum\":10}", .{});
    defer schema.deinit();
    const val_ok = std.json.Value{ .integer = 10 };
    const val_bad = std.json.Value{ .integer = 9 };
    try std.testing.expect(validate(val_ok, schema.value).valid);
    try std.testing.expect(!validate(val_bad, schema.value).valid);
}

test "maximum" {
    const schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"number\",\"maximum\":100}", .{});
    defer schema.deinit();
    const val_ok = std.json.Value{ .integer = 100 };
    const val_bad = std.json.Value{ .integer = 101 };
    try std.testing.expect(validate(val_ok, schema.value).valid);
    try std.testing.expect(!validate(val_bad, schema.value).valid);
}

test "maxLength" {
    const schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"string\",\"maxLength\":5}", .{});
    defer schema.deinit();
    const val_ok = std.json.Value{ .string = "hello" };
    const val_bad = std.json.Value{ .string = "toolong" };
    try std.testing.expect(validate(val_ok, schema.value).valid);
    try std.testing.expect(!validate(val_bad, schema.value).valid);
}

test "enum" {
    const schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"enum\":[\"a\",\"b\",\"c\"]}", .{});
    defer schema.deinit();
    const val_ok = std.json.Value{ .string = "b" };
    const val_bad = std.json.Value{ .string = "d" };
    try std.testing.expect(validate(val_ok, schema.value).valid);
    try std.testing.expect(!validate(val_bad, schema.value).valid);
}

test "empty schema allows any value" {
    const schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer schema.deinit();
    try std.testing.expect(validate(std.json.Value{ .string = "anything" }, schema.value).valid);
    try std.testing.expect(validate(std.json.Value{ .integer = -1 }, schema.value).valid);
}
