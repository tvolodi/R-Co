//! Host API: fail(reason: string, details: string) -> never
//! Causes the instance to fail with a reason.

const std = @import("std");

pub const FailError = error{ExecutionFailed};

/// Fail the invocation with a reason.
pub fn platform_fail(
    reason: []const u8,
) !noreturn {
    std.debug.print("Module failed: {s}\n", .{reason});
    return error.ExecutionFailed;
}
