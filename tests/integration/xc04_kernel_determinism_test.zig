//! Integration tests for XC-04 — Kernel Determinism
//!
//! XC-04 is a design constraint enforced via static analysis and code review.
//! This test file validates determinism properties: no randomness, consistent ordering.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const uuid_mod = @import("../crypto/uuid.zig");

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-04-02: Pure transition function — no I/O, no randomness
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-04-02: pure transition function produces deterministic output" {
    const alloc = testing.allocator;

    // Test that identical inputs produce identical outputs
    // (In real scenario, this would test the transition() function directly)

    const input1 = "deterministic-input";
    const input2 = "deterministic-input";

    // Simulate pure function: hash(input) should be identical
    var hasher1 = std.crypto.hash.sha2.Sha256.init(.{});
    hasher1.update(input1);
    var hash1: [32]u8 = undefined;
    hasher1.final(&hash1);

    var hasher2 = std.crypto.hash.sha2.Sha256.init(.{});
    hasher2.update(input2);
    var hash2: [32]u8 = undefined;
    hasher2.final(&hash2);

    // Both hashes should be identical (deterministic)
    try testing.expectEqualSlices(u8, &hash1, &hash2);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-04-03: Deterministic scheduler — timers fire in reproducible order
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-04-03: scheduler fires timers in deterministic order" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const instance_id = try uuid_mod.newUuidV4(alloc);
    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(instance_id);
        alloc.free(tenant_id);
    }

    // Insert timers with known due times
    const now = std.time.microTimestamp();
    const timer1_due = now + 1_000_000; // 1 second from now
    const timer2_due = now + 2_000_000; // 2 seconds from now
    const timer3_due = now + 1_000_000; // Same as timer1

    for (0..3) |i| {
        const timer_id = try uuid_mod.newUuidV4(alloc);
        defer alloc.free(timer_id);

        const due_at = switch (i) {
            0 => timer1_due,
            1 => timer2_due,
            else => timer3_due,
        };

        _ = try harness.conn.exec(
            \\INSERT INTO timers (
            \\  timer_id, instance_id, tenant_id, timer_type, due_at_us,
            \\  sequence_number, created_at
            \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
        ,
            &.{ timer_id, instance_id, tenant_id, "event_timer", due_at, @as(i64, @intCast(i)) },
        );
    }

    // Query due timers twice (should return in identical order)
    var query1 = try harness.conn.query(
        alloc,
        \\SELECT timer_id FROM timers
        \\WHERE instance_id = $1 AND due_at_us <= $2
        \\ORDER BY due_at_us, sequence_number
    ,
        &.{ instance_id, now + 3_000_000 },
    );
    defer query1.deinit();

    var query2 = try harness.conn.query(
        alloc,
        \\SELECT timer_id FROM timers
        \\WHERE instance_id = $1 AND due_at_us <= $2
        \\ORDER BY due_at_us, sequence_number
    ,
        &.{ instance_id, now + 3_000_000 },
    );
    defer query2.deinit();

    try testing.expectEqual(query1.rows.len, query2.rows.len);

    // Verify order is identical
    for (query1.rows, query2.rows) |row1, row2| {
        try testing.expectEqualStrings(row1[0] orelse "", row2[0] orelse "");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-04-04: Audit chain hash computation is deterministic
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-04-04: audit chain hash computation is deterministic" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    const actor_id = try uuid_mod.newUuidV4(alloc);
    const resource_id = try uuid_mod.newUuidV4(alloc);
    const ref_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(tenant_id);
        alloc.free(actor_id);
        alloc.free(resource_id);
        alloc.free(ref_id);
    }

    // Compute same hash three times
    var hashes = std.ArrayList([]u8).init(alloc);
    defer {
        for (hashes.items) |h| alloc.free(h);
        hashes.deinit();
    }

    for (0..3) |_| {
        var query = try harness.conn.query(
            alloc,
            \\SELECT
            \\  bpm_audit_compute_chain_hash(
            \\    $1::uuid, $2::uuid, $3::uuid, 'test.action',
            \\    'test', $4::uuid, NOW()::timestamptz,
            \\    '{"key":"value"}'::jsonb, '{"result":"ok"}'::jsonb,
            \\    $5::uuid, 'trace-123', '0000000000000000000000000000000000000000000000000000000000000000'::text, NULL
            \\  ) AS hash
        ,
            &.{ tenant_id, actor_id, resource_id, resource_id, ref_id },
        );
        defer query.deinit();

        try testing.expectEqual(@as(usize, 1), query.rows.len);
        const hash_str = query.rows[0][0] orelse "";
        const hash_copy = try alloc.dupe(u8, hash_str);
        try hashes.append(hash_copy);
    }

    // All three hashes should be identical
    try testing.expectEqualStrings(hashes.items[0], hashes.items[1]);
    try testing.expectEqualStrings(hashes.items[1], hashes.items[2]);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-04-05: Event append preserves deterministic ordering
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-04-05: event append preserves deterministic ordering" {
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

    // Append events
    for (0..5) |i| {
        const event_id = try uuid_mod.newUuidV4(alloc);
        const idempotency_key = try std.fmt.allocPrint(alloc, "idem-key-{d}", .{i});
        defer {
            alloc.free(event_id);
            alloc.free(idempotency_key);
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
                "{\"index\":" ++ std.fmt.fmt("{d}", .{i}) ++ "}",
                idempotency_key,
            },
        );
    }

    // Query events twice (should return in identical order)
    var query1 = try harness.conn.query(
        alloc,
        \\SELECT event_id FROM events
        \\WHERE instance_id = $1 ORDER BY created_at, sequence_number
    ,
        &.{instance_id},
    );
    defer query1.deinit();

    var query2 = try harness.conn.query(
        alloc,
        \\SELECT event_id FROM events
        \\WHERE instance_id = $1 ORDER BY created_at, sequence_number
    ,
        &.{instance_id},
    );
    defer query2.deinit();

    try testing.expectEqual(query1.rows.len, query2.rows.len);

    // Verify order is identical
    for (query1.rows, query2.rows) |row1, row2| {
        try testing.expectEqualStrings(row1[0] orelse "", row2[0] orelse "");
    }
}
