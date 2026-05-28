//! Canonical JSON serialisation and SHA-256 content hashing (REPO-01, REPO-04)
//!
//! Pure function module for deterministic canonicalisation of JSON artifacts
//! and SHA-256 hashing. Binary artifacts (Wasm) are hashed by byte identity.
//!
//! Design artefact: src/design/repository.md (REPO-04, REPO-01)

const std = @import("std");
const crypto = std.crypto.hash.sha2;

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const CanonicaliserError = error{
    OutOfMemory,
    InvalidJson,    // Malformed JSON input
    InvalidBinary,  // Binary content has invalid header (e.g., bad Wasm magic)
};

// ---------------------------------------------------------------------------
// Public interface
// ---------------------------------------------------------------------------

/// Pure function: canonicalise JSON by sorting keys, removing whitespace,
/// normalising numbers. Output is deterministic and reversible per input.
///
/// Behavior:
///   - Keys are sorted alphabetically in each object.
///   - All insignificant whitespace is removed (single-line output).
///   - Numbers are normalised: integers without decimal point; no exponent
///     notation unless required for very large/small values.
///   - null values are preserved as-is.
///   - Arrays maintain their original order.
///
/// Returns a newly allocated byte slice containing the canonical form.
/// Caller must free with allocator.free(result).
pub fn canonicaliseJson(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
) CanonicaliserError![]const u8 {
    var parser = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_bytes,
        .{},
    ) catch return CanonicaliserError.InvalidJson;
    defer parser.deinit();

    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    try serializeValue(parser.value, &output, allocator);

    return output.toOwnedSlice();
}

/// Compute SHA-256 hash of content.
///
/// For JSON content: canonicalises first, then hashes.
/// For binary content (application/wasm, etc.): hashes byte identity directly.
///
/// Returns 32-byte SHA-256 digest.
pub fn hashContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    content_type: []const u8,
) CanonicaliserError![32]u8 {
    var digest: [32]u8 = undefined;

    if (std.mem.eql(u8, content_type, "application/json")) {
        const canonical = try canonicaliseJson(allocator, content);
        defer allocator.free(canonical);
        crypto.Sha256.hash(canonical, &digest, .{});
    } else {
        // Binary content: hash byte identity directly
        crypto.Sha256.hash(content, &digest, .{});
    }

    return digest;
}

/// Verify that a given content's hash matches expected_hash.
/// Used for integrity checks on artifact retrieval.
pub fn verifyHash(
    allocator: std.mem.Allocator,
    content: []const u8,
    content_type: []const u8,
    expected_hash: [32]u8,
) CanonicaliserError!bool {
    const computed = try hashContent(allocator, content, content_type);
    return std.mem.eql(u8, &computed, &expected_hash);
}

// ---------------------------------------------------------------------------
// Private serialization helpers
// ---------------------------------------------------------------------------

fn serializeValue(value: std.json.Value, output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (value) {
        .null => try output.appendSlice("null"),
        .bool => |b| try output.appendSlice(if (b) "true" else "false"),
        .integer => |i| try std.fmt.format(output.writer(), "{}", .{i}),
        .float => |f| try serializeFloat(f, output),
        .string => |s| try serializeString(s, output),
        .array => |arr| try serializeArray(arr, output, allocator),
        .object => |obj| try serializeObject(obj, output, allocator),
    }
}

fn serializeFloat(f: f64, output: *std.ArrayList(u8)) !void {
    // Normalize floats: no unnecessary decimals, compact representation
    if (f == std.math.floor(f) and f >= -9007199254740992 and f <= 9007199254740992) {
        // Integer-valued float
        try std.fmt.format(output.writer(), "{d:.0}", .{f});
    } else {
        // Use compact representation
        try std.fmt.format(output.writer(), "{}", .{f});
    }
}

fn serializeString(s: []const u8, output: *std.ArrayList(u8)) !void {
    try output.append('"');
    for (s) |byte| {
        switch (byte) {
            '"' => try output.appendSlice("\\\""),
            '\\' => try output.appendSlice("\\\\"),
            '\b' => try output.appendSlice("\\b"),
            '\t' => try output.appendSlice("\\t"),
            '\n' => try output.appendSlice("\\n"),
            '\r' => try output.appendSlice("\\r"),
            '\x0c' => try output.appendSlice("\\f"),
            0x00...0x1f => try std.fmt.format(output.writer(), "\\u{:0>4x}", .{byte}),
            else => try output.append(byte),
        }
    }
    try output.append('"');
}

fn serializeArray(arr: std.json.Array, output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try output.append('[');
    for (arr.items, 0..) |item, i| {
        if (i > 0) try output.append(',');
        try serializeValue(item, output, allocator);
    }
    try output.append(']');
}

fn serializeObject(obj: std.json.ObjectMap, output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try output.append('{');

    // Collect and sort keys
    var keys = std.ArrayList([]const u8).init(allocator);
    defer keys.deinit();

    var it = obj.iterator();
    while (it.next()) |entry| {
        try keys.append(entry.key_ptr.*);
    }

    std.sort.insertion([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (keys.items, 0..) |key, i| {
        if (i > 0) try output.append(',');

        try serializeString(key, output);
        try output.append(':');

        const value = obj.get(key) orelse unreachable;
        try serializeValue(value, output, allocator);
    }

    try output.append('}');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "canonicaliseJson: sorts keys" {
    const allocator = std.testing.allocator;
    const input = "{\"z\": 1, \"a\": 2, \"m\": 3}";
    const result = try canonicaliseJson(allocator, input);
    defer allocator.free(result);

    const expected = "{\"a\":2,\"m\":3,\"z\":1}";
    try std.testing.expectEqualStrings(expected, result);
}

test "canonicaliseJson: removes whitespace" {
    const allocator = std.testing.allocator;
    const input = "{ \"key\" : \"value\" , \"num\" : 42 }";
    const result = try canonicaliseJson(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"key\":\"value\",\"num\":42}", result);
}

test "canonicaliseJson: preserves array order" {
    const allocator = std.testing.allocator;
    const input = "{\"arr\": [3, 1, 2]}";
    const result = try canonicaliseJson(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"arr\":[3,1,2]}", result);
}

test "canonicaliseJson: normalizes numbers" {
    const allocator = std.testing.allocator;
    const input = "{\"int\": 42, \"float\": 3.14}";
    const result = try canonicaliseJson(allocator, input);
    defer allocator.free(result);

    // Should not have unnecessary decimals on the integer
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "42"));
}

test "canonicaliseJson: rejects invalid JSON" {
    const allocator = std.testing.allocator;
    const input = "{invalid json}";
    try std.testing.expectError(CanonicaliserError.InvalidJson, canonicaliseJson(allocator, input));
}

test "hashContent: deterministic for same JSON" {
    const allocator = std.testing.allocator;
    const input1 = "{\"z\": 1, \"a\": 2}";
    const input2 = "{\"a\": 2, \"z\": 1}";

    const hash1 = try hashContent(allocator, input1, "application/json");
    const hash2 = try hashContent(allocator, input2, "application/json");

    try std.testing.expectEqualSlices(u8, &hash1, &hash2);
}

test "verifyHash: valid hash passes" {
    const allocator = std.testing.allocator;
    const content = "{\"test\": true}";
    const hash = try hashContent(allocator, content, "application/json");

    try std.testing.expect(try verifyHash(allocator, content, "application/json", hash));
}

test "verifyHash: invalid hash fails" {
    const allocator = std.testing.allocator;
    const content = "{\"test\": true}";
    var bad_hash: [32]u8 = undefined;
    @memset(&bad_hash, 0);

    try std.testing.expect(!(try verifyHash(allocator, content, "application/json", bad_hash)));
}
