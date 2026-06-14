//! EXP-601: Central quota enforcement middleware.
//!
//! This middleware resolves a tenant's effective quota profile from the single
//! tier_quota_policy config surface, reads usage snapshots, and rejects write
//! requests that exceed any configured quota dimension.

const std = @import("std");
const errors = @import("../errors.zig");
const pool_mod = @import("pool");
const quota_policy = @import("../../config/quota_policy.zig");

pub const QuotaGuardTarget = enum {
    entity_write,
    file_write,
    sandbox_allocate,
    agent_retry,
    script_execute,
};

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

pub const QuotaCheckInput = struct {
    tenant_id: []const u8,
    target: QuotaGuardTarget,
    requested_delta: u64,
    request_path: []const u8,
    request_method: std.http.Method,
};

pub const QuotaMiddlewareResult = union(enum) {
    allowed,
    rejected: HandlerResult,
};

pub const QuotaMiddlewareError = error{
    NotInitialized,
    OutOfMemory,
    PoolExhausted,
    QuotaPolicyNotConfigured,
    QuotaPolicyInvalid,
    QuotaUsageReadFailed,
    QuotaDimensionUnsupported,
};

var initialized: bool = false;

pub fn init(allocator: std.mem.Allocator) QuotaMiddlewareError!void {
    _ = allocator;
    initialized = true;
}

pub fn deinit() void {
    initialized = false;
}

pub fn classifyTarget(path: []const u8, method: std.http.Method) ?QuotaGuardTarget {
    switch (method) {
        .POST, .PUT, .PATCH, .DELETE => {},
        else => return null,
    }

    if (std.mem.startsWith(u8, path, "/api/v1/entities/")) return .entity_write;
    if (std.mem.startsWith(u8, path, "/api/v1/files/")) return .file_write;
    if (std.mem.startsWith(u8, path, "/api/v1/sandbox/")) return .sandbox_allocate;
    if (std.mem.startsWith(u8, path, "/api/v1/agent/") and std.mem.endsWith(u8, path, "/retry")) return .agent_retry;
    if (std.mem.startsWith(u8, path, "/api/v1/scripts/") or std.mem.startsWith(u8, path, "/api/v1/expr/")) return .script_execute;

    return null;
}

pub fn check(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    input: QuotaCheckInput,
) QuotaMiddlewareError!QuotaMiddlewareResult {
    if (!initialized) return error.NotInitialized;

    const profile = quota_policy.loadEffectiveQuotaProfile(allocator, pool, input.tenant_id) catch |err| switch (err) {
        quota_policy.QuotaPolicyError.QuotaPolicyNotConfigured => return error.QuotaPolicyNotConfigured,
        quota_policy.QuotaPolicyError.QuotaPolicyInvalid => return error.QuotaPolicyInvalid,
        quota_policy.QuotaPolicyError.DatabaseError => return error.QuotaUsageReadFailed,
        quota_policy.QuotaPolicyError.OutOfMemory => return error.OutOfMemory,
    };

    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();

    var snapshots: [2]quota_policy.QuotaUsageSnapshot = undefined;
    var count: usize = 0;

    switch (input.target) {
        .entity_write => {
            snapshots[0] = try readUsageForDimension(ta, pool, input.tenant_id, .entity_records, profile.max_entity_records_total);
            snapshots[1] = try readUsageForDimension(ta, pool, input.tenant_id, .entity_storage, profile.max_entity_storage_bytes);
            count = 2;
        },
        .file_write => {
            snapshots[0] = try readUsageForDimension(ta, pool, input.tenant_id, .file_count, profile.max_file_count_total);
            snapshots[1] = try readUsageForDimension(ta, pool, input.tenant_id, .file_bytes, profile.max_file_bytes_total);
            count = 2;
        },
        .sandbox_allocate => {
            snapshots[0] = try readUsageForDimension(ta, pool, input.tenant_id, .concurrent_sandboxes, profile.max_concurrent_sandboxes);
            count = 1;
        },
        .agent_retry => {
            snapshots[0] = try readUsageForDimension(ta, pool, input.tenant_id, .agent_retry_per_job, profile.max_agent_retries_per_job);
            snapshots[1] = try readUsageForDimension(ta, pool, input.tenant_id, .agent_retry_per_day, profile.max_agent_retries_per_day);
            count = 2;
        },
        .script_execute => {
            snapshots[0] = try readUsageForDimension(ta, pool, input.tenant_id, .script_cpu, profile.script_cpu_millis_per_request);
            snapshots[1] = try readUsageForDimension(ta, pool, input.tenant_id, .script_memory, profile.script_memory_bytes_per_request);
            count = 2;
        },
    }

    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const decision = quota_policy.evaluateQuota(profile, snapshots[idx], input.requested_delta);
        switch (decision) {
            .allowed => {},
            .rejected => |v| {
                const body = quota_policy.mapQuotaDecisionToProblem(allocator, v) catch |err| switch (err) {
                    quota_policy.QuotaPolicyError.OutOfMemory => return error.OutOfMemory,
                    else => blk: {
                        const pd = errors.problemRateLimited("quota limit exceeded");
                        break :blk errors.serialise(allocator, pd) catch return error.OutOfMemory;
                    },
                };
                return .{ .rejected = .{ .status_code = 429, .body = body } };
            },
        }
    }

    return .allowed;
}

fn readUsageForDimension(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    dimension: quota_policy.QuotaDimension,
    limit: u64,
) QuotaMiddlewareError!quota_policy.QuotaUsageSnapshot {
    const used = switch (dimension) {
        .entity_records => countRows(allocator, pool, "instance_projections", tenant_id),
        .entity_storage => tableStorageBytes(allocator, pool, "instance_projections"),
        .file_count => countRows(allocator, pool, "repository_artifacts", tenant_id),
        .file_bytes => sumColumn(allocator, pool, "repository_artifacts", "byte_size", tenant_id),
        .concurrent_sandboxes => countRows(allocator, pool, "instance_waits", tenant_id),
        .agent_retry_per_job => maxColumn(allocator, pool, "dead_letter_queue", "retry_count", tenant_id),
        .agent_retry_per_day => countRowsWhereRecent(allocator, pool, "dead_letter_queue", tenant_id),
        .script_cpu => 0,
        .script_memory => 0,
    } catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.QuotaUsageReadFailed,
    };

    const remaining = if (used >= limit) 0 else limit - used;
    return .{
        .tenant_id = tenant_id,
        .dimension = dimension,
        .used = used,
        .limit = limit,
        .remaining = remaining,
    };
}

fn countRows(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    table_name: []const u8,
    tenant_id: []const u8,
) (error{ OutOfMemory, QueryFailed } || pool_mod.PoolError)!u64 {
    const sql = if (std.mem.eql(u8, table_name, "repository_artifacts"))
        "SELECT COUNT(*)::text FROM repository_artifacts WHERE tenant_id = $1::uuid"
    else if (std.mem.eql(u8, table_name, "instance_waits"))
        "SELECT COUNT(*)::text FROM instance_waits WHERE resolved_at IS NULL"
    else
        "SELECT COUNT(*)::text FROM instance_projections WHERE tenant_id = $1::uuid";

    const conn = pool.acquire() catch return error.QueryFailed;
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        sql,
        if (std.mem.eql(u8, table_name, "instance_waits")) &.{} else &[_][]const u8{tenant_id},
    ) catch return error.QueryFailed;

    if (row == null) return 0;
    defer {
        for (row.?) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(row.?);
    }

    const text = row.?[0] orelse return 0;
    return std.fmt.parseUnsigned(u64, text, 10) catch return error.QueryFailed;
}

fn countRowsWhereRecent(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    table_name: []const u8,
    tenant_id: []const u8,
) (error{ OutOfMemory, QueryFailed } || pool_mod.PoolError)!u64 {
    _ = tenant_id;
    const sql = if (std.mem.eql(u8, table_name, "dead_letter_queue"))
        "SELECT COUNT(*)::text FROM dead_letter_queue WHERE COALESCE(last_retried_at, updated_at, created_at) >= NOW() - INTERVAL '1 day'"
    else
        "SELECT 0::text";

    const conn = pool.acquire() catch return error.QueryFailed;
    defer pool.release(conn);

    const row = conn.queryRow(allocator, sql, &.{}) catch return error.QueryFailed;
    if (row == null) return 0;
    defer {
        for (row.?) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(row.?);
    }

    const text = row.?[0] orelse return 0;
    return std.fmt.parseUnsigned(u64, text, 10) catch return error.QueryFailed;
}

fn sumColumn(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    table_name: []const u8,
    col_name: []const u8,
    tenant_id: []const u8,
) (error{ OutOfMemory, QueryFailed } || pool_mod.PoolError)!u64 {
    if (!std.mem.eql(u8, table_name, "repository_artifacts") or !std.mem.eql(u8, col_name, "byte_size")) {
        return 0;
    }

    const conn = pool.acquire() catch return error.QueryFailed;
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        "SELECT COALESCE(SUM(byte_size), 0)::text FROM repository_artifacts WHERE tenant_id = $1::uuid",
        &[_][]const u8{tenant_id},
    ) catch return error.QueryFailed;

    if (row == null) return 0;
    defer {
        for (row.?) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(row.?);
    }

    const text = row.?[0] orelse return 0;
    return std.fmt.parseUnsigned(u64, text, 10) catch return error.QueryFailed;
}

fn maxColumn(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    table_name: []const u8,
    col_name: []const u8,
    tenant_id: []const u8,
) (error{ OutOfMemory, QueryFailed } || pool_mod.PoolError)!u64 {
    _ = tenant_id;
    if (!std.mem.eql(u8, table_name, "dead_letter_queue") or !std.mem.eql(u8, col_name, "retry_count")) {
        return 0;
    }

    const conn = pool.acquire() catch return error.QueryFailed;
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        "SELECT COALESCE(MAX(retry_count), 0)::text FROM dead_letter_queue",
        &.{},
    ) catch return error.QueryFailed;

    if (row == null) return 0;
    defer {
        for (row.?) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(row.?);
    }

    const text = row.?[0] orelse return 0;
    return std.fmt.parseUnsigned(u64, text, 10) catch return error.QueryFailed;
}

fn tableStorageBytes(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    table_name: []const u8,
) (error{ OutOfMemory, QueryFailed } || pool_mod.PoolError)!u64 {
    const conn = pool.acquire() catch return error.QueryFailed;
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        "SELECT COALESCE(pg_total_relation_size($1::regclass), 0)::text",
        &[_][]const u8{table_name},
    ) catch return error.QueryFailed;

    if (row == null) return 0;
    defer {
        for (row.?) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(row.?);
    }

    const text = row.?[0] orelse return 0;
    return std.fmt.parseUnsigned(u64, text, 10) catch return error.QueryFailed;
}

test "classifyTarget maps known API paths" {
    try std.testing.expectEqual(@as(?QuotaGuardTarget, .entity_write), classifyTarget("/api/v1/entities/customer/1", .POST));
    try std.testing.expectEqual(@as(?QuotaGuardTarget, .file_write), classifyTarget("/api/v1/files/upload", .POST));
    try std.testing.expectEqual(@as(?QuotaGuardTarget, .sandbox_allocate), classifyTarget("/api/v1/sandbox/claim", .POST));
    try std.testing.expectEqual(@as(?QuotaGuardTarget, .agent_retry), classifyTarget("/api/v1/agent/jobs/123/retry", .POST));
    try std.testing.expectEqual(@as(?QuotaGuardTarget, .script_execute), classifyTarget("/api/v1/scripts/run", .POST));
    try std.testing.expectEqual(@as(?QuotaGuardTarget, null), classifyTarget("/api/v1/instances", .GET));
}
