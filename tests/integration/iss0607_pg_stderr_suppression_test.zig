// ISS-0607 / GH-542 — regression test for the vendor/pg/pg.zig stderr
// suppression fix.
//
// Background (see src/design/iss0607-pg-stderr-suppression.md):
// vendor/pg/pg.zig used to emit `std.debug.print("\nPOSTGRES ERROR: ...",
// ..)` for EVERY ErrorResponse message, regardless of cause. The `zig
// test` runner treats any stderr output during a test binary as a
// hard failure for that binary, so any negative-path integration test
// (iss107 TC-04 UPDATE storage_mode='BOGUS', iss0605 constraint
// violations, and every expectError(error.ServerError, …) test in the
// repo) aborted the entire binary BEFORE its `expectError` assertion
// ever ran.
//
// Fix: the print is now gated on `build_options.log_pg_errors`, which
// is wired through `build.zig` as `-Dlog-pg-errors=<bool>` and defaults
// to false. The typed `PgError.ServerError` return value is preserved
// unchanged.
//
// What THIS test proves:
//   1. The test binary reaches `expectError(error.ServerError, …)`
//      instead of aborting on stderr.
//   2. `PgError.ServerError` is still the typed return value (no
//      swallowing, no rewrite — the gate is purely a side-effect
//      suppression).
//
// DIRECTIVE T-1: no mocks, no in-memory fakes. Real PostgreSQL via
// BPM_TEST_DB_URL. Per-test UUID. Real CHECK constraint violation.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const helpers = @import("helpers.zig");

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is required for ISS-0607 regression tests\n",
                .{},
            );
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

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
// TC-ISS-0607-01: negative-path integration test runs to completion.
//
// Pre-fix: vendor/pg/pg.zig unconditionally writes
// `POSTGRES ERROR: ERROR:  new row for relation "tenant" violates
// check constraint "tenant_storage_mode_check" (23514)` to stderr
// during the 'E' (ErrorResponse) arm of readUntilReady, BEFORE the
// exec() call returns error.ServerError. zig test aborts the binary
// on the stderr write, so the `expectError` assertion below is never
// reached.
//
// Post-fix: build_options.log_pg_errors = false by default, the print
// is compiled out, and the binary reaches the assertion. The test
// PASSES iff:
//   (a) the binary reaches this line at all (i.e. stderr did not abort it), and
//   (b) pg.Conn.exec returns error.ServerError for a real CHECK violation.
// ---------------------------------------------------------------------------

test "regression: ISS-0607 — negative-path test runs to completion (no stderr abort)" {
    const allocator = std.testing.allocator;
    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const tenant_id_uuid = try randomUuidStr(allocator);
    defer allocator.free(tenant_id_uuid);

    // Seed a tenant row inside the harness's transaction (the harness rolls
    // back on deinit, so this row never leaks to other tests).
    // Slug starts with the test-fixture prefix 'tc-' so the GBL-103 ISS-503
    // guard excludes it from production code paths (lint_test_isolation C5).
    try h.conn.exec(
        "INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id) " ++
            "VALUES ($1::uuid, 'tc-iss0607-neg', 'ISS-0607 Negative Test', 'ACTIVE', 'realm-iss0607', 'test', '00000000-0000-0000-0000-000000000000'::uuid)",
        &.{tenant_id_uuid},
    );

    // Establish a savepoint so the violation does not abort the harness
    // transaction (mirrors iss107 TC-04).
    try h.conn.exec("SAVEPOINT before_bogus", &.{});

    const update_result = h.conn.exec(
        "UPDATE public.tenant SET storage_mode = 'BOGUS' WHERE id = $1::uuid",
        &.{tenant_id_uuid},
    );

    // (a) Reaching this assertion means zig test did NOT abort on the
    //     vendor/pg/pg.zig stderr print — the gate worked.
    // (b) The typed error is still error.ServerError — the gate is purely
    //     a side-effect suppression, not a swallow/rewrite.
    try std.testing.expectError(error.ServerError, update_result);

    // Restore the connection so the harness rollback on deinit succeeds
    // cleanly even after the constraint violation.
    h.conn.exec("ROLLBACK TO SAVEPOINT before_bogus", &.{}) catch {};
}
