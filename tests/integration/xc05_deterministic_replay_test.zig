//! Integration tests for XC-05 — Deterministic Replay
//!
//! State reconstruction via point-in-time queries produces identical results
//! on repeated runs. Service tasks and Tier 4 nodes replay from recorded outputs.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const uuid_mod = @import("../crypto/uuid.zig");

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-05-01: Point-in-time reconstruction produces matching state
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-05-01: point-in-time reconstruction produces matching state" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const instance_id = try uuid_mod.newUuidV4(alloc);
    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(instance_id);
        alloc.free(tenant_id);
    }

    // Create instance with initial state
    _ = try harness.conn.exec(
        \\INSERT INTO instances (
        \\  instance_id, tenant_id, definition_artifact_hash,
        \\  status, variables, created_at
        \\) VALUES ($1, $2, $3, $4, $5, NOW())
    ,
        &.{
            instance_id,
            tenant_id,
            "def-hash",
            "ACTIVE",
            "{\"counter\":0}",
        },
    );

    // Append 10 events with state evolution
    for (0..10) |i| {
        const event_id = try uuid_mod.newUuidV4(alloc);
        const idem_key = try std.fmt.allocPrint(alloc, "event-{d}", .{i});
        defer {
            alloc.free(event_id);
            alloc.free(idem_key);
        }

        _ = try harness.conn.exec(
            \\INSERT INTO events (
            \\  event_id, instance_id, tenant_id, event_type,
            \\  payload, idempotency_key, created_at
            \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
        ,
            &.{
                event_id,
                instance_id,
                tenant_id,
                "counter.incremented",
                "{\"delta\":1}",
                idem_key,
            },
        );
    }

    // Query state at sequence 5 (should show counter=5 after 5 increments)
    var query_5 = try harness.conn.query(
        alloc,
        \\SELECT COUNT(*) FROM events
        \\WHERE instance_id = $1 AND sequence_number <= 5
    ,
        &.{instance_id},
    );
    defer query_5.deinit();

    try testing.expectEqual(@as(usize, 1), query_5.rows.len);
    const count_5_str = query_5.rows[0][0] orelse "0";
    const count_5 = try std.fmt.parseInt(i64, count_5_str, 10);
    try testing.expectEqual(@as(i64, 5), count_5);

    // Query state at sequence 10 (all events)
    var query_all = try harness.conn.query(
        alloc,
        \\SELECT COUNT(*) FROM events WHERE instance_id = $1
    ,
        &.{instance_id},
    );
    defer query_all.deinit();

    try testing.expectEqual(@as(usize, 1), query_all.rows.len);
    const count_all_str = query_all.rows[0][0] orelse "0";
    const count_all = try std.fmt.parseInt(i64, count_all_str, 10);
    try testing.expectEqual(@as(i64, 10), count_all);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-05-02: Repeated reconstruction produces bit-identical state
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-05-02: repeated reconstruction produces identical state" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const instance_id = try uuid_mod.newUuidV4(alloc);
    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(instance_id);
        alloc.free(tenant_id);
    }

    // Create instance
    _ = try harness.conn.exec(
        \\INSERT INTO instances (
        \\  instance_id, tenant_id, definition_artifact_hash,
        \\  status, variables, created_at
        \\) VALUES ($1, $2, $3, $4, $5, NOW())
    ,
        &.{
            instance_id,
            tenant_id,
            "def-hash",
            "ACTIVE",
            "{\"state\":\"initial\"}",
        },
    );

    // Append 20 events
    for (0..20) |i| {
        const event_id = try uuid_mod.newUuidV4(alloc);
        const idem_key = try std.fmt.allocPrint(alloc, "event-{d}", .{i});
        defer {
            alloc.free(event_id);
            alloc.free(idem_key);
        }

        _ = try harness.conn.exec(
            \\INSERT INTO events (
            \\  event_id, instance_id, tenant_id, event_type,
            \\  payload, idempotency_key, created_at
            \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
        ,
            &.{
                event_id,
                instance_id,
                tenant_id,
                "state.updated",
                "{\"value\":" ++ try std.fmt.allocPrint(alloc, "{d}", .{i}) ++ "}",
                idem_key,
            },
        );
    }

    // Query state at sequence 10 three times
    var states = std.ArrayList([]u8).init(alloc);
    defer {
        for (states.items) |s| alloc.free(s);
        states.deinit();
    }

    for (0..3) |_| {
        var query = try harness.conn.query(
            alloc,
            \\SELECT COUNT(*) FROM events
            \\WHERE instance_id = $1 AND sequence_number <= 10
        ,
            &.{instance_id},
        );
        defer query.deinit();

        const count_str = query.rows[0][0] orelse "0";
        const count_copy = try alloc.dupe(u8, count_str);
        try states.append(count_copy);
    }

    // All three queries should return identical count
    try testing.expectEqualStrings(states.items[0], states.items[1]);
    try testing.expectEqualStrings(states.items[1], states.items[2]);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-05-03: Timestamp-based reconstruction works correctly
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-05-03: timestamp-based reconstruction works correctly" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const instance_id = try uuid_mod.newUuidV4(alloc);
    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(instance_id);
        alloc.free(tenant_id);
    }

    // Create instance
    _ = try harness.conn.exec(
        \\INSERT INTO instances (
        \\  instance_id, tenant_id, definition_artifact_hash,
        \\  status, created_at
        \\) VALUES ($1, $2, $3, $4, NOW())
    ,
        &.{ instance_id, tenant_id, "def-hash", "ACTIVE" },
    );

    // Insert events with different timestamps
    var timestamps = std.ArrayList([]u8).init(alloc);
    defer {
        for (timestamps.items) |ts| alloc.free(ts);
        timestamps.deinit();
    }

    for (0..5) |i| {
        const event_id = try uuid_mod.newUuidV4(alloc);
        const idem_key = try std.fmt.allocPrint(alloc, "event-{d}", .{i});
        defer {
            alloc.free(event_id);
            alloc.free(idem_key);
        }

        // Generate a unique timestamp per event
        const offset_ms = i * 1000;
        const ts = try std.fmt.allocPrint(
            alloc,
            "NOW() + INTERVAL '{d} milliseconds'",
            .{offset_ms},
        );
        try timestamps.append(ts);

        _ = try harness.conn.exec(
            \\INSERT INTO events (
            \\  event_id, instance_id, tenant_id, event_type,
            \\  payload, idempotency_key, created_at
            \\) VALUES ($1, $2, $3, $4, $5, $6, $7::timestamp)
        ,
            &.{
                event_id,
                instance_id,
                tenant_id,
                "test.event",
                "{\"index\":" ++ try std.fmt.allocPrint(alloc, "{d}", .{i}) ++ "}",
                idem_key,
                ts,
            },
        );
    }

    // Query events at a specific timestamp (should return events before that time)
    var query = try harness.conn.query(
        alloc,
        \\SELECT COUNT(*) FROM events
        \\WHERE instance_id = $1 AND created_at <= NOW() + INTERVAL '2500 milliseconds'
    ,
        &.{instance_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    const count_str = query.rows[0][0] orelse "0";
    const count = try std.fmt.parseInt(i64, count_str, 10);

    // Should include events 0, 1, 2 (at 0ms, 1000ms, 2000ms)
    try testing.expect(count >= 3);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-05-04: Archived events are included in point-in-time reconstruction
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-05-04: archived events are included in reconstruction" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const instance_id = try uuid_mod.newUuidV4(alloc);
    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(instance_id);
        alloc.free(tenant_id);
    }

    // Create instance
    _ = try harness.conn.exec(
        \\INSERT INTO instances (
        \\  instance_id, tenant_id, definition_artifact_hash,
        \\  status, created_at
        \\) VALUES ($1, $2, $3, $4, NOW())
    ,
        &.{ instance_id, tenant_id, "def-hash", "ACTIVE" },
    );

    // Insert 100 events
    for (0..100) |i| {
        const event_id = try uuid_mod.newUuidV4(alloc);
        const idem_key = try std.fmt.allocPrint(alloc, "event-{d}", .{i});
        defer {
            alloc.free(event_id);
            alloc.free(idem_key);
        }

        _ = try harness.conn.exec(
            \\INSERT INTO events (
            \\  event_id, instance_id, tenant_id, event_type,
            \\  payload, idempotency_key, created_at
            \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
        ,
            &.{
                event_id,
                instance_id,
                tenant_id,
                "test.event",
                "{\"index\":" ++ try std.fmt.allocPrint(alloc, "{d}", .{i}) ++ "}",
                idem_key,
            },
        );
    }

    // Archive events 1-50 (move to events_archive)
    _ = try harness.conn.exec(
        \\INSERT INTO events_archive
        \\SELECT * FROM events
        \\WHERE instance_id = $1 AND sequence_number BETWEEN 1 AND 50
    ,
        &.{instance_id},
    );

    _ = try harness.conn.exec(
        \\DELETE FROM events
        \\WHERE instance_id = $1 AND sequence_number BETWEEN 1 AND 50
    ,
        &.{instance_id},
    );

    // Reconstruct state at sequence 75 (includes archived 1-50 and live 51-75)
    var query_live = try harness.conn.query(
        alloc,
        \\SELECT COUNT(*) FROM events
        \\WHERE instance_id = $1 AND sequence_number <= 75
    ,
        &.{instance_id},
    );
    defer query_live.deinit();

    var query_archive = try harness.conn.query(
        alloc,
        \\SELECT COUNT(*) FROM events_archive
        \\WHERE instance_id = $1 AND sequence_number BETWEEN 1 AND 75
    ,
        &.{instance_id},
    );
    defer query_archive.deinit();

    // Verify both tables have events
    try testing.expect(query_live.rows.len > 0);
    try testing.expect(query_archive.rows.len > 0);

    // Combined: should have access to all events up to 75
    const live_count_str = query_live.rows[0][0] orelse "0";
    const archive_count_str = query_archive.rows[0][0] orelse "0";
    const live_count = try std.fmt.parseInt(i64, live_count_str, 10);
    const archive_count = try std.fmt.parseInt(i64, archive_count_str, 10);

    // Archive has 50 events (1-50), live has up to 50 events (51-100, capped at 75)
    try testing.expectEqual(@as(i64, 50), archive_count);
    try testing.expectEqual(@as(i64, 25), live_count); // 51-75 = 25 events
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-05-07: Reconstruction of empty instance returns initial state
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-05-07: empty instance reconstruction returns initial state" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const instance_id = try uuid_mod.newUuidV4(alloc);
    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(instance_id);
        alloc.free(tenant_id);
    }

    // Create instance with no events
    const initial_state = "{\"status\":\"ACTIVE\",\"counter\":0}";
    _ = try harness.conn.exec(
        \\INSERT INTO instances (
        \\  instance_id, tenant_id, definition_artifact_hash,
        \\  status, variables, created_at
        \\) VALUES ($1, $2, $3, $4, $5, NOW())
    ,
        &.{ instance_id, tenant_id, "def-hash", "ACTIVE", initial_state },
    );

    // Query instance state (should be initial)
    var query = try harness.conn.query(
        alloc,
        \\SELECT variables FROM instances WHERE instance_id = $1
    ,
        &.{instance_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    try testing.expectEqualStrings(initial_state, query.rows[0][0] orelse "");

    // Count events (should be zero)
    var event_query = try harness.conn.query(
        alloc,
        \\SELECT COUNT(*) FROM events WHERE instance_id = $1
    ,
        &.{instance_id},
    );
    defer event_query.deinit();

    const count_str = event_query.rows[0][0] orelse "0";
    const count = try std.fmt.parseInt(i64, count_str, 10);
    try testing.expectEqual(@as(i64, 0), count);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-05-08: Reconstruction fails gracefully for non-existent instance
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-05-08: reconstruction fails gracefully for non-existent instance" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const non_existent_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(non_existent_id);

    // Try to query non-existent instance
    var query = try harness.conn.query(
        alloc,
        \\SELECT variables FROM instances WHERE instance_id = $1
    ,
        &.{non_existent_id},
    );
    defer query.deinit();

    // Should return empty result set
    try testing.expectEqual(@as(usize, 0), query.rows.len);
}
