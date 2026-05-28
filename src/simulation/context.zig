const std = @import("std");
const types = @import("types.zig");

pub fn beginSimulationRun(
    allocator: std.mem.Allocator,
    seed: types.SimulationSeed,
    scenario_id: []const u8,
) types.SimulationError!types.SimulationContext {
    _ = allocator;

    if (!isValidScenarioId(scenario_id)) return error.InvalidScenarioId;
    if (seed.uuid_seed == 0) return error.DeterministicUuidSeedInvalid;

    const run_id = deriveRunId(seed, scenario_id);
    const sim_tenant_id = deriveSimulationTenantId(run_id);

    return .{
        .run_id = run_id,
        .simulation_tenant_id = sim_tenant_id,
        .seed = seed,
        .now_ms = seed.time_epoch_ms,
    };
}

pub fn deriveRunId(seed: types.SimulationSeed, scenario_id: []const u8) types.SimulationRunId {
    var bytes: [16]u8 = undefined;
    const h1 = std.hash.Wyhash.hash(seed.uuid_seed, scenario_id);
    const h2 = std.hash.Wyhash.hash(@bitCast(@as(u64, @intCast(seed.time_epoch_ms))), scenario_id);
    std.mem.writeInt(u64, bytes[0..8], h1, .big);
    std.mem.writeInt(u64, bytes[8..16], h2, .big);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return bytes;
}

pub fn deriveSimulationTenantId(run_id: types.SimulationRunId) types.TenantId {
    var tenant = run_id;
    // Reserve a deterministic simulation marker prefix to guard visibility.
    tenant[0] = 'S';
    tenant[1] = 'I';
    tenant[2] = 'M';
    tenant[3] = 0x01;
    tenant[6] = (tenant[6] & 0x0f) | 0x40;
    tenant[8] = (tenant[8] & 0x3f) | 0x80;
    return tenant;
}

pub fn isSimulationTenant(tenant_id: types.TenantId) bool {
    return tenant_id[0] == 'S' and tenant_id[1] == 'I' and tenant_id[2] == 'M' and tenant_id[3] == 0x01;
}

fn isValidScenarioId(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    if (!std.ascii.isAlphanumeric(s[0])) return false;

    for (s) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (c == '.' or c == '_' or c == ':' or c == '-') continue;
        return false;
    }
    return true;
}

test "beginSimulationRun: validates scenario id" {
    const seed = types.SimulationSeed{ .uuid_seed = 1, .time_epoch_ms = 123 };
    try std.testing.expectError(error.InvalidScenarioId, beginSimulationRun(std.testing.allocator, seed, ""));
    _ = try beginSimulationRun(std.testing.allocator, seed, "Scenario-1");
}
