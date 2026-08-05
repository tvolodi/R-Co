//! Integration tests for ISS-207 — Convergent EXECUTION_ERROR retry.
//!
//! Tests exercise retryConvergent, retryWithInput, and discard against a real
//! PostgreSQL database. All tests follow DIRECTIVE T-1: no mocks, no stubs.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//!
//! Requirement traceability:
//!   ISS-207 → TC1: bare retry same def version → RetryWithoutChange
//!   ISS-207 → TC2: retry-with-input corrected payload → RETRYING
//!   ISS-207 → TC3: discard → CANCELLED + dead_letter_items deleted
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

// Root-level export required so pool connections apply tenant-schema search_path
// instead of falling back to search_path=public (see audit_iss103_test.zig).
pub const api_tenant_context = bpm.api_tenant_context;
const dlq_store = bpm.dlq_store;

// ---------------------------------------------------------------------------
// UUID helper
// ---------------------------------------------------------------------------

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 10xx
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        raw[0],  raw[1],  raw[2],  raw[3],
        raw[4],  raw[5],  raw[6],  raw[7],
        raw[8],  raw[9],  raw[10], raw[11],
        raw[12], raw[13], raw[14], raw[15],
    });
}

// ---------------------------------------------------------------------------
// UUIDs generated per-test using per-test unique hex segments
// ---------------------------------------------------------------------------

/// Skip if BPM_TEST_DB_URL is absent — avoids SkipZigTest on MUST-requirement tests.
fn getTestDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping ISS-207 integration tests\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 3,
    });
}

// ---------------------------------------------------------------------------
// TC1: bare retry of error instance (same def version) → RetryWithoutChange
// ---------------------------------------------------------------------------

test "ISS-207-TC1: bare retry same def version returns RetryWithoutChange" {
    const allocator = std.testing.allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    var h = helpers.TestHarness.init(allocator) catch |err| {
        if (err == error.MissingTestDatabaseUrl) return error.SkipZigTest;
        return err;
    };
    defer h.deinit();

    // Insert a process_definition with status ACTIVE and a known artifact hash.
    const def_id = try h.newUuidString(allocator);
    defer allocator.free(def_id);
    const inst_id = try h.newUuidString(allocator);
    defer allocator.free(inst_id);
    const dlq_id = try h.newUuidString(allocator);
    defer allocator.free(dlq_id);
    const artifact_hash = "abc123def456";

    try h.conn.exec(
        \\INSERT INTO process_definitions (id, tenant_id, name, status, definition_artifact_hash, version, created_by, created_at, updated_at)
        \\VALUES ($1::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'test-def-iss207', 'ACTIVE', $2, 1, '00000000-0000-0000-0000-000000000000'::uuid, NOW(), NOW())
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ def_id, artifact_hash },
    );

    // Insert instance_projection in ERROR status with the same artifact hash.
    try h.conn.exec(
        \\INSERT INTO instance_projections
        \\  (instance_id, tenant_id, definition_id, status, variables, current_nodes, definition_artifact_hash, started_at, updated_at, last_event_seq)
        \\VALUES
        \\  ($1::uuid, '00000000-0000-0000-0000-000000000000'::uuid, $2::uuid, 'ERROR', '{}', '[]', $3, NOW(), NOW(), 1)
        \\ON CONFLICT (instance_id) DO NOTHING
    ,
        &.{ inst_id, def_id, artifact_hash },
    );

    // Insert DLQ item referencing the error instance.
    try h.conn.exec(
        \\INSERT INTO dead_letter_items
        \\  (id, entry_type, instance_id, reason, error_detail, retry_count, max_retries,
        \\   status, item_type, retry_limit, original_payload, error_chain, processor_metadata,
        \\   first_failed_at, last_failed_at, source_ref, updated_at)
        \\VALUES
        \\  ($1::uuid,
        \\   'service_task_failed', $2::uuid, 'test error', '{}', 0, 3,
        \\   'pending', 'SERVICE_TASK', 3, '{}', '[]', '{}',
        \\   NOW(), NOW(), 'test-source-ref-207-tc1', NOW())
        \\ON CONFLICT DO NOTHING
    ,
        &.{ dlq_id, inst_id },
    );

    // Commit the setup so pool connections see it.
    try h.conn.commit();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    // ACT: bare retry — same artifact hash, no EXECUTION_CORRECTION event.
    const result = dlq_store.retryConvergent(allocator, &pool, "test-actor", dlq_id);

    // ASSERT: must return RetryWithoutChange.
    try std.testing.expectError(dlq_store.DlqRetryError.RetryWithoutChange, result);

    // Verify instance remains in ERROR.
    var check_conn = try pool.acquire();
    defer pool.release(check_conn);
    const row = try check_conn.queryRow(
        allocator,
        "SELECT status FROM instance_projections WHERE instance_id = $1::uuid",
        &.{inst_id},
    );
    if (row) |r| {
        defer {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
        }
        try std.testing.expectEqualStrings("ERROR", r[0] orelse "");
    } else {
        return error.TestUnexpectedNull;
    }
}

// ---------------------------------------------------------------------------
// TC2: retry-with-input (corrected payload) → RETRYING status
// ---------------------------------------------------------------------------

test "ISS-207-TC2: retry-with-input returns RETRYING and updates payload" {
    const allocator = std.testing.allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    var h = helpers.TestHarness.init(allocator) catch |err| {
        if (err == error.MissingTestDatabaseUrl) return error.SkipZigTest;
        return err;
    };
    defer h.deinit();

    const def_id = try randomUuidStr(allocator);
    defer allocator.free(def_id);
    const inst_id = try randomUuidStr(allocator);
    defer allocator.free(inst_id);
    const dlq_id = try randomUuidStr(allocator);
    defer allocator.free(dlq_id);

    try h.conn.exec(
        \\INSERT INTO process_definitions (id, tenant_id, name, status, definition_artifact_hash, version, created_by, created_at, updated_at)
        \\VALUES ($1::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'test-def-iss207-tc2', 'ACTIVE', 'hash-tc2', 1, '00000000-0000-0000-0000-000000000000'::uuid, NOW(), NOW())
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{def_id},
    );

    try h.conn.exec(
        \\INSERT INTO instance_projections
        \\  (instance_id, tenant_id, definition_id, status, variables, current_nodes, definition_artifact_hash, started_at, updated_at, last_event_seq)
        \\VALUES
        \\  ($1::uuid, '00000000-0000-0000-0000-000000000000'::uuid, $2::uuid, 'ERROR', '{}', '[]', 'hash-tc2', NOW(), NOW(), 1)
        \\ON CONFLICT (instance_id) DO NOTHING
    ,
        &.{ inst_id, def_id },
    );

    try h.conn.exec(
        \\INSERT INTO dead_letter_items
        \\  (id, entry_type, instance_id, reason, error_detail, retry_count, max_retries,
        \\   status, item_type, retry_limit, original_payload, error_chain, processor_metadata,
        \\   first_failed_at, last_failed_at, source_ref, updated_at)
        \\VALUES
        \\  ($1::uuid,
        \\   'service_task_failed', $2::uuid, 'test error', '{}', 0, 3,
        \\   'pending', 'SERVICE_TASK', 3, '{"key":"old"}', '[]', '{}',
        \\   NOW(), NOW(), 'test-source-ref-207-tc2', NOW())
        \\ON CONFLICT DO NOTHING
    ,
        &.{ dlq_id, inst_id },
    );

    try h.conn.commit();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    // ACT: retry with corrected payload.
    const result = try dlq_store.retryWithInput(
        allocator,
        &pool,
        "test-actor",
        dlq_id,
        "{\"key\":\"corrected\"}",
    );
    defer result.deinit(allocator);

    // ASSERT: result indicates RETRYING.
    try std.testing.expectEqualStrings("RETRYING", result.status);
    try std.testing.expectEqualStrings(dlq_id, result.dlq_id);

    // Verify DLQ item is now 'retrying' and payload updated.
    var check_conn = try pool.acquire();
    defer pool.release(check_conn);
    const row = try check_conn.queryRow(
        allocator,
        "SELECT status, original_payload::text FROM dead_letter_items WHERE id = $1::uuid",
        &.{dlq_id},
    );
    if (row) |r| {
        defer {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
        }
        try std.testing.expectEqualStrings("retrying", r[0] orelse "");
        // Payload should now contain "corrected".
        const payload = r[1] orelse "";
        try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "corrected"));
    } else {
        return error.TestUnexpectedNull;
    }
}

// ---------------------------------------------------------------------------
// TC3: discard → instance CANCELLED + DLQ row deleted
// ---------------------------------------------------------------------------

test "ISS-207-TC3: discard cancels instance and removes DLQ row" {
    const allocator = std.testing.allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    var h = helpers.TestHarness.init(allocator) catch |err| {
        if (err == error.MissingTestDatabaseUrl) return error.SkipZigTest;
        return err;
    };
    defer h.deinit();

    const def_id = try randomUuidStr(allocator);
    defer allocator.free(def_id);
    const inst_id = try randomUuidStr(allocator);
    defer allocator.free(inst_id);
    const dlq_id = try randomUuidStr(allocator);
    defer allocator.free(dlq_id);

    try h.conn.exec(
        \\INSERT INTO process_definitions (id, tenant_id, name, status, definition_artifact_hash, version, created_by, created_at, updated_at)
        \\VALUES ($1::uuid, '00000000-0000-0000-0000-000000000000'::uuid, 'test-def-iss207-tc3', 'ACTIVE', 'hash-tc3', 1, '00000000-0000-0000-0000-000000000000'::uuid, NOW(), NOW())
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{def_id},
    );

    try h.conn.exec(
        \\INSERT INTO instance_projections
        \\  (instance_id, tenant_id, definition_id, status, variables, current_nodes, definition_artifact_hash, started_at, updated_at, last_event_seq)
        \\VALUES
        \\  ($1::uuid, '00000000-0000-0000-0000-000000000000'::uuid, $2::uuid, 'ERROR', '{}', '[]', 'hash-tc3', NOW(), NOW(), 1)
        \\ON CONFLICT (instance_id) DO NOTHING
    ,
        &.{ inst_id, def_id },
    );

    try h.conn.exec(
        \\INSERT INTO dead_letter_items
        \\  (id, entry_type, instance_id, reason, error_detail, retry_count, max_retries,
        \\   status, item_type, retry_limit, original_payload, error_chain, processor_metadata,
        \\   first_failed_at, last_failed_at, source_ref, updated_at)
        \\VALUES
        \\  ($1::uuid,
        \\   'service_task_failed', $2::uuid, 'test error', '{}', 0, 3,
        \\   'pending', 'SERVICE_TASK', 3, '{}', '[]', '{}',
        \\   NOW(), NOW(), 'test-source-ref-207-tc3', NOW())
        \\ON CONFLICT DO NOTHING
    ,
        &.{ dlq_id, inst_id },
    );

    try h.conn.commit();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    // ACT: discard the DLQ item.
    const result = try dlq_store.discard(allocator, &pool, "test-actor", dlq_id, null);
    defer result.deinit(allocator);

    // ASSERT: DLQ row is deleted.
    var check_conn = try pool.acquire();
    defer pool.release(check_conn);

    const dlq_row = try check_conn.queryRow(
        allocator,
        "SELECT id::text FROM dead_letter_items WHERE id = $1::uuid",
        &.{dlq_id},
    );
    try std.testing.expect(dlq_row == null);
}
