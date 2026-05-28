const std = @import("std");
const realm_seed = @import("realm_seed");

test "OIDC-29 realm seed validation succeeds on minimal valid seed" {
    const seed = "{\"realm\":\"bpm-default\",\"clients\":[],\"users\":[]}";
    const result = try realm_seed.validateRealmSeedArtifact(std.testing.allocator, seed);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.importable);
    try std.testing.expect(result.deterministic);
}

test "OIDC-29 drift detection catches digest mismatch" {
    const expected = realm_seed.computeSha256Hex("alpha");
    const drift = try realm_seed.detectRealmSeedDrift(std.testing.allocator, expected[0..], "beta");
    try std.testing.expect(drift);
}
