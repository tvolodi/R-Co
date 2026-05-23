const std = @import("std");

pub const FailingSubsystem = struct {
    subsystem: []const u8,
    code: []const u8,
    detail: []const u8,
    retryable: bool,
};

pub const SubsystemCheckResult = union(enum) {
    ok: void,
    failed: FailingSubsystem,
};

pub const SubsystemChecker = struct {
    name: []const u8,
    checkFn: *const fn (allocator: std.mem.Allocator) anyerror!SubsystemCheckResult,
};

fn checkApiRouterReady(_: std.mem.Allocator) !SubsystemCheckResult {
    return .{ .ok = {} };
}

const default_checkers: [1]SubsystemChecker = .{
    .{ .name = "api_router", .checkFn = checkApiRouterReady },
};

pub fn defaultCriticalCheckers() []const SubsystemChecker {
    return &default_checkers;
}

pub fn runCheckers(
    allocator: std.mem.Allocator,
    checkers: []const SubsystemChecker,
) error{OutOfMemory}![]FailingSubsystem {
    var failures = std.ArrayList(FailingSubsystem).empty;
    defer failures.deinit(allocator);

    for (checkers) |checker| {
        const result = checker.checkFn(allocator) catch {
            try failures.append(allocator, .{
                .subsystem = checker.name,
                .code = "CHECK_FAILED",
                .detail = "subsystem readiness checker failed",
                .retryable = true,
            });
            continue;
        };

        switch (result) {
            .ok => {},
            .failed => |failure| try failures.append(allocator, failure),
        }
    }

    return try allocator.dupe(FailingSubsystem, failures.items);
}
