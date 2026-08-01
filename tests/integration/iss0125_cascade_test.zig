//! ISS-0125 integration regression tests for FK cascade ordering.
//!
//! Requires a real PostgreSQL database through BPM_TEST_DB_URL. Each test uses
//! TestHarness transaction rollback and per-test random UUID fixtures.
const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

fn requireTestDatabaseUrl(allocator: std.mem.Allocator) !void {
    const env: std.process.Environ = .{ .block = .global };
    const url = env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-0125 integration tests\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
    allocator.free(url);
}

fn newUuid(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
}

fn expectCascadeConstraint(allocator: std.mem.Allocator, conn: anytype) !void {
    var rows = try conn.query(
        allocator,
        \\SELECT c.confdeltype::text
        \\FROM pg_constraint c
        \\JOIN pg_namespace n ON n.oid = c.connamespace
        \\WHERE n.nspname = current_schema()
        \\  AND c.conrelid = 'instance_definition_snapshots'::regclass
        \\  AND c.contype = 'f'
        \\  AND c.conname = 'instance_definition_snapshots_definition_id_fkey'
    ,
        &.{},
    );
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expectEqualStrings("c", rows.rows[0][0] orelse "");
}

fn insertDefinitionAndSnapshot(conn: anytype, definition_id: []const u8, instance_id: []const u8, name: []const u8) !void {
    try conn.exec(
        \\INSERT INTO process_definitions
        \\  (id, name, version, description, status, graph, created_by)
        \\VALUES ($1::uuid, $2, '1.0', 'ISS-0125 fixture', 'DRAFT',
        \\        '{"nodes":[],"edges":[]}'::jsonb, $3::uuid)
    ,
        &.{ definition_id, name, instance_id },
    );
    try conn.exec(
        \\INSERT INTO instance_definition_snapshots
        \\  (instance_id, definition_id, definition_name, definition_ver, graph)
        \\VALUES ($1::uuid, $2::uuid, $3, '1.0', '{"nodes":[],"edges":[]}'::jsonb)
    ,
        &.{ instance_id, definition_id, name },
    );
}

test "TC-ISS-0125-01: FK definition reports confdeltype cascade" {
    const allocator = std.testing.allocator;
    try requireTestDatabaseUrl(allocator);

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    try expectCascadeConstraint(allocator, &h.conn);
}

test "TC-ISS-0125-02: deleting process definition cascades to definition snapshot" {
    const allocator = std.testing.allocator;
    try requireTestDatabaseUrl(allocator);

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const definition_id = try newUuid(allocator);
    defer allocator.free(definition_id);
    const instance_id = try newUuid(allocator);
    defer allocator.free(instance_id);
    const name = try std.fmt.allocPrint(allocator, "iss0125-cascade-{s}", .{definition_id});
    defer allocator.free(name);

    try insertDefinitionAndSnapshot(&h.conn, definition_id, instance_id, name);
    try h.conn.exec("DELETE FROM process_definitions WHERE id = $1::uuid", &.{definition_id});

    var rows = try h.conn.query(
        allocator,
        "SELECT count(*)::text FROM instance_definition_snapshots WHERE definition_id = $1::uuid",
        &.{definition_id},
    );
    defer rows.deinit();
    try std.testing.expectEqualStrings("0", rows.rows[0][0] orelse "");
}

test "TC-ISS-0125-03: migration ALTER body reapplies cleanly" {
    const allocator = std.testing.allocator;
    try requireTestDatabaseUrl(allocator);

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const alter_body =
        \\ALTER TABLE instance_definition_snapshots
        \\    DROP CONSTRAINT IF EXISTS instance_definition_snapshots_definition_id_fkey;
        \\ALTER TABLE instance_definition_snapshots
        \\    ADD CONSTRAINT instance_definition_snapshots_definition_id_fkey
        \\    FOREIGN KEY (definition_id)
        \\    REFERENCES process_definitions(id)
        \\    ON DELETE CASCADE
    ;

    try h.conn.exec(alter_body, &.{});
    try h.conn.exec(alter_body, &.{});
    try expectCascadeConstraint(allocator, &h.conn);
}

test "TC-ISS-0125-04: cleanup helper propagates child DELETE errors" {
    const allocator = std.testing.allocator;
    try requireTestDatabaseUrl(allocator);

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const definition_id = try newUuid(allocator);
    defer allocator.free(definition_id);
    const instance_id = try newUuid(allocator);
    defer allocator.free(instance_id);
    const name = try std.fmt.allocPrint(allocator, "iss0125-cleanup-{s}", .{definition_id});
    defer allocator.free(name);

    try insertDefinitionAndSnapshot(&h.conn, definition_id, instance_id, name);
    try h.conn.exec(
        \\CREATE OR REPLACE FUNCTION iss0125_reject_snapshot_delete()
        \\RETURNS trigger LANGUAGE plpgsql AS $$
        \\BEGIN
        \\    RAISE EXCEPTION 'ISS-0125 forced child cleanup failure';
        \\END;
        \\$$;
        \\CREATE TRIGGER iss0125_reject_snapshot_delete_trigger
        \\BEFORE DELETE ON instance_definition_snapshots
        \\FOR EACH ROW EXECUTE FUNCTION iss0125_reject_snapshot_delete()
    ,
        &.{},
    );

    try std.testing.expectError(
        error.ServerError,
        helpers.cleanupDefinitionSnapshots(&h.conn, definition_id),
    );

    var rows = try h.conn.query(
        allocator,
        "SELECT count(*)::text FROM process_definitions WHERE id = $1::uuid",
        &.{definition_id},
    );
    defer rows.deinit();
    try std.testing.expectEqualStrings("1", rows.rows[0][0] orelse "");
}
