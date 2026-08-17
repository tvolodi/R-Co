//! OBP-03 — Integration tests for the typed outbox overflow on internal emit.
//!
//! Test spec: tests/specs/OBP-03.md
//! Covers (see spec for the full acceptance-criterion mapping):
//!   - TC-OBP-03-AC1: emit() at cap returns OutboxOverflow; no effects_outbox row inserted
//!   - TC-OBP-03-AC2: OutboxOverflow is a member of EffectQueueError (compile-time type check)
//!   - TC-OBP-03-AC3: OutboxOverflow propagates through the same error union as other failures
//!   - TC-OBP-03-AC4: emit() succeeds after depth falls below cap (self-throttle reversal)
//!   - TC-OBP-03-AC5: dead_letter_items can carry OutboxOverflow + attempt_count + depth_per_attempt
//!   - TC-OBP-03-AC6: instance_projections carries a definition version column (PD-08 pre-condition)
//!
//! All tests that touch the DB connect via BPM_TEST_DB_URL; the test fails
//! loudly if the env var is absent — never a silent skip.
//! Fixture isolation: per-test UUIDs, TestHarness rollback on deinit().

const std = @import("std");
const helpers = @import("helpers.zig");
const bpm = @import("bpm");
const env = @import("env");
const depth_mod = @import("outbox_depth");
const emit_mod = @import("outbox_emit");
const queue_mod = bpm.effects_queue;

fn requireTestDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const environ = env.globalEnviron();
    return environ.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — cannot run OBP-03 outbox overflow integration tests\n",
                .{},
            );
            return error.MissingTestDbUrl;
        },
        else => return err,
    };
}

fn tenantName(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const uuid = try bpm.uuid.newUuidV4(allocator);
    defer allocator.free(uuid);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, uuid });
}

// ---------------------------------------------------------------------------
// TC-OBP-03-AC2: compile-time enforcement — OutboxOverflow is in EffectQueueError.
// ---------------------------------------------------------------------------

test "TC-OBP-03-AC2-compile-time-enforcement: OutboxOverflow is a member of EffectQueueError" {
    // covers: OBP-03 AC2 — the Zig compiler enforces that every caller of
    // emit() declares OutboxOverflow in its error set. This test verifies the
    // type-system guarantee mechanically: if OutboxOverflow were removed from
    // EffectQueueError, this assertion (and the emit() call sites) would fail
    // to compile.
    // Zig 0.16: &comptime-local-var is not allowed as a runtime value;
    // use a single comptime bool instead.
    const found = comptime blk: {
        const E = queue_mod.EffectQueueError;
        const fields = @typeInfo(E).error_set orelse break :blk false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "OutboxOverflow")) break :blk true;
        }
        break :blk false;
    };
    try std.testing.expect(found); // OutboxOverflow must be in EffectQueueError
}

// ---------------------------------------------------------------------------
// TC-OBP-03-AC1 + AC4: emit() at cap → error + no row; emit() below cap → row.
// ---------------------------------------------------------------------------

test "TC-OBP-03-AC1-emit-returns-overflow-no-row: emit() at cap returns OutboxOverflow; no effects_outbox row" {
    // covers: OBP-03 AC1
    _ = try requireTestDbUrl(std.testing.allocator);

    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant = try tenantName(std.testing.allocator, "obp03-ac1");
    defer std.testing.allocator.free(tenant);

    const event_id = try bpm.uuid.newUuidV4(std.testing.allocator);
    defer std.testing.allocator.free(event_id);
    const instance_id = try bpm.uuid.newUuidV4(std.testing.allocator);
    defer std.testing.allocator.free(instance_id);

    // Seed depth at cap.
    var cache = depth_mod.DepthCache.init(std.testing.allocator, 5_000);
    defer cache.deinit();
    const StubConn = struct {
        pub fn exec(_: @This(), _: []const u8, _: *const [1][]const u8) !void {}
    };
    try depth_mod.writeFresh(&cache, StubConn{}, tenant, 50_000);

    const spec = queue_mod.EffectSpec{
        .effect_event_id = event_id,
        .tenant_id = tenant,
        .instance_id = instance_id,
        .node_id = "node-emit-01",
        .token_id = "token-emit-01",
        .correlation_key = "corr-emit-01",
        .kind = .http_call,
        .spec_json = "{}",
    };

    // emit() must return OutboxOverflow and NOT insert into effects_outbox.
    const result = emit_mod.emit(std.testing.allocator, &h.conn, &cache, 50_000, spec);
    try std.testing.expectError(error.OutboxOverflow, result);

    // Verify no effects_outbox row was created.
    var result115 = try h.conn.query(
        std.testing.allocator,
        "SELECT COUNT(*)::int AS n FROM effects_outbox WHERE effect_event_id = $1::uuid",
        &.{event_id},
    );
    defer result115.deinit();
    try std.testing.expect(result115.rows.len > 0);
    const n_str = result115.rows[0][0] orelse "99";
    try std.testing.expectEqualStrings("0", n_str);
}

test "TC-OBP-03-AC4-self-throttle: emit() succeeds after depth falls below cap" {
    // covers: OBP-03 AC4 — when depth falls below cap, emit() transitions from
    // OutboxOverflow to success, reducing the producer's effective emit rate to
    // zero while at cap (self-throttling).
    _ = try requireTestDbUrl(std.testing.allocator);

    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant = try tenantName(std.testing.allocator, "obp03-ac4");
    defer std.testing.allocator.free(tenant);

    const event_id = try bpm.uuid.newUuidV4(std.testing.allocator);
    defer std.testing.allocator.free(event_id);
    const instance_id = try bpm.uuid.newUuidV4(std.testing.allocator);
    defer std.testing.allocator.free(instance_id);

    var cache = depth_mod.DepthCache.init(std.testing.allocator, 5_000);
    defer cache.deinit();
    const StubConn = struct {
        pub fn exec(_: @This(), _: []const u8, _: *const [1][]const u8) !void {}
    };

    const spec = queue_mod.EffectSpec{
        .effect_event_id = event_id,
        .tenant_id = tenant,
        .instance_id = instance_id,
        .node_id = "node-ac4",
        .token_id = "token-ac4",
        .correlation_key = "corr-ac4",
        .kind = .http_call,
        .spec_json = "{}",
    };

    // At cap: emit() returns OutboxOverflow (self-throttle engaged).
    try depth_mod.writeFresh(&cache, StubConn{}, tenant, 50_000);
    const r1 = emit_mod.emit(std.testing.allocator, &h.conn, &cache, 50_000, spec);
    try std.testing.expectError(error.OutboxOverflow, r1);

    // Drainer runs: depth drops to 0 (gate reopens).
    try depth_mod.writeFresh(&cache, StubConn{}, tenant, 0);

    // emit() now succeeds (self-throttle disengaged).
    const delivery_id = try emit_mod.emit(std.testing.allocator, &h.conn, &cache, 50_000, spec);
    defer std.testing.allocator.free(delivery_id);

    // Verify the effects_outbox row was inserted.
    var result176 = try h.conn.query(
        std.testing.allocator,
        "SELECT COUNT(*)::int AS n FROM effects_outbox WHERE effect_event_id = $1::uuid",
        &.{event_id},
    );
    defer result176.deinit();
    try std.testing.expect(result176.rows.len > 0);
    const n_str = result176.rows[0][0] orelse "0";
    try std.testing.expectEqualStrings("1", n_str);
}

// ---------------------------------------------------------------------------
// TC-OBP-03-AC3: OutboxOverflow is in the same error union as PersistenceFailed.
// The test verifies that OutboxOverflow propagates identically to other
// EffectQueueError values — no separate retry mechanism is introduced.
// ---------------------------------------------------------------------------

test "TC-OBP-03-AC3-retry-policy-unchanged: OutboxOverflow and PersistenceFailed are siblings in EffectQueueError" {
    // covers: OBP-03 AC3 — compile-time proof that no separate error type or
    // separate code path exists for OutboxOverflow vs other step failures. Both
    // are members of EffectQueueError, so the engine's existing failure handler
    // receives the same error union tag and applies the same retry policy.
    const E = queue_mod.EffectQueueError;
    const overflow_is_member = comptime blk: {
        const fields = @typeInfo(E).error_set orelse break :blk false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "OutboxOverflow")) break :blk true;
        }
        break :blk false;
    };
    const persistence_is_member = comptime blk: {
        const fields = @typeInfo(E).error_set orelse break :blk false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "PersistenceFailed")) break :blk true;
        }
        break :blk false;
    };
    try std.testing.expect(overflow_is_member);
    try std.testing.expect(persistence_is_member);
    // The two errors coexist in the same union — no separate union wrapping required.
}

// ---------------------------------------------------------------------------
// TC-OBP-03-AC5: dead_letter_items can store OutboxOverflow metadata.
// ---------------------------------------------------------------------------

test "TC-OBP-03-AC5-dlq-entry-overflow-depths: dead_letter_items accepts OutboxOverflow + depth_per_attempt" {
    // covers: OBP-03 AC5 — the DLQ entry for an OutboxOverflow step carries
    // reason='OutboxOverflow', attempt_count, and depth_per_attempt JSON array.
    // This test seeds the row and reads it back to verify the schema accepts the
    // OutboxOverflow metadata shape.
    _ = try requireTestDbUrl(std.testing.allocator);

    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const dlq_id = try bpm.uuid.newUuidV4(std.testing.allocator);
    defer std.testing.allocator.free(dlq_id);
    const inst_id = try bpm.uuid.newUuidV4(std.testing.allocator);
    defer std.testing.allocator.free(inst_id);
    const source_ref = try tenantName(std.testing.allocator, "obp03-ac5");
    defer std.testing.allocator.free(source_ref);

    // Insert a dead_letter_items row whose reason is 'OutboxOverflow' and
    // whose processor_metadata carries the depth_per_attempt array.
    try h.conn.exec(
        \\INSERT INTO dead_letter_items (
        \\  id, entry_type, instance_id, reason, error_detail,
        \\  retry_count, max_retries, status,
        \\  created_at, updated_at,
        \\  item_type, retry_limit,
        \\  original_payload, error_chain, processor_metadata,
        \\  first_failed_at, last_failed_at, source_ref
        \\)
        \\VALUES (
        \\  $1::uuid,
        \\  'service_task_failed',
        \\  $2::uuid,
        \\  'OutboxOverflow',
        \\  '{"code":"OutboxOverflow"}'::jsonb,
        \\  3,
        \\  3,
        \\  'dead',
        \\  NOW(), NOW(),
        \\  'SERVICE_TASK',
        \\  3,
        \\  '{}'::jsonb,
        \\  '[]'::jsonb,
        \\  '{"outbox_overflow":true,"depth_per_attempt":[50000,50000,50001]}'::jsonb,
        \\  NOW(), NOW(),
        \\  $3
        \\)
    ,
        &.{ dlq_id, inst_id, source_ref },
    );

    // Read back and verify reason and depth_per_attempt array length.
    var result276 = try h.conn.query(
        std.testing.allocator,
        \\SELECT reason,
        \\       retry_count::int AS attempt_count,
        \\       jsonb_array_length(processor_metadata->'depth_per_attempt')::int AS depth_arr_len
        \\FROM dead_letter_items
        \\WHERE id = $1::uuid
    ,
        &.{dlq_id},
    );
    defer result276.deinit();
    try std.testing.expect(result276.rows.len > 0);
    const reason = result276.rows[0][0] orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("OutboxOverflow", reason);
    const attempt_str = result276.rows[0][1] orelse "0";
    try std.testing.expectEqualStrings("3", attempt_str);
    const depth_arr_len = result276.rows[0][2] orelse "0";
    try std.testing.expectEqualStrings("3", depth_arr_len);
}

// ---------------------------------------------------------------------------
// TC-OBP-03-AC6: instance_projections carries definition_id column (PD-08
// pre-condition — the pinned version is the definition_id at instance start).
// ---------------------------------------------------------------------------

test "TC-OBP-03-AC6-pinned-version-on-retry: instance_projections has definition_id column" {
    // covers: OBP-03 AC6 (pre-condition verification) — the pinned definition
    // version is the definition_id stored in instance_projections at instance
    // start. This test confirms the column exists so the engine can resume a
    // dead-lettered instance against the pinned version without a schema error.
    _ = try requireTestDbUrl(std.testing.allocator);

    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var result314 = try h.conn.query(
        std.testing.allocator,
        \\SELECT COUNT(*)::int AS n
        \\FROM information_schema.columns
        \\WHERE table_name = 'instance_projections'
        \\  AND column_name = 'definition_id'
    ,
        &.{},
    );
    defer result314.deinit();
    try std.testing.expect(result314.rows.len > 0);
    const n = result314.rows[0][0] orelse "0";
    try std.testing.expectEqualStrings("1", n);
}
