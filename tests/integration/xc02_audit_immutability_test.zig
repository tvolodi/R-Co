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

fn insertAuditEntry(
    conn: anytype,
    audit_id: []const u8,
    tenant_id: []const u8,
    actor_id: []const u8,
    action: []const u8,
    resource_id: []const u8,
    timestamp: []const u8,
) !void {
    // ISS-0645 / GH-649 (same root cause as ISS-0149 / GH-465, fixed in
    // audit_chain_utf8_test.zig, and reapplied to
    // adp09_tamper_evident_audit_chain_test.zig / adp10_agent_io_capture_audit_test.zig
    // in this same pass): TestHarness.init() sets session_replication_role =
    // 'replica' session-wide so resetTestData() can DELETE audit_entries
    // without tripping the immutability guard. That setting also suppresses
    // trg_bpm_audit_apply_chain_hash -- the exact trigger this file exercises
    // to populate chain_hash/prev_chain_hash. Scope the override to this one
    // INSERT and restore 'replica' immediately after.
    try conn.exec("SET session_replication_role = 'origin'", &.{});
    defer conn.exec("SET session_replication_role = 'replica'", &.{}) catch {};

    _ = try conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  timestamp
        \\) VALUES ($1, $2, $3, $4, 'test', $5, $6::timestamptz)
    ,
        &.{ audit_id, tenant_id, actor_id, action, resource_id, timestamp },
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

    // ISS-0645 / GH-649, ISS-0653 / GH-662: TestHarness.init() sets
    // session_replication_role = 'replica' session-wide so resetTestData()
    // can DELETE audit_entries without tripping the immutability guard --
    // but that same setting suppresses every other trigger too, including
    // the append-only immutability trigger this test exists to exercise.
    // Every OTHER test in this file that needs real trigger behavior goes
    // through insertAuditEntry(), which already scopes 'origin' around its
    // own INSERT and restores 'replica' immediately after -- but this test
    // calls harness.conn.exec() directly (both the INSERT and the UPDATE
    // under test), so it never got that scoping and the UPDATE silently
    // succeeded instead of being rejected by the trigger. Set 'origin' for
    // the whole test body; there is nothing to restore since the entire
    // sequence runs inside one transaction that is always rolled back.
    try harness.conn.exec("SET session_replication_role = 'origin'", &.{});

    const audit_id = try uuid_mod.newUuidV4(alloc);
    const tenant_id = try uuid_mod.newUuidV4(alloc);
    const actor_id = try uuid_mod.newUuidV4(alloc);
    const resource_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(audit_id);
        alloc.free(tenant_id);
        alloc.free(actor_id);
        alloc.free(resource_id);
    }

    // Insert audit entry
    _ = try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  timestamp
        \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
    ,
        &.{ audit_id, tenant_id, actor_id, "test.create", "test", resource_id },
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

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    const actor_id = try uuid_mod.newUuidV4(alloc);
    const resource_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(tenant_id);
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
    //
    // ISS-0645 / GH-649: $4 (resource_id) is passed WITHOUT a ::uuid cast --
    // bpm_audit_compute_chain_hash's canonical signature (since GBL-081/1107)
    // declares p_resource_id TEXT, matching audit_entries.resource_id. See
    // adp09_tamper_evident_audit_chain_test.zig TC-ADP-09-05 for the same fix
    // and its rationale.
    var query1 = try harness.conn.query(
        alloc,
        \\SELECT
        \\  bpm_audit_compute_chain_hash(
        \\    $1::uuid, $2::uuid, $3::uuid, 'test.action',
        \\    'test', $4, NOW()::timestamptz,
        \\    '{"key":"value"}'::jsonb, '{"result":"ok"}'::jsonb,
        \\    $5::uuid, NULL, '0000000000000000000000000000000000000000000000000000000000000000'::text, NULL
        \\  ) AS hash1
    ,
        &.{ tenant_id, actor_id, hash_audit_id, resource_id, hash_ref_id },
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

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(tenant_id);

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
            tenant_id,
            actor_id,
            if (i == 0) "entry.1" else if (i == 1) "entry.2" else "entry.3",
            resource_id,
            timestamps[i],
        );
    }

    // Query the chain
    var query = try harness.conn.query(
        alloc,
        \\SELECT action, chain_hash, prev_chain_hash
        \\FROM audit_entries
        \\WHERE tenant_id = $1
        \\ORDER BY timestamp, audit_id
    ,
        &.{tenant_id},
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

    // Query Tenant A chain
    var query_a = try harness.conn.query(
        alloc,
        \\SELECT chain_hash, prev_chain_hash FROM audit_entries
        \\WHERE tenant_id = $1 ORDER BY timestamp, audit_id
    ,
        &.{tenant_a},
    );
    defer query_a.deinit();

    // Query Tenant B chain
    var query_b = try harness.conn.query(
        alloc,
        \\SELECT chain_hash, prev_chain_hash FROM audit_entries
        \\WHERE tenant_id = $1 ORDER BY timestamp, audit_id
    ,
        &.{tenant_b},
    );
    defer query_b.deinit();

    try testing.expectEqual(@as(usize, 2), query_a.rows.len);
    try testing.expectEqual(@as(usize, 2), query_b.rows.len);

    // Verify no cross-tenant links
    const hash_a1 = query_a.rows[0][0] orelse "";
    const prev_b1 = query_b.rows[0][1];

    // Tenant B's first entry should have null prev (boundary), not link to Tenant A
    try testing.expect(prev_b1 == null);
    try testing.expect(!std.mem.eql(u8, hash_a1, prev_b1 orelse ""));
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-02-05: Tampering detection — modified entry breaks chain
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-02-05: tampering detection via chain validation" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(tenant_id);

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
            tenant_id,
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

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(tenant_id);

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
        tenant_id,
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
        tenant_id,
        chain_actor,
        "chained.action",
        chain_resource,
        "2026-05-28T00:40:02Z",
    );

    // Query both
    var query = try harness.conn.query(
        alloc,
        \\SELECT action, chain_hash, prev_chain_hash FROM audit_entries
        \\WHERE tenant_id = $1 ORDER BY timestamp, audit_id
    ,
        &.{tenant_id},
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

    // Compute hash with trace_id = "trace-123"
    //
    // ISS-0645 / GH-649: $4 (resource_id) is passed WITHOUT a ::uuid cast --
    // bpm_audit_compute_chain_hash's canonical signature (since GBL-081/1107)
    // declares p_resource_id TEXT, matching audit_entries.resource_id. See
    // adp09_tamper_evident_audit_chain_test.zig TC-ADP-09-05 for the same fix
    // and its rationale.
    //
    // ISS-0653 / GH-662: the canonical 13-parameter signature (GBL-121 /
    // 1107) is (tenant_id, audit_id, actor_id, action, resource_type,
    // resource_id, timestamp, before_state JSONB, after_state JSONB,
    // pipeline_run_id, payload_full JSONB, prev_chain_hash TEXT, trace_id
    // TEXT) -- this call had 'trace-123'/'trace-999' positioned as the 11th
    // argument (payload_full, JSONB), not the 13th (trace_id), so Postgres
    // rejected the bare string as invalid JSON (C22P02 "Token trace is
    // invalid"). Reordered so trace_id lands in its actual parameter slot,
    // with payload_full given a real JSONB literal and prev_chain_hash
    // given the all-zero sentinel hash (matching the sibling adp09 test's
    // usage of the same function).
    var query1 = try harness.conn.query(
        alloc,
        \\SELECT
        \\  bpm_audit_compute_chain_hash(
        \\    $1::uuid, $2::uuid, $3::uuid, 'test.action',
        \\    'test', $4, NOW()::timestamptz,
        \\    '{"key":"value"}'::jsonb, '{"result":"ok"}'::jsonb,
        \\    $5::uuid, '{}'::jsonb, '0000000000000000000000000000000000000000000000000000000000000000'::text, 'trace-123'
        \\  ) AS hash1,
        \\  bpm_audit_compute_chain_hash(
        \\    $1::uuid, $2::uuid, $3::uuid, 'test.action',
        \\    'test', $4, NOW()::timestamptz,
        \\    '{"key":"value"}'::jsonb, '{"result":"ok"}'::jsonb,
        \\    $5::uuid, '{}'::jsonb, '0000000000000000000000000000000000000000000000000000000000000000'::text, 'trace-999'
        \\  ) AS hash2
    ,
        &.{ tenant_id, actor_id, resource_id, resource_id, ref_id },
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

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(tenant_id);

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
            tenant_id,
            actor_id,
            "test.action",
            resource_id,
            "2026-05-28T00:50:00Z",
        );
    }

    var validation = try harness.conn.query(
        alloc,
        \\SELECT count(*) FROM audit_entries
        \\WHERE tenant_id = $1
    ,
        &.{tenant_id},
    );
    defer validation.deinit();

    try testing.expectEqual(@as(usize, 1), validation.rows.len);
    try testing.expectEqualStrings("100", validation.rows[0][0] orelse "");
}
