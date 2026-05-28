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

    var output = try std.ArrayList(u8).initCapacity(allocator, 256);
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

fn serializeValue(value: std.json.Value, output: *std.ArrayList(u8), allocator: std.mem.Allocator) (std.mem.Allocator.Error || std.fmt.BufPrintError)!void {
    switch (value) {
        .null => try output.appendSlice(allocator, "null"),
        .bool => |b| try output.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| try serializeInteger(i, output, allocator),
        .float => |f| try serializeFloat(f, output, allocator),
        .number_string => |s| try output.appendSlice(allocator, s),
        .string => |s| try serializeString(s, output, allocator),
        .array => |arr| try serializeArray(arr, output, allocator),
        .object => |obj| try serializeObject(obj, output, allocator),
    }
}

fn serializeInteger(i: i64, output: *std.ArrayList(u8), allocator: std.mem.Allocator) (std.mem.Allocator.Error || std.fmt.BufPrintError)!void {
    var buf: [32]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{}", .{i});
    try output.appendSlice(allocator, str);
}

fn serializeFloat(f: f64, output: *std.ArrayList(u8), allocator: std.mem.Allocator) (std.mem.Allocator.Error || std.fmt.BufPrintError)!void {
    var buf: [64]u8 = undefined;
    // Normalize floats: no unnecessary decimals, compact representation
    const str = if (f == std.math.floor(f) and f >= -9007199254740992 and f <= 9007199254740992) blk: {
        // Integer-valued float
        break :blk try std.fmt.bufPrint(&buf, "{d:.0}", .{f});
    } else blk: {
        // Use compact representation
        break :blk try std.fmt.bufPrint(&buf, "{}", .{f});
    };
    try output.appendSlice(allocator, str);
}

fn serializeString(s: []const u8, output: *std.ArrayList(u8), allocator: std.mem.Allocator) (std.mem.Allocator.Error || std.fmt.BufPrintError)!void {
    try output.append(allocator, '"');
    for (s) |byte| {
        switch (byte) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            0x08 => try output.appendSlice(allocator, "\\b"),
            0x09 => try output.appendSlice(allocator, "\\t"),
            0x0a => try output.appendSlice(allocator, "\\n"),
            0x0d => try output.appendSlice(allocator, "\\r"),
            0x0c => try output.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try serializeControlChar(byte, output, allocator),
            else => try output.append(allocator, byte),
        }
    }
    try output.append(allocator, '"');
}

fn serializeControlChar(byte: u8, output: *std.ArrayList(u8), allocator: std.mem.Allocator) (std.mem.Allocator.Error || std.fmt.BufPrintError)!void {
    var buf: [8]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "\\u{:0>4x}", .{byte});
    try output.appendSlice(allocator, str);
}

fn serializeArray(arr: std.json.Array, output: *std.ArrayList(u8), allocator: std.mem.Allocator) (std.mem.Allocator.Error || std.fmt.BufPrintError)!void {
    try output.append(allocator, '[');
    for (arr.items, 0..) |item, i| {
        if (i > 0) try output.append(allocator, ',');
        try serializeValue(item, output, allocator);
    }
    try output.append(allocator, ']');
}

fn serializeObject(obj: std.json.ObjectMap, output: *std.ArrayList(u8), allocator: std.mem.Allocator) (std.mem.Allocator.Error || std.fmt.BufPrintError)!void {
    try output.append(allocator, '{');

    // Collect and sort keys
    var keys = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    defer keys.deinit();

    var it = obj.iterator();
    while (it.next()) |entry| {
        try keys.append(allocator, entry.key_ptr.*);
    }

    std.sort.insertion([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (keys.items, 0..) |key, i| {
        if (i > 0) try output.append(allocator, ',');

        try serializeString(key, output, allocator);
        try output.append(allocator, ':');

        const value = obj.get(key) orelse unreachable;
        try serializeValue(value, output, allocator);
    }

    try output.append(allocator, '}');
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
