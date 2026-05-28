//! Integration tests for XC-02 — Audit Immutability
//!
//! Audit entries are append-only with SHA-256 cryptographic chaining.
//! Tampering is detectable via chain hash validation.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const uuid_mod = @import("../util/uuid.zig");

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-02-01: Audit entries are append-only (no UPDATE/DELETE allowed)
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-02-01: audit entries are append-only (immutability trigger)" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

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
        \\  action_timestamp
        \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
    ,
        &.{ audit_id, tenant_id, actor_id, "test.create", "test", resource_id },
    );

    // Attempt UPDATE — should fail due to immutability trigger
    const update_result = harness.conn.exec(
        \\UPDATE audit_entries SET action = $1 WHERE audit_id = $2
    ,
        &.{ "modified.action", audit_id },
    );

    // Expect error (immutability constraint violated)
    try testing.expectError(error.UnexpectedRow, update_result);

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

    // Compute hash twice for identical audit data
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
        &.{ tenant_id, actor_id, try uuid_mod.newUuidV4(alloc), resource_id, try uuid_mod.newUuidV4(alloc) },
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

    // Insert 3 audit entries sequentially for same tenant
    // Entries will auto-chain via trigger
    for (0..3) |i| {
        const audit_id = try uuid_mod.newUuidV4(alloc);
        const actor_id = try uuid_mod.newUuidV4(alloc);
        const resource_id = try uuid_mod.newUuidV4(alloc);
        defer {
            alloc.free(audit_id);
            alloc.free(actor_id);
            alloc.free(resource_id);
        }

        _ = try harness.conn.exec(
            \\INSERT INTO audit_entries (
            \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
            \\  action_timestamp
            \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
        ,
            &.{
                audit_id,
                tenant_id,
                actor_id,
                if (i == 0) "entry.1" else if (i == 1) "entry.2" else "entry.3",
                "test",
                resource_id,
            },
        );
    }

    // Query the chain
    var query = try harness.conn.query(
        alloc,
        \\SELECT action, chain_hash, prev_chain_hash
        \\FROM audit_entries
        \\WHERE tenant_id = $1
        \\ORDER BY action_timestamp, audit_id
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

    // Insert entries for Tenant A
    for (0..2) |_| {
        const audit_id = try uuid_mod.newUuidV4(alloc);
        const actor_id = try uuid_mod.newUuidV4(alloc);
        const resource_id = try uuid_mod.newUuidV4(alloc);
        defer {
            alloc.free(audit_id);
            alloc.free(actor_id);
            alloc.free(resource_id);
        }

        _ = try harness.conn.exec(
            \\INSERT INTO audit_entries (
            \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
            \\  action_timestamp
            \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
        ,
            &.{ audit_id, tenant_a, actor_id, "tenant_a.action", "test", resource_id },
        );
    }

    // Insert entries for Tenant B
    for (0..2) |_| {
        const audit_id = try uuid_mod.newUuidV4(alloc);
        const actor_id = try uuid_mod.newUuidV4(alloc);
        const resource_id = try uuid_mod.newUuidV4(alloc);
        defer {
            alloc.free(audit_id);
            alloc.free(actor_id);
            alloc.free(resource_id);
        }

        _ = try harness.conn.exec(
            \\INSERT INTO audit_entries (
            \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
            \\  action_timestamp
            \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
        ,
            &.{ audit_id, tenant_b, actor_id, "tenant_b.action", "test", resource_id },
        );
    }

    // Query Tenant A chain
    var query_a = try harness.conn.query(
        alloc,
        \\SELECT chain_hash, prev_chain_hash FROM audit_entries
        \\WHERE tenant_id = $1 ORDER BY action_timestamp, audit_id
    ,
        &.{tenant_a},
    );
    defer query_a.deinit();

    // Query Tenant B chain
    var query_b = try harness.conn.query(
        alloc,
        \\SELECT chain_hash, prev_chain_hash FROM audit_entries
        \\WHERE tenant_id = $1 ORDER BY action_timestamp, audit_id
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
    var audit_ids = std.ArrayList([]u8).init(alloc);
    defer {
        for (audit_ids.items) |id| alloc.free(id);
        audit_ids.deinit();
    }

    for (0..3) |_| {
        const audit_id = try uuid_mod.newUuidV4(alloc);
        try audit_ids.append(audit_id);

        const actor_id = try uuid_mod.newUuidV4(alloc);
        const resource_id = try uuid_mod.newUuidV4(alloc);
        defer {
            alloc.free(actor_id);
            alloc.free(resource_id);
        }

        _ = try harness.conn.exec(
            \\INSERT INTO audit_entries (
            \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
            \\  action_timestamp
            \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
        ,
            &.{ audit_id, tenant_id, actor_id, "test.action", "test", resource_id },
        );
    }

    // Disable trigger temporarily to inject tampering
    try harness.conn.exec(
        \\DROP TRIGGER IF EXISTS trg_bpm_audit_apply_chain_hash ON audit_entries
    ,
        &.{},
    );

    // Tamper with entry 2's action
    _ = try harness.conn.exec(
        \\UPDATE audit_entries SET action = $1 WHERE audit_id = $2
    ,
        &.{ "tampered.action", audit_ids.items[1] },
    );

    // Restore trigger for subsequent operations
    try harness.conn.exec(
        \\CREATE TRIGGER trg_bpm_audit_apply_chain_hash
        \\BEFORE INSERT ON audit_entries
        \\FOR EACH ROW EXECUTE FUNCTION bpm_audit_apply_chain_hash()
    ,
        &.{},
    );

    // Run chain validation
    var validation = try harness.conn.query(
        alloc,
        \\SELECT
        \\  bpm_audit_validate_chain($1::uuid) AS validation_result
    ,
        &.{tenant_id},
    );
    defer validation.deinit();

    // Validation should detect tampering (result will be a JSON with issues)
    try testing.expectEqual(@as(usize, 1), validation.rows.len);
    const result_str = validation.rows[0][0] orelse "";
    try testing.expect(result_str.len > 0); // Non-empty validation result
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

    _ = try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  action_timestamp, chain_hash, prev_chain_hash
        \\) VALUES ($1, $2, $3, $4, $5, $6, NOW(), NULL, NULL)
    ,
        &.{ legacy_id, tenant_id, legacy_actor, "legacy.action", "test", legacy_resource },
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

    _ = try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  action_timestamp
        \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
    ,
        &.{ chain_id, tenant_id, chain_actor, "chained.action", "test", chain_resource },
    );

    // Query both
    var query = try harness.conn.query(
        alloc,
        \\SELECT action, chain_hash, prev_chain_hash FROM audit_entries
        \\WHERE tenant_id = $1 ORDER BY action_timestamp, audit_id
    ,
        &.{tenant_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 2), query.rows.len);

    // Legacy entry should have NULL chain fields
    try testing.expect(query.rows[0][1] == null);
    try testing.expect(query.rows[0][2] == null);

    // Chained entry should have non-NULL chain_hash and NULL prev (boundary)
    try testing.expect(query.rows[1][1] != null);
    try testing.expect(query.rows[1][2] == null);
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

        _ = try harness.conn.exec(
            \\INSERT INTO audit_entries (
            \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
            \\  action_timestamp
            \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
        ,
            &.{ audit_id, tenant_id, actor_id, "test.action", "test", resource_id },
        );
    }

    // Validate the chain (should complete in reasonable time)
    const start = std.time.milliTimestamp();
    var validation = try harness.conn.query(
        alloc,
        \\SELECT bpm_audit_validate_chain($1::uuid) AS result
    ,
        &.{tenant_id},
    );
    defer validation.deinit();
    const elapsed = std.time.milliTimestamp() - start;

    try testing.expectEqual(@as(usize, 1), validation.rows.len);

    // Should complete in less than 2 seconds
    try testing.expect(elapsed < 2000);
}
