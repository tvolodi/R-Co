//! SBX-05/06 — Shared sandbox access helpers: principal binding check and probe rate limiting.
//!
//! Extracted from agent_sandboxes.zig so future operation handlers can import these
//! without importing the routing layer.

const std = @import("std");
const db = @import("pool");
const audit_mod = @import("../../obs/audit.zig");
const trace_context = @import("../../api/trace_context.zig");

// SBX-05 constants — not env-configurable per design OQ-SBX-02.
const probe_threshold: u32 = 20;
const probe_window_secs: u64 = 60;

pub const SandboxRow = struct {
    sandbox_id: []const u8,
    status: []const u8,
    owner_principal: ?[]const u8,
    task_spec_id: ?[]const u8,
    claimed_at: ?[]const u8,
};

pub const SandboxAccessResult = union(enum) {
    ok: SandboxRow,
    inaccessible: void,
};

pub const ProbeRateResult = union(enum) {
    allowed: void,
    exceeded: u32, // seconds until window resets (Retry-After value)
};

/// Load sandbox row and validate principal binding in one query (SBX-05).
///
/// Returns `.inaccessible` for all three negative cases: nonexistent sandbox,
/// cross-tenant sandbox (via search_path isolation), and wrong-principal sandbox.
/// The tenant predicate is the schema search_path — no timing difference between cases.
///
/// The returned SandboxRow slices are allocated with `allocator`; the caller must free them.
/// On `.inaccessible` no heap allocation is made beyond the query itself.
pub fn checkPrincipalBound(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    sandbox_id: []const u8,
    caller_principal: []const u8,
) db.PoolError!SandboxAccessResult {
    const row = conn.queryRow(
        allocator,
        \\SELECT sandbox_id::text, status, owner_principal, task_spec_id::text,
        \\       to_char(claimed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        \\FROM agent_sandboxes
        \\WHERE sandbox_id = $1::uuid
        \\  AND status = 'claimed'
        \\  AND owner_principal = $2
    ,
        &.{ sandbox_id, caller_principal },
    ) catch return db.PoolError.QueryFailed;

    if (row == null) return .{ .inaccessible = {} };

    const r = row.?;
    defer allocator.free(r);

    const sbx: SandboxRow = .{
        .sandbox_id = if (r[0]) |v| allocator.dupe(u8, v) catch return db.PoolError.QueryFailed else "",
        .status = if (r[1]) |v| allocator.dupe(u8, v) catch return db.PoolError.QueryFailed else "",
        .owner_principal = if (r[2]) |v| allocator.dupe(u8, v) catch return db.PoolError.QueryFailed else null,
        .task_spec_id = if (r[3]) |v| allocator.dupe(u8, v) catch return db.PoolError.QueryFailed else null,
        .claimed_at = if (r[4]) |v| allocator.dupe(u8, v) catch return db.PoolError.QueryFailed else null,
    };

    for (r) |col| if (col) |c| allocator.free(c);

    return .{ .ok = sbx };
}

/// Increment the sentinel probe counter for `principal` and check the threshold (SBX-05).
///
/// Uses a sliding 60-second window keyed on unix epoch truncated to the window boundary.
/// Returns `.exceeded` with a `Retry-After` seconds value if the counter exceeds 20.
/// Always commits the counter increment (probe attempts are recorded even when rejected).
pub fn checkProbeRate(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    principal: []const u8,
) db.PoolError!ProbeRateResult {
    const builtin = @import("builtin");
    const now_secs: u64 = blk: {
        if (builtin.os.tag == .windows) {
            const windows = std.os.windows;
            const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
            const unix_100ns: i64 = ft - 116_444_736_000_000_000;
            break :blk @intCast(@divTrunc(unix_100ns, 10_000_000));
        } else {
            const posix = std.posix;
            var ts: posix.timespec = undefined;
            _ = posix.system.clock_gettime(.REALTIME, &ts);
            break :blk @intCast(ts.sec);
        }
    };
    const window_start: u64 = (now_secs / probe_window_secs) * probe_window_secs;
    const window_start_str = std.fmt.allocPrint(allocator, "{d}", .{window_start}) catch
        return db.PoolError.QueryFailed;
    defer allocator.free(window_start_str);

    const row = conn.queryRow(
        allocator,
        \\INSERT INTO sandbox_probe_counters (principal, window_start, count)
        \\VALUES ($1, $2, 1)
        \\ON CONFLICT (principal, window_start)
        \\DO UPDATE SET count = sandbox_probe_counters.count + 1
        \\RETURNING count
    ,
        &.{ principal, window_start_str },
    ) catch return db.PoolError.QueryFailed;

    const new_count: u32 = blk: {
        if (row) |r| {
            defer allocator.free(r);
            defer for (r) |col| if (col) |c| allocator.free(c);
            if (r.len > 0) {
                if (r[0]) |v| {
                    break :blk std.fmt.parseInt(u32, v, 10) catch probe_threshold + 1;
                }
            }
        }
        break :blk 0;
    };

    // Opportunistic cleanup of stale windows (best-effort, failure is non-fatal).
    _ = conn.exec(
        "DELETE FROM sandbox_probe_counters WHERE window_start < $1",
        &.{window_start_str},
    ) catch {};

    if (new_count > probe_threshold) {
        const window_end: u64 = window_start + probe_window_secs;
        const retry_after: u32 = if (window_end > now_secs)
            @intCast(window_end - now_secs)
        else
            0;
        return .{ .exceeded = retry_after };
    }
    return .{ .allowed = {} };
}

/// Write a sandbox.claim_rejected audit entry (SBX-05/06).
///
/// Called for every sentinel response, including probe-rate rejections.
/// Does not write within a transaction — if the connection has no open
/// transaction the audit INSERT is auto-committed by the server.
pub fn writeSentinelAudit(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    tenant_id: []const u8,
    principal: []const u8,
    sandbox_id: []const u8,
    rejection_code: []const u8,
) void {
    const trace_id = trace_context.get();
    const after = std.fmt.allocPrint(
        allocator,
        "{{\"principal\":\"{s}\",\"sandbox_id\":\"{s}\",\"rejection_code\":\"{s}\",\"tenant_id\":\"{s}\"}}",
        .{ principal, sandbox_id, rejection_code, tenant_id },
    ) catch return;
    defer allocator.free(after);
    const audit_id = audit_mod.writeAuditInTx(
        allocator,
        conn,
        tenant_id,
        principal,
        "sandbox.claim_rejected",
        "agent_sandbox",
        sandbox_id,
        null,
        after,
        trace_id,
        null,
    ) catch return;
    allocator.free(audit_id);
}
