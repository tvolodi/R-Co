const std = @import("std");

test "print env" {
    const env = std.process.Environ{ .block = .global };
    const map = try std.process.Environ.createMap(env, std.testing.allocator);
    defer map.deinit();
    std.debug.print("BPM_TEST_DB_URL={?s}\n", .{map.get("BPM_TEST_DB_URL")});
}
