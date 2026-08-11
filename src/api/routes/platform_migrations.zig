//! Migration admin surface — MIG-06
//!
//! Design artefact: src/design/mig-04-mig-05-mig-06-resume-idempotency-admin-surface.md
//! Depends on: src/platform/migration_fanout.zig (runFanout, resumeFanout —
//! MIG-02/03/04), platform.platform_migrations (MIG-01).
//!
//! Three route handlers, following the exact shape onboarding.zig /
//! webhooks.zig / identity.zig already establish (role check first line,
//! errorResult()/errors.zig helpers, HandlerResult{status_code, body}
//! return):
//!   POST /api/v1/admin/migrations/run
//!   GET  /api/v1/admin/migrations/{migration_id}/status
//!   POST /api/v1/admin/migrations/{migration_id}/resume
//!
//! All three are gated on actor.role == .PLATFORM_ADMIN (MIG-06 AC1) — the
//! codebase's existing single administrative role, per the design doc's
//! Dependencies "RBAC convention" section; no separate PLATFORM_OPERATOR
//! role exists.
const std = @import("std");
const pool_mod = @import("pool");
const auth = @import("../middleware/auth.zig");
const errors = @import("../errors.zig");
const migration_fanout = @import("../../platform/migration_fanout.zig");
const trace = @import("../middleware/trace.zig");

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

fn errorResult(allocator: std.mem.Allocator, status_code: u16, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{code}) catch
        "{\"error\":\"internal_error\"}";
    return .{ .status_code = status_code, .body = body };
}

fn parseMigrationIdBody(allocator: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    const entry = obj.get("migration_id") orelse return null;
    if (entry != .string) return null;
    return allocator.dupe(u8, entry.string) catch null;
}

/// Generates a fresh run_id for this call. Reuses the existing
/// api/middleware/trace.zig UUID v4 generator (CSPRNG-backed, platform-aware
/// fillRandom) rather than re-deriving a random-bytes helper — the same
/// utility src/api/middleware/trace.zig's own extractOrGenerate uses for
/// trace_id.
fn generateRunId(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [trace.UUID_V4_LEN]u8 = undefined;
    trace.generateUuidV4(&buf);
    return allocator.dupe(u8, &buf);
}

fn serializeFanoutLike(
    allocator: std.mem.Allocator,
    run_id: []const u8,
    done: u32,
    failed: u32,
    pending: u32,
) []const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"run_id\":\"{s}\",\"done\":{d},\"failed\":{d},\"pending\":{d}}}",
        .{ run_id, done, failed, pending },
    ) catch "{\"error\":\"internal_error\"}";
}

// ── POST /api/v1/admin/migrations/run ─────────────────────────────────────

/// `known_migration_ids` is a caller-supplied registry of valid migration_id
/// values, per the accepted interim design for MIG-06 AC2's "unknown
/// migration" 404 check (design doc Open Questions §2) — there is no
/// concrete on-disk "migration set" for the platform.platform_migrations
/// fanout system yet (distinct from the numbered-file
/// public.schema_migrations runner), so the caller (whatever wires this
/// route up) supplies the currently-known set explicitly rather than this
/// module inventing an enumeration mechanism.
///
/// A `step` DdlStep must also be supplied by the caller — this module does
/// not select or embed DDL of its own; it is a thin wrapper over
/// migration_fanout.runFanout (MIG-02/03, unchanged) exactly as the design
/// doc specifies.
pub fn handleRunMigration(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    body: []const u8,
    known_migration_ids: []const []const u8,
    step: migration_fanout.DdlStep,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN) {
        return errorResult(allocator, 403, "forbidden");
    }

    const migration_id = parseMigrationIdBody(allocator, body) orelse
        return errorResult(allocator, 422, "validation_failed");
    defer allocator.free(migration_id);

    // MIG-06 AC2: unknown migration_id -> 404, writes no control rows.
    // Checked BEFORE any call into runFanout, which would otherwise seed
    // rows for an unknown id.
    var known = false;
    for (known_migration_ids) |k| {
        if (std.mem.eql(u8, k, migration_id)) {
            known = true;
            break;
        }
    }
    if (!known) {
        const pd = errors.problemNotFound("UnknownMigration");
        const pd_body = errors.serialise(allocator, pd) catch
            return errorResult(allocator, 500, "internal_error");
        return .{ .status_code = 404, .body = pd_body };
    }

    const run_id = generateRunId(allocator) catch
        return errorResult(allocator, 500, "internal_error");
    defer allocator.free(run_id);

    const result = migration_fanout.runFanout(allocator, pool, .{
        .migration_id = migration_id,
        .run_id = run_id,
    }, step) catch |err| switch (err) {
        migration_fanout.FanoutError.MigrationAlreadyRunning => {
            const pd = errors.problemConflict("migration already running");
            const pd_body = errors.serialise(allocator, pd) catch
                return errorResult(allocator, 500, "internal_error");
            return .{ .status_code = 409, .body = pd_body };
        },
        migration_fanout.FanoutError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        migration_fanout.FanoutError.SnapshotQueryFailed => return errorResult(allocator, 500, "internal_error"),
    };

    return .{
        .status_code = 200,
        .body = serializeFanoutLike(allocator, result.run_id, result.done, result.failed, result.pending),
    };
}

// ── GET /api/v1/admin/migrations/{migration_id}/status ────────────────────

fn appendJsonStr(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

/// GET /api/v1/admin/migrations/{migration_id}/status — MIG-06 AC3: the
/// three counts and a per-tenant list with error_msg and completed_at.
/// Read-only: a single SELECT over platform.platform_migrations WHERE
/// migration_id = $1, aggregated in-process into counts.
pub fn handleMigrationStatus(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    migration_id: []const u8,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN) {
        return errorResult(allocator, 403, "forbidden");
    }

    const conn = pool.acquire() catch return errorResult(allocator, 503, "service_unavailable");
    defer pool.release(conn);

    var result = conn.query(
        allocator,
        \\SELECT tenant_id::text, status, error_msg, completed_at::text
        \\FROM platform.platform_migrations
        \\WHERE migration_id = $1
        \\ORDER BY tenant_id
    ,
        &.{migration_id},
    ) catch return errorResult(allocator, 500, "internal_error");
    defer result.deinit();

    var pending_count: u32 = 0;
    var done_count: u32 = 0;
    var failed_count: u32 = 0;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\"migration_id\":") catch return errorResult(allocator, 500, "internal_error");
    appendJsonStr(allocator, &buf, migration_id) catch return errorResult(allocator, 500, "internal_error");
    buf.appendSlice(allocator, ",\"tenants\":[") catch return errorResult(allocator, 500, "internal_error");

    for (result.rows, 0..) |row, i| {
        const tenant_id = row[0] orelse continue;
        const status = row[1] orelse continue;
        const error_msg = row[2];
        const completed_at = row[3];

        if (std.mem.eql(u8, status, "pending")) pending_count += 1;
        if (std.mem.eql(u8, status, "done")) done_count += 1;
        if (std.mem.eql(u8, status, "failed")) failed_count += 1;

        if (i > 0) buf.appendSlice(allocator, ",") catch return errorResult(allocator, 500, "internal_error");
        buf.appendSlice(allocator, "{\"tenant_id\":") catch return errorResult(allocator, 500, "internal_error");
        appendJsonStr(allocator, &buf, tenant_id) catch return errorResult(allocator, 500, "internal_error");
        buf.appendSlice(allocator, ",\"status\":") catch return errorResult(allocator, 500, "internal_error");
        appendJsonStr(allocator, &buf, status) catch return errorResult(allocator, 500, "internal_error");
        buf.appendSlice(allocator, ",\"error_msg\":") catch return errorResult(allocator, 500, "internal_error");
        if (error_msg) |m| {
            appendJsonStr(allocator, &buf, m) catch return errorResult(allocator, 500, "internal_error");
        } else {
            buf.appendSlice(allocator, "null") catch return errorResult(allocator, 500, "internal_error");
        }
        buf.appendSlice(allocator, ",\"completed_at\":") catch return errorResult(allocator, 500, "internal_error");
        if (completed_at) |c| {
            appendJsonStr(allocator, &buf, c) catch return errorResult(allocator, 500, "internal_error");
        } else {
            buf.appendSlice(allocator, "null") catch return errorResult(allocator, 500, "internal_error");
        }
        buf.appendSlice(allocator, "}") catch return errorResult(allocator, 500, "internal_error");
    }

    buf.appendSlice(allocator, "]") catch return errorResult(allocator, 500, "internal_error");

    const counts_suffix = std.fmt.allocPrint(
        allocator,
        ",\"pending\":{d},\"done\":{d},\"failed\":{d}}}",
        .{ pending_count, done_count, failed_count },
    ) catch return errorResult(allocator, 500, "internal_error");
    defer allocator.free(counts_suffix);
    buf.appendSlice(allocator, counts_suffix) catch return errorResult(allocator, 500, "internal_error");

    const owned = buf.toOwnedSlice(allocator) catch return errorResult(allocator, 500, "internal_error");
    return .{ .status_code = 200, .body = owned };
}

// ── POST /api/v1/admin/migrations/{migration_id}/resume ───────────────────

/// POST /api/v1/admin/migrations/{migration_id}/resume — resumeFanout
/// (MIG-04), serialised in the same shape handleRunMigration uses for
/// FanoutResult.
pub fn handleResumeMigration(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    migration_id: []const u8,
    step: migration_fanout.DdlStep,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN) {
        return errorResult(allocator, 403, "forbidden");
    }

    const run_id = generateRunId(allocator) catch
        return errorResult(allocator, 500, "internal_error");
    defer allocator.free(run_id);

    const result = migration_fanout.resumeFanout(allocator, pool, .{
        .migration_id = migration_id,
        .run_id = run_id,
    }, step) catch |err| switch (err) {
        migration_fanout.ResumeError.MigrationAlreadyRunning => {
            const pd = errors.problemConflict("migration already running");
            const pd_body = errors.serialise(allocator, pd) catch
                return errorResult(allocator, 500, "internal_error");
            return .{ .status_code = 409, .body = pd_body };
        },
        migration_fanout.ResumeError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        migration_fanout.ResumeError.SnapshotQueryFailed => return errorResult(allocator, 500, "internal_error"),
    };

    return .{
        .status_code = 200,
        .body = serializeFanoutLike(allocator, result.run_id, result.done, result.failed, result.pending),
    };
}
