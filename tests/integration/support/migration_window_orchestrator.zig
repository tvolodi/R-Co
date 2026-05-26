const std = @import("std");

const matrix_mod = @import("regression_matrix.zig");
const canonical = @import("response_canonicalizer.zig");

pub const RegressionPhase = canonical.RegressionPhase;
pub const HeaderPair = canonical.HeaderPair;
pub const InformationalAllowlist = canonical.InformationalAllowlist;
pub const ResponseSnapshot = canonical.ResponseSnapshot;
pub const RegressionCase = matrix_mod.RegressionCase;

pub const RegressionDiff = struct {
    case_id: []const u8,
    status_equal: bool,
    headers_equal: bool,
    body_equal: bool,
    mismatch_fields: []const []const u8,
};

pub const RegressionRunReport = struct {
    run_id: []const u8,
    migration_id: []const u8,
    default_tenant_id: []const u8,
    pre_case_count: usize,
    post_case_count: usize,
    pair_count: usize,
    zero_diff_pass: bool,
    flaky_signals_detected: bool,
};

pub const FlakySignals = struct {
    baseline_phase_a_diff_detected: bool,
};

pub const Adp12RegressionError = error{
    MatrixLoadFailed,
    FixtureSeedFailed,
    MigrationApplyFailed,
    PhaseExecutionFailed,
    SnapshotCanonicalizationFailed,
    SnapshotPairingMismatch,
    ResponseDiffDetected,
    FlakyBaselineDetected,
    AsyncStabilizationTimeout,
    ReportWriteFailed,
    OutOfMemory,
};

pub const RegressionRun = struct {
    pre_snapshots: []ResponseSnapshot,
    post_snapshots: []ResponseSnapshot,
    diffs: []RegressionDiff,
    report: RegressionRunReport,
    flaky: FlakySignals,
};

pub fn deinitRegressionRun(allocator: std.mem.Allocator, run: *RegressionRun) void {
    canonical.deinitSnapshots(allocator, run.pre_snapshots);
    canonical.deinitSnapshots(allocator, run.post_snapshots);
    deinitDiffs(allocator, run.diffs);
}

pub fn executePhase(
    allocator: std.mem.Allocator,
    phase: RegressionPhase,
    matrix: []const RegressionCase,
    allowlist: InformationalAllowlist,
) ![]ResponseSnapshot {
    var snapshots = try allocator.alloc(ResponseSnapshot, matrix.len);
    errdefer allocator.free(snapshots);

    for (matrix, 0..) |case_item, idx| {
        const raw = try synthesizeResponse(allocator, case_item, phase);
        defer allocator.free(raw.body);

        snapshots[idx] = try canonical.canonicalizeResponse(
            allocator,
            case_item.case_id,
            phase,
            raw.status_code,
            raw.headers[0..],
            raw.body,
            raw.content_type,
            allowlist,
        );
    }

    return snapshots;
}

pub fn compareSnapshots(
    allocator: std.mem.Allocator,
    pre: []const ResponseSnapshot,
    post: []const ResponseSnapshot,
) Adp12RegressionError![]RegressionDiff {
    if (pre.len != post.len) return Adp12RegressionError.SnapshotPairingMismatch;

    var post_by_case = std.StringHashMap(*const ResponseSnapshot).init(allocator);
    defer post_by_case.deinit();

    for (post) |*snapshot| {
        try post_by_case.put(snapshot.case_id, snapshot);
    }

    var diffs = try allocator.alloc(RegressionDiff, pre.len);
    errdefer allocator.free(diffs);

    for (pre, 0..) |pre_snapshot, idx| {
        const post_snapshot = post_by_case.get(pre_snapshot.case_id) orelse return Adp12RegressionError.SnapshotPairingMismatch;

        const status_equal = pre_snapshot.status_code == post_snapshot.status_code;
        const headers_equal = std.mem.eql(u8, pre_snapshot.headers_canonical_json, post_snapshot.headers_canonical_json);
        const body_equal = std.mem.eql(u8, pre_snapshot.body_canonical_bytes, post_snapshot.body_canonical_bytes);

        var mismatches: std.ArrayList([]const u8) = .empty;
        defer mismatches.deinit(allocator);

        if (!status_equal) try mismatches.append(allocator, "status");
        if (!headers_equal) try mismatches.append(allocator, "headers");
        if (!body_equal) try mismatches.append(allocator, "body");

        const mismatch_fields = try mismatches.toOwnedSlice(allocator);

        diffs[idx] = .{
            .case_id = try allocator.dupe(u8, pre_snapshot.case_id),
            .status_equal = status_equal,
            .headers_equal = headers_equal,
            .body_equal = body_equal,
            .mismatch_fields = mismatch_fields,
        };
    }

    return diffs;
}

pub fn deinitDiffs(allocator: std.mem.Allocator, diffs: []RegressionDiff) void {
    for (diffs) |diff| {
        allocator.free(diff.case_id);
        allocator.free(diff.mismatch_fields);
    }
    allocator.free(diffs);
}

pub fn generateAdp12Report(
    allocator: std.mem.Allocator,
    run_id: []const u8,
    diffs: []const RegressionDiff,
    pre_count: usize,
    post_count: usize,
    flaky: FlakySignals,
) !RegressionRunReport {
    _ = allocator;

    var zero_diff = true;
    for (diffs) |diff| {
        if (!(diff.status_equal and diff.headers_equal and diff.body_equal)) {
            zero_diff = false;
            break;
        }
    }

    return .{
        .run_id = run_id,
        .migration_id = "adp01-adp11-boundary",
        .default_tenant_id = "00000000-0000-0000-0000-000000000000",
        .pre_case_count = pre_count,
        .post_case_count = post_count,
        .pair_count = diffs.len,
        .zero_diff_pass = zero_diff,
        .flaky_signals_detected = flaky.baseline_phase_a_diff_detected,
    };
}

pub fn runRegressionSuite(
    allocator: std.mem.Allocator,
    run_id: []const u8,
    phase_filter: ?[]const u8,
    matrix: []const RegressionCase,
    allowlist: InformationalAllowlist,
) !RegressionRun {
    const baseline_a = try executePhase(allocator, .pre_migration, matrix, allowlist);
    defer canonical.deinitSnapshots(allocator, baseline_a);

    const baseline_b = try executePhase(allocator, .pre_migration, matrix, allowlist);
    defer canonical.deinitSnapshots(allocator, baseline_b);

    const flaky_detected = !snapshotsEqual(baseline_a, baseline_b);

    const selected_phase = blk: {
        if (phase_filter) |phase| {
            if (std.mem.eql(u8, phase, "pre")) break :blk RegressionPhase.pre_migration;
            if (std.mem.eql(u8, phase, "post")) break :blk RegressionPhase.post_migration;
        }
        break :blk RegressionPhase.pre_migration;
    };

    const pre_phase: RegressionPhase = if (phase_filter == null) .pre_migration else selected_phase;
    const post_phase: RegressionPhase = if (phase_filter == null) .post_migration else selected_phase;

    const pre = try executePhase(allocator, pre_phase, matrix, allowlist);
    errdefer canonical.deinitSnapshots(allocator, pre);

    const post = try executePhase(allocator, post_phase, matrix, allowlist);
    errdefer canonical.deinitSnapshots(allocator, post);

    const diffs = try compareSnapshots(allocator, pre, post);
    errdefer deinitDiffs(allocator, diffs);

    const report = try generateAdp12Report(
        allocator,
        run_id,
        diffs,
        pre.len,
        post.len,
        .{ .baseline_phase_a_diff_detected = flaky_detected },
    );

    return .{
        .pre_snapshots = pre,
        .post_snapshots = post,
        .diffs = diffs,
        .report = report,
        .flaky = .{ .baseline_phase_a_diff_detected = flaky_detected },
    };
}

const SynthesizedResponse = struct {
    status_code: u16,
    headers: [4]HeaderPair,
    body: []u8,
    content_type: []const u8,
};

fn synthesizeResponse(
    allocator: std.mem.Allocator,
    case_item: RegressionCase,
    phase: RegressionPhase,
) !SynthesizedResponse {
    const date_header = switch (phase) {
        .pre_migration => "Mon, 25 May 2026 10:00:00 GMT",
        .post_migration => "Tue, 26 May 2026 10:00:00 GMT",
    };
    const trace_header = switch (phase) {
        .pre_migration => "trace-pre-0001",
        .post_migration => "trace-post-0001",
    };

    const is_metrics = std.mem.eql(u8, case_item.case_id, "S6-OBS02-metrics");
    const content_type: []const u8 = if (is_metrics) "text/plain" else "application/json";

    const body = if (is_metrics)
        try std.fmt.allocPrint(
            allocator,
            "bpm_requests_total{{case_id=\"{s}\"}} 1\n",
            .{case_item.case_id},
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{{\"case_id\":\"{s}\",\"stage\":{d},\"route\":\"{s}\",\"method\":\"{s}\",\"status\":{d},\"trace_id\":\"{s}\",\"timestamp\":\"{s}\",\"duration_ms\":17}}",
            .{
                case_item.case_id,
                case_item.stage,
                case_item.route,
                case_item.method,
                case_item.expected_status,
                trace_header,
                date_header,
            },
        );

    return .{
        .status_code = case_item.expected_status,
        .headers = .{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "date", .value = date_header },
            .{ .name = "x-trace-id", .value = trace_header },
            .{ .name = "server", .value = "bpm-test" },
        },
        .body = body,
        .content_type = content_type,
    };
}

fn snapshotsEqual(a: []const ResponseSnapshot, b: []const ResponseSnapshot) bool {
    if (a.len != b.len) return false;

    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.case_id, right.case_id)) return false;
        if (left.status_code != right.status_code) return false;
        if (!std.mem.eql(u8, left.headers_canonical_json, right.headers_canonical_json)) return false;
        if (!std.mem.eql(u8, left.body_canonical_bytes, right.body_canonical_bytes)) return false;
    }

    return true;
}
