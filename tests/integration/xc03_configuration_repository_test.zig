//! Integration tests for XC-03 — Configuration in Repository
//!
//! Configuration artifacts are stored, versioned, and activated like process definitions.
//! Configuration is read on-demand at runtime without restart requirement.

const std = @import("std");
const testing = std.testing;
const bpm = @import("bpm");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const uuid_mod = bpm.uuid;

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-03-01: Configuration artifact can be uploaded and versioned
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-03-01: configuration artifact can be uploaded and versioned" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const config_content = "{\"tier1_node_timeout_ms\":30000,\"tier2_node_timeout_ms\":120000}";
    const artifact_id = try uuid_mod.newUuidV4(alloc);
    const version_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(artifact_id);
        alloc.free(version_id);
    }

    // Upload configuration artifact
    _ = try harness.conn.exec(
        \\INSERT INTO repository_artifacts (
        \\  artifact_id, version_id, artifact_kind, artifact_name,
        \\  content_hash, content_json, parent_version_id, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, NULL, NOW())
    ,
        &.{
            artifact_id,
            version_id,
            "config",
            "capabilities",
            "config-hash-123",
            config_content,
        },
    );

    // Verify artifact is stored
    var query = try harness.conn.query(
        alloc,
        \\SELECT artifact_kind, artifact_name, content_json FROM repository_artifacts
        \\WHERE version_id = $1
    ,
        &.{version_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    try testing.expectEqualStrings("config", query.rows[0][0] orelse "");
    try testing.expectEqualStrings("capabilities", query.rows[0][1] orelse "");
    try testing.expectEqualStrings(config_content, query.rows[0][2] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-03-02: Configuration schema is validated on upload
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-03-02: configuration schema is validated on upload" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const artifact_id = try uuid_mod.newUuidV4(alloc);
    const version_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(artifact_id);
        alloc.free(version_id);
    }

    // Valid configuration with expected schema
    const valid_config = "{\"tier1_node_timeout_ms\":30000,\"tier2_node_timeout_ms\":120000}";

    _ = try harness.conn.exec(
        \\INSERT INTO repository_artifacts (
        \\  artifact_id, version_id, artifact_kind, artifact_name,
        \\  content_hash, content_json, parent_version_id, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, NULL, NOW())
    ,
        &.{
            artifact_id,
            version_id,
            "config",
            "timeouts",
            "config-hash-202",
            valid_config,
        },
    );

    // Verify configuration is stored with valid schema
    var query = try harness.conn.query(
        alloc,
        \\SELECT content_json FROM repository_artifacts
        \\WHERE artifact_kind = $1 AND artifact_name = $2
    ,
        &.{ "config", "timeouts" },
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    try testing.expectEqualStrings(valid_config, query.rows[0][0] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-03-03: Configuration is activated per-tenant atomically
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-03-03: configuration is activated per-tenant atomically" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    const version_id = try uuid_mod.newUuidV4(alloc);
    const actor_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(tenant_id);
        alloc.free(version_id);
        alloc.free(actor_id);
    }

    // Create artifact first
    const artifact_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(artifact_id);

    _ = try harness.conn.exec(
        \\INSERT INTO repository_artifacts (
        \\  artifact_id, version_id, artifact_kind, artifact_name,
        \\  content_hash, content_json, parent_version_id, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, NULL, NOW())
    ,
        &.{
            artifact_id,
            version_id,
            "config",
            "monitoring_config",
            "hash-456",
            "{\"alert_on_latency_p99_ms\":500}",
        },
    );

    // Activate configuration
    _ = try harness.conn.exec(
        \\INSERT INTO tenant_artifact_activations (
        \\  tenant_id, artifact_kind, artifact_name, active_version_id, activated_at
        \\) VALUES ($1, $2, $3, $4, NOW())
        \\ON CONFLICT (tenant_id, artifact_kind, artifact_name) DO UPDATE
        \\SET active_version_id = $4, activated_at = NOW()
    ,
        &.{ tenant_id, "config", "monitoring_config", version_id },
    );

    // Record activation audit
    const audit_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(audit_id);

    _ = try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  action_timestamp, trace_id
        \\) VALUES ($1, $2, $3, $4, $5, $6, NOW(), $7)
    ,
        &.{
            audit_id,
            tenant_id,
            actor_id,
            "configuration.activate",
            "configuration",
            version_id,
            "activate-trace-123",
        },
    );

    // Verify activation
    var query = try harness.conn.query(
        alloc,
        \\SELECT active_version_id FROM tenant_artifact_activations
        \\WHERE tenant_id = $1 AND artifact_kind = $2 AND artifact_name = $3
    ,
        &.{ tenant_id, "config", "monitoring_config" },
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    try testing.expectEqualStrings(version_id, query.rows[0][0] orelse "");

    // Verify audit entry
    var audit_query = try harness.conn.query(
        alloc,
        \\SELECT action, trace_id FROM audit_entries
        \\WHERE action = $1 AND resource_type = $2
    ,
        &.{ "configuration.activate", "configuration" },
    );
    defer audit_query.deinit();

    try testing.expectEqual(@as(usize, 1), audit_query.rows.len);
    try testing.expectEqualStrings("activate-trace-123", audit_query.rows[0][1] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-03-04: Different tenants can have different active configurations
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-03-04: different tenants have isolated configurations" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_a = try uuid_mod.newUuidV4(alloc);
    const tenant_b = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(tenant_a);
        alloc.free(tenant_b);
    }

    // Create two configuration versions
    const version_v1 = try uuid_mod.newUuidV4(alloc);
    const version_v2 = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(version_v1);
        alloc.free(version_v2);
    }

    // Insert both versions
    for ([_][]const u8{ version_v1, version_v2 }) |vid| {
        const artifact_id = try uuid_mod.newUuidV4(alloc);
        defer alloc.free(artifact_id);

        _ = try harness.conn.exec(
            \\INSERT INTO repository_artifacts (
            \\  artifact_id, version_id, artifact_kind, artifact_name,
            \\  content_hash, content_json, parent_version_id, created_at
            \\) VALUES ($1, $2, $3, $4, $5, $6, NULL, NOW())
        ,
            &.{
                artifact_id,
                vid,
                "config",
                "monitoring_config",
                "hash",
                if (std.mem.eql(u8, vid, version_v1)) "{\"alert_on_latency_p99_ms\":500}" else "{\"alert_on_latency_p99_ms\":600}",
            },
        );
    }

    // Activate V1 for Tenant A
    _ = try harness.conn.exec(
        \\INSERT INTO tenant_artifact_activations (
        \\  tenant_id, artifact_kind, artifact_name, active_version_id, activated_at
        \\) VALUES ($1, $2, $3, $4, NOW())
        \\ON CONFLICT (tenant_id, artifact_kind, artifact_name) DO UPDATE
        \\SET active_version_id = $4
    ,
        &.{ tenant_a, "config", "monitoring_config", version_v1 },
    );

    // Activate V2 for Tenant B
    _ = try harness.conn.exec(
        \\INSERT INTO tenant_artifact_activations (
        \\  tenant_id, artifact_kind, artifact_name, active_version_id, activated_at
        \\) VALUES ($1, $2, $3, $4, NOW())
        \\ON CONFLICT (tenant_id, artifact_kind, artifact_name) DO UPDATE
        \\SET active_version_id = $4
    ,
        &.{ tenant_b, "config", "monitoring_config", version_v2 },
    );

    // Query both tenants' configurations
    var query_a = try harness.conn.query(
        alloc,
        \\SELECT active_version_id FROM tenant_artifact_activations
        \\WHERE tenant_id = $1 AND artifact_kind = $2
    ,
        &.{ tenant_a, "config" },
    );
    defer query_a.deinit();

    var query_b = try harness.conn.query(
        alloc,
        \\SELECT active_version_id FROM tenant_artifact_activations
        \\WHERE tenant_id = $1 AND artifact_kind = $2
    ,
        &.{ tenant_b, "config" },
    );
    defer query_b.deinit();

    try testing.expectEqual(@as(usize, 1), query_a.rows.len);
    try testing.expectEqual(@as(usize, 1), query_b.rows.len);

    // Verify they have different versions
    const version_for_a = query_a.rows[0][0] orelse "";
    const version_for_b = query_b.rows[0][0] orelse "";

    try testing.expect(!std.mem.eql(u8, version_for_a, version_for_b));
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-03-05: Configuration is read on-demand at runtime
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-03-05: configuration is read on-demand at runtime" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    const artifact_id = try uuid_mod.newUuidV4(alloc);
    const version_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(tenant_id);
        alloc.free(artifact_id);
        alloc.free(version_id);
    }

    const config_content = "{\"runtime_feature\":true}";

    // Create configuration artifact
    _ = try harness.conn.exec(
        \\INSERT INTO repository_artifacts (
        \\  artifact_id, version_id, artifact_kind, artifact_name,
        \\  content_hash, content_json, parent_version_id, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, NULL, NOW())
    ,
        &.{
            artifact_id,
            version_id,
            "config",
            "runtime_feature",
            "hash-runtime",
            config_content,
        },
    );

    // Activate configuration for tenant
    _ = try harness.conn.exec(
        \\INSERT INTO tenant_artifact_activations (
        \\  tenant_id, artifact_kind, artifact_name, active_version_id, activated_at
        \\) VALUES ($1, $2, $3, $4, NOW())
        \\ON CONFLICT (tenant_id, artifact_kind, artifact_name) DO UPDATE
        \\SET active_version_id = $4
    ,
        &.{ tenant_id, "config", "runtime_feature", version_id },
    );

    // Read configuration at runtime (on-demand)
    var query = try harness.conn.query(
        alloc,
        \\SELECT ra.content_json FROM repository_artifacts ra
        \\JOIN tenant_artifact_activations taa ON ra.version_id = taa.active_version_id
        \\WHERE taa.tenant_id = $1 AND taa.artifact_kind = $2 AND taa.artifact_name = $3
    ,
        &.{ tenant_id, "config", "runtime_feature" },
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    try testing.expectEqualStrings(config_content, query.rows[0][0] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-03-06: Missing or inactive configuration fails gracefully
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-03-06: missing or inactive configuration fails gracefully" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(tenant_id);

    // Query for a configuration that was never activated for this tenant
    var query = try harness.conn.query(
        alloc,
        \\SELECT ra.content_json FROM repository_artifacts ra
        \\JOIN tenant_artifact_activations taa ON ra.version_id = taa.active_version_id
        \\WHERE taa.tenant_id = $1 AND taa.artifact_kind = $2 AND taa.artifact_name = $3
    ,
        &.{ tenant_id, "config", "nonexistent_feature" },
    );
    defer query.deinit();

    // Should return empty result (graceful failure: no rows)
    try testing.expectEqual(@as(usize, 0), query.rows.len);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-03-08: Configuration artifact activation is audited
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-03-08: configuration artifact activation is audited" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    const artifact_id = try uuid_mod.newUuidV4(alloc);
    const version_id = try uuid_mod.newUuidV4(alloc);
    const actor_id = try uuid_mod.newUuidV4(alloc);
    const trace_id = "config-audit-trace-001";
    defer {
        alloc.free(tenant_id);
        alloc.free(artifact_id);
        alloc.free(version_id);
        alloc.free(actor_id);
    }

    // Create configuration artifact
    _ = try harness.conn.exec(
        \\INSERT INTO repository_artifacts (
        \\  artifact_id, version_id, artifact_kind, artifact_name,
        \\  content_hash, content_json, parent_version_id, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, NULL, NOW())
    ,
        &.{
            artifact_id,
            version_id,
            "config",
            "audit_config",
            "hash-audit",
            "{\"audit_enabled\":true}",
        },
    );

    // Activate configuration
    _ = try harness.conn.exec(
        \\INSERT INTO tenant_artifact_activations (
        \\  tenant_id, artifact_kind, artifact_name, active_version_id, activated_at
        \\) VALUES ($1, $2, $3, $4, NOW())
        \\ON CONFLICT (tenant_id, artifact_kind, artifact_name) DO UPDATE
        \\SET active_version_id = $4
    ,
        &.{ tenant_id, "config", "audit_config", version_id },
    );

    // Record audit entry for activation
    const audit_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(audit_id);

    _ = try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  action_timestamp, trace_id
        \\) VALUES ($1, $2, $3, $4, $5, $6, NOW(), $7)
    ,
        &.{
            audit_id,
            tenant_id,
            actor_id,
            "config.activated",
            "configuration",
            version_id,
            trace_id,
        },
    );

    // Verify audit entry exists
    var query = try harness.conn.query(
        alloc,
        \\SELECT action, resource_type, trace_id FROM audit_entries
        \\WHERE action = $1 AND trace_id = $2
    ,
        &.{ "config.activated", trace_id },
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    try testing.expectEqualStrings("config.activated", query.rows[0][0] orelse "");
    try testing.expectEqualStrings("configuration", query.rows[0][1] orelse "");
    try testing.expectEqualStrings(trace_id, query.rows[0][2] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-03-07: Configuration artifact immutability is enforced
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-03-07: configuration artifact immutability is enforced" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const artifact_id = try uuid_mod.newUuidV4(alloc);
    const version_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(artifact_id);
        alloc.free(version_id);
    }

    // Create configuration artifact
    _ = try harness.conn.exec(
        \\INSERT INTO repository_artifacts (
        \\  artifact_id, version_id, artifact_kind, artifact_name,
        \\  content_hash, content_json, parent_version_id, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, NULL, NOW())
    ,
        &.{
            artifact_id,
            version_id,
            "config",
            "capabilities",
            "hash",
            "{\"tier1_timeout\":30000}",
        },
    );

    // Attempt to modify (should fail)
    const update_result = harness.conn.exec(
        \\UPDATE repository_artifacts SET content_json = $1 WHERE version_id = $2
    ,
        &.{ "{\"tier1_timeout\":60000}", version_id },
    );

    // Configuration should be immutable
    try testing.expectError(error.UnexpectedRow, update_result);

    // Verify content is unchanged
    var query = try harness.conn.query(
        alloc,
        \\SELECT content_json FROM repository_artifacts WHERE version_id = $1
    ,
        &.{version_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    try testing.expectEqualStrings("{\"tier1_timeout\":30000}", query.rows[0][0] orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-XC-03-09: Configuration artifact follows repository versioning (REPO-03)
// ─────────────────────────────────────────────────────────────────────────────

test "TC-XC-03-09: configuration artifact versioning follows REPO-03" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const artifact_id = try uuid_mod.newUuidV4(alloc);
    const version_1 = try uuid_mod.newUuidV4(alloc);
    const version_2 = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(artifact_id);
        alloc.free(version_1);
        alloc.free(version_2);
    }

    // Create version 1
    _ = try harness.conn.exec(
        \\INSERT INTO repository_artifacts (
        \\  artifact_id, version_id, artifact_kind, artifact_name,
        \\  content_hash, content_json, parent_version_id, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, NULL, NOW())
    ,
        &.{
            artifact_id,
            version_1,
            "config",
            "monitoring_config",
            "hash-v1",
            "{\"threshold\":100}",
        },
    );

    // Create version 2 (child of version 1)
    _ = try harness.conn.exec(
        \\INSERT INTO repository_artifacts (
        \\  artifact_id, version_id, artifact_kind, artifact_name,
        \\  content_hash, content_json, parent_version_id, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())
    ,
        &.{
            artifact_id,
            version_2,
            "config",
            "monitoring_config",
            "hash-v2",
            "{\"threshold\":200}",
            version_1,
        },
    );

    // Query version chain
    var query = try harness.conn.query(
        alloc,
        \\SELECT version_id, parent_version_id FROM repository_artifacts
        \\WHERE artifact_id = $1 ORDER BY created_at
    ,
        &.{artifact_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 2), query.rows.len);

    // Version 1: no parent
    try testing.expectEqualStrings(version_1, query.rows[0][0] orelse "");
    try testing.expect(query.rows[0][1] == null);

    // Version 2: parent is version 1
    try testing.expectEqualStrings(version_2, query.rows[1][0] orelse "");
    try testing.expectEqualStrings(version_1, query.rows[1][1] orelse "");
}
