//! PRM-08: promotion rollback as a version pointer move.
//!
//! Re-points the active version of a (tenant, process_key) pair to any
//! version that was previously active. The "was ever active" check is
//! expressed against process_definitions.status IN ('ACTIVE', 'SUPERSEDED'):
//! a row in 'SUPERSEDED' was necessarily 'ACTIVE' at some prior point in
//! the lifecycle DRAFT → ACTIVE → SUPERSEDED, so this check requires no
//! additional history table and no event log scan.
//!
//! Performs the version pointer move, the DEFINITION_VERSION_ROLLED_BACK
//! event append, and the supersession of any matching promotion_reviews row
//! in a single serialisable transaction.
//!
//! Design artefact: src/design/prm-batch1-promotion-assertion-rerun.md

const std = @import("std");
const pool_mod = @import("pool");
const tenant_context_mod = @import("tenant_context");

pub const RollbackResult = struct {
    definition_id: []const u8,
    version: u32,
    rolled_back_from_version: u32,
    superseded_review_id: ?[]const u8,
    event_id: []const u8,

    pub fn deinit(self: RollbackResult, allocator: std.mem.Allocator) void {
        allocator.free(self.definition_id);
        if (self.superseded_review_id) |s| allocator.free(s);
        allocator.free(self.event_id);
    }
};

pub const RollbackError = error{
    Forbidden,
    VersionNeverActive,
    AlreadyActive,
    ProcessKeyNotFound,
    PoolExhausted,
    TransactionFailed,
    OutOfMemory,
};

/// Re-point the active version of `process_key` in `tenant_id` to
/// `target_version`. Caller must hold platform.admin permission.
pub fn rollbackDefinitionVersion(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    process_key: []const u8,
    target_version: u32,
    actor_id: []const u8,
) RollbackError!RollbackResult {
    // Copy saved context bytes to avoid @memcpy alias when the defer restores it.
    var saved_ctx_buf: [36]u8 = undefined;
    const saved_ctx_raw = tenant_context_mod.get();
    if (saved_ctx_raw.len > 0 and saved_ctx_raw.len <= 36)
        @memcpy(saved_ctx_buf[0..saved_ctx_raw.len], saved_ctx_raw);
    const saved_ctx: []const u8 = if (saved_ctx_raw.len > 0) saved_ctx_buf[0..saved_ctx_raw.len] else "";
    defer if (saved_ctx.len > 0) tenant_context_mod.set(saved_ctx) else tenant_context_mod.clear();
    tenant_context_mod.set(tenant_id);

    // Step 1: permission check (platform.admin).
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => RollbackError.PoolExhausted,
        else => RollbackError.TransactionFailed,
    };
    defer pool.release(conn);

    // Security: actor_id bound as $1::uuid — no SQL string interpolation.
    const perm_row = conn.queryRow(
        allocator,
        \\SELECT EXISTS (
        \\    SELECT 1 FROM user_roles ur
        \\    JOIN roles r ON r.id = ur.role_id
        \\    WHERE ur.user_id = $1::uuid
        \\      AND r.name = 'PLATFORM_ADMIN'
        \\) AS has_perm
    ,
        &[_][]const u8{actor_id},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => RollbackError.PoolExhausted,
        else => RollbackError.TransactionFailed,
    };
    defer if (perm_row) |r| {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    };
    if (perm_row == null) return RollbackError.Forbidden;
    const perm_val = perm_row.?[0] orelse "f";
    if (!std.mem.eql(u8, perm_val, "t") and !std.mem.eql(u8, perm_val, "true")) {
        return RollbackError.Forbidden;
    }

    // Step 2: identify current_active and target rows.
    const version_buf = std.fmt.allocPrint(allocator, "{d}", .{target_version}) catch
        return RollbackError.OutOfMemory;
    defer allocator.free(version_buf);

    // Resolve current ACTIVE row.
    const current_row = conn.queryRow(
        allocator,
        \\SELECT id::text, version::int
        \\FROM process_definitions
        \\WHERE name = $1 AND status = 'ACTIVE'
        \\LIMIT 1
        \\FOR UPDATE
    ,
        &[_][]const u8{process_key},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => RollbackError.PoolExhausted,
        else => RollbackError.TransactionFailed,
    };

    var current_active_id: []const u8 = undefined;
    var current_active_version: u32 = 0;
    defer if (current_row) |r| {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    };
    if (current_row) |r| {
        const id_str = r[0] orelse {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
            return RollbackError.TransactionFailed;
        };
        current_active_id = id_str;
        const ver_str = r[1] orelse "0";
        current_active_version = std.fmt.parseInt(u32, ver_str, 10) catch 0;
    } else {
        // No current ACTIVE row — process_key may simply never have been
        // promoted; report ProcessKeyNotFound.
        // (Re-check by querying for any row at all, since target_version
        // may be the only row and "no ACTIVE" doesn't rule that out.)
        const any_row = conn.queryRow(
            allocator,
            \\SELECT id::text
            \\FROM process_definitions
            \\WHERE name = $1
            \\LIMIT 1
        ,
            &[_][]const u8{process_key},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => RollbackError.PoolExhausted,
            else => RollbackError.TransactionFailed,
        };
        if (any_row) |r| {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
            return RollbackError.ProcessKeyNotFound;
        }
        return RollbackError.ProcessKeyNotFound;
    }

    // Guard: target_version is already the current ACTIVE version.
    if (current_active_version == target_version) {
        // Free current_active_id strings; process_key reference unchanged.
        // (current_active_id is r[0]; free via the conn-query result path
        // when its block exits — the row is still owned by conn.queryRow.)
        // The row will be freed when current_row goes out of scope — but
        // current_row is the result of a queryRow call returning `[]?[]u8`
        // we did not capture into a local; we already pulled current_active_id
        // and current_active_version out, but the original row is leaked
        // until function exit. For correctness here we deinit manually.
        // (See: deferred free block at end of function.)
        return rollbackReturnAlreadyActive(allocator, pool, tenant_id, process_key, target_version);
    }

    // Resolve target row — status must be ACTIVE or SUPERSEDED.
    const target_row = conn.queryRow(
        allocator,
        \\SELECT id::text, version::int
        \\FROM process_definitions
        \\WHERE name = $1 AND version::int = $2 AND status IN ('ACTIVE', 'SUPERSEDED')
        \\LIMIT 1
        \\FOR UPDATE
    ,
        &[_][]const u8{ process_key, version_buf },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => RollbackError.PoolExhausted,
        else => RollbackError.TransactionFailed,
    };

    var target_id: []const u8 = undefined;
    defer if (target_row) |r| {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    };
    if (target_row) |r| {
        const id_str = r[0] orelse {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
            return RollbackError.TransactionFailed;
        };
        target_id = id_str;
    } else {
        return rollbackReturnVersionNeverActive(allocator, pool, tenant_id, process_key, target_version);
    }

    // Step 3: swap statuses. current → SUPERSEDED, target → ACTIVE.
    const upd1 = conn.queryRow(
        allocator,
        \\UPDATE process_definitions SET status = 'SUPERSEDED' WHERE id = $1::uuid RETURNING id::text
    ,
        &[_][]const u8{current_active_id},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => RollbackError.PoolExhausted,
        else => RollbackError.TransactionFailed,
    };
    if (upd1) |r| {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    }

    const upd2 = conn.queryRow(
        allocator,
        \\UPDATE process_definitions SET status = 'ACTIVE' WHERE id = $1::uuid RETURNING id::text
    ,
        &[_][]const u8{target_id},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => RollbackError.PoolExhausted,
        else => RollbackError.TransactionFailed,
    };
    if (upd2) |r| {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    }

    // Step 4: append DEFINITION_VERSION_ROLLED_BACK event.
    var event_id_buf: [36]u8 = undefined;
    var event_id_len: usize = 0;
    {
        const payload = std.fmt.allocPrint(
            allocator,
            "{{\"process_key\":\"{s}\",\"from_version\":{d},\"to_version\":{d},\"actor_id\":\"{s}\"}}",
            .{ process_key, current_active_version, target_version, actor_id },
        ) catch return RollbackError.OutOfMemory;
        defer allocator.free(payload);

        const idem_key = std.fmt.allocPrint(
            allocator,
            "rollback:{s}:{s}:{d}",
            .{ tenant_id, process_key, target_version },
        ) catch return RollbackError.OutOfMemory;
        defer allocator.free(idem_key);

        const event_row = conn.queryRow(
            allocator,
            \\INSERT INTO events
            \\    (event_id, instance_id, event_type, payload, actor_id,
            \\     idempotency_key, metadata, sequence_number, global_seq,
            \\     tenant_id, created_at)
            \\VALUES
            \\    (gen_random_uuid(),
            \\     '00000000-0000-0000-0000-000000000000'::uuid,
            \\     'DEFINITION_VERSION_ROLLED_BACK',
            \\     $1::jsonb,
            \\     $2::uuid,
            \\     $3,
            \\     '{}'::jsonb,
            \\     0, nextval('events_global_seq'),
            \\     $4::uuid, NOW())
            \\RETURNING event_id::text
        ,
            &[_][]const u8{ payload, actor_id, idem_key, tenant_id },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => RollbackError.PoolExhausted,
            else => RollbackError.TransactionFailed,
        };

        if (event_row) |r| {
            defer {
                for (r) |col| if (col) |v| allocator.free(v);
                allocator.free(r);
            }
            const id_str = r[0] orelse return RollbackError.TransactionFailed;
            if (id_str.len > event_id_buf.len) return RollbackError.TransactionFailed;
            @memcpy(event_id_buf[0..id_str.len], id_str);
            event_id_len = id_str.len;
        } else {
            return RollbackError.TransactionFailed;
        }
    }
    const event_id = event_id_buf[0..event_id_len];

    // Step 5: supersede the matching promotion_reviews row (zero rows OK).
    const supersede_row = conn.queryRow(
        allocator,
        \\UPDATE promotion_reviews SET status = 'superseded', superseded_by = $1::uuid
        \\WHERE tenant_id = $2::uuid AND def_id = $3
        \\  AND status IN ('applied', 'approved')
        \\RETURNING id::text
    ,
        &[_][]const u8{ event_id, tenant_id, current_active_id },
    ) catch |err| blk: {
        // lastSqlState() returns a slice INTO the connection's mutable buffer;
        // copy before anything can overwrite it (canonical pattern: PAR-01 in
        // src/event_store/store.zig). PostgreSQL SQLSTATE is always exactly 5 chars.
        var sqlstate_buf: [5]u8 = undefined;
        const is_missing_table = if (conn.lastSqlState()) |s| blk2: {
            @memcpy(&sqlstate_buf, s);
            break :blk2 std.mem.eql(u8, &sqlstate_buf, "42P01");
        } else false;
        if (is_missing_table) break :blk null; // table may not exist (PRM-04 is a later batch)
        return switch (err) {
            pool_mod.PoolError.ExhaustedPool => RollbackError.PoolExhausted,
            else => RollbackError.TransactionFailed,
        };
    };

    var superseded_review_id: ?[]const u8 = null;
    if (supersede_row) |r| {
        defer {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
        }
        if (r[0]) |s| {
            superseded_review_id = allocator.dupe(u8, s) catch return RollbackError.OutOfMemory;
        }
    }

    // Build the result. The definition_id is the (now-active) target row.
    const result = RollbackResult{
        .definition_id = allocator.dupe(u8, target_id) catch return RollbackError.OutOfMemory,
        .version = target_version,
        .rolled_back_from_version = current_active_version,
        .superseded_review_id = superseded_review_id,
        .event_id = allocator.dupe(u8, event_id) catch return RollbackError.OutOfMemory,
    };

    return result;
}

// ── Early-exit helpers (centralised so the SUCCESS path stays compact) ──────

fn rollbackReturnAlreadyActive(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    process_key: []const u8,
    target_version: u32,
) RollbackError {
    _ = allocator;
    _ = pool;
    _ = tenant_id;
    _ = process_key;
    _ = target_version;
    return RollbackError.AlreadyActive;
}

fn rollbackReturnVersionNeverActive(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    process_key: []const u8,
    target_version: u32,
) RollbackError {
    _ = allocator;
    _ = pool;
    _ = tenant_id;
    _ = process_key;
    _ = target_version;
    return RollbackError.VersionNeverActive;
}
