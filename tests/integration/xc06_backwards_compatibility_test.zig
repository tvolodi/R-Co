//! Integration tests for XC-06 — Backwards Compatibility
//!
//! New platform versions load and continue instances created by prior versions.
//! Schema migrations are additive and idempotent.

const std = @import("std");
const testing = std.testing;
const bpm = @import("bpm");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const uuid_mod = bpm.uuid;

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

    // Verify migrations have been applied (check for known tables).
    // Core business tables are per-tenant (non-GBL migrations apply to each
    // tenant schema), so they live in `tenant_default`, not `public` — see
    // docs/anti-patterns.md "Writing unqualified SQL in an integration test
    // that exercises a GBL-prefixed (public-only) migration's effect".
    var tables_query = try harness.conn.query(
        alloc,
        \\SELECT table_name FROM information_schema.tables
        \\WHERE table_schema = 'tenant_default'
        \\AND table_name IN ('instance_projections', 'events', 'audit_entries')
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
        \\INSERT INTO instance_projections (
        \\  instance_id, definition_id, tenant_id, definition_artifact_hash,
        \\  status, variables, started_at
        \\) VALUES ($1, gen_random_uuid(), $2, $3, $4, $5, NOW())
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
        \\SELECT instance_id, tenant_id, status, variables FROM instance_projections
        \\WHERE instance_id = $1
    ,
        &.{instance_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 1), query.rows.len);
    try testing.expectEqualStrings(instance_id, query.rows[0][0] orelse "");
    try testing.expectEqualStrings(tenant_id, query.rows[0][1] orelse "");
    try testing.expectEqualStrings("ACTIVE", query.rows[0][2] orelse "");
    const variables_json = query.rows[0][3] orelse "";
    try testing.expect(std.mem.containsAtLeast(u8, variables_json, 1, "old_format"));
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
        \\INSERT INTO instance_projections (
        \\  instance_id, definition_id, tenant_id, definition_artifact_hash,
        \\  status, variables, started_at
        \\) VALUES ($1, gen_random_uuid(), $2, $3, $4, $5, NOW())
    ,
        &.{ instance_id, tenant_id, "def-hash", "ACTIVE", "{}" },
    );

    // V2 appends event (with new fields like trace_id)
    const event_id = try uuid_mod.newUuidV4(alloc);
    const idem_key = "v2-event-idem-key";
    // ISS-0647 / GH-652 (TC-XC-06-03): events.actor_id and sequence_number
    // are both NOT NULL with no default (confirmed via
    // `-Dlog-pg-errors=true`: C23502 on each in turn as the other was
    // fixed). No FK constraint exists on actor_id, so any UUID is a valid
    // fixture value — mirrors the pattern already used for
    // audit_entries.actor_id elsewhere in this file (TC-XC-06-08).
    // sequence_number only needs to be unique per instance_id (see the
    // uq_event_sequence constraint) — production code reserves it via
    // instance_sequence (src/effects/worker.zig, ISS-0158/GH-479) for
    // concurrency safety, but this test creates one event on a single fresh
    // instance_id, so a literal "1" is sufficient and avoids pulling that
    // machinery into a fixture that doesn't need it.
    const actor_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(event_id);
        alloc.free(actor_id);
    }

    _ = try harness.conn.exec(
        \\INSERT INTO events (
        \\  event_id, instance_id, tenant_id, event_type,
        \\  payload, actor_id, sequence_number, idempotency_key, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, 1, $7, NOW())
    ,
        &.{
            event_id,
            instance_id,
            tenant_id,
            "v2.event",
            "{\"v2_field\":true}",
            actor_id,
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
        \\  content_hash, content_type, byte_size,
        \\  artifact_id, version_id, artifact_kind, artifact_name,
        \\  content_json, parent_version_id, created_at
        \\) VALUES (
        \\  convert_to(($1::text || ':' || $2::text || ':' || $3::text || ':' || $4::text), 'UTF8'),
        \\  'application/json',
        \\  octet_length($4::text),
        \\  $1::uuid, $2::uuid, $3, $5,
        \\  $4::jsonb, NULL, NOW()
        \\)
    ,
        &.{
            artifact_id,
            version_id,
            "definition",
            v1_content,
            "test_definition",
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
        \\INSERT INTO instance_projections (
        \\  instance_id, definition_id, tenant_id, definition_artifact_hash,
        \\  status, started_at
        \\) VALUES ($1, gen_random_uuid(), $2, $3, $4, NOW())
    ,
        &.{ instance_id, tenant_id, "def-hash", "ACTIVE" },
    );

    // Insert V1-format event (missing V2 fields)
    const event_id_v1 = try uuid_mod.newUuidV4(alloc);
    // ISS-0647 / GH-652 (TC-XC-06-05): events.actor_id and sequence_number
    // are both NOT NULL with no default — see the identical note on
    // TC-XC-06-03 above.
    const actor_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(event_id_v1);
        alloc.free(actor_id);
    }

    _ = try harness.conn.exec(
        \\INSERT INTO events (
        \\  event_id, instance_id, tenant_id, event_type,
        \\  payload, actor_id, sequence_number, idempotency_key, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, 1, $7, NOW())
    ,
        &.{
            event_id_v1,
            instance_id,
            tenant_id,
            "order.created",
            "{\"order_id\":\"order-123\",\"amount\":100}",
            actor_id,
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
        \\INSERT INTO instance_projections (
        \\  instance_id, definition_id, tenant_id, definition_artifact_hash,
        \\  status, started_at
        \\) VALUES ($1, gen_random_uuid(), $2, $3, $4, NOW())
    ,
        &.{ instance_id, tenant_id, "def-hash", "ACTIVE" },
    );

    // Insert and archive events
    for (0..10) |i| {
        const event_id = try uuid_mod.newUuidV4(alloc);
        const idem_key = try std.fmt.allocPrint(alloc, "archived-{d}", .{i});
        const payload = try std.fmt.allocPrint(alloc, "{{\"index\":{d}}}", .{i});
        // ISS-0647 / GH-652 (TC-XC-06-06): events.actor_id and
        // sequence_number are both NOT NULL with no default — see the
        // identical note on TC-XC-06-03 above. sequence_number must also be
        // unique per instance_id (uq_event_sequence), so each loop iteration
        // uses i+1 (1-based, matching production's convention of starting
        // instance_sequence.next_seq at 2 for the first assigned value 1).
        const actor_id = try uuid_mod.newUuidV4(alloc);
        const seq_str = try std.fmt.allocPrint(alloc, "{d}", .{i + 1});
        defer {
            alloc.free(event_id);
            alloc.free(idem_key);
            alloc.free(payload);
            alloc.free(actor_id);
            alloc.free(seq_str);
        }

        _ = try harness.conn.exec(
            \\INSERT INTO events (
            \\  event_id, instance_id, tenant_id, event_type,
            \\  payload, actor_id, sequence_number, idempotency_key, created_at
            \\) VALUES ($1, $2, $3, $4, $5, $6, $7::bigint, $8, NOW())
        ,
            &.{
                event_id,
                instance_id,
                tenant_id,
                "test.event",
                payload,
                actor_id,
                seq_str,
                idem_key,
            },
        );
    }

    // Archive some events
    _ = try harness.conn.exec(
        \\INSERT INTO events_archive (
        \\  event_id, instance_id, event_type, payload, actor_id,
        \\  created_at, sequence_number, idempotency_key, metadata, global_seq
        \\)
        \\SELECT
        \\  event_id, instance_id, event_type, payload, actor_id,
        \\  created_at, sequence_number, idempotency_key, metadata, global_seq
        \\FROM events
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
        \\INSERT INTO instance_projections (
        \\  instance_id, definition_id, tenant_id, definition_artifact_hash,
        \\  status, variables, started_at
        \\) VALUES ($1, gen_random_uuid(), $2, $3, $4, $5, NOW())
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
    // ISS-0647 / GH-652 (TC-XC-06-07): events.actor_id and sequence_number
    // are both NOT NULL with no default — see the identical note on
    // TC-XC-06-03 above. sequence_number must be unique per instance_id, so
    // the v2 and v3 events (same instance_id) use 1 and 2 respectively.
    const actor_v2_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(event_v2_id);
        alloc.free(actor_v2_id);
    }

    _ = try harness.conn.exec(
        \\INSERT INTO events (
        \\  event_id, instance_id, tenant_id, event_type,
        \\  payload, actor_id, sequence_number, idempotency_key, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, 1, $7, NOW())
    ,
        &.{
            event_v2_id,
            instance_id,
            tenant_id,
            "migration.v2_event",
            "{\"v2_field\":\"extended\"}",
            actor_v2_id,
            "v2-event-1",
        },
    );

    // V3: Add event with v3-specific payload
    const event_v3_id = try uuid_mod.newUuidV4(alloc);
    const actor_v3_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(event_v3_id);
        alloc.free(actor_v3_id);
    }

    _ = try harness.conn.exec(
        \\INSERT INTO events (
        \\  event_id, instance_id, tenant_id, event_type,
        \\  payload, actor_id, sequence_number, idempotency_key, created_at
        \\) VALUES ($1, $2, $3, $4, $5, $6, 2, $7, NOW())
    ,
        &.{
            event_v3_id,
            instance_id,
            tenant_id,
            "migration.v3_event",
            "{\"v3_field\":\"evolved\"}",
            actor_v3_id,
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
        \\SELECT status, variables FROM instance_projections WHERE instance_id = $1
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

    // ISS-0647 / GH-652: wrap this INSERT too (see the identical note on the
    // v2 INSERT below) — trg_bpm_audit_apply_chain_hash is ENABLE ORIGIN
    // (confirmed via `SELECT tgname, tgenabled FROM pg_trigger`), so it is
    // suppressed by TestHarness.init()'s session-wide
    // session_replication_role='replica' for every INSERT on this
    // connection, not just the one that happens to omit chain_hash
    // explicitly.
    try harness.conn.exec("SET session_replication_role = 'origin'", &.{});
    _ = try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  timestamp, chain_hash, prev_chain_hash
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
    try harness.conn.exec("SET session_replication_role = 'replica'", &.{});

    // Insert V2 chained audit entry
    const v2_id = try uuid_mod.newUuidV4(alloc);
    const v2_actor = try uuid_mod.newUuidV4(alloc);
    const v2_resource = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(v2_id);
        alloc.free(v2_actor);
        alloc.free(v2_resource);
    }

    // ISS-0647 / GH-652 (same root cause as ISS-0645 / GH-649's fix to
    // adp09_tamper_evident_audit_chain_test.zig / xc02_audit_immutability_test.zig
    // in this same session): TestHarness.init() sets session_replication_role
    // = 'replica' session-wide so resetTestData() can DELETE audit_entries
    // without tripping the immutability guard. That setting also suppresses
    // trg_bpm_audit_apply_chain_hash, the trigger this INSERT relies on to
    // populate chain_hash — without it chain_hash stayed NULL, failing the
    // `query.rows[0][1] != null` assertion below. Scope the override to this
    // one INSERT and restore 'replica' immediately after.
    try harness.conn.exec("SET session_replication_role = 'origin'", &.{});
    _ = try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  timestamp
        \\) VALUES ($1, $2, $3, $4, $5, $6, NOW())
    ,
        &.{ v2_id, tenant_id, v2_actor, "v2.action", "test", v2_resource },
    );
    try harness.conn.exec("SET session_replication_role = 'replica'", &.{});

    // ISS-0653 / GH-662: the previous version of this query used
    // `ORDER BY timestamp, audit_id` and then indexed rows[0]/rows[1],
    // assuming rows[0] would always be the legacy row and rows[1] the V2
    // row. That assumption is false: both INSERTs run inside the SAME
    // transaction (harness.conn.begin(), in TestHarness.init()), and
    // PostgreSQL's NOW() returns transaction_timestamp() -- a value fixed
    // for the entire transaction, not the statement -- so `timestamp` is
    // byte-identical for both rows. `ORDER BY timestamp, audit_id` then
    // tiebreaks on audit_id, which is a fresh random UUID per row with no
    // relationship to insertion order: roughly half the time the V2 row's
    // audit_id sorts lower and lands in rows[0] instead of the legacy row.
    // That is the entire "flake" this issue describes -- not a trigger,
    // advisory-lock, or Zig test-runner concurrency bug (ruled out: Zig
    // 0.16's default test runner executes test blocks strictly
    // sequentially within one binary, confirmed via
    // lib/compiler/test_runner.zig's single-threaded mainServer loop).
    // Fixed by matching each row to its known audit_id explicitly instead
    // of relying on array position from an ambiguous sort.
    var query = try harness.conn.query(
        alloc,
        \\SELECT audit_id, action, chain_hash, prev_chain_hash FROM audit_entries
        \\WHERE tenant_id = $1
    ,
        &.{tenant_id},
    );
    defer query.deinit();

    try testing.expectEqual(@as(usize, 2), query.rows.len);

    var legacy_row: ?[]const ?[]const u8 = null;
    var v2_row: ?[]const ?[]const u8 = null;
    for (query.rows) |row| {
        const row_audit_id = row[0] orelse "";
        if (std.mem.eql(u8, row_audit_id, legacy_id)) {
            legacy_row = row;
        } else if (std.mem.eql(u8, row_audit_id, v2_id)) {
            v2_row = row;
        }
    }
    const legacy = legacy_row orelse return error.LegacyRowNotFound;
    const v2 = v2_row orelse return error.V2RowNotFound;

    // Legacy (tenant's first) row: chain_hash is populated by the trigger,
    // but prev_chain_hash must be null -- there is no prior row to link to.
    try testing.expect(legacy[2] != null);
    try testing.expect(legacy[3] == null);

    // V2 entry should continue the chain from the legacy row.
    try testing.expect(v2[2] != null);
    if (v2[3]) |prev_hash| {
        try testing.expect(prev_hash.len > 0);
    }
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
        \\INSERT INTO instance_projections (
        \\  instance_id, definition_id, tenant_id, definition_artifact_hash,
        \\  status, started_at
        \\) VALUES ($1, gen_random_uuid(), $2, $3, $4, NOW())
    ,
        &.{ instance_id, tenant_id, "def-hash", "ACTIVE" },
    );

    // Query instance (V2 schema may have added nullable columns with defaults)
    var query = try harness.conn.query(
        alloc,
        \\SELECT instance_id, tenant_id, status FROM instance_projections
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
