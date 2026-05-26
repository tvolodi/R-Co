const std = @import("std");

const canonical = @import("response_canonicalizer.zig");
const orchestrator = @import("migration_window_orchestrator.zig");

pub fn writeAdp12Artifacts(
    allocator: std.mem.Allocator,
    allowlist: canonical.InformationalAllowlist,
    pre_snapshots: []const canonical.ResponseSnapshot,
    post_snapshots: []const canonical.ResponseSnapshot,
    diffs: []const orchestrator.RegressionDiff,
    report: orchestrator.RegressionRunReport,
    flaky: orchestrator.FlakySignals,
) !void {
    const cwd_dir = std.Io.Dir.cwd();
    try cwd_dir.createDirPath(std.testing.io, "tests/reports/adp12");

    const pre_ndjson = try snapshotsToNdjson(allocator, pre_snapshots);
    defer allocator.free(pre_ndjson);
    try writeFile(cwd_dir, "tests/reports/adp12/pre-snapshots.ndjson", pre_ndjson);

    const post_ndjson = try snapshotsToNdjson(allocator, post_snapshots);
    defer allocator.free(post_ndjson);
    try writeFile(cwd_dir, "tests/reports/adp12/post-snapshots.ndjson", post_ndjson);

    const diffs_ndjson = try diffsToNdjson(allocator, diffs);
    defer allocator.free(diffs_ndjson);
    try writeFile(cwd_dir, "tests/reports/adp12/diffs.ndjson", diffs_ndjson);

    const flaky_json = try flakyToJson(allocator, flaky);
    defer allocator.free(flaky_json);
    try writeFile(cwd_dir, "tests/reports/adp12/flaky-signals.json", flaky_json);

    const summary_json = try summaryToJson(allocator, allowlist, diffs, report, flaky);
    defer allocator.free(summary_json);
    try writeFile(cwd_dir, "tests/reports/adp12/adp12-regression-summary.json", summary_json);
}

fn snapshotsToNdjson(allocator: std.mem.Allocator, snapshots: []const canonical.ResponseSnapshot) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (snapshots) |snapshot| {
        const row = .{
            .case_id = snapshot.case_id,
            .phase = @tagName(snapshot.phase),
            .status_code = snapshot.status_code,
            .headers_canonical_json = snapshot.headers_canonical_json,
            .body_sha256_hex = snapshot.body_sha256_hex,
            .content_type = snapshot.content_type,
        };
        const line = try std.json.Stringify.valueAlloc(allocator, row, .{});
        defer allocator.free(line);

        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

fn diffsToNdjson(allocator: std.mem.Allocator, diffs: []const orchestrator.RegressionDiff) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (diffs) |diff| {
        const row = .{
            .case_id = diff.case_id,
            .status_equal = diff.status_equal,
            .headers_equal = diff.headers_equal,
            .body_equal = diff.body_equal,
            .diffs = diff.mismatch_fields,
        };
        const line = try std.json.Stringify.valueAlloc(allocator, row, .{});
        defer allocator.free(line);

        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

fn flakyToJson(allocator: std.mem.Allocator, flaky: orchestrator.FlakySignals) ![]u8 {
    const payload = .{
        .baseline_phase_a_diff_detected = flaky.baseline_phase_a_diff_detected,
        .flaky_signals_detected = flaky.baseline_phase_a_diff_detected,
    };
    return std.json.Stringify.valueAlloc(allocator, payload, .{});
}

fn summaryToJson(
    allocator: std.mem.Allocator,
    allowlist: canonical.InformationalAllowlist,
    diffs: []const orchestrator.RegressionDiff,
    report: orchestrator.RegressionRunReport,
    flaky: orchestrator.FlakySignals,
) ![]u8 {
    const CaseRow = struct {
        case_id: []const u8,
        status_equal: bool,
        headers_equal: bool,
        body_equal: bool,
        diffs: []const []const u8,
    };

    var mismatch_count: usize = 0;
    var rows = try allocator.alloc(CaseRow, diffs.len);
    defer allocator.free(rows);

    for (diffs, 0..) |diff, idx| {
        if (diff.mismatch_fields.len > 0) mismatch_count += 1;
        rows[idx] = .{
            .case_id = diff.case_id,
            .status_equal = diff.status_equal,
            .headers_equal = diff.headers_equal,
            .body_equal = diff.body_equal,
            .diffs = diff.mismatch_fields,
        };
    }

    const payload = .{
        .run_id = report.run_id,
        .requirement_id = "ADP-12",
        .default_tenant_id = report.default_tenant_id,
        .migration_window = .{
            .pre_schema_version = "before-adp-migrations",
            .post_schema_version = "after-adp-migrations",
        },
        .summary = .{
            .cases_total = report.pre_case_count,
            .pairs_compared = report.pair_count,
            .zero_diff = report.zero_diff_pass,
            .mismatches = mismatch_count,
            .flaky_signals = @as(u8, if (flaky.baseline_phase_a_diff_detected) 1 else 0),
        },
        .allowlist = .{
            .headers = allowlist.header_names,
            .json_pointers = allowlist.json_pointer_paths,
        },
        .cases = rows,
    };

    return std.json.Stringify.valueAlloc(allocator, payload, .{});
}

fn writeFile(dir: anytype, path: []const u8, bytes: []const u8) !void {
    try dir.writeFile(std.testing.io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .truncate = true },
    });
}
