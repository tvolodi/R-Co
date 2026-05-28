const std = @import("std");
const realm_seed = @import("../oidc/realm_seed.zig");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const expected = try std.fs.cwd().readFileAlloc(allocator, "infrastructure/keycloak/realms/bpm-default.json", 8 * 1024 * 1024);
    defer allocator.free(expected);

    const runtime_path_owned = std.process.getEnvVarOwned(allocator, "BPM_RUNTIME_REALM_EXPORT_PATH") catch null;
    defer if (runtime_path_owned) |p| allocator.free(p);
    const runtime_path = if (runtime_path_owned) |p| p else "infrastructure/keycloak/realms/bpm-default.json";

    const runtime_seed = try std.fs.cwd().readFileAlloc(allocator, runtime_path, 8 * 1024 * 1024);
    defer allocator.free(runtime_seed);

    const expected_digest = realm_seed.computeSha256Hex(expected);
    const drift = try realm_seed.detectRealmSeedDrift(allocator, expected_digest[0..], runtime_seed);

    std.debug.print("REALM_SEED_DRIFT|drift_detected={s}|expected_digest={s}\n", .{ if (drift) "true" else "false", expected_digest });

    if (drift) return error.DriftDetected;
}
