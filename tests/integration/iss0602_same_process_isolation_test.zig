//! Requires: BPM_TEST_DB_URL environment variable pointing at a real
//! PostgreSQL database — read internally by helpers.TestHarness.init().
const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

test "step1" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();
    const tag = try helpers.GetTestOwnerTag(alloc);
    defer alloc.free(tag);
    try testing.expect(std.mem.startsWith(u8, tag, "uid_"));
}
