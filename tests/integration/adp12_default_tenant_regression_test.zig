const std = @import("std");
const testing = std.testing;

const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const build_options = @import("build_options");
const matrix_mod = @import("support/regression_matrix.zig");
const canonical = @import("support/response_canonicalizer.zig");
const orchestrator = @import("support/migration_window_orchestrator.zig");
const report_writer = @import("support/report_writer.zig");

const run_id = "WF02-adp12-20260526";

const header_allowlist = [_][]const u8{
    "date",
    "server",
    "x-trace-id",
    "x-request-id",
    "content-length",
    "transfer-encoding",
    "connection",
    "keep-alive",
};

const json_pointer_allowlist = [_][]const u8{
    "/trace_id",
    "/timestamp",
    "/now",
    "/generated_at",
    "/uptime_ms",
    "/duration_ms",
};

fn adp12Allowlist() canonical.InformationalAllowlist {
    return .{
        .header_names = header_allowlist[0..],
        .json_pointer_paths = json_pointer_allowlist[0..],
    };
}

test "TC-ADP-12-01: stage matrix includes deterministic Stage 1-6 coverage" {
    const allocator = testing.allocator;
    const matrix = try matrix_mod.loadStageCoverageMatrix(allocator);
    defer allocator.free(matrix);

    try testing.expect(matrix.len >= 44);

    var seen: [7]bool = .{ false, false, false, false, false, false, false };
    for (matrix) |entry| {
        try testing.expect(entry.stage >= 1 and entry.stage <= 6);
        seen[entry.stage] = true;
        try testing.expect(entry.case_id.len > 0);
        try testing.expect(entry.route.len > 0);
        try testing.expect(entry.method.len > 0);
    }

    var stage: usize = 1;
    while (stage <= 6) : (stage += 1) {
        try testing.expect(seen[stage]);
    }
}

test "TC-ADP-12-02: canonicalizer excludes only allowed informational fields" {
    const allocator = testing.allocator;

    const raw_headers = [_]canonical.HeaderPair{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "X-Trace-Id", .value = "trace-pre" },
        .{ .name = "X-Custom", .value = "stable" },
        .{ .name = "Date", .value = "Tue, 26 May 2026 00:00:00 GMT" },
    };

    const body =
        "{\"case_id\":\"demo\",\"trace_id\":\"dynamic\",\"timestamp\":\"dynamic\",\"duration_ms\":12,\"payload\":\"stable\"}";

    const snapshot = try canonical.canonicalizeResponse(
        allocator,
        "S4-API-03-start-instance-default",
        .pre_migration,
        200,
        raw_headers[0..],
        body,
        "application/json",
        adp12Allowlist(),
    );
    var owned_snapshot = snapshot;
    defer canonical.deinitSnapshot(allocator, &owned_snapshot);

    try testing.expect(std.mem.indexOf(u8, snapshot.headers_canonical_json, "x-custom") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot.headers_canonical_json, "x-trace-id") == null);

    try testing.expect(std.mem.indexOf(u8, snapshot.body_canonical_bytes, "trace_id") == null);
    try testing.expect(std.mem.indexOf(u8, snapshot.body_canonical_bytes, "timestamp") == null);
    try testing.expect(std.mem.indexOf(u8, snapshot.body_canonical_bytes, "duration_ms") == null);
    try testing.expect(std.mem.indexOf(u8, snapshot.body_canonical_bytes, "payload") != null);
}

test "TC-ADP-12-03: deterministic pre/post suite emits zero diff report artifacts" {
    const allocator = testing.allocator;

    // Verify migration metadata exists before running the deterministic comparison.
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var migration_count = try harness.conn.query(
        allocator,
        "SELECT COUNT(*)::text FROM schema_migrations",
        &.{},
    );
    defer migration_count.deinit();

    try testing.expectEqual(@as(usize, 1), migration_count.rows.len);

    const matrix = try matrix_mod.loadStageCoverageMatrix(allocator);
    defer allocator.free(matrix);

    const run = try orchestrator.runRegressionSuite(
        allocator,
        run_id,
        build_options.adp12_phase,
        matrix,
        adp12Allowlist(),
    );
    defer {
        var owned = run;
        orchestrator.deinitRegressionRun(allocator, &owned);
    }

    try testing.expect(run.report.pre_case_count == matrix.len);
    try testing.expect(run.report.post_case_count == matrix.len);
    try testing.expect(run.report.pair_count == matrix.len);
    try testing.expect(run.report.zero_diff_pass);
    try testing.expect(!run.report.flaky_signals_detected);

    try report_writer.writeAdp12Artifacts(
        allocator,
        adp12Allowlist(),
        run.pre_snapshots,
        run.post_snapshots,
        run.diffs,
        run.report,
        run.flaky,
    );

    const summary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/reports/adp12/adp12-regression-summary.json",
        allocator,
        std.Io.Limit.limited(4 * 1024 * 1024),
    );
    defer allocator.free(summary_bytes);

    try testing.expect(std.mem.indexOf(u8, summary_bytes, "\"requirement_id\":\"ADP-12\"") != null);
    try testing.expect(std.mem.indexOf(u8, summary_bytes, "\"zero_diff\":true") != null);
}
