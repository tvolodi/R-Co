const std = @import("std");

pub const Role = enum {
    PLATFORM_ADMIN,
    PROCESS_DESIGNER,
    PROCESS_OPERATOR,
    TASK_WORKER,
    AGENT_RUNNER,
};

pub const Permission = enum {
    DefinitionsWrite,
    DefinitionsRead,
    InstancesStart,
    InstancesCancel,
    InstancesRead,
    TasksRead,
    TasksComplete,
    TasksAssign,
    UsersGroupsRolesManage,
    TokensManage,
    AuditRead,
    DlqOperate,
    MetricsRead,
    WebhooksManage,
};

pub const AccessDecisionKind = enum {
    Allow,
    Deny403,
    AllowWithRowFilter,
};

pub const EndpointPolicyKey = enum {
    DefinitionsCreate,
    DefinitionsUpdate,
    DefinitionsPatch,
    DefinitionsActivate,
    DefinitionsRead,
    InstancesStart,
    InstancesCancel,
    InstancesRead,
    TasksList,
    TasksGetById,
    TasksComplete,
    TasksAssign,
    TasksReassign,
    UsersManage,
    GroupsManage,
    TokensManage,
    AuditRead,
    DlqReadRetryDiscard,
    MetricsRead,
    WebhookSubscriptionsManage,
    Unknown,
};

pub const TaskRowScope = union(enum) {
    All,
    OwnUserAndGroups: []const u8,
};

pub const AccessContext = struct {
    user_id: []const u8,
    roles: []const Role,
};

pub const AccessDecision = struct {
    kind: AccessDecisionKind,
    task_scope: ?TaskRowScope,
};

pub fn endpointPolicyKey(method: []const u8, path_template: []const u8) EndpointPolicyKey {
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path_template, "/definitions")) return .DefinitionsCreate;
    if (std.mem.eql(u8, method, "PUT") and std.mem.eql(u8, path_template, "/definitions/:id")) return .DefinitionsUpdate;
    if (std.mem.eql(u8, method, "PATCH") and std.mem.eql(u8, path_template, "/definitions/:id")) return .DefinitionsPatch;
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path_template, "/definitions/:id/activate")) return .DefinitionsActivate;
    if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, path_template, "/definitions") or std.mem.eql(u8, path_template, "/definitions/:id"))) return .DefinitionsRead;

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path_template, "/instances")) return .InstancesStart;
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path_template, "/instances/:id/cancel")) return .InstancesCancel;
    if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, path_template, "/instances") or std.mem.eql(u8, path_template, "/instances/:id") or std.mem.eql(u8, path_template, "/instances/:id/history") or std.mem.eql(u8, path_template, "/instances/:id/timeline"))) return .InstancesRead;

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path_template, "/tasks")) return .TasksList;
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path_template, "/tasks/:id")) return .TasksGetById;
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path_template, "/tasks/:id/complete")) return .TasksComplete;
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path_template, "/tasks/:id/assign")) return .TasksAssign;
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path_template, "/tasks/:id/reassign")) return .TasksReassign;

    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path_template, "/users")) return .UsersManage;
    if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, path_template, "/users") or std.mem.eql(u8, path_template, "/users/:id"))) return .UsersManage;
    if (std.mem.eql(u8, method, "PATCH") and std.mem.eql(u8, path_template, "/users/:id")) return .UsersManage;
    if ((std.mem.eql(u8, method, "POST") or std.mem.eql(u8, method, "DELETE") or std.mem.eql(u8, method, "GET")) and std.mem.startsWith(u8, path_template, "/groups")) return .GroupsManage;
    if ((std.mem.eql(u8, method, "POST") or std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "DELETE")) and std.mem.startsWith(u8, path_template, "/tokens")) return .TokensManage;
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path_template, "/audit")) return .AuditRead;
    if ((std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "POST")) and std.mem.startsWith(u8, path_template, "/dlq")) return .DlqReadRetryDiscard;
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path_template, "/metrics")) return .MetricsRead;
    if ((std.mem.eql(u8, method, "POST") or std.mem.eql(u8, method, "GET")) and std.mem.eql(u8, path_template, "/webhooks/subscriptions")) return .WebhookSubscriptionsManage;
    if (std.mem.eql(u8, method, "DELETE") and std.mem.eql(u8, path_template, "/webhooks/subscriptions/:id")) return .WebhookSubscriptionsManage;

    return .Unknown;
}

pub fn evaluateAccess(ctx: AccessContext, endpoint: EndpointPolicyKey) AccessDecision {
    if (endpoint == .Unknown) {
        if (hasRole(ctx.roles, .PLATFORM_ADMIN)) {
            return .{ .kind = .Allow, .task_scope = null };
        }
        return .{ .kind = .Deny403, .task_scope = null };
    }

    if (endpoint == .MetricsRead) {
        return .{ .kind = .Allow, .task_scope = .{ .All = {} } };
    }

    const required = requiredPermission(endpoint);
    if (!hasPermission(ctx.roles, required)) {
        return .{ .kind = .Deny403, .task_scope = null };
    }

    if (endpoint == .TasksList and isTaskWorkerOnly(ctx.roles)) {
        return .{
            .kind = .AllowWithRowFilter,
            .task_scope = .{ .OwnUserAndGroups = ctx.user_id },
        };
    }

    return .{ .kind = .Allow, .task_scope = .{ .All = {} } };
}

pub fn isTaskWorkerOnly(roles: []const Role) bool {
    return hasRole(roles, .TASK_WORKER) and
        !hasRole(roles, .PLATFORM_ADMIN) and
        !hasRole(roles, .PROCESS_DESIGNER) and
        !hasRole(roles, .PROCESS_OPERATOR);
}

fn requiredPermission(endpoint: EndpointPolicyKey) Permission {
    return switch (endpoint) {
        .DefinitionsCreate, .DefinitionsUpdate, .DefinitionsPatch, .DefinitionsActivate => .DefinitionsWrite,
        .DefinitionsRead => .DefinitionsRead,
        .InstancesStart => .InstancesStart,
        .InstancesCancel => .InstancesCancel,
        .InstancesRead => .InstancesRead,
        .TasksList, .TasksGetById => .TasksRead,
        .TasksComplete => .TasksComplete,
        .TasksAssign, .TasksReassign => .TasksAssign,
        .UsersManage, .GroupsManage => .UsersGroupsRolesManage,
        .TokensManage => .TokensManage,
        .AuditRead => .AuditRead,
        .DlqReadRetryDiscard => .DlqOperate,
        .MetricsRead => .MetricsRead,
        .WebhookSubscriptionsManage => .WebhooksManage,
        .Unknown => .MetricsRead,
    };
}

fn hasPermission(roles: []const Role, permission: Permission) bool {
    for (roles) |role| {
        if (roleAllows(role, permission)) return true;
    }
    return false;
}

fn hasRole(roles: []const Role, target: Role) bool {
    for (roles) |role| {
        if (role == target) return true;
    }
    return false;
}

fn roleAllows(role: Role, permission: Permission) bool {
    return switch (role) {
        .PLATFORM_ADMIN => true,
        .PROCESS_DESIGNER => switch (permission) {
            .DefinitionsWrite,
            .DefinitionsRead,
            .InstancesStart,
            .InstancesRead,
            .TasksRead,
            => true,
            else => false,
        },
        .PROCESS_OPERATOR => switch (permission) {
            .DefinitionsRead,
            .InstancesStart,
            .InstancesCancel,
            .InstancesRead,
            .TasksRead,
            .TasksComplete,
            .TasksAssign,
            .AuditRead,
            .DlqOperate,
            .MetricsRead,
            .WebhooksManage,
            => true,
            else => false,
        },
        .TASK_WORKER => switch (permission) {
            .DefinitionsRead,
            .InstancesRead,
            .TasksRead,
            .TasksComplete,
            => true,
            else => false,
        },
        .AGENT_RUNNER => false,
    };
}

test "TC-IDN-03-01: TASK_WORKER only cannot create definitions" {
    const ctx = AccessContext{ .user_id = "u1", .roles = &[_]Role{.TASK_WORKER} };
    const decision = evaluateAccess(ctx, .DefinitionsCreate);
    try std.testing.expect(decision.kind == .Deny403);
}

test "TC-IDN-03-02: TASK_WORKER + PROCESS_OPERATOR can cancel instances" {
    const ctx = AccessContext{ .user_id = "u1", .roles = &[_]Role{ .TASK_WORKER, .PROCESS_OPERATOR } };
    const decision = evaluateAccess(ctx, .InstancesCancel);
    try std.testing.expect(decision.kind == .Allow);
}

test "TC-IDN-03-03a: TASK_WORKER GET /tasks is row-filtered, not denied" {
    const ctx = AccessContext{ .user_id = "worker-1", .roles = &[_]Role{.TASK_WORKER} };
    const decision = evaluateAccess(ctx, .TasksList);
    try std.testing.expect(decision.kind == .AllowWithRowFilter);
    const scope = decision.task_scope orelse return error.TestUnexpectedResult;
    try std.testing.expect(scope == .OwnUserAndGroups);
    try std.testing.expectEqualStrings("worker-1", scope.OwnUserAndGroups);
}

test "TC-IDN-03-04: unmapped endpoints default to PLATFORM_ADMIN" {
    const non_admin_ctx = AccessContext{ .user_id = "u1", .roles = &[_]Role{.PROCESS_OPERATOR} };
    const admin_ctx = AccessContext{ .user_id = "u2", .roles = &[_]Role{.PLATFORM_ADMIN} };

    const denied = evaluateAccess(non_admin_ctx, .Unknown);
    const allowed = evaluateAccess(admin_ctx, .Unknown);

    try std.testing.expect(denied.kind == .Deny403);
    try std.testing.expect(allowed.kind == .Allow);
}

test "TC-IDN-03-05: timeline endpoint maps to InstancesRead" {
    const key = endpointPolicyKey("GET", "/instances/:id/timeline");
    try std.testing.expect(key == .InstancesRead);
}

test "TC-IDN-03-06: webhook subscription endpoints map to PLATFORM_ADMIN-only policy" {
    try std.testing.expect(endpointPolicyKey("POST", "/webhooks/subscriptions") == .WebhookSubscriptionsManage);
    try std.testing.expect(endpointPolicyKey("GET", "/webhooks/subscriptions") == .WebhookSubscriptionsManage);
    try std.testing.expect(endpointPolicyKey("DELETE", "/webhooks/subscriptions/:id") == .WebhookSubscriptionsManage);

    const admin_ctx = AccessContext{ .user_id = "u-admin", .roles = &[_]Role{.PLATFORM_ADMIN} };
    const worker_ctx = AccessContext{ .user_id = "u-worker", .roles = &[_]Role{.TASK_WORKER} };

    try std.testing.expect(evaluateAccess(admin_ctx, .WebhookSubscriptionsManage).kind == .Allow);
    try std.testing.expect(evaluateAccess(worker_ctx, .WebhookSubscriptionsManage).kind == .Deny403);
}

test "TC-IDN-03-07: AGENT_RUNNER does not inherit task or admin permissions" {
    const agent_ctx = AccessContext{ .user_id = "u-agent", .roles = &[_]Role{.AGENT_RUNNER} };

    try std.testing.expect(evaluateAccess(agent_ctx, .DefinitionsRead).kind == .Deny403);
    try std.testing.expect(evaluateAccess(agent_ctx, .TasksList).kind == .Deny403);
    try std.testing.expect(evaluateAccess(agent_ctx, .Unknown).kind == .Deny403);
}
