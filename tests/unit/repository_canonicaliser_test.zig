//! Unit tests for repository canonicaliser (REPO-01, REPO-04)
//!
//! Tests deterministic JSON canonicalisation and SHA-256 hashing.

const std = @import("std");
const repository = @import("repository");
const canonicaliser = repository.canonicaliser;

test "canonicaliser: sorts object keys" {
    const allocator = std.testing.allocator;
    const input = "{\"z\": 1, \"a\": 2, \"m\": 3}";
    const result = try canonicaliser.canonicaliseJson(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"a\":2,\"m\":3,\"z\":1}", result);
}

test "canonicaliser: removes whitespace" {
    const allocator = std.testing.allocator;
    const input = "{ \"key\" : \"value\" , \"num\" : 42 }";
    const result = try canonicaliser.canonicaliseJson(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"key\":\"value\",\"num\":42}", result);
}

test "canonicaliser: preserves array order" {
    const allocator = std.testing.allocator;
    const input = "{\"arr\": [3, 1, 2]}";
    const result = try canonicaliser.canonicaliseJson(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"arr\":[3,1,2]}", result);
}

test "canonicaliser: null values preserved" {
    const allocator = std.testing.allocator;
    const input = "{\"value\": null}";
    const result = try canonicaliser.canonicaliseJson(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"value\":null}", result);
}

test "canonicaliser: nested objects sorted" {
    const allocator = std.testing.allocator;
    const input = "{\"outer\": {\"z\": 1, \"a\": 2}}";
    const result = try canonicaliser.canonicaliseJson(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"outer\":{\"a\":2,\"z\":1}}", result);
}

test "canonicaliser: rejects invalid JSON" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(canonicaliser.CanonicaliserError.InvalidJson,
        canonicaliser.canonicaliseJson(allocator, "{invalid}"));
}

test "canonicaliser: hash deterministic for same content" {
    const allocator = std.testing.allocator;
    const input1 = "{\"z\": 1, \"a\": 2}";
    const input2 = "{\"a\": 2, \"z\": 1}";

    const hash1 = try canonicaliser.hashContent(allocator, input1, "application/json");
    const hash2 = try canonicaliser.hashContent(allocator, input2, "application/json");

    try std.testing.expect(std.mem.eql(u8, &hash1, &hash2));
}

test "canonicaliser: hash differs for different content" {
    const allocator = std.testing.allocator;
    const input1 = "{\"a\": 1}";
    const input2 = "{\"a\": 2}";

    const hash1 = try canonicaliser.hashContent(allocator, input1, "application/json");
    const hash2 = try canonicaliser.hashContent(allocator, input2, "application/json");

    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "canonicaliser: verifyHash accepts correct hash" {
    const allocator = std.testing.allocator;
    const content = "{\"test\": true}";
    const hash = try canonicaliser.hashContent(allocator, content, "application/json");

    try std.testing.expect(try canonicaliser.verifyHash(allocator, content, "application/json", hash));
}

test "canonicaliser: verifyHash rejects wrong hash" {
    const allocator = std.testing.allocator;
    const content = "{\"test\": true}";
    var bad_hash: [32]u8 = undefined;
    @memset(&bad_hash, 0);

    try std.testing.expect(!(try canonicaliser.verifyHash(allocator, content, "application/json", bad_hash)));
}

test "canonicaliser: binary content hashed as-is" {
    const allocator = std.testing.allocator;
    const binary_content = "some binary data";

    const hash1 = try canonicaliser.hashContent(allocator, binary_content, "application/wasm");
    const hash2 = try canonicaliser.hashContent(allocator, binary_content, "application/wasm");

    try std.testing.expect(std.mem.eql(u8, &hash1, &hash2));
}

test "canonicaliser: escapes special characters in strings" {
    const allocator = std.testing.allocator;
    const input = "{\"key\": \"value with \\\"quotes\\\"\"}";
    const result = try canonicaliser.canonicaliseJson(allocator, input);
    defer allocator.free(result);

    // The result should escape the quotes properly
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "\\\""));
}
