//! SBX-01/02/03 — Agent-role gate middleware.

const std = @import("std");
const auth_mod = @import("../../api/middleware/auth.zig");

pub const HandlerResult = auth_mod.HandlerResult;
pub const AuthContext = auth_mod.AuthContext;
pub const AgentRealmRole = auth_mod.AgentRealmRole;

/// Result of an agent gate check.
pub const AgentGateResult = union(enum) {
    pass: void,
    forbidden: HandlerResult,
};

fn forbidden403(allocator: std.mem.Allocator, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"detail\":\"{s}\",\"status\":403}}",
        .{code},
    ) catch "{\"detail\":\"forbidden\",\"status\":403}";
    return .{ .status_code = 403, .body = body };
}

fn hasScope(auth: AuthContext, scope: []const u8) bool {
    for (auth.token_scopes) |s| {
        if (std.mem.eql(u8, s, scope)) return true;
    }
    return false;
}

fn hasAgentRole(auth: AuthContext, role: AgentRealmRole) bool {
    for (auth.agent_realm_roles) |r| {
        if (r == role) return true;
    }
    return false;
}

/// Gate for POST /api/v1/agent/task-specs (SBX-01).
/// Requires scope "agent.submit_task_spec" AND role tenant_orchestrator.
pub fn requireOrchestratorSubmit(allocator: std.mem.Allocator, auth: AuthContext) AgentGateResult {
    const has_scope = hasScope(auth, "agent.submit_task_spec");
    const has_role = hasAgentRole(auth, .tenant_orchestrator);
    if (!has_scope or !has_role) {
        return .{ .forbidden = forbidden403(allocator, "orchestrator_role_required") };
    }
    return .pass;
}

/// Gate for sandbox claim endpoint (SBX-03).
/// Requires tenant_implementer; rejects tenant_orchestrator.
pub fn requireImplementerClaim(allocator: std.mem.Allocator, auth: AuthContext) AgentGateResult {
    if (hasAgentRole(auth, .tenant_orchestrator)) {
        return .{ .forbidden = forbidden403(allocator, "orchestrator_may_not_claim") };
    }
    if (!hasAgentRole(auth, .tenant_implementer)) {
        return .{ .forbidden = forbidden403(allocator, "implementer_role_required") };
    }
    return .pass;
}

/// Gate for any sandbox execution route (SBX-03 AC4).
pub fn requireImplementerExecution(allocator: std.mem.Allocator, auth: AuthContext) AgentGateResult {
    return requireImplementerClaim(allocator, auth);
}
