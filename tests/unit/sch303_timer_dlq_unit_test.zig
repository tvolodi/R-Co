//! Unit tests for ISS-303 — Timer DLQ routing on retry exhaustion.
//!
//! These tests verify pure-logic / file-presence properties that do not
//! require a live database:
//!
//!   TC-SCH-303-02: Migration 092 exists and contains expected column names.
//!
//! Source-inspection tests (TC-SCH-301-01, TC-SCH-301-02, TC-SCH-302-04) are
//! placed as inline tests inside src/scheduler/scheduler.zig (Zig idiom for
//! @embedFile within the declaring file's package root).
//!
//! Note: TC-SCH-303-01 (max_timer_fire_retries default = 3) is already covered
//! by TC-SCH-05-13 in tests/unit/sch05_missed_timer_recovery_test.zig.
const std = @import("std");
const testing = std.testing;

// TC-SCH-303-02: Migration file 092_iss303_timer_fire_error_count.sql exists
// and contains the `fire_error_count` and `failed_at` column definitions.
//
// Uses std.fs at runtime with a relative path from the project root CWD.
// The build step for unit tests sets CWD to the project root (b.path(".")).
test "TC-SCH-303-02: migration 092 exists and defines fire_error_count and failed_at" {
    const allocator = std.testing.allocator;
    const migration_path = "migrations/092_iss303_timer_fire_error_count.sql";

    const dir = std.Io.Dir.cwd();
    const content = dir.readFileAlloc(std.testing.io, migration_path, allocator, std.Io.Limit.limited(64 * 1024)) catch |err| {
        std.debug.print("Could not open {s}: {} (CWD must be project root)\n", .{ migration_path, err });
        return err;
    };
    defer allocator.free(content);

    // Both column names must appear in the migration.
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "fire_error_count"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "failed_at"));
    // Idempotent guard pattern must be present.
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "to_regclass"));
    try testing.expect(std.mem.containsAtLeast(u8, content, 1, "information_schema.columns"));
}

