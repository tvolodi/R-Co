const std = @import("std");

fn containsText(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const seed = try std.fs.cwd().readFileAlloc(allocator, "infrastructure/keycloak/realms/bpm-default.json", 8 * 1024 * 1024);
    defer allocator.free(seed);

    const policy = try std.fs.cwd().readFileAlloc(allocator, "infrastructure/keycloak/policies/agent-test-identities.json", 1024 * 1024);
    defer allocator.free(policy);

    const required = [_][]const u8{ "agent-architect", "agent-developer", "agent-devops" };
    for (required) |client_id| {
        if (!containsText(seed, client_id) or !containsText(policy, client_id)) {
            std.debug.print("AGENT_IDENTITY_VALIDATION|status=fail|missing={s}\n", .{client_id});
            return error.IdentityMissing;
        }
    }

    std.debug.print("AGENT_IDENTITY_VALIDATION|status=ok|count=3\n", .{});
}
