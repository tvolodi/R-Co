const std = @import("std");
const testing = std.testing;

fn readFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        std.Io.Limit.limited(max_bytes),
    );
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

fn seedHasServiceAccountClient(seed_root: std.json.ObjectMap, client_id: []const u8) bool {
    const clients = seed_root.get("clients") orelse return false;
    if (clients != .array) return false;

    for (clients.array.items) |client| {
        if (client != .object) continue;
        const cid_val = client.object.get("clientId") orelse continue;
        const service_val = client.object.get("serviceAccountsEnabled") orelse continue;
        const cid = jsonString(cid_val) orelse continue;
        if (std.mem.eql(u8, cid, client_id) and service_val == .bool and service_val.bool) {
            return true;
        }
    }

    return false;
}

test "TC-OIDC-32-01: seed includes required agent clients with service accounts enabled" {
    const alloc = testing.allocator;
    const seed = try readFile(alloc, "infrastructure/keycloak/realms/bpm-default.json", 4 * 1024 * 1024);
    defer alloc.free(seed);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, seed, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);
    const root = parsed.value.object;

    try testing.expect(seedHasServiceAccountClient(root, "agent-architect"));
    try testing.expect(seedHasServiceAccountClient(root, "agent-developer"));
    try testing.expect(seedHasServiceAccountClient(root, "agent-devops"));
}

test "TC-OIDC-32-02: policy requires AGENT_RUNNER for each agent identity" {
    const alloc = testing.allocator;
    const policy = try readFile(alloc, "infrastructure/keycloak/policies/agent-test-identities.json", 1024 * 1024);
    defer alloc.free(policy);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, policy, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);
    const root = parsed.value.object;

    const identities = root.get("identities") orelse return error.TestUnexpectedResult;
    try testing.expect(identities == .array);

    var found_architect = false;
    var found_developer = false;
    var found_devops = false;

    for (identities.array.items) |identity| {
        if (identity != .object) continue;

        const key_val = identity.object.get("key") orelse continue;
        const roles_val = identity.object.get("requiredRoles") orelse continue;
        if (roles_val != .array) continue;

        const key = jsonString(key_val) orelse continue;
        var has_agent_runner = false;
        for (roles_val.array.items) |role| {
            const role_name = jsonString(role) orelse continue;
            if (std.mem.eql(u8, role_name, "AGENT_RUNNER")) {
                has_agent_runner = true;
                break;
            }
        }

        if (std.mem.eql(u8, key, "agent-architect") and has_agent_runner) found_architect = true;
        if (std.mem.eql(u8, key, "agent-developer") and has_agent_runner) found_developer = true;
        if (std.mem.eql(u8, key, "agent-devops") and has_agent_runner) found_devops = true;
    }

    try testing.expect(found_architect);
    try testing.expect(found_developer);
    try testing.expect(found_devops);
}
