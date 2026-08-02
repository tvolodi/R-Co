//! ISS-0123 / GitHub tvolodi/R-Co#389 — regression tests for the DLQ rename
//! (Cluster B) and the obs05 audit-trigger isolation (Cluster A) fixes.
//!
//! See `src/design/dlq_rename_and_trigger_isolation.md` and
//! `docs/issue-reports/ISS-0123-root-cause.yaml` for the diagnosis.
//!
//! These tests follow DIRECTIVE T-1: real PostgreSQL via `BPM_TEST_DB_URL`,
//! no mocks, no stubs, no `error.SkipZigTest`. The
//! `requireTestDatabaseUrl` helper fails the test with the typed
//! `error.MissingTestDatabaseUrl` (matching `helpers.zig`'s contract) when
//! the env var is absent — the failure is reported, not silently swallowed.
//!
//! Both tests are part of the `test-integration` family. Per the handoff
//! scope, this file is created here and is intended to be wired into
//! `build.zig` and `tests/integration/main_test.zig` by a follow-up
//! BACKEND-DEV step (see `tests/specs/ISS-0123-regression.md` §Wiring).
//!
//! Requirement traceability:
//!   ISS-0123 → TC-ISS-0123-01: no `dead_letter_queue` literal in source/test
//!   ISS-0123 → TC-ISS-0123-02: normal audit INSERT succeeds after obs05 savepoint
const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

// ---------------------------------------------------------------------------
// Test infrastructure helpers (per-test UUIDs, BPM_TEST_DB_URL gate).
// ---------------------------------------------------------------------------

fn fillRandom(buf: []u8) void {
    // Same platform-conditional source as iss0125_cascade_test.zig and
    // iss207_error_retry_test.zig. Production tests use std.crypto.random;
    // these helpers are the project's established Windows-compatible
    // idiom for per-test UUID generation in the integration suite.
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.arc4random_buf(buf.ptr, buf.len),
        else => @compileError("fillRandom: unsupported OS — add a platform branch"),
    }
}

/// Hard-fail the test with `error.MissingTestDatabaseUrl` when
/// `BPM_TEST_DB_URL` is absent. The failure is reported loudly via
/// `std.debug.print` (the harness is going to print the same message
/// shortly after, but the explicit print here makes the test's
/// infrastructure-unavailable reason obvious in CI logs).
///
/// `error.SkipZigTest` is FORBIDDEN here — the project rule is that
/// a skipped MUST test = requirement stays PENDING. We fail instead.
fn requireTestDatabaseUrl(allocator: std.mem.Allocator) !void {
    const env: std.process.Environ = .{ .block = .global };
    const url = env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-0123 integration tests (test infrastructure unavailable)\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
    allocator.free(url);
}

/// Generate a fresh v4 UUID for per-test fixture isolation. NOT a hardcoded
/// literal — per-test UUIDs are mandatory per test_infrastructure_guide.md
/// §9 "Correct pattern: per-test UUIDs with unconditional defer cleanup".
fn newUuid(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    fillRandom(&bytes);
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

// ---------------------------------------------------------------------------
// TC-ISS-0123-01 — Cluster B source-assertion canary
// ---------------------------------------------------------------------------
//
// Walks `src/**/*.zig` and `tests/integration/**/*.zig` and fails with a
// `relative/path.zig:line` list if the legacy literal `dead_letter_queue`
// appears anywhere. This is the same source-assertion pattern that
// `tools/lint_sql_table_refs.py` enforces as a build-time lint, expressed
// as a runnable test that ties into the integration suite so the assertion
// is verified by `zig build test-integration`.
//
// The walk is read-only: no DB writes, no filesystem mutations.

const LegacyTableLiteral = "dead_letter_queue";

fn scanFileForLegacyLiteral(allocator: std.mem.Allocator, file_path: []const u8) !?[]u8 {
    // Open the file relative to the repo root (cwd is the repo root when
    // the test binary is invoked via `zig build test-integration`).
    const contents = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        file_path,
        allocator,
        std.Io.Limit.limited(16 * 1024 * 1024),
    ) catch |err| switch (err) {
        // A missing file is treated as "no match" — the test walks the
        // expected directories and a missing file in either means the
        // layout has drifted, which the source-assertion alone cannot
        // distinguish from a true no-match. Callers detect the layout
        // drift by checking the directory walker's existence.
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(contents);

    // Find first occurrence and its 1-based line number.
    if (std.mem.indexOf(u8, contents, LegacyTableLiteral)) |byte_offset| {
        var line: usize = 1;
        var i: usize = 0;
        while (i < byte_offset) : (i += 1) {
            if (contents[i] == '\n') line += 1;
        }
        return try std.fmt.allocPrint(
            allocator,
            "{s}:{d}",
            .{ file_path, line },
        );
    }
    return null;
}

test "TC-ISS-0123-01: no dead_letter_queue literal in src/ or tests/integration/ (Cluster B source-assertion)" {
    const allocator = std.testing.allocator;
    // Test infrastructure gate: fail loudly if BPM_TEST_DB_URL is missing
    // (the rest of the suite shares the same gate; this test does not
    // actually need a DB but uses the same env-var contract for symmetry).
    try requireTestDatabaseUrl(allocator);

    // Walk src/ and tests/integration/ — any failure to open these
    // directories is a layout drift, not a false positive, and the test
    // surfaces it as a hard failure.
    var hits = std.ArrayList([]u8).empty;
    defer {
        for (hits.items) |hit| allocator.free(hit);
        hits.deinit(allocator);
    }

    const dirs = [_][]const u8{ "src", "tests/integration" };
    for (dirs) |dir_path| {
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true });
        var walker = try dir.walk(allocator);
        defer {
            walker.deinit();
            dir.close(std.testing.io);
        }
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
            defer allocator.free(full_path);
            if (std.mem.eql(u8, full_path, "tests/integration/iss0123_regression_test.zig") or
                std.mem.eql(u8, full_path, "tests/integration\\iss0123_regression_test.zig")) continue;
            if (try scanFileForLegacyLiteral(allocator, full_path)) |hit| {
                try hits.append(allocator, hit);
            }
        }
    }

    if (hits.items.len > 0) {
        std.debug.print("\nISS-0123 Cluster B regression: legacy `dead_letter_queue` literal found in {d} file(s):\n", .{hits.items.len});
        for (hits.items) |hit| {
            std.debug.print("  {s}\n", .{hit});
        }
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-0123-02 — Cluster A audit-insert smoke
// ---------------------------------------------------------------------------
//
// Acquires a fresh `TestHarness` (transaction-isolated, schema migrated,
// audit triggers installed by migration 020) and issues a normal
// `INSERT INTO audit_entries` with a per-test UUID for `resource_id`.
// With the obs05 savepoint fix, `trg_bpm_test_fail_audit_insert` cannot
// have leaked into this connection — so a normal INSERT MUST succeed
// without raising P0001 (either 'forced audit insert failure for test'
// from the test-installed trigger or 'audit_entries is immutable' from
// bpm_audit_immutable_guard, the latter fires only on UPDATE/DELETE so
// the test exercises the exact failure mode observed in
// `test-runner-step5c` Cluster A).
//
// Cleanup: `TestHarness.deinit()` rolls back the open transaction, so
// the inserted row never leaves the test session. No `DELETE FROM
// audit_entries` is required.

test "TC-ISS-0123-02: normal INSERT INTO audit_entries succeeds after obs05 trigger savepoint cleanup (Cluster A)" {
    const allocator = std.testing.allocator;
    try requireTestDatabaseUrl(allocator);

    var h = TestHarness.init(allocator) catch |err| switch (err) {
        error.MissingTestDatabaseUrl => return error.MissingTestDatabaseUrl,
        else => return err,
    };
    defer h.deinit();

    // Per-test random UUID for resource_id — per-test UUIDs are
    // mandatory (test_infrastructure_guide.md §9). NOT a hardcoded
    // literal. The test never reads or compares this row outside the
    // INSERT itself (the harness rollback discards it on deinit).
    const resource_id = try newUuid(allocator);
    defer allocator.free(resource_id);

    // Normal INSERT — same column list as the production audit code path
    // in `src/obs/audit.zig` and the bpm_audit_on_mutation() trigger body
    // in `migrations/020_obs03_audit_entries.sql:269-279`. We exercise
    // the INSERT path explicitly with NULL actor_id, NULL before_state,
    // and NULL after_state — these are the cheapest valid insert shape
    // and the same shape the test failure pattern (P0001 'forced audit
    // insert failure for test') was observed on in the original log.
    try h.conn.exec(
        \\INSERT INTO audit_entries
        \\  (actor_id, action, resource_type, resource_id, before_state, after_state)
        \\VALUES
        \\  (NULL, 'regression.iss0123', 'dlq', $1::uuid, NULL, NULL)
    , &.{resource_id});
}
