//! PRM-02: Conflict pre-flight rejection
//!
//! Detects whether the target tenant has advanced past the version the source
//! was branched from, as the FIRST step of the promotion pipeline before any
//! transaction opens. A conflict exists when target_active_version > base_version.
//! On conflict: returns a typed ConflictRejection, appends DEFINITION_PROMOTION_REJECTED
//! in its own transaction, and moves no version pointer.
//!
//! Design artefact: src/design/prm-02-conflict-preflight-rejection.md

const std = @import("std");
const pool_mod = @import("pool");
const tenant_context_mod = @import("tenant_context");

// ── Public types ────────────────────────────────────────────────────────────────

/// Result of a conflict check. Non-null return means a conflict was detected.
pub const ConflictRejection = struct {
    /// The conflicting definition id on the target tenant (target_def.id).
    target_definition_id: []const u8,
    /// The version of the conflicting definition on the target tenant.
    target_version: u32,
    /// The source-side change description (which version the source branched from).
    source_change: []const u8,
    /// The target-side change description (which version the target is now at).
    target_change: []const u8,

    pub fn deinit(self: *const ConflictRejection, allocator: std.mem.Allocator) void {
        allocator.free(self.target_definition_id);
        allocator.free(self.source_change);
        allocator.free(self.target_change);
    }
};

pub const ConflictCheckError = error{
    PoolExhausted,
    TransactionFailed,
};

/// Checks for a promotion conflict before any transaction opens.
/// Reads target tenant's active version of process_key; compares with base_version.
/// On conflict: opens its own transaction to append DEFINITION_PROMOTION_REJECTED
/// and returns the rejection. On no conflict: returns null.
/// Called after computePromotionPlan(), before promotion_reviews insert.
pub fn rejectIfConflicts(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    target_tenant_id: []const u8,
    process_key: []const u8,
    base_version: u32,
    promotion_id: []const u8,
    source_tenant_id: []const u8,
    actor_id: []const u8,
) ConflictCheckError!?ConflictRejection {
    // Save and restore tenant context.
    const saved_ctx = blk: {
        const s = tenant_context_mod.get();
        break :blk if (s.len > 0) s else "";
    };
    defer if (saved_ctx.len > 0) tenant_context_mod.set(saved_ctx) else tenant_context_mod.clear();

    // Step 1: read target tenant's active version — NO lock, plain read.
    tenant_context_mod.set(target_tenant_id);

    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ConflictCheckError.PoolExhausted,
        else => ConflictCheckError.TransactionFailed,
    };
    defer pool.release(conn);

    // Security: all params bound as $N — no SQL string interpolation.
    const row = conn.queryRow(
        allocator,
        \\SELECT id::text, (version::int)::text
        \\FROM process_definitions
        \\WHERE name = $1 AND status = 'ACTIVE'
        \\LIMIT 1
    ,
        &[_][]const u8{process_key},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ConflictCheckError.PoolExhausted,
        else => ConflictCheckError.TransactionFailed,
    };

    // No ACTIVE version on target → no conflict.
    if (row == null) return null;

    const r = row.?;
    defer {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    }

    const target_def_id = r[0] orelse return null;
    const target_version_str = r[1] orelse return null;
    const target_version = std.fmt.parseInt(u32, target_version_str, 10) catch return null;

    // Conflict condition: target_active_version > base_version.
    if (target_version <= base_version) return null;

    // ── CONFLICT DETECTED ─────────────────────────────────────────────────────
    // Build rejection info (owned by caller).
    const target_def_id_dup = allocator.dupe(u8, target_def_id) catch return null;
    errdefer allocator.free(target_def_id_dup);

    const source_change = std.fmt.allocPrint(allocator, "branched from version {d}", .{base_version}) catch
        return null;
    errdefer allocator.free(source_change);

    const target_change = std.fmt.allocPrint(allocator, "target is now at version {d}", .{target_version}) catch
        return null;
    errdefer allocator.free(target_change);

    // Step 2: append DEFINITION_PROMOTION_REJECTED in its own independent transaction.
    // The event store is PER_TENANT after the PAR-01 partitioning (migration 1147
    // / GBL-112): `events` and `plat_event_idempotency` live in the target tenant
    // schema, so the event is appended under the target-tenant search_path
    // established at the top of this function (the same pattern rollback.zig
    // uses for DEFINITION_VERSION_ROLLED_BACK). public.events no longer exists.
    const rejection_payload = std.fmt.allocPrint(
        allocator,
        \\{{"promotion_id":"{s}","source_tenant_id":"{s}","target_tenant_id":"{s}","process_key":"{s}","target_definition_id":"{s}","target_version":{d},"base_version":{d},"reason":"Target tenant has advanced past base_version"}}
    ,
        .{
            promotion_id,
            source_tenant_id,
            target_tenant_id,
            process_key,
            target_def_id,
            target_version,
            base_version,
        },
    ) catch return null;
    errdefer allocator.free(rejection_payload);

    const idem_key = std.fmt.allocPrint(
        allocator,
        "DEFINITION_PROMOTION_REJECTED-{s}",
        .{promotion_id},
    ) catch return null;
    errdefer allocator.free(idem_key);

    // Append via direct connection — independent transaction.
    const write_conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => ConflictCheckError.PoolExhausted,
        else => ConflictCheckError.TransactionFailed,
    };
    defer pool.release(write_conn);

    write_conn.exec("BEGIN", &.{}) catch {};
    errdefer write_conn.exec("ROLLBACK", &.{}) catch {};

    // Insert into plat_event_idempotency for ES-03 idempotency.
    const plat_idem_rows = write_conn.query(
        allocator,
        \\INSERT INTO plat_event_idempotency (idempotency_key, event_id, created_at)
        \\VALUES ($1, gen_random_uuid(), NOW())
        \\ON CONFLICT (idempotency_key) DO NOTHING
        \\RETURNING event_id
    ,
        &.{idem_key},
    ) catch |err| {
        write_conn.exec("ROLLBACK", &.{}) catch {};
        _ = err;
        return ConflictCheckError.TransactionFailed;
    };
    defer plat_idem_rows.deinit();

    if (plat_idem_rows.rows.len == 0) {
        // Duplicate — another concurrent call already wrote this rejection.
        write_conn.exec("ROLLBACK", &.{}) catch {};
        return ConflictRejection{
            .target_definition_id = target_def_id_dup,
            .target_version = target_version,
            .source_change = source_change,
            .target_change = target_change,
        };
    }

    // INSERT the event.
    write_conn.exec(
        \\INSERT INTO events
        \\  (event_id, instance_id, event_type, payload, actor_id,
        \\   sequence_number, idempotency_key, metadata, tenant_id, global_seq)
        \\VALUES
        \\  ($1::uuid, $2::uuid, $3, $4::jsonb, $5::uuid,
        \\   0, $6, '{}'::jsonb, $7::uuid, nextval('events_global_seq'))
    ,
        &[_][]const u8{
            plat_idem_rows.rows[0][0] orelse "",
            "00000000-0000-0000-0000-000000000000",
            "DEFINITION_PROMOTION_REJECTED",
            rejection_payload,
            actor_id,
            idem_key,
            "00000000-0000-0000-0000-000000000000",
        },
    ) catch |err| {
        write_conn.exec("ROLLBACK", &.{}) catch {};
        _ = err;
        return ConflictCheckError.TransactionFailed;
    };

    write_conn.exec("COMMIT", &.{}) catch |err| {
        write_conn.exec("ROLLBACK", &.{}) catch {};
        _ = err;
        return ConflictCheckError.TransactionFailed;
    };

    return ConflictRejection{
        .target_definition_id = target_def_id_dup,
        .target_version = target_version,
        .source_change = source_change,
        .target_change = target_change,
    };
}

/// Checks multiple process_keys for conflicts and returns all rejections.
/// Called when a promotion plan contains multiple process definitions.
pub fn rejectIfConflictsMulti(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    target_tenant_id: []const u8,
    process_keys: []const []const u8,
    base_versions: []const u32,
    promotion_id: []const u8,
    source_tenant_id: []const u8,
    actor_id: []const u8,
) ConflictCheckError![]const ConflictRejection {
    var rejections = std.ArrayList(ConflictRejection).init(allocator);
    errdefer {
        for (rejections.items) |*r| r.deinit(allocator);
        rejections.deinit();
    }

    for (process_keys, base_versions) |pk, bv| {
        const rejection = try rejectIfConflicts(
            allocator,
            pool,
            target_tenant_id,
            pk,
            bv,
            promotion_id,
            source_tenant_id,
            actor_id,
        );
        if (rejection) |*r| {
            try rejections.append(r.*);
        }
    }

    return try rejections.toOwnedSlice();
}
