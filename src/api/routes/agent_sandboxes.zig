//! SBX-03 — Agent sandbox list and claim handlers.

const std = @import("std");
const db = @import("pool");
const auth_mod = @import("../../api/middleware/auth.zig");
const agent_auth = @import("../../api/middleware/agent_auth.zig");
const audit_mod = @import("../../obs/audit.zig");
const trace_context = @import("../../api/trace_context.zig");

pub const HandlerResult = auth_mod.HandlerResult;

pub const AgentSandboxRow = struct {
    sandbox_id: []const u8,
    status: []const u8,
    owner_principal: ?[]const u8,
    task_spec_id: ?[]const u8,
    claimed_at: ?[]const u8,
    created_at: []const u8,
};

fn forbidden403(allocator: std.mem.Allocator, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"detail\":\"{s}\",\"status\":403}}",
        .{code},
    ) catch "{\"detail\":\"forbidden\",\"status\":403}";
    return .{ .status_code = 403, .body = body };
}

fn conflict409(allocator: std.mem.Allocator, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"detail\":\"{s}\",\"status\":409}}",
        .{code},
    ) catch "{\"detail\":\"conflict\",\"status\":409}";
    return .{ .status_code = 409, .body = body };
}

/// GET /api/v1/agent/sandboxes
pub fn handleListSandboxes(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    auth: auth_mod.AuthContext,
    cursor: ?[]const u8,
    page_size: ?u16,
) HandlerResult {
    _ = cursor;
    const limit: u16 = page_size orelse 50;

    const is_orchestrator = blk: {
        for (auth.agent_realm_roles) |r| {
            if (r == .tenant_orchestrator) break :blk true;
        }
        break :blk false;
    };
    const is_implementer = blk: {
        for (auth.agent_realm_roles) |r| {
            if (r == .tenant_implementer) break :blk true;
        }
        break :blk false;
    };

    if (!is_orchestrator and !is_implementer) {
        return forbidden403(allocator, "agent_role_required");
    }

    const conn = pool.acquire() catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"pool_exhausted\",\"status\":503}",
    };
    defer pool.release(conn);

    const limit_str = std.fmt.allocPrint(allocator, "{d}", .{limit + 1}) catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"out_of_memory\",\"status\":503}",
    };
    defer allocator.free(limit_str);

    var rows = blk: {
        if (is_orchestrator) {
            break :blk conn.query(allocator,
                \\SELECT
                \\    sandbox_id::text,
                \\    status,
                \\    owner_principal,
                \\    task_spec_id::text,
                \\    to_char(claimed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                \\    to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                \\FROM agent_sandboxes
                \\ORDER BY created_at ASC, sandbox_id ASC
                \\LIMIT $1
            , &.{limit_str}) catch return .{
                .status_code = 503,
                .body = "{\"detail\":\"db_error\",\"status\":503}",
            };
        } else {
            break :blk conn.query(allocator,
                \\SELECT
                \\    sandbox_id::text,
                \\    status,
                \\    owner_principal,
                \\    task_spec_id::text,
                \\    to_char(claimed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                \\    to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                \\FROM agent_sandboxes
                \\WHERE owner_principal = $1
                \\ORDER BY created_at ASC, sandbox_id ASC
                \\LIMIT $2
            , &.{ auth.user_id, limit_str }) catch return .{
                .status_code = 503,
                .body = "{\"detail\":\"db_error\",\"status\":503}",
            };
        }
    };
    defer rows.deinit();

    const has_next = rows.rows.len > limit;
    const out_len: usize = if (has_next) limit else rows.rows.len;

    var items_buf: std.ArrayList(u8) = .empty;
    defer items_buf.deinit(allocator);

    items_buf.append(allocator, '[') catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"out_of_memory\",\"status\":503}",
    };
    for (rows.rows[0..out_len], 0..) |row, i| {
        if (i > 0) items_buf.append(allocator, ',') catch return .{
            .status_code = 503,
            .body = "{\"detail\":\"out_of_memory\",\"status\":503}",
        };
        const sandbox_id = row[0] orelse "";
        const status = row[1] orelse "unknown";
        const owner = row[2];
        const ts_id = row[3];
        const claimed_at = row[4];
        const created_at = row[5] orelse "";

        const owner_json: []const u8 = if (owner) |o|
            std.fmt.allocPrint(allocator, "\"{s}\"", .{o}) catch "null"
        else
            "null";
        defer if (owner != null and !std.mem.eql(u8, owner_json, "null")) allocator.free(owner_json);

        const ts_json: []const u8 = if (ts_id) |t|
            std.fmt.allocPrint(allocator, "\"{s}\"", .{t}) catch "null"
        else
            "null";
        defer if (ts_id != null and !std.mem.eql(u8, ts_json, "null")) allocator.free(ts_json);

        const ca_json: []const u8 = if (claimed_at) |c|
            std.fmt.allocPrint(allocator, "\"{s}\"", .{c}) catch "null"
        else
            "null";
        defer if (claimed_at != null and !std.mem.eql(u8, ca_json, "null")) allocator.free(ca_json);

        const item = std.fmt.allocPrint(
            allocator,
            "{{\"sandbox_id\":\"{s}\",\"status\":\"{s}\",\"owner_principal\":{s},\"task_spec_id\":{s},\"claimed_at\":{s},\"created_at\":\"{s}\"}}",
            .{ sandbox_id, status, owner_json, ts_json, ca_json, created_at },
        ) catch return .{ .status_code = 503, .body = "{\"detail\":\"out_of_memory\",\"status\":503}" };
        defer allocator.free(item);
        items_buf.appendSlice(allocator, item) catch return .{
            .status_code = 503,
            .body = "{\"detail\":\"out_of_memory\",\"status\":503}",
        };
    }
    items_buf.append(allocator, ']') catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"out_of_memory\",\"status\":503}",
    };

    const body = std.fmt.allocPrint(
        allocator,
        "{{\"items\":{s},\"next_cursor\":{s}}}",
        .{ items_buf.items, if (has_next) "\"next\"" else "null" },
    ) catch return .{ .status_code = 503, .body = "{\"detail\":\"out_of_memory\",\"status\":503}" };

    return .{ .status_code = 200, .body = body };
}

/// POST /api/v1/agent/sandboxes/{sandbox_id}/claim
pub fn handleClaimSandbox(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    auth: auth_mod.AuthContext,
    sandbox_id: []const u8,
    body_json: []const u8,
) HandlerResult {
    _ = body_json;
    const tenant_id_slice: []const u8 = auth.tenant_id[0..];
    const trace_id = trace_context.get();

    // SBX-03: gate
    switch (agent_auth.requireImplementerClaim(allocator, auth)) {
        .forbidden => |hr| {
            const conn = pool.acquire() catch return hr;
            defer pool.release(conn);
            const rejection_code: []const u8 = if (hr.status_code == 403)
                (if (std.mem.indexOf(u8, hr.body, "orchestrator_may_not_claim") != null)
                    "orchestrator_may_not_claim"
                else
                    "implementer_role_required")
            else
                "forbidden";
            const after = std.fmt.allocPrint(
                allocator,
                "{{\"principal\":\"{s}\",\"sandbox_id\":\"{s}\",\"rejection_code\":\"{s}\"}}",
                .{ auth.user_id, sandbox_id, rejection_code },
            ) catch null;
            if (after) |a| {
                const audit_id = audit_mod.writeAuditInTx(
                    allocator,
                    conn,
                    tenant_id_slice,
                    auth.user_id,
                    "sandbox.claim_rejected",
                    "agent_sandbox",
                    sandbox_id,
                    null,
                    a,
                    trace_id,
                    null,
                ) catch null;
                if (audit_id) |id| allocator.free(id);
                allocator.free(a);
            }
            return hr;
        },
        .pass => {},
    }

    const conn = pool.acquire() catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"pool_exhausted\",\"status\":503}",
    };
    defer pool.release(conn);

    // UPDATE agent_sandboxes SET status='claimed', owner_principal=$1, claimed_at=NOW()
    // WHERE sandbox_id=$2 AND status='unclaimed'
    // ON CONFLICT (owner_principal, task_spec_id) → 409 sandbox_already_claimed
    // (body must NOT name current owner — no SELECT before UPDATE)
    conn.exec(
        \\UPDATE agent_sandboxes
        \\SET status = 'claimed',
        \\    owner_principal = $1,
        \\    claimed_at = NOW(),
        \\    updated_at = NOW()
        \\WHERE sandbox_id = $2::uuid AND status = 'unclaimed'
    ,
        &.{ auth.user_id, sandbox_id },
    ) catch {
        // Unique constraint violation (ux_sandbox_owner) or other DB error
        return conflict409(allocator, "sandbox_already_claimed");
    };

    return .{ .status_code = 201, .body = "{}" };
}
