const std = @import("std");
const build_options = @import("build_options");

pub const VersionSourceError = error{
    OutOfMemory,
};

pub fn platformVersion(allocator: std.mem.Allocator) VersionSourceError![]const u8 {
    return allocator.dupe(u8, build_options.platform_version) catch error.OutOfMemory;
}
