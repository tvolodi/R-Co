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

test "TC-OIDC-28-01: compose includes Keycloak 26 import-realm setup" {
    const alloc = testing.allocator;
    const compose = try readFile(alloc, "docker-compose.yml", 1024 * 1024);
    defer alloc.free(compose);

    try testing.expect(std.mem.indexOf(u8, compose, "quay.io/keycloak/keycloak:26.") != null);
    try testing.expect(std.mem.indexOf(u8, compose, "start-dev") != null);
    try testing.expect(std.mem.indexOf(u8, compose, "--import-realm") != null);
    try testing.expect(std.mem.indexOf(u8, compose, "./infrastructure/keycloak/realms:/opt/keycloak/data/import:ro") != null);
}

test "TC-OIDC-28-02: seed includes bpm-default realm, platform client, and role-distinct users" {
    const alloc = testing.allocator;
    const seed = try readFile(alloc, "infrastructure/keycloak/realms/bpm-default.json", 4 * 1024 * 1024);
    defer alloc.free(seed);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, seed, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);
    const root = parsed.value.object;

    const realm = root.get("realm") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("bpm-default", jsonString(realm) orelse return error.TestUnexpectedResult);

    const clients = root.get("clients") orelse return error.TestUnexpectedResult;
    try testing.expect(clients == .array);

    var has_platform_client = false;
    for (clients.array.items) |client| {
        if (client != .object) continue;
        const cid = client.object.get("clientId") orelse continue;
        if (jsonString(cid)) |s| {
            if (std.mem.eql(u8, s, "bpm-platform-api")) {
                has_platform_client = true;
                break;
            }
        }
    }
    try testing.expect(has_platform_client);

    const users = root.get("users") orelse return error.TestUnexpectedResult;
    try testing.expect(users == .array);

    var has_admin = false;
    var has_designer = false;
    var has_worker = false;

    for (users.array.items) |user| {
        if (user != .object) continue;
        const username_val = user.object.get("username") orelse continue;
        const realm_roles_val = user.object.get("realmRoles") orelse continue;
        if (realm_roles_val != .array) continue;

        const username = jsonString(username_val) orelse continue;
        var role_admin = false;
        var role_designer = false;
        var role_worker = false;
        for (realm_roles_val.array.items) |role| {
            const role_name = jsonString(role) orelse continue;
            if (std.mem.eql(u8, role_name, "PLATFORM_ADMIN")) role_admin = true;
            if (std.mem.eql(u8, role_name, "PROCESS_DESIGNER")) role_designer = true;
            if (std.mem.eql(u8, role_name, "TASK_WORKER")) role_worker = true;
        }

        if (std.mem.eql(u8, username, "admin-user") and role_admin) has_admin = true;
        if (std.mem.eql(u8, username, "designer-user") and role_designer) has_designer = true;
        if (std.mem.eql(u8, username, "worker-user") and role_worker) has_worker = true;
    }

    try testing.expect(has_admin);
    try testing.expect(has_designer);
    try testing.expect(has_worker);
}
