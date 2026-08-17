// Integration tests for PAR-02's plat_partition_catalog /
// plat_partition_maintenance_run_log tables (migration
// 1148_par02_partition_catalog.sql), hand-written from
// templates/specs/par-02-partition-catalog.migration.yaml's test scaffold
// (codegen's generated CUSTOM-block placeholders replaced with real
// assertions here, following the SAVEPOINT-around-a-CHECK-violation pattern
// tests/integration/iss107_tenant_storage_mode_test.zig already establishes —
// TestHarness.h.conn sits inside one open transaction for the whole test, so
// a server error inside it must be contained by a SAVEPOINT or the entire
// harness transaction aborts).
//
// BPM_TEST_DB_URL must be set; the test connects to a real PostgreSQL.
const std = @import("std");
const helpers = @import("helpers.zig");
const portable_env = @import("env");
const bpm = @import("bpm");

fn randomSuffix(h: *helpers.TestHarness, allocator: std.mem.Allocator) ![]u8 {
    const id = try h.newUuidString(allocator);
    defer allocator.free(id);
    return std.fmt.allocPrint(allocator, "par02_{s}", .{id});
}

// TC (PAR-02): a second row for the same table_name violates
// plat_partition_catalog_table_uq.
test "par02_partition_catalog: unique_constraint_on_table_name" {
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const table_name = try randomSuffix(&h, alloc);
    defer alloc.free(table_name);

    try h.conn.exec(
        "INSERT INTO plat_partition_catalog (table_name, parent_table, range_start, range_end) " ++
            "VALUES ($1, 'events', NOW(), NOW() + interval '1 month')",
        &.{table_name},
    );

    try h.conn.exec("BEGIN", &.{});
    try h.conn.exec("SAVEPOINT before_dup", &.{});
    const dup_result = h.conn.exec(
        "INSERT INTO plat_partition_catalog (table_name, parent_table, range_start, range_end) " ++
            "VALUES ($1, 'events', NOW(), NOW() + interval '1 month')",
        &.{table_name},
    );
    try std.testing.expectError(error.ServerError, dup_result);
    try h.conn.exec("ROLLBACK TO SAVEPOINT before_dup", &.{});

    var rows = try h.conn.query(
        alloc,
        "SELECT COUNT(*) FROM plat_partition_catalog WHERE table_name = $1",
        &.{table_name},
    );
    defer rows.deinit();
    const count = std.fmt.parseInt(i64, rows.rows[0][0] orelse "0", 10) catch -1;
    try std.testing.expectEqual(@as(i64, 1), count);
}

// TC (PAR-02): a state outside ATTACHED/DETACHED/ORPHAN_PARTITION/DROPPED is
// rejected by the CHECK constraint.
test "par02_partition_catalog: state_check_constraint_rejects_unknown_value" {
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const table_name = try randomSuffix(&h, alloc);
    defer alloc.free(table_name);

    try h.conn.exec("BEGIN", &.{});
    try h.conn.exec("SAVEPOINT before_bogus", &.{});
    const result = h.conn.exec(
        "INSERT INTO plat_partition_catalog (table_name, parent_table, range_start, range_end, state) " ++
            "VALUES ($1, 'events', NOW(), NOW() + interval '1 month', 'BOGUS')",
        &.{table_name},
    );
    try std.testing.expectError(error.ServerError, result);
    try h.conn.exec("ROLLBACK TO SAVEPOINT before_bogus", &.{});

    var rows = try h.conn.query(
        alloc,
        "SELECT COUNT(*) FROM plat_partition_catalog WHERE table_name = $1",
        &.{table_name},
    );
    defer rows.deinit();
    const count = std.fmt.parseInt(i64, rows.rows[0][0] orelse "0", 10) catch -1;
    try std.testing.expectEqual(@as(i64, 0), count);
}

// TC (PAR-02 AC2): a second INSERT for the same run_date is absorbed silently
// by ON CONFLICT DO NOTHING — the mechanism the daily job's idempotency gate
// relies on. Uses a synthetic far-future run_date (rather than CURRENT_DATE)
// so this test cannot collide with a concurrently-running maintenance job or
// another test in the same suite that also claims today's row.
test "par02_partition_catalog: run_log_unique_per_date_enforces_idempotency" {
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    // A random-ish far-future date derived from the test's own UUID entropy,
    // rather than a hardcoded literal, to avoid collision with other test
    // runs sharing this database (T010 per docs/guides/test_infrastructure_guide.md).
    const uuid_str = try h.newUuidString(alloc);
    defer alloc.free(uuid_str);
    const day_offset: u32 = (@as(u32, uuid_str[0]) % 200) + 1;
    const day_offset_str = try std.fmt.allocPrint(alloc, "{d}", .{day_offset});
    defer alloc.free(day_offset_str);

    var first = try h.conn.query(
        alloc,
        "INSERT INTO plat_partition_maintenance_run_log (run_date, future_partition_count) " ++
            "VALUES (CURRENT_DATE + ($1 || ' days')::interval, 3) RETURNING id",
        &.{day_offset_str},
    );
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 1), first.rows.len);

    var second = try h.conn.query(
        alloc,
        "INSERT INTO plat_partition_maintenance_run_log (run_date, future_partition_count) " ++
            "VALUES (CURRENT_DATE + ($1 || ' days')::interval, 3) ON CONFLICT (run_date) DO NOTHING RETURNING id",
        &.{day_offset_str},
    );
    defer second.deinit();

    // ON CONFLICT DO NOTHING absorbed the second insert silently — no error,
    // matching PAR-02 AC2's "raises no error", and RETURNING yields zero rows.
    try std.testing.expectEqual(@as(usize, 0), second.rows.len);
}

// TC-PAR-02-09 (PAR-02 AC5): ensurePartitionAttached emits EXECUTION_PARTITION_CREATED
// in the events table (via Store.appendPlatform).
//
// Verifies that each new partition creation appends exactly one platform event and
// that a subsequent call for already-ATTACHED partitions emits no additional events
// (idempotency at the event-emission level).
test "par02_ac5: ensurePartitionAttached emits EXECUTION_PARTITION_CREATED" {
    const alloc = std.testing.allocator;
    // Ensure migrations are applied.
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const env = portable_env.globalEnviron();
    const url = env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
    defer alloc.free(url);

    // Create pool, registry, store — same pattern as event_store_integration_test.zig.
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try bpm.pool.Pool.init(std.testing.io, alloc, bpm.pool.PoolConfig{
        .url = url,
        .pool_size = 3,
    });
    defer pool.deinit();
    var registry = bpm.registry.Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = bpm.store.Store.init(alloc, &pool, &registry);
    defer store.deinit();

    // Delete today's run-log row so runMaintenanceCycle() always runs fresh,
    // even when this test is re-run against the same DB on the same day.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        conn.exec("DELETE FROM plat_partition_maintenance_run_log WHERE run_date = CURRENT_DATE", &.{}) catch {};
    }

    // Count EXECUTION_PARTITION_CREATED events written by prior test runs.
    const count_before: i64 = blk: {
        const conn = try pool.acquire();
        defer pool.release(conn);
        var rows = try conn.query(
            alloc,
            "SELECT COUNT(*) FROM events WHERE instance_id = $1 AND event_type = 'EXECUTION_PARTITION_CREATED'",
            &.{bpm.store.PLATFORM_INSTANCE_ID},
        );
        defer rows.deinit();
        if (rows.rows.len > 0 and rows.rows[0].len > 0) {
            break :blk std.fmt.parseInt(i64, rows.rows[0][0] orelse "0", 10) catch 0;
        }
        break :blk 0;
    };

    // Run the daily maintenance cycle with a store so appendPlatform is called.
    var scheduler = bpm.partition_maintenance.PartitionMaintenanceScheduler.initWithStore(
        &pool,
        bpm.partition_maintenance.PartitionMaintenanceConfig{},
        &store,
    );
    const result = try scheduler.runMaintenanceCycle(alloc);
    try std.testing.expect(result.ran);
    try std.testing.expect(result.partitions_created > 0);

    // Exactly one EXECUTION_PARTITION_CREATED event per partition created.
    const count_after: i64 = blk: {
        const conn = try pool.acquire();
        defer pool.release(conn);
        var rows = try conn.query(
            alloc,
            "SELECT COUNT(*) FROM events WHERE instance_id = $1 AND event_type = 'EXECUTION_PARTITION_CREATED'",
            &.{bpm.store.PLATFORM_INSTANCE_ID},
        );
        defer rows.deinit();
        if (rows.rows.len > 0 and rows.rows[0].len > 0) {
            break :blk std.fmt.parseInt(i64, rows.rows[0][0] orelse "0", 10) catch 0;
        }
        break :blk 0;
    };
    try std.testing.expectEqual(count_before + @as(i64, @intCast(result.partitions_created)), count_after);

    // Idempotency: delete the run-log and re-run; all partitions are already ATTACHED
    // so ensurePartitionAttached() returns false for each, emitting no new events.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        conn.exec("DELETE FROM plat_partition_maintenance_run_log WHERE run_date = CURRENT_DATE", &.{}) catch {};
    }
    const result2 = try scheduler.runMaintenanceCycle(alloc);
    try std.testing.expect(result2.ran);
    try std.testing.expectEqual(@as(u32, 0), result2.partitions_created);

    const count_idempotent: i64 = blk: {
        const conn = try pool.acquire();
        defer pool.release(conn);
        var rows = try conn.query(
            alloc,
            "SELECT COUNT(*) FROM events WHERE instance_id = $1 AND event_type = 'EXECUTION_PARTITION_CREATED'",
            &.{bpm.store.PLATFORM_INSTANCE_ID},
        );
        defer rows.deinit();
        if (rows.rows.len > 0 and rows.rows[0].len > 0) {
            break :blk std.fmt.parseInt(i64, rows.rows[0][0] orelse "0", 10) catch 0;
        }
        break :blk 0;
    };
    // No new events emitted on idempotent re-run.
    try std.testing.expectEqual(count_after, count_idempotent);
}
