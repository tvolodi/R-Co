//! Minimal JSON Schema validator — EE-09 (OQ-EE09-1) and ES-05 (ISS-0155)
//!
//! Validates a `std.json.Value` against a JSON Schema object.
//! Covers the constraint keywords required for EE-09:
//!   - `type`      (string or array of strings)
//!   - `minimum`   (number, inclusive)
//!   - `maximum`   (number, inclusive)
//!   - `maxLength` (integer)
//!   - `enum`      (array of allowed values)
//!
//! ISS-0155 / GH #473 adds the object- and string-structure keywords ES-05's
//! registered event-type schemas actually use, plus a collecting entry point
//! (`validateCollect`) that reports EVERY violation with an RFC 6901 pointer
//! rather than only the first message:
//!   - `required`             (array of property names that must be present)
//!   - `properties`           (per-property subschema, recursively validated)
//!   - `items`                (uniform array element subschema, recursive)
//!   - `minLength`            (integer, string code-point count)
//!   - `additionalProperties` (only the `false` form — unknown keys rejected)
//!
//! Full JSON Schema draft-07 compliance is still NOT required. `$ref`,
//! `allOf`/`anyOf`/`oneOf`/`not`, `patternProperties`, `pattern`, `format`,
//! `dependencies`, and tuple-form `items` are deliberately NOT implemented;
//! unknown keywords remain silently ignored, so a schema using them is
//! accepted rather than spuriously rejected.
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
// Collecting validator — ES-05 (ISS-0155 / GH #473)
//
// `validate` above returns only the FIRST violation as a static message, which
// is enough for EE-09's variable check but not for ES-05, whose acceptance
// criterion requires "an RFC 9457 body listing EVERY validation failure (field
// path, constraint violated, actual value)". `validateCollect` walks the whole
// document and appends one Violation per failing constraint.
// ---------------------------------------------------------------------------

/// One constraint violation located by an RFC 6901 JSON Pointer.
pub const Violation = struct {
    /// RFC 6901 pointer to the failing location. "" denotes the document root;
    /// callers that need a non-empty root render it as "/".
    /// Allocator-owned (see `deinitViolations`).
    path: []const u8,
    /// The schema keyword that failed: "type", "required", "maxLength", ...
    /// A static string literal — never freed.
    constraint: []const u8,
    /// The serialised actual value at `path`, or "null" when the location is
    /// absent. Allocator-owned (see `deinitViolations`).
    actual: []const u8,
};

/// Free a slice of Violations produced by `validateCollect`.
pub fn deinitViolations(allocator: std.mem.Allocator, violations: []Violation) void {
    for (violations) |v| {
        allocator.free(v.path);
        allocator.free(v.actual);
    }
    allocator.free(violations);
}

/// Validate `value` against `schema`, collecting every violation found.
///
/// Returns an allocator-owned slice (empty when the value conforms); free it
/// with `deinitViolations`. A non-object `schema` imposes no constraints and
/// yields an empty slice, matching `validate`'s behaviour.
pub fn validateCollect(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    schema: std.json.Value,
) error{OutOfMemory}![]Violation {
    var list: std.ArrayList(Violation) = .empty;
    errdefer {
        for (list.items) |v| {
            allocator.free(v.path);
            allocator.free(v.actual);
        }
        list.deinit(allocator);
    }
    try collectInto(allocator, &list, "", value, schema);
    return list.toOwnedSlice(allocator);
}

/// Recursive worker for `validateCollect`. `path` is the RFC 6901 pointer of
/// `value` within the root document.
fn collectInto(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Violation),
    path: []const u8,
    value: std.json.Value,
    schema: std.json.Value,
) error{OutOfMemory}!void {
    if (schema != .object) return;
    const s = schema.object;

    // ── `type` ───────────────────────────────────────────────────────────────
    // A type mismatch invalidates every other keyword at this level (e.g.
    // `required` on a non-object is meaningless), so report it and stop
    // descending rather than emitting a cascade of derived noise.
    if (s.get("type")) |type_val| {
        if (!checkType(value, type_val)) {
            try appendViolation(allocator, list, path, "type", value);
            return;
        }
    }

    // ── `enum` ───────────────────────────────────────────────────────────────
    if (s.get("enum")) |enum_val| {
        if (enum_val == .array) {
            var found = false;
            for (enum_val.array.items) |allowed| {
                if (jsonValuesEqual(value, allowed)) {
                    found = true;
                    break;
                }
            }
            if (!found) try appendViolation(allocator, list, path, "enum", value);
        }
    }

    // ── `minimum` / `maximum` (numbers only) ─────────────────────────────────
    if (jsonToFloat(value)) |v| {
        if (s.get("minimum")) |min_val| {
            if (jsonToFloat(min_val)) |m| {
                if (v < m) try appendViolation(allocator, list, path, "minimum", value);
            }
        }
        if (s.get("maximum")) |max_val| {
            if (jsonToFloat(max_val)) |m| {
                if (v > m) try appendViolation(allocator, list, path, "maximum", value);
            }
        }
    }

    // ── `minLength` / `maxLength` (strings only, code-point counted) ─────────
    if (value == .string) {
        const char_count = std.unicode.utf8CountCodepoints(value.string) catch value.string.len;
        if (s.get("maxLength")) |ml| {
            if (ml == .integer and ml.integer >= 0 and char_count > @as(usize, @intCast(ml.integer))) {
                try appendViolation(allocator, list, path, "maxLength", value);
            }
        }
        if (s.get("minLength")) |ml| {
            if (ml == .integer and ml.integer >= 0 and char_count < @as(usize, @intCast(ml.integer))) {
                try appendViolation(allocator, list, path, "minLength", value);
            }
        }
    }

    // ── object keywords: `required`, `properties`, `additionalProperties` ────
    if (value == .object) {
        const obj = value.object;

        if (s.get("required")) |req| {
            if (req == .array) {
                for (req.array.items) |name_val| {
                    if (name_val != .string) continue;
                    if (obj.get(name_val.string) == null) {
                        // The missing member's own pointer, with "null" as the
                        // actual value — that is where the caller must look.
                        const child_path = try joinPointer(allocator, path, name_val.string);
                        errdefer allocator.free(child_path);
                        const actual = try allocator.dupe(u8, "null");
                        try list.append(allocator, .{
                            .path = child_path,
                            .constraint = "required",
                            .actual = actual,
                        });
                    }
                }
            }
        }

        if (s.get("properties")) |props| {
            if (props == .object) {
                var it = props.object.iterator();
                while (it.next()) |entry| {
                    const child = obj.get(entry.key_ptr.*) orelse continue;
                    const child_path = try joinPointer(allocator, path, entry.key_ptr.*);
                    defer allocator.free(child_path);
                    try collectInto(allocator, list, child_path, child, entry.value_ptr.*);
                }
            }
        }

        // Only the `additionalProperties: false` form is supported; the
        // subschema form is ignored (documented non-goal).
        if (s.get("additionalProperties")) |ap| {
            if (ap == .bool and ap.bool == false) {
                const props = s.get("properties");
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const declared = if (props) |p|
                        (p == .object and p.object.get(entry.key_ptr.*) != null)
                    else
                        false;
                    if (!declared) {
                        const child_path = try joinPointer(allocator, path, entry.key_ptr.*);
                        defer allocator.free(child_path);
                        try appendViolation(
                            allocator,
                            list,
                            child_path,
                            "additionalProperties",
                            entry.value_ptr.*,
                        );
                    }
                }
            }
        }
    }

    // ── array keyword: `items` (uniform subschema form only) ─────────────────
    if (value == .array) {
        if (s.get("items")) |items_schema| {
            if (items_schema == .object) {
                for (value.array.items, 0..) |elem, i| {
                    var idx_buf: [24]u8 = undefined;
                    const idx = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
                    const child_path = try joinPointer(allocator, path, idx);
                    defer allocator.free(child_path);
                    try collectInto(allocator, list, child_path, elem, items_schema);
                }
            }
        }
    }
}

/// Append one Violation, serialising `value` as the reported actual value.
fn appendViolation(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Violation),
    path: []const u8,
    constraint: []const u8,
    value: std.json.Value,
) error{OutOfMemory}!void {
    const path_dup = try allocator.dupe(u8, path);
    errdefer allocator.free(path_dup);
    const actual = try serialiseValue(allocator, value);
    errdefer allocator.free(actual);
    try list.append(allocator, .{
        .path = path_dup,
        .constraint = constraint,
        .actual = actual,
    });
}

/// Serialise a JSON value to its compact text form, allocator-owned.
fn serialiseValue(allocator: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

/// Append `token` to RFC 6901 pointer `base`, escaping `~` as `~0` and `/` as
/// `~1` per RFC 6901 §3. Result is allocator-owned.
fn joinPointer(
    allocator: std.mem.Allocator,
    base: []const u8,
    token: []const u8,
) error{OutOfMemory}![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, base);
    try buf.append(allocator, '/');
    for (token) |c| {
        switch (c) {
            '~' => try buf.appendSlice(allocator, "~0"),
            '/' => try buf.appendSlice(allocator, "~1"),
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
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

// ---------------------------------------------------------------------------
// validateCollect — ES-05 (ISS-0155 / GH #473)
// ---------------------------------------------------------------------------

const talloc = std.testing.allocator;

/// Parse schema + document, run validateCollect, hand the result to `check`.
fn collectFor(
    schema_text: []const u8,
    doc_text: []const u8,
) !struct { parsed_schema: std.json.Parsed(std.json.Value), parsed_doc: std.json.Parsed(std.json.Value), violations: []Violation } {
    const ps = try std.json.parseFromSlice(std.json.Value, talloc, schema_text, .{});
    errdefer ps.deinit();
    const pd = try std.json.parseFromSlice(std.json.Value, talloc, doc_text, .{});
    errdefer pd.deinit();
    const v = try validateCollect(talloc, pd.value, ps.value);
    return .{ .parsed_schema = ps, .parsed_doc = pd, .violations = v };
}

test "validateCollect: conforming document yields zero violations" {
    const r = try collectFor(
        \\{"type":"object","required":["a","b"],"properties":{"a":{"type":"string","maxLength":5},"b":{"type":"integer","minimum":1}}}
    ,
        \\{"a":"hi","b":7}
    );
    defer r.parsed_schema.deinit();
    defer r.parsed_doc.deinit();
    defer deinitViolations(talloc, r.violations);
    try std.testing.expectEqual(@as(usize, 0), r.violations.len);
}

test "validateCollect: missing required members are reported per member with RFC 6901 pointers" {
    const r = try collectFor(
        \\{"type":"object","required":["a","b","c"],"properties":{"a":{"type":"string"}}}
    ,
        \\{"a":"present"}
    );
    defer r.parsed_schema.deinit();
    defer r.parsed_doc.deinit();
    defer deinitViolations(talloc, r.violations);

    // ES-05 requires EVERY failure listed — both missing members, not just one.
    try std.testing.expectEqual(@as(usize, 2), r.violations.len);
    for (r.violations) |v| {
        try std.testing.expectEqualStrings("required", v.constraint);
        try std.testing.expectEqualStrings("null", v.actual);
    }
    try std.testing.expectEqualStrings("/b", r.violations[0].path);
    try std.testing.expectEqualStrings("/c", r.violations[1].path);
}

test "validateCollect: nested property type violation carries the nested pointer and actual value" {
    const r = try collectFor(
        \\{"type":"object","properties":{"outer":{"type":"object","properties":{"inner":{"type":"integer"}}}}}
    ,
        \\{"outer":{"inner":"not-a-number"}}
    );
    defer r.parsed_schema.deinit();
    defer r.parsed_doc.deinit();
    defer deinitViolations(talloc, r.violations);

    try std.testing.expectEqual(@as(usize, 1), r.violations.len);
    try std.testing.expectEqualStrings("/outer/inner", r.violations[0].path);
    try std.testing.expectEqualStrings("type", r.violations[0].constraint);
    try std.testing.expectEqualStrings("\"not-a-number\"", r.violations[0].actual);
}

test "validateCollect: array items are validated element-wise with indexed pointers" {
    const r = try collectFor(
        \\{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}}}
    ,
        \\{"tags":["ok",42,"fine",false]}
    );
    defer r.parsed_schema.deinit();
    defer r.parsed_doc.deinit();
    defer deinitViolations(talloc, r.violations);

    try std.testing.expectEqual(@as(usize, 2), r.violations.len);
    try std.testing.expectEqualStrings("/tags/1", r.violations[0].path);
    try std.testing.expectEqualStrings("42", r.violations[0].actual);
    try std.testing.expectEqualStrings("/tags/3", r.violations[1].path);
    try std.testing.expectEqualStrings("false", r.violations[1].actual);
}

test "validateCollect: minLength and maxLength both enforced" {
    const r = try collectFor(
        \\{"type":"object","properties":{"s":{"type":"string","minLength":3,"maxLength":5}}}
    ,
        \\{"s":"ab"}
    );
    defer r.parsed_schema.deinit();
    defer r.parsed_doc.deinit();
    defer deinitViolations(talloc, r.violations);
    try std.testing.expectEqual(@as(usize, 1), r.violations.len);
    try std.testing.expectEqualStrings("minLength", r.violations[0].constraint);

    const r2 = try collectFor(
        \\{"type":"object","properties":{"s":{"type":"string","minLength":3,"maxLength":5}}}
    ,
        \\{"s":"abcdefgh"}
    );
    defer r2.parsed_schema.deinit();
    defer r2.parsed_doc.deinit();
    defer deinitViolations(talloc, r2.violations);
    try std.testing.expectEqual(@as(usize, 1), r2.violations.len);
    try std.testing.expectEqualStrings("maxLength", r2.violations[0].constraint);
}

test "validateCollect: additionalProperties false rejects undeclared members" {
    const r = try collectFor(
        \\{"type":"object","properties":{"a":{"type":"string"}},"additionalProperties":false}
    ,
        \\{"a":"ok","surprise":1}
    );
    defer r.parsed_schema.deinit();
    defer r.parsed_doc.deinit();
    defer deinitViolations(talloc, r.violations);
    try std.testing.expectEqual(@as(usize, 1), r.violations.len);
    try std.testing.expectEqualStrings("/surprise", r.violations[0].path);
    try std.testing.expectEqualStrings("additionalProperties", r.violations[0].constraint);
}

test "validateCollect: RFC 6901 escaping of ~ and / in member names" {
    const r = try collectFor(
        \\{"type":"object","required":["a/b","c~d"]}
    ,
        \\{}
    );
    defer r.parsed_schema.deinit();
    defer r.parsed_doc.deinit();
    defer deinitViolations(talloc, r.violations);
    try std.testing.expectEqual(@as(usize, 2), r.violations.len);
    try std.testing.expectEqualStrings("/a~1b", r.violations[0].path);
    try std.testing.expectEqualStrings("/c~0d", r.violations[1].path);
}

test "validateCollect: empty schema accepts anything (no constraints to violate)" {
    const r = try collectFor("{}",
        \\{"anything":[1,2,{"deep":true}]}
    );
    defer r.parsed_schema.deinit();
    defer r.parsed_doc.deinit();
    defer deinitViolations(talloc, r.violations);
    try std.testing.expectEqual(@as(usize, 0), r.violations.len);
}

test "validateCollect: root type mismatch reported at the root pointer and stops descent" {
    const r = try collectFor(
        \\{"type":"object","required":["a"]}
    ,
        \\[1,2,3]
    );
    defer r.parsed_schema.deinit();
    defer r.parsed_doc.deinit();
    defer deinitViolations(talloc, r.violations);
    // Exactly one violation: the type failure. `required` is NOT also reported,
    // because it is meaningless against a non-object.
    try std.testing.expectEqual(@as(usize, 1), r.violations.len);
    try std.testing.expectEqualStrings("", r.violations[0].path);
    try std.testing.expectEqualStrings("type", r.violations[0].constraint);
}

test "validateCollect: unsupported keywords are ignored, not treated as failures" {
    // $ref / allOf / pattern / format are documented non-goals. A schema using
    // them must still accept a document rather than spuriously rejecting it.
    const r = try collectFor(
        \\{"type":"object","properties":{"id":{"type":"string","format":"uuid","pattern":"^x"}},"allOf":[{"required":["nope"]}]}
    ,
        \\{"id":"not-a-uuid-and-not-matching"}
    );
    defer r.parsed_schema.deinit();
    defer r.parsed_doc.deinit();
    defer deinitViolations(talloc, r.violations);
    try std.testing.expectEqual(@as(usize, 0), r.violations.len);
}

test "validateCollect: the real ENTITY_RECORD_CREATED schema accepts and rejects correctly" {
    // Verbatim from migrations/094_entity_subsystem.sql — the schema production
    // actually registers for this event type.
    const schema =
        \\{"type":"object","required":["entity_type","entity_def_version","record_id","field_values"],"properties":{"entity_type":{"type":"string","minLength":1,"maxLength":128},"entity_def_version":{"type":"integer","minimum":1},"record_id":{"type":"string","format":"uuid"},"field_values":{"type":"object"}}}
    ;

    const ok = try collectFor(schema,
        \\{"entity_type":"customer","entity_def_version":1,"record_id":"550e8400-e29b-41d4-a716-446655440000","field_values":{"email":"a@b.c"}}
    );
    defer ok.parsed_schema.deinit();
    defer ok.parsed_doc.deinit();
    defer deinitViolations(talloc, ok.violations);
    try std.testing.expectEqual(@as(usize, 0), ok.violations.len);

    // Missing record_id + field_values, and entity_def_version below minimum.
    const bad = try collectFor(schema,
        \\{"entity_type":"customer","entity_def_version":0}
    );
    defer bad.parsed_schema.deinit();
    defer bad.parsed_doc.deinit();
    defer deinitViolations(talloc, bad.violations);
    try std.testing.expectEqual(@as(usize, 3), bad.violations.len);
    try std.testing.expectEqualStrings("/record_id", bad.violations[0].path);
    try std.testing.expectEqualStrings("required", bad.violations[0].constraint);
    try std.testing.expectEqualStrings("/field_values", bad.violations[1].path);
    try std.testing.expectEqualStrings("required", bad.violations[1].constraint);
    try std.testing.expectEqualStrings("/entity_def_version", bad.violations[2].path);
    try std.testing.expectEqualStrings("minimum", bad.violations[2].constraint);
    try std.testing.expectEqualStrings("0", bad.violations[2].actual);
}
