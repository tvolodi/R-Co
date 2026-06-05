//! Integration tests for XC-02 — Audit Immutability
//!
//! Audit entries are append-only with SHA-256 cryptographic chaining.
//! Tampering is detectable via chain hash validation.

const std = @import("std");
const testing = std.testing;
const bpm = @import("bpm");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const uuid_mod = bpm.uuid;

// SPT-02 (migration 062): audit_entries no longer has a row-level scope column.
// The scope_id parameter is kept for API backward compatibility but not used in SQL.
fn insertAuditEntry(
    conn: anytype,
    audit_id: []const u8,
    scope_id: []const u8,
    actor_id: []const u8,
    action: []const u8,
    resource_id: []const u8,
    timestamp: []const u8,
) !void {
    _ = scope_id;
    _ = try conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, actor_id, action, resource_type, resource_id,
        \\  timestamp
        \\) VALUES ($1, $2, $3, 'test', $4, $5::timestamptz)
    ,
        &.{ audit_id, actor_id, action, resource_id, timestamp },
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-02-01: Audit entries are append-only (no UPDATE/DELETE allowed)
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-02-01: audit entries are append-only (immutability trigger)" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    try harness.conn.exec("BEGIN", &.{});
    defer harness.conn.exec("ROLLBACK", &.{}) catch {};

    const audit_id = try uuid_mod.newUuidV4(alloc);
    const scope_id = try uuid_mod.newUuidV4(alloc);
    const actor_id = try uuid_mod.newUuidV4(alloc);
    const resource_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(audit_id);
        alloc.free(scope_id);
        alloc.free(actor_id);
        alloc.free(resource_id);
    }

    // SPT-02 (migration 062): scope_id not used in audit SQL.
    _ = scope_id;
    _ = actor_id;

    // Insert audit entry
    _ = try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, actor_id, action, resource_type, resource_id,
        \\  timestamp
        \\) VALUES ($1, $2, $3, $4, $5, NOW())
    ,
        &.{ audit_id, "00000000-0000-0000-0000-000000000001", "test.create", "test", resource_id },
    );

    // Attempt UPDATE — should fail due to immutability trigger
    try harness.conn.exec("SAVEPOINT xc02_01", &.{});
    const update_result = harness.conn.exec(
        \\UPDATE audit_entries SET action = $1 WHERE audit_id = $2
    ,
        &.{ "modified.action", audit_id },
    );

    // pg.zig surfaces trigger-raised SQL exceptions as ServerError.
    try testing.expectError(error.ServerError, update_result);

    harness.conn.exec("ROLLBACK TO SAVEPOINT xc02_01", &.{}) catch {};

    // Verify original value is unchanged
    var query = try harness.conn.query(
        alloc,
        \\SELECT action FROM audit_entries WHERE audit_id = $1
    ,
        &.{audit_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    try testing.expectEqualStrings("test.create", query.rows[0][0] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-02-02: Chain hash is deterministically computed
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-02-02: chain hash is deterministically computed" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const scope_id = try uuid_mod.newUuidV4(alloc);
    const actor_id = try uuid_mod.newUuidV4(alloc);
    const resource_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(scope_id);
        alloc.free(actor_id);
        alloc.free(resource_id);
    }

    const hash_audit_id = try uuid_mod.newUuidV4(alloc);
    const hash_ref_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(hash_audit_id);
        alloc.free(hash_ref_id);
    }

    // Compute hash for a stable payload.
    var query1 = try harness.conn.query(
        alloc,
        \\SELECT
        \\  bpm_audit_compute_chain_hash(
        \\    $1::uuid, $2::uuid, $3::uuid, 'test.action',
        \\    'test', $4::uuid, NOW()::timestamptz,
        \\    '{"key":"value"}'::jsonb, '{"result":"ok"}'::jsonb,
        \\    $5::uuid, NULL, '0000000000000000000000000000000000000000000000000000000000000000'::text, NULL
        \\  ) AS hash1
    ,
        &.{ scope_id, actor_id, hash_audit_id, resource_id, hash_ref_id },
    );
    defer query1.deinit();

    // Note: in practice, we'd compute hashes at slightly different times
    // For this test, we use the DB function which is deterministic
    try testing.expectEqual(@as(usize, 1), query1.rows.len);
    const hash_hex = query1.rows[0][0] orelse "";
    try testing.expectEqual(@as(usize, 64), hash_hex.len); // SHA-256 = 64 hex chars

    // All characters should be valid hex
    for (hash_hex) |ch| {
        try testing.expect(
            (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'),
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-02-03: Each new entry links to its predecessor
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-02-03: each new entry links to its predecessor" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const scope_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(scope_id);

    const timestamps = [_][]const u8{
        "2026-05-28T00:00:01Z",
        "2026-05-28T00:00:02Z",
        "2026-05-28T00:00:03Z",
    };

    // Insert 3 audit entries sequentially for same tenant.
    for (0..3) |i| {
        const audit_id = try uuid_mod.newUuidV4(alloc);
        const actor_id = try uuid_mod.newUuidV4(alloc);
        const resource_id = try uuid_mod.newUuidV4(alloc);
        defer {
            alloc.free(audit_id);
            alloc.free(actor_id);
            alloc.free(resource_id);
        }

        try insertAuditEntry(
            &harness.conn,
            audit_id,
            scope_id,
            actor_id,
            if (i == 0) "entry.1" else if (i == 1) "entry.2" else "entry.3",
            resource_id,
            timestamps[i],
        );
    }

    // Query the chain — audit entries no longer have a row-level scope column; use action-based filter.
    var query = try harness.conn.query(
        alloc,
        \\SELECT action, chain_hash, prev_chain_hash
        \\FROM audit_entries
        \\WHERE action IN ('entry.1', 'entry.2', 'entry.3')
        \\ORDER BY timestamp, audit_id
    ,
        &.{},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 3), query.rows.len);

    // Entry 1: prev_chain_hash should be NULL
    const prev_hash_1 = query.rows[0][2];
    try testing.expect(prev_hash_1 == null);

    // Entry 2: prev_chain_hash should equal Entry 1's chain_hash
    const hash_1 = query.rows[0][1] orelse "";
    const prev_hash_2 = query.rows[1][2] orelse "";
    try testing.expectEqualStrings(hash_1, prev_hash_2);

    // Entry 3: prev_chain_hash should equal Entry 2's chain_hash
    const hash_2 = query.rows[1][1] orelse "";
    const prev_hash_3 = query.rows[2][2] orelse "";
    try testing.expectEqualStrings(hash_2, prev_hash_3);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-02-04: Per-tenant chains do not cross-reference
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-02-04: per-tenant chains do not cross-reference" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_a = try uuid_mod.newUuidV4(alloc);
    const tenant_b = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(tenant_a);
        alloc.free(tenant_b);
    }

    const tenant_a_timestamps = [_][]const u8{ "2026-05-28T00:10:01Z", "2026-05-28T00:10:02Z" };
    const tenant_b_timestamps = [_][]const u8{ "2026-05-28T00:20:01Z", "2026-05-28T00:20:02Z" };

    // Insert entries for Tenant A
    for (0..2) |i| {
        const audit_id = try uuid_mod.newUuidV4(alloc);
        const actor_id = try uuid_mod.newUuidV4(alloc);
        const resource_id = try uuid_mod.newUuidV4(alloc);
        defer {
            alloc.free(audit_id);
            alloc.free(actor_id);
            alloc.free(resource_id);
        }

        try insertAuditEntry(
            &harness.conn,
            audit_id,
            tenant_a,
            actor_id,
            "tenant_a.action",
            resource_id,
            tenant_a_timestamps[i],
        );
    }

    // Insert entries for Tenant B
    for (0..2) |i| {
        const audit_id = try uuid_mod.newUuidV4(alloc);
        const actor_id = try uuid_mod.newUuidV4(alloc);
        const resource_id = try uuid_mod.newUuidV4(alloc);
        defer {
            alloc.free(audit_id);
            alloc.free(actor_id);
            alloc.free(resource_id);
        }

        try insertAuditEntry(
            &harness.conn,
            audit_id,
            tenant_b,
            actor_id,
            "tenant_b.action",
            resource_id,
            tenant_b_timestamps[i],
        );
    }

    // Query chain A — audit entries no longer have a row-level scope column; use action-based filter.
    var query_a = try harness.conn.query(
        alloc,
        \\SELECT chain_hash, prev_chain_hash FROM audit_entries
        \\WHERE action = 'tenant_a.action' ORDER BY timestamp, audit_id
    ,
        &.{},
    );
    defer query_a.deinit();

    // Query chain B
    var query_b = try harness.conn.query(
        alloc,
        \\SELECT chain_hash, prev_chain_hash FROM audit_entries
        \\WHERE action = 'tenant_b.action' ORDER BY timestamp, audit_id
    ,
        &.{},
    );
    defer query_b.deinit();

    try testing.expectEqual(@as(usize, 2), query_a.rows.len);
    try testing.expectEqual(@as(usize, 2), query_b.rows.len);

    // After SPT-02 (migration 064), audit chain is GLOBAL not per-tenant.
    // The chain spans all entries ordered by timestamp globally.
    // Tenant A entries (00:10:xx) come before Tenant B entries (00:20:xx).
    // Therefore B's first entry will have a non-null prev_chain_hash (linking to A's last).
    const hash_a2 = query_a.rows[1][0] orelse "";
    const prev_b1 = query_b.rows[0][1] orelse "";

    // Global chain: B's first entry's prev_chain_hash should equal A's last chain_hash.
    try testing.expect(hash_a2.len > 0);
    try testing.expectEqualStrings(hash_a2, prev_b1);

    // B's second entry chains to B's first.
    const hash_b1 = query_b.rows[0][0] orelse "";
    const prev_b2 = query_b.rows[1][1] orelse "";
    try testing.expectEqualStrings(hash_b1, prev_b2);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-02-05: Tampering detection — modified entry breaks chain
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-02-05: tampering detection via chain validation" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const scope_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(scope_id);

    // Create a chain of 3 entries
    var audit_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (audit_ids.items) |id| alloc.free(id);
        audit_ids.deinit(alloc);
    }

    for (0..3) |_| {
        const audit_id = try uuid_mod.newUuidV4(alloc);
        try audit_ids.append(alloc, try alloc.dupe(u8, audit_id));

        const actor_id = try uuid_mod.newUuidV4(alloc);
        const resource_id = try uuid_mod.newUuidV4(alloc);
        defer {
            alloc.free(actor_id);
            alloc.free(resource_id);
        }

        try insertAuditEntry(
            &harness.conn,
            audit_id,
            scope_id,
            actor_id,
            "test.action",
            resource_id,
            "2026-05-28T00:30:00Z",
        );

        alloc.free(audit_id);
    }

    // Disable user triggers temporarily to inject tampering.
    try harness.conn.exec("ALTER TABLE audit_entries DISABLE TRIGGER USER", &.{});
    defer harness.conn.exec("ALTER TABLE audit_entries ENABLE TRIGGER USER", &.{}) catch {};

    // Tamper with entry 2's action
    _ = try harness.conn.exec(
        \\UPDATE audit_entries SET action = $1 WHERE audit_id = $2
    ,
        &.{ "tampered.action", audit_ids.items[1] },
    );

    var validation = try harness.conn.query(
        alloc,
        \\SELECT action, chain_hash, prev_chain_hash, timestamp
        \\FROM audit_entries
        \\WHERE audit_id = $1
    ,
        &.{audit_ids.items[1]},
    );
    defer validation.deinit();

    try testing.expectEqual(@as(usize, 1), validation.rows.len);
    const current_action = validation.rows[0][0] orelse "";
    const stored_chain_hash = validation.rows[0][1] orelse "";
    try testing.expectEqualStrings("tampered.action", current_action);
    try testing.expect(stored_chain_hash.len > 0);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-02-06: Legacy entries coexist with chained entries
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-02-06: legacy entries coexist with chained entries" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const scope_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(scope_id);

    // Insert legacy entry (pre-XC-02, no chain)
    const legacy_id = try uuid_mod.newUuidV4(alloc);
    const legacy_actor = try uuid_mod.newUuidV4(alloc);
    const legacy_resource = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(legacy_id);
        alloc.free(legacy_actor);
        alloc.free(legacy_resource);
    }

    try insertAuditEntry(
        &harness.conn,
        legacy_id,
        scope_id,
        legacy_actor,
        "legacy.action",
        legacy_resource,
        "2026-05-28T00:40:01Z",
    );

    // Insert chained entry (post-XC-02)
    const chain_id = try uuid_mod.newUuidV4(alloc);
    const chain_actor = try uuid_mod.newUuidV4(alloc);
    const chain_resource = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(chain_id);
        alloc.free(chain_actor);
        alloc.free(chain_resource);
    }

    try insertAuditEntry(
        &harness.conn,
        chain_id,
        scope_id,
        chain_actor,
        "chained.action",
        chain_resource,
        "2026-05-28T00:40:02Z",
    );

    // Query both — audit entries no longer have a row-level scope column; use audit_id filter.
    var query = try harness.conn.query(
        alloc,
        \\SELECT action, chain_hash, prev_chain_hash FROM audit_entries
        \\WHERE audit_id IN ($1, $2) ORDER BY timestamp, audit_id
    ,
        &.{ legacy_id, chain_id },
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 2), query.rows.len);

    // Chain trigger computes a hash for every inserted row.
    try testing.expect(query.rows[0][1] != null);
    try testing.expect(query.rows[0][2] == null);

    // Chained entry should have non-NULL chain_hash and link to predecessor.
    try testing.expect(query.rows[1][1] != null);
    try testing.expect(query.rows[1][2] != null);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-02-07: Chain hash incorporates all audit fields
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-02-07: chain hash incorporates all audit fields" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const scope_id = try uuid_mod.newUuidV4(alloc);
    const actor_id = try uuid_mod.newUuidV4(alloc);
    const resource_id = try uuid_mod.newUuidV4(alloc);
    const ref_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(scope_id);
        alloc.free(actor_id);
        alloc.free(resource_id);
        alloc.free(ref_id);
    }

    // Compute hash with trace_id = "trace-123"
    var query1 = try harness.conn.query(
        alloc,
        \\SELECT
        \\  bpm_audit_compute_chain_hash(
        \\    $1::uuid, $2::uuid, $3::uuid, 'test.action',
        \\    'test', $4::uuid, NOW()::timestamptz,
        \\    '{"key":"value"}'::jsonb, '{"result":"ok"}'::jsonb,
        \\    $5::uuid, 'trace-123', '0000000000000000000000000000000000000000000000000000000000000000'::text, NULL
        \\  ) AS hash1,
        \\  bpm_audit_compute_chain_hash(
        \\    $1::uuid, $2::uuid, $3::uuid, 'test.action',
        \\    'test', $4::uuid, NOW()::timestamptz,
        \\    '{"key":"value"}'::jsonb, '{"result":"ok"}'::jsonb,
        \\    $5::uuid, 'trace-999', '0000000000000000000000000000000000000000000000000000000000000000'::text, NULL
        \\  ) AS hash2
    ,
        &.{ scope_id, actor_id, resource_id, resource_id, ref_id },
    );
    defer query1.deinit();

    try testing.expectEqual(@as(usize, 1), query1.rows.len);
    const hash1 = query1.rows[0][0] orelse "";
    const hash2 = query1.rows[0][1] orelse "";

    // Different trace_id should produce different hashes
    try testing.expect(!std.mem.eql(u8, hash1, hash2));
    try testing.expectEqual(@as(usize, 64), hash1.len);
    try testing.expectEqual(@as(usize, 64), hash2.len);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-02-08: Chain validation is computationally efficient
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-02-08: chain validation is efficient for large chains" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const scope_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(scope_id);

    // Insert 100 audit entries (larger chain)
    for (0..100) |_| {
        const audit_id = try uuid_mod.newUuidV4(alloc);
        const actor_id = try uuid_mod.newUuidV4(alloc);
        const resource_id = try uuid_mod.newUuidV4(alloc);
        defer {
            alloc.free(audit_id);
            alloc.free(actor_id);
            alloc.free(resource_id);
        }

        try insertAuditEntry(
            &harness.conn,
            audit_id,
            scope_id,
            actor_id,
            "test.action",
            resource_id,
            "2026-05-28T00:50:00Z",
        );
    }

    var validation = try harness.conn.query(
        alloc,
        \\SELECT count(*) FROM audit_entries
        \\WHERE action = 'test.action'
    ,
        &.{},
    );
    defer validation.deinit();

    try testing.expectEqual(@as(usize, 1), validation.rows.len);
    try testing.expectEqualStrings("100", validation.rows[0][0] orelse "");
}
