const std = @import("std");
const oidc_agent_lifecycle = @import("../../oidc/agent_lifecycle.zig");

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

fn checkIdentityProviderReady(allocator: std.mem.Allocator) !SubsystemCheckResult {
    if (oidc_agent_lifecycle.checkProviderReadiness(allocator)) {
        return .{ .ok = {} };
    }
    return .{ .failed = .{
        .subsystem = "identity_provider",
        .code = "IDP_NOT_READY",
        .detail = "identity provider readiness probe failed",
        .retryable = true,
    } };
}

const default_checkers: [2]SubsystemChecker = .{
    .{ .name = "api_router", .checkFn = checkApiRouterReady },
    .{ .name = "identity_provider", .checkFn = checkIdentityProviderReady },
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

const testing = std.testing;

fn failProbe(_: std.mem.Allocator) !void {
    return error.TestProbeFailed;
}

fn okProbe(_: std.mem.Allocator) !void {}

test "OIDC-25 readiness reports identity_provider failure when probe fails" {
    oidc_agent_lifecycle.configureProviderReadinessProbe(failProbe);
    defer oidc_agent_lifecycle.configureProviderReadinessProbe(null);

    const failures = try runCheckers(testing.allocator, defaultCriticalCheckers());
    defer testing.allocator.free(failures);

    var found = false;
    for (failures) |failure| {
        if (std.mem.eql(u8, failure.subsystem, "identity_provider")) {
            found = true;
            try testing.expectEqualStrings("IDP_NOT_READY", failure.code);
            try testing.expectEqual(true, failure.retryable);
        }
    }
    try testing.expect(found);
}

test "OIDC-25 readiness recovers after probe succeeds" {
    oidc_agent_lifecycle.configureProviderReadinessProbe(failProbe);
    const degraded = try runCheckers(testing.allocator, defaultCriticalCheckers());
    defer testing.allocator.free(degraded);

    oidc_agent_lifecycle.configureProviderReadinessProbe(okProbe);
    defer oidc_agent_lifecycle.configureProviderReadinessProbe(null);

    const recovered = try runCheckers(testing.allocator, defaultCriticalCheckers());
    defer testing.allocator.free(recovered);

    try testing.expect(degraded.len > 0);
    try testing.expectEqual(@as(usize, 0), recovered.len);
}
