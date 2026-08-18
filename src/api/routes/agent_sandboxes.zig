//! SBX-03/04/05/06 — Agent sandbox list, claim, and release handlers.

const std = @import("std");
const db = @import("pool");
const auth_mod = @import("../../api/middleware/auth.zig");
const agent_auth = @import("../../api/middleware/agent_auth.zig");
const audit_mod = @import("../../obs/audit.zig");
const trace_context = @import("../../api/trace_context.zig");
const sandbox_access = @import("sandbox_access.zig");

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

/// POST /api/v1/agent/sandboxes/{sandbox_id}/claim  (SBX-03/04)
pub fn handleClaimSandbox(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    auth: auth_mod.AuthContext,
    sandbox_id: []const u8,
    body_json: []const u8,
) HandlerResult {
    const tenant_id_slice: []const u8 = auth.tenant_id[0..];
    const trace_id = trace_context.get();

    // SBX-03: role gate — orchestrator and non-implementer write claim_rejected audit.
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
                "{{\"principal\":\"{s}\",\"sandbox_id\":\"{s}\",\"rejection_code\":\"{s}\",\"tenant_id\":\"{s}\"}}",
                .{ auth.user_id, sandbox_id, rejection_code, tenant_id_slice },
            ) catch null;
            if (after) |a| {
                const audit_id = audit_mod.writeAuditInTx(
                    allocator, conn, tenant_id_slice, auth.user_id,
                    "sandbox.claim_rejected", "agent_sandbox", sandbox_id,
                    null, a, trace_id, null,
                ) catch null;
                if (audit_id) |id| allocator.free(id);
                allocator.free(a);
            }
            return hr;
        },
        .pass => {},
    }

    // SBX-04: parse task_spec_id from request body.
    const task_spec_id: []const u8 = blk: {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            body_json,
            .{ .allocate = .alloc_always },
        ) catch break :blk "";
        defer parsed.deinit();
        if (parsed.value != .object) break :blk "";
        const obj = parsed.value.object;
        const field = obj.get("task_spec_id") orelse break :blk "";
        if (field != .string) break :blk "";
        break :blk allocator.dupe(u8, field.string) catch "";
    };
    defer if (task_spec_id.len > 0) allocator.free(task_spec_id);

    if (task_spec_id.len == 0) {
        return .{ .status_code = 400, .body = "{\"detail\":\"task_spec_id_required\",\"status\":400}" };
    }

    const conn = pool.acquire() catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"pool_exhausted\",\"status\":503}",
    };
    defer pool.release(conn);

    // SBX-04/INV-2: verify task_spec_id exists for this tenant before claiming.
    const spec_row = conn.queryRow(
        allocator,
        \\SELECT 1 FROM task_specs
        \\WHERE tenant_id = current_setting('app.current_tenant_id')::uuid
        \\AND task_spec_id = $1::uuid
    , &.{task_spec_id}) catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"db_error\",\"status\":503}",
    };
    if (spec_row == null) {
        return .{ .status_code = 404, .body = "{\"detail\":\"task_spec_not_found\",\"status\":404}" };
    }
    if (spec_row) |r| {
        for (r) |col| if (col) |c| allocator.free(c);
        allocator.free(r);
    }

    // SBX-04: atomic UPDATE + audit inside one transaction.
    conn.begin() catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"db_error\",\"status\":503}",
    };

    const claim_row = conn.queryRow(
        allocator,
        \\UPDATE agent_sandboxes
        \\SET status = 'claimed',
        \\    owner_principal = $1,
        \\    task_spec_id = $3::uuid,
        \\    claimed_at = NOW(),
        \\    last_active_at = NOW(),
        \\    updated_at = NOW()
        \\WHERE sandbox_id = $2::uuid AND status = 'unclaimed'
        \\RETURNING sandbox_id::text
    , &.{ auth.user_id, sandbox_id, task_spec_id }) catch blk: {
        // Capture SQLSTATE before ROLLBACK clears the error state.
        var sqlstate_buf: [5]u8 = undefined;
        const is_unique_violation: bool = if (conn.lastSqlState()) |s| blk2: {
            if (s.len == 5) @memcpy(&sqlstate_buf, s[0..5]);
            break :blk2 s.len == 5 and std.mem.eql(u8, s[0..5], "23505");
        } else false;
        conn.rollback() catch {};
        if (is_unique_violation) {
            // SBX-04: ux_sandbox_owner partial index — same task_spec_id already claimed.
            sandbox_access.writeSentinelAudit(
                allocator, conn, tenant_id_slice, auth.user_id, sandbox_id, "sandbox_already_claimed",
            );
            return conflict409(allocator, "sandbox_already_claimed");
        }

        break :blk null;
    };

    if (claim_row == null) {
        // 0 rows updated — sandbox not found, not unclaimed, or wrong tenant (or generic error).
        conn.rollback() catch {};

        // SBX-05: probe rate check before emitting sentinel.
        switch (@as(sandbox_access.ProbeRateResult, sandbox_access.checkProbeRate(allocator, conn, auth.user_id) catch .{ .allowed = {} })) {
            .exceeded => |retry_after| {
                sandbox_access.writeSentinelAudit(
                    allocator, conn, tenant_id_slice, auth.user_id, sandbox_id, "probe_rate_exceeded",
                );
                const body429 = std.fmt.allocPrint(
                    allocator,
                    "{{\"detail\":\"probe_rate_exceeded\",\"status\":429}}",
                    .{},
                ) catch "{\"detail\":\"probe_rate_exceeded\",\"status\":429}";
                _ = retry_after;
                return .{ .status_code = 429, .body = body429 };
            },
            .allowed => {},
        }
        sandbox_access.writeSentinelAudit(
            allocator, conn, tenant_id_slice, auth.user_id, sandbox_id, "sandbox_not_accessible",
        );
        return .{ .status_code = 403, .body = "{\"detail\":\"sandbox_not_accessible\",\"status\":403}" };
    }

    // 1 row updated — write sandbox.claimed audit and commit.
    if (claim_row) |r| {
        defer {
            for (r) |col| if (col) |c| allocator.free(c);
            allocator.free(r);
        }
    }

    const after = std.fmt.allocPrint(
        allocator,
        "{{\"principal\":\"{s}\",\"sandbox_id\":\"{s}\",\"task_spec_id\":\"{s}\"}}",
        .{ auth.user_id, sandbox_id, task_spec_id },
    ) catch null;
    if (after) |a| {
        defer allocator.free(a);
        const audit_id = audit_mod.writeAuditInTx(
            allocator, conn, tenant_id_slice, auth.user_id,
            "sandbox.claimed", "agent_sandbox", sandbox_id,
            null, a, trace_id, null,
        ) catch null;
        if (audit_id) |id| allocator.free(id);
    }

    conn.commit() catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"db_error\",\"status\":503}",
    };

    return .{ .status_code = 201, .body = "{}" };
}

/// DELETE /api/v1/agent/sandboxes/{sandbox_id}/claim  (SBX-06)
pub fn handleReleaseSandbox(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    auth: auth_mod.AuthContext,
    sandbox_id: []const u8,
) HandlerResult {
    const tenant_id_slice: []const u8 = auth.tenant_id[0..];
    const trace_id = trace_context.get();

    // SBX-06: orchestrators and non-implementers receive the sentinel (not a role-specific error).
    const has_implementer = blk: {
        for (auth.agent_realm_roles) |r| {
            if (r == .tenant_implementer) break :blk true;
        }
        break :blk false;
    };
    if (!has_implementer) {
        const conn = pool.acquire() catch return .{
            .status_code = 503,
            .body = "{\"detail\":\"pool_exhausted\",\"status\":503}",
        };
        defer pool.release(conn);
        sandbox_access.writeSentinelAudit(
            allocator, conn, tenant_id_slice, auth.user_id, sandbox_id, "sandbox_not_accessible",
        );
        return .{ .status_code = 403, .body = "{\"detail\":\"sandbox_not_accessible\",\"status\":403}" };
    }

    const conn = pool.acquire() catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"pool_exhausted\",\"status\":503}",
    };
    defer pool.release(conn);

    // SBX-05: probe rate check before emitting any sentinel.
    const probe: sandbox_access.ProbeRateResult = sandbox_access.checkProbeRate(allocator, conn, auth.user_id) catch .{ .allowed = {} };

    // SBX-05: validate principal binding (tenant predicate via search_path).
    const access = sandbox_access.checkPrincipalBound(allocator, conn, sandbox_id, auth.user_id) catch {
        return .{ .status_code = 503, .body = "{\"detail\":\"db_error\",\"status\":503}" };
    };

    switch (access) {
        .inaccessible => {
            switch (probe) {
                .exceeded => |retry_after| {
                    sandbox_access.writeSentinelAudit(
                        allocator, conn, tenant_id_slice, auth.user_id, sandbox_id, "probe_rate_exceeded",
                    );
                    const body429 = std.fmt.allocPrint(
                        allocator,
                        "{{\"detail\":\"probe_rate_exceeded\",\"status\":429}}",
                        .{},
                    ) catch "{\"detail\":\"probe_rate_exceeded\",\"status\":429}";
                    _ = retry_after;
                    return .{ .status_code = 429, .body = body429 };
                },
                .allowed => {},
            }
            sandbox_access.writeSentinelAudit(
                allocator, conn, tenant_id_slice, auth.user_id, sandbox_id, "sandbox_not_accessible",
            );
            return .{ .status_code = 403, .body = "{\"detail\":\"sandbox_not_accessible\",\"status\":403}" };
        },
        .ok => |sbx| {
            defer {
                allocator.free(sbx.sandbox_id);
                allocator.free(sbx.status);
                if (sbx.owner_principal) |p| allocator.free(p);
                if (sbx.task_spec_id) |t| allocator.free(t);
                if (sbx.claimed_at) |c| allocator.free(c);
            }

            const task_spec_for_audit: []const u8 = sbx.task_spec_id orelse "";

            // SBX-06: atomic release UPDATE + sandbox.released audit.
            conn.begin() catch return .{
                .status_code = 503,
                .body = "{\"detail\":\"db_error\",\"status\":503}",
            };

            conn.exec(
                \\UPDATE agent_sandboxes
                \\SET status = 'released',
                \\    owner_principal = NULL,
                \\    task_spec_id = NULL,
                \\    claimed_at = NULL,
                \\    last_active_at = NULL,
                \\    updated_at = NOW()
                \\WHERE sandbox_id = $1::uuid
                \\  AND status = 'claimed'
                \\  AND owner_principal = $2
            , &.{ sandbox_id, auth.user_id }) catch {
                conn.rollback() catch {};
                return .{ .status_code = 503, .body = "{\"detail\":\"db_error\",\"status\":503}" };
            };

            const after = std.fmt.allocPrint(
                allocator,
                "{{\"principal\":\"{s}\",\"sandbox_id\":\"{s}\",\"task_spec_id\":\"{s}\"}}",
                .{ auth.user_id, sandbox_id, task_spec_for_audit },
            ) catch null;
            if (after) |a| {
                defer allocator.free(a);
                const audit_id = audit_mod.writeAuditInTx(
                    allocator, conn, tenant_id_slice, auth.user_id,
                    "sandbox.released", "agent_sandbox", sandbox_id,
                    null, a, trace_id, null,
                ) catch null;
                if (audit_id) |id| allocator.free(id);
            }

            conn.commit() catch return .{
                .status_code = 503,
                .body = "{\"detail\":\"db_error\",\"status\":503}",
            };

            return .{ .status_code = 204, .body = "" };
        },
    }
}
