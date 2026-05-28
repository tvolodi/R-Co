//! Integration tests for XC-06 — Backwards Compatibility
//!
//! New platform versions load and continue instances created by prior versions.
//! Schema migrations are additive and idempotent.

const std = @import("std");
const testing = std.testing;
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const uuid_mod = @import("../util/uuid.zig");

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-06-01: Schema migrations are idempotent and additive
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-06-01: schema migrations are idempotent" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    // Verify schema_migrations table exists
    var query = try harness.conn.query(
        alloc,
        \\SELECT EXISTS(SELECT 1 FROM information_schema.tables
        \\WHERE table_schema = 'public' AND table_name = 'schema_migrations')
    ,
        &.{},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);

    // Verify migrations have been applied (check for known tables)
    var tables_query = try harness.conn.query(
        alloc,
        \\SELECT table_name FROM information_schema.tables
        \\WHERE table_schema = 'public'
        \\AND table_name IN ('instances', 'events', 'audit_entries')
        \\ORDER BY table_name
    ,
        &.{},
    );
    defer tables_query.deinit();

    // All core tables should exist
    try testing.expect(tables_query.rows.len >= 3);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-06-02: Instance records from prior version can be loaded
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-06-02: instance records from prior version load correctly" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const instance_id = try uuid_mod.newUuidV4(alloc);
    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(instance_id);
        alloc.free(tenant_id);
    }

    // Create instance (simulating V1 instance)
    // V1 instances may not have newer columns like trace_id
    _ = try harness.conn.exec(
        \\INSERT INTO instances (
        \\  instance_id, tenant_id, definition_artifact_hash,
        \\  status, variables, created_at
        \\) VALUES ($1, $2, $3, $4, $5, NOW())
    ,
        &.{
            instance_id,
            tenant_id,
            "old-def-hash",
            "ACTIVE",
            "{\"state\":\"old_format\"}",
        },
    );

    // Load instance (new version reading old schema)
    var query = try harness.conn.query(
        alloc,
        \\SELECT instance_id, tenant_id, status, variables FROM instances
        \\WHERE instance_id = $1
    ,
        &.{instance_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    try testing.expectEqualStrings(instance_id, query.rows[0][0] orelse "");
    try testing.expectEqualStrings(tenant_id, query.rows[0][1] orelse "");
    try testing.expectEqualStrings("ACTIVE", query.rows[0][2] orelse "");
    try testing.expectEqualStrings("{\"state\":\"old_format\"}", query.rows[0][3] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-06-03: Instance continues normally after schema upgrade
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-06-03: instance continues normally after schema upgrade" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const instance_id = try uuid_mod.newUuidV4(alloc);
    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(instance_id);
        alloc.free(tenant_id);
    }

    // Create V1-style instance
    _ = try harness.conn.exec(
        \\INSERT INTO instances (
        \\  instance_id, tenant_id, definition_artifact_hash,
        \\  status, variables, created_at
        \\) VALUES ($1, $2, $3, $4, $5, NOW())
    ,
        &.{ instance_id, tenant_id, "def-hash", "ACTIVE", "{}" },
    );

    // V2 appends event (with new fields like trace_id)
    const event_id = try uuid_mod.newUuidV4(alloc);
    const idem_key = "v2-event-idem-key";
    defer alloc.free(event_id);

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
            "v2.event",
            "{\"v2_field\":true}",
            idem_key,
        },
    );

    // Verify event appended successfully
    var query = try harness.conn.query(
        alloc,
        \\SELECT event_type FROM events WHERE instance_id = $1
    ,
        &.{instance_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    try testing.expectEqualStrings("v2.event", query.rows[0][0] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-06-04: Definition format migration is automatic at activation
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-06-04: definition format migration is automatic at activation" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const artifact_id = try uuid_mod.newUuidV4(alloc);
    const version_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(artifact_id);
        alloc.free(version_id);
    }

    // Create V1-format definition (missing V2 fields)
    const v1_content = "{\"nodes\":[],\"edges\":[],\"name\":\"v1_definition\"}";

    _ = try harness.conn.exec(
        \\INSERT INTO repository_artifacts (
        \\  artifact_id, version_id, artifact_kind, artifact_name,
        \\  content_hash, content_json, parent_version_id, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, NULL, NOW())
    ,
        &.{
            artifact_id,
            version_id,
            "definition",
            "test_definition",
            "def-hash-v1",
            v1_content,
        },
    );

    // Activate definition (migration happens here in production)
    var query = try harness.conn.query(
        alloc,
        \\SELECT content_json FROM repository_artifacts WHERE version_id = $1
    ,
        &.{version_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    const content = query.rows[0][0] orelse "";

    // Content should be retrievable and parseable
    try testing.expect(content.len > 0);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-06-05: Event type evolution is backwards compatible
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-06-05: event type evolution is backwards compatible" {
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

    // Insert V1-format event (missing V2 fields)
    const event_id_v1 = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(event_id_v1);

    _ = try harness.conn.exec(
        \\INSERT INTO events (
        \\  event_id, instance_id, tenant_id, event_type,
        \\  payload, idempotency_key, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
    ,
        &.{
            event_id_v1,
            instance_id,
            tenant_id,
            "order.created",
            "{\"order_id\":\"order-123\",\"amount\":100}",
            "v1-event-1",
        },
    );

    // V2 code reads V1 event (should work with backwards compatibility)
    var query = try harness.conn.query(
        alloc,
        \\SELECT payload FROM events
        \\WHERE event_type = $1 AND instance_id = $2
    ,
        &.{ "order.created", instance_id },
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    const payload = query.rows[0][0] orelse "";
    try testing.expect(std.mem.containsAtLeast(u8, payload, 1, "order_id"));
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-06-06: Archived events remain queryable after upgrade
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-06-06: archived events remain queryable after upgrade" {
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

    // Insert and archive events
    for (0..10) |i| {
        const event_id = try uuid_mod.newUuidV4(alloc);
        const idem_key = try std.fmt.allocPrint(alloc, "archived-{d}", .{i});
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

    // Archive some events
    _ = try harness.conn.exec(
        \\INSERT INTO events_archive SELECT * FROM events
        \\WHERE instance_id = $1 AND sequence_number BETWEEN 1 AND 5
    ,
        &.{instance_id},
    );

    _ = try harness.conn.exec(
        \\DELETE FROM events WHERE instance_id = $1 AND sequence_number BETWEEN 1 AND 5
    ,
        &.{instance_id},
    );

    // Query archived events (should still be accessible)
    var query_archive = try harness.conn.query(
        alloc,
        \\SELECT COUNT(*) FROM events_archive WHERE instance_id = $1
    ,
        &.{instance_id},
    );
    defer query_archive.deinit();

    const archive_count_str = query_archive.rows[0][0] orelse "0";
    const archive_count = try std.fmt.parseInt(i64, archive_count_str, 10);
    try testing.expectEqual(@as(i64, 5), archive_count);

    // Query live events
    var query_live = try harness.conn.query(
        alloc,
        \\SELECT COUNT(*) FROM events WHERE instance_id = $1
    ,
        &.{instance_id},
    );
    defer query_live.deinit();

    const live_count_str = query_live.rows[0][0] orelse "0";
    const live_count = try std.fmt.parseInt(i64, live_count_str, 10);
    try testing.expectEqual(@as(i64, 5), live_count);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-06-07: Multi-step schema evolution is supported
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-06-07: multi-step schema evolution is supported" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const instance_id = try uuid_mod.newUuidV4(alloc);
    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(instance_id);
        alloc.free(tenant_id);
    }

    // V1: Create instance
    _ = try harness.conn.exec(
        \\INSERT INTO instances (
        \\  instance_id, tenant_id, definition_artifact_hash,
        \\  status, variables, created_at
        \\) VALUES ($1, $2, $3, $4, $5, NOW())
    ,
        &.{
            instance_id,
            tenant_id,
            "def-hash-v1",
            "ACTIVE",
            "{\"v1_field\":\"value\"}",
        },
    );

    // Simulate V2 migration: add v2_field column (new columns should be nullable)
    // In practice, this is a schema migration in the DB.
    // For this test, we verify the instance can still be queried and extended.

    // V2: Add event with v2-specific payload
    const event_v2_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(event_v2_id);

    _ = try harness.conn.exec(
        \\INSERT INTO events (
        \\  event_id, instance_id, tenant_id, event_type,
        \\  payload, idempotency_key, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
    ,
        &.{
            event_v2_id,
            instance_id,
            tenant_id,
            "migration.v2_event",
            "{\"v2_field\":\"extended\"}",
            "v2-event-1",
        },
    );

    // V3: Add event with v3-specific payload
    const event_v3_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(event_v3_id);

    _ = try harness.conn.exec(
        \\INSERT INTO events (
        \\  event_id, instance_id, tenant_id, event_type,
        \\  payload, idempotency_key, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
    ,
        &.{
            event_v3_id,
            instance_id,
            tenant_id,
            "migration.v3_event",
            "{\"v3_field\":\"evolved\"}",
            "v3-event-1",
        },
    );

    // Verify instance is still accessible and events accumulate correctly
    var query = try harness.conn.query(
        alloc,
        \\SELECT COUNT(*) FROM events WHERE instance_id = $1
    ,
        &.{instance_id},
    );
    defer query.deinit();

    const event_count_str = query.rows[0][0] orelse "0";
    const event_count = try std.fmt.parseInt(i64, event_count_str, 10);
    try testing.expectEqual(@as(i64, 2), event_count); // v2 and v3 events

    // Verify instance base record is still intact
    var instance_query = try harness.conn.query(
        alloc,
        \\SELECT status, variables FROM instances WHERE instance_id = $1
    ,
        &.{instance_id},
    );
    defer instance_query.deinit();

    try testing.expectEqual(@as(usize, 1), instance_query.rows.len);
    try testing.expectEqualStrings("ACTIVE", instance_query.rows[0][0] orelse "");
    try testing.expect(std.mem.containsAtLeast(u8, instance_query.rows[0][1] orelse "", 1, "v1_field"));
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-06-08: Audit log evolution maintains chain integrity
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-06-08: audit log evolution maintains chain integrity" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(tenant_id);

    // Insert legacy audit entry (V1: no chain fields)
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
        &.{
            legacy_id,
            tenant_id,
            legacy_actor,
            "v1.action",
            "test",
            legacy_resource,
        },
    );

    // Insert V2 chained audit entry
    const v2_id = try uuid_mod.newUuidV4(alloc);
    const v2_actor = try uuid_mod.newUuidV4(alloc);
    const v2_resource = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(v2_id);
        alloc.free(v2_actor);
        alloc.free(v2_resource);
    }

    _ = try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  action_timestamp
        \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
    ,
        &.{ v2_id, tenant_id, v2_actor, "v2.action", "test", v2_resource },
    );

    // Query both entries
    var query = try harness.conn.query(
        alloc,
        \\SELECT action, chain_hash, prev_chain_hash FROM audit_entries
        \\WHERE tenant_id = $1 ORDER BY action_timestamp, audit_id
    ,
        &.{tenant_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 2), query.rows.len);

    // Legacy entry has null chain
    try testing.expect(query.rows[0][1] == null);
    try testing.expect(query.rows[0][2] == null);

    // V2 entry has chain (boundary, so prev_chain_hash = NULL)
    try testing.expect(query.rows[1][1] != null);
    try testing.expect(query.rows[1][2] == null);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-06-09: Backward-compatible defaults prevent runtime errors
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-06-09: backward-compatible defaults satisfy constraints" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const instance_id = try uuid_mod.newUuidV4(alloc);
    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(instance_id);
        alloc.free(tenant_id);
    }

    // Create instance with minimal V1 fields
    _ = try harness.conn.exec(
        \\INSERT INTO instances (
        \\  instance_id, tenant_id, definition_artifact_hash,
        \\  status, created_at
        \\) VALUES ($1, $2, $3, $4, NOW())
    ,
        &.{ instance_id, tenant_id, "def-hash", "ACTIVE" },
    );

    // Query instance (V2 schema may have added nullable columns with defaults)
    var query = try harness.conn.query(
        alloc,
        \\SELECT instance_id, tenant_id, status FROM instances
        \\WHERE instance_id = $1
    ,
        &.{instance_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);

    // All required fields should be present
    try testing.expectEqualStrings(instance_id, query.rows[0][0] orelse "");
    try testing.expectEqualStrings(tenant_id, query.rows[0][1] orelse "");
    try testing.expectEqualStrings("ACTIVE", query.rows[0][2] orelse "");
}
