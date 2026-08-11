// Integration tests for PAR-03's retention_class column, its two CHECK
// constraints (chk_retention_class, chk_retention_class_protected_family),
// and the hand-written events_ephemeral table (migration
// 1149_par03_retention_class.sql), hand-written from
// templates/specs/par-03-retention-class.migration.yaml's test scaffold.
//
// BPM_TEST_DB_URL must be set; the test connects to a real PostgreSQL.
const std = @import("std");
const helpers = @import("helpers.zig");

fn randomEventTypeName(h: *helpers.TestHarness, allocator: std.mem.Allocator) ![]u8 {
    const id = try h.newUuidString(allocator);
    defer allocator.free(id);
    return std.fmt.allocPrint(allocator, "PAR03_TYPE_{s}", .{id});
}

// TC (PAR-03): a retention_class outside retain_forever/archive_queryable/
// delete is rejected by chk_retention_class.
test "par03_retention_class: check_constraint_rejects_unknown_value" {
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const type_name = try randomEventTypeName(&h, alloc);
    defer alloc.free(type_name);

    try h.conn.exec(
        "INSERT INTO event_type_registry (name, schema_version, json_schema) VALUES ($1, 1, '{}')",
        &.{type_name},
    );

    try h.conn.exec("BEGIN", &.{});
    try h.conn.exec("SAVEPOINT before_bogus", &.{});
    const result = h.conn.exec(
        "UPDATE event_type_registry SET retention_class = 'BOGUS' WHERE name = $1",
        &.{type_name},
    );
    try std.testing.expectError(error.ServerError, result);
    try h.conn.exec("ROLLBACK TO SAVEPOINT before_bogus", &.{});

    var rows = try h.conn.query(
        alloc,
        "SELECT retention_class FROM event_type_registry WHERE name = $1",
        &.{type_name},
    );
    defer rows.deinit();
    try std.testing.expectEqualStrings("archive_queryable", rows.rows[0][0] orelse "");
}

// TC (PAR-03 AC1, REWORK 1): a direct SQL UPDATE setting retention_class =
// 'delete' for a protected-family name is rejected by
// chk_retention_class_protected_family, even when it bypasses
// Registry.registerType()'s app-level guard entirely (this fixture issues raw
// SQL, no Registry call — the app-level RetentionClassForbidden guard is
// exercised separately by a Registry-level unit test, see
// tests/unit/registry_retention_class_test.zig).
test "par03_retention_class: protected_family_delete_rejected_by_db_check" {
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const uuid_str = try h.newUuidString(alloc);
    defer alloc.free(uuid_str);
    const protected_name = try std.fmt.allocPrint(alloc, "INSTANCE_PAR03_{s}", .{uuid_str});
    defer alloc.free(protected_name);

    try h.conn.exec(
        "INSERT INTO event_type_registry (name, schema_version, json_schema) VALUES ($1, 1, '{}')",
        &.{protected_name},
    );

    try h.conn.exec("BEGIN", &.{});
    try h.conn.exec("SAVEPOINT before_protected_delete", &.{});
    const result = h.conn.exec(
        "UPDATE event_type_registry SET retention_class = 'delete' WHERE name = $1",
        &.{protected_name},
    );
    try std.testing.expectError(error.ServerError, result);
    try h.conn.exec("ROLLBACK TO SAVEPOINT before_protected_delete", &.{});

    var rows = try h.conn.query(
        alloc,
        "SELECT retention_class FROM event_type_registry WHERE name = $1",
        &.{protected_name},
    );
    defer rows.deinit();
    try std.testing.expectEqualStrings("archive_queryable", rows.rows[0][0] orelse "");
}

// TC (PAR-03): a newly registered event type defaults to archive_queryable,
// not delete.
test "par03_retention_class: defaults_to_archive_queryable" {
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const type_name = try randomEventTypeName(&h, alloc);
    defer alloc.free(type_name);

    try h.conn.exec(
        "INSERT INTO event_type_registry (name, schema_version, json_schema) VALUES ($1, 1, '{}')",
        &.{type_name},
    );

    var rows = try h.conn.query(
        alloc,
        "SELECT retention_class FROM event_type_registry WHERE name = $1",
        &.{type_name},
    );
    defer rows.deinit();
    try std.testing.expectEqualStrings("archive_queryable", rows.rows[0][0] orelse "");
}

// TC (PAR-03): events_ephemeral's (event_id, created_at) composite PK accepts
// a well-formed insert and rejects a duplicate pair. events_ephemeral itself
// is hand-written in migration 1149 (codegen cannot express PARTITION BY or a
// composite PK) — this exercises that hand-written portion.
test "par03_retention_class: events_ephemeral_accepts_row_with_composite_pk" {
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const event_id = try h.newUuidString(alloc);
    defer alloc.free(event_id);
    const instance_id = try h.newUuidString(alloc);
    defer alloc.free(instance_id);
    const actor_id = try h.newUuidString(alloc);
    defer alloc.free(actor_id);
    const idem_key = try h.newUuidString(alloc);
    defer alloc.free(idem_key);
    const tenant_id = "00000000-0000-0000-0000-000000000000";

    // Fetch the server's own `now()` ONCE and reuse it as an explicit
    // created_at parameter on every subsequent INSERT in this test, rather
    // than letting each statement default to its own now() call (which,
    // across separate autocommit statements, could differ by microseconds
    // and make the composite-PK collision assertion below non-deterministic)
    // or hardcoding a fixed calendar date (which must fall inside whatever
    // 3-month partition window migration 1149 actually seeded relative to
    // whenever it ran — a hardcoded literal like 2026-01-01 is NOT guaranteed
    // to be covered and fails with "no partition of relation events_ephemeral
    // found for row", confirmed live against bpm_test).
    var now_rows = try h.conn.query(alloc, "SELECT now()::text", &.{});
    defer now_rows.deinit();
    const created_at_text = try alloc.dupe(u8, now_rows.rows[0][0] orelse "");
    defer alloc.free(created_at_text);

    try h.conn.exec(
        "INSERT INTO events_ephemeral (event_id, instance_id, event_type, actor_id, " ++
            "created_at, sequence_number, idempotency_key, global_seq, tenant_id) " ++
            "VALUES ($1::uuid, $2::uuid, 'SOME_DELETE_CLASS_TYPE', $3::uuid, $6::timestamptz, 1, $4, 1, $5::uuid)",
        &.{ event_id, instance_id, actor_id, idem_key, tenant_id, created_at_text },
    );

    var rows = try h.conn.query(
        alloc,
        "SELECT COUNT(*) FROM events_ephemeral WHERE event_id = $1::uuid",
        &.{event_id},
    );
    defer rows.deinit();
    const count = std.fmt.parseInt(i64, rows.rows[0][0] orelse "0", 10) catch -1;
    try std.testing.expectEqual(@as(i64, 1), count);

    // A second INSERT with the SAME (event_id, created_at) pair fails with a
    // primary-key violation.
    const idem_key2 = try h.newUuidString(alloc);
    defer alloc.free(idem_key2);

    try h.conn.exec("BEGIN", &.{});
    try h.conn.exec("SAVEPOINT before_pk_violation", &.{});
    const dup_result = h.conn.exec(
        "INSERT INTO events_ephemeral (event_id, instance_id, event_type, actor_id, " ++
            "created_at, sequence_number, idempotency_key, global_seq, tenant_id) " ++
            "VALUES ($1::uuid, $2::uuid, 'SOME_DELETE_CLASS_TYPE', $3::uuid, $6::timestamptz, 2, $4, 2, $5::uuid)",
        &.{ event_id, instance_id, actor_id, idem_key2, tenant_id, created_at_text },
    );
    try std.testing.expectError(error.ServerError, dup_result);
    try h.conn.exec("ROLLBACK TO SAVEPOINT before_pk_violation", &.{});
}
