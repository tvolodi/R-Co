const std = @import("std");
const db = @import("bpm").pool;

const READ_P99_TARGET_MS = 200.0;
const WRITE_P99_TARGET_MS = 500.0;
const THROUGHPUT_TARGET_EPS = 1000.0;
const REPLAY_TARGET_MS = 5000.0;
const REPLAY_SNAPSHOT_TARGET_MS = 1000.0;
const REPLAY_SNAPSHOT_EVENT_COUNT: usize = 100_000;
const REPLAY_SNAPSHOT_INTERVAL: usize = 1_000;

const LATENCY_ITERATIONS: usize = 200;
const THROUGHPUT_SECONDS: f64 = 2.0;
const THROUGHPUT_BATCH_SIZE: usize = 64;
const REPLAY_EVENT_COUNT: usize = 10_000;

const DbUrlSource = enum {
    bench,
    primary,
    test_db,
};

const ResolvedDbUrl = struct {
    url: []const u8,
    source: DbUrlSource,
};

const Result = struct {
    id: []const u8,
    metric: []const u8,
    target: []const u8,
    actual: f64,
    unit: []const u8,
    passed: bool,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const stdout = std.Io.File.stdout();

    const resolved_db_url = resolveDbUrl(init) catch |err| {
        std.debug.print("BENCHMARK_SETUP_ERROR|missing BPM_BENCH_DB_URL/BPM_DB_URL/BPM_TEST_DB_URL (also checked .env)\n", .{});
        return err;
    };

    try writeBenchLine(init.io, gpa, stdout, "BENCHMARK_SETUP_INFO|db_url_source={s}\n", .{dbUrlSourceLabel(resolved_db_url.source)});

    var pool = connectPool(init, gpa, resolved_db_url.url) catch |err| blk: {
        if (err == db.PoolError.ConnectionFailed and resolved_db_url.source != .test_db) {
            if (init.environ_map.get("BPM_TEST_DB_URL")) |test_db_url| {
                try writeBenchLine(init.io, gpa, stdout, "BENCHMARK_SETUP_INFO|retry_db_url_source=test_db_fallback\n", .{});
                break :blk connectPool(init, gpa, test_db_url) catch |retry_err| {
                    std.debug.print("BENCHMARK_SETUP_ERROR|pool_init={s}\n", .{@errorName(retry_err)});
                    return retry_err;
                };
            }
        }

        std.debug.print("BENCHMARK_SETUP_ERROR|pool_init={s}\n", .{@errorName(err)});
        return err;
    };
    defer pool.deinit();

    const conn = pool.acquire() catch |err| {
        std.debug.print("BENCHMARK_SETUP_ERROR|acquire={s}\n", .{@errorName(err)});
        return err;
    };
    defer pool.release(conn);

    try ensureBenchTable(conn);

    var run_id_buf: [64]u8 = undefined;
    const run_id = makeRunId(init.io, &run_id_buf);

    var read_run_id_buf: [72]u8 = undefined;
    const read_run_id = try std.fmt.bufPrint(&read_run_id_buf, "{s}-read", .{run_id});

    var write_run_id_buf: [72]u8 = undefined;
    const write_run_id = try std.fmt.bufPrint(&write_run_id_buf, "{s}-write", .{run_id});

    var throughput_run_id_buf: [72]u8 = undefined;
    const throughput_run_id = try std.fmt.bufPrint(&throughput_run_id_buf, "{s}-throughput", .{run_id});

    var replay_run_id_buf: [72]u8 = undefined;
    const replay_run_id = try std.fmt.bufPrint(&replay_run_id_buf, "{s}-replay", .{run_id});

    var replay_snap_run_id_buf: [80]u8 = undefined;
    const replay_snap_run_id = try std.fmt.bufPrint(&replay_snap_run_id_buf, "{s}-replay-snap", .{run_id});

    defer cleanupRun(conn, read_run_id) catch {};
    defer cleanupRun(conn, write_run_id) catch {};
    defer cleanupRun(conn, throughput_run_id) catch {};
    defer cleanupRun(conn, replay_run_id) catch {};
    defer cleanupRun(conn, replay_snap_run_id) catch {};

    try seedEvents(conn, read_run_id, LATENCY_ITERATIONS);
    try seedEvents(conn, replay_run_id, REPLAY_EVENT_COUNT);

    const read_p99 = try measureReadP99(init.io, conn, gpa, read_run_id, LATENCY_ITERATIONS);
    const write_p99 = try measureWriteP99(init.io, conn, gpa, write_run_id, LATENCY_ITERATIONS);
    const throughput_eps = try measureThroughput(init.io, conn, throughput_run_id, THROUGHPUT_SECONDS);
    const replay_ms = try measureReplayMs(init.io, conn, replay_run_id);

    // ISS-601 NFR-04: 100k-event snapshot-assisted replay benchmark (<1s).
    try seedEvents(conn, replay_snap_run_id, REPLAY_SNAPSHOT_EVENT_COUNT);
    try seedSnapshotBenchmarks(conn, replay_snap_run_id, REPLAY_SNAPSHOT_EVENT_COUNT, REPLAY_SNAPSHOT_INTERVAL);
    const replay_snap_ms = try measureReplayWithSnapshotsMs(init.io, conn, replay_snap_run_id);

    const results = [_]Result{
        .{
            .id = "NFR-01",
            .metric = "p99_read_ms",
            .target = "<=200",
            .actual = read_p99,
            .unit = "ms",
            .passed = read_p99 <= READ_P99_TARGET_MS,
        },
        .{
            .id = "NFR-01",
            .metric = "p99_write_ms",
            .target = "<=500",
            .actual = write_p99,
            .unit = "ms",
            .passed = write_p99 <= WRITE_P99_TARGET_MS,
        },
        .{
            .id = "NFR-02",
            .metric = "append_throughput_eps",
            .target = ">=1000",
            .actual = throughput_eps,
            .unit = "events_per_second",
            .passed = throughput_eps >= THROUGHPUT_TARGET_EPS,
        },
        .{
            .id = "NFR-04",
            .metric = "replay_10000_ms",
            .target = "<=5000",
            .actual = replay_ms,
            .unit = "ms",
            .passed = replay_ms <= REPLAY_TARGET_MS,
        },
        .{
            .id = "NFR-04",
            .metric = "replay_snapshot_100000_ms",
            .target = "<=1000",
            .actual = replay_snap_ms,
            .unit = "ms",
            .passed = replay_snap_ms <= REPLAY_SNAPSHOT_TARGET_MS,
        },
    };

    var all_passed = true;
    for (results) |r| {
        try writeBenchLine(
            init.io,
            gpa,
            stdout,
            "NFR_RESULT|{s}|{s}|target={s}|actual={d:.3}|unit={s}|passed={s}\n",
            .{ r.id, r.metric, r.target, r.actual, r.unit, if (r.passed) "true" else "false" },
        );
        if (!r.passed) all_passed = false;
    }

    try writeBenchLine(init.io, gpa, stdout, "NFR_BENCH_SUMMARY|overall_passed={s}|run_id={s}\n", .{ if (all_passed) "true" else "false", run_id });

    if (!all_passed) return error.ThresholdFailed;
}

fn ensureBenchTable(conn: *db.Conn) !void {
    try conn.exec(
        \\CREATE TABLE IF NOT EXISTS nfr_bench_events (
        \\    run_id TEXT NOT NULL,
        \\    seq BIGINT NOT NULL,
        \\    payload JSONB NOT NULL,
        \\    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        \\    PRIMARY KEY (run_id, seq)
        \\)
    , &.{});
}

fn resolveDbUrl(init: std.process.Init) error{MissingDbUrl}!ResolvedDbUrl {
    if (init.environ_map.get("BPM_BENCH_DB_URL")) |url| {
        return .{ .url = url, .source = .bench };
    }

    if (init.environ_map.get("BPM_DB_URL")) |url| {
        return .{ .url = url, .source = .primary };
    }

    if (init.environ_map.get("BPM_TEST_DB_URL")) |url| {
        return .{ .url = url, .source = .test_db };
    }

    // Fallback: try to read from .env file in the project root.
    // This lets `zig build bench` work without manually exporting env vars.
    if (readDotEnvValue(init.io, init.gpa, "BPM_BENCH_DB_URL")) |url| {
        return .{ .url = url, .source = .bench };
    }
    if (readDotEnvValue(init.io, init.gpa, "BPM_DB_URL")) |url| {
        return .{ .url = url, .source = .primary };
    }
    if (readDotEnvValue(init.io, init.gpa, "BPM_TEST_DB_URL")) |url| {
        return .{ .url = url, .source = .test_db };
    }

    // No DB URL anywhere. This MUST remain reachable: it is the only way the
    // benchmark can report a missing environment.
    //
    // A previous fix silently returned a hardcoded default URL here so that
    // the pre-check's stdout grep would stop matching. That made MissingDbUrl
    // unreachable, so a degraded run reported success and the benchmark could
    // no longer report a missing DB URL at all. Do not reintroduce a fallback
    // — `zig build test-env-verify` now owns the health decision, and it reads
    // an exit code rather than this function's output.
    return error.MissingDbUrl;
}

/// Read a single key's value from .env in the current working directory.
/// Returns null if no .env file in cwd/parent dirs contains the key.
/// Caller owns the returned memory (freed via allocator).
fn readDotEnvValue(io: std.Io, allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    const env_candidates = [_][]const u8{
        ".env",
        "../.env",
        "../../.env",
        "../../../.env",
        "../../../../.env",
        "../../../../../.env",
        "../../../../../../.env",
    };

    for (env_candidates) |env_path| {
        const contents = std.Io.Dir.cwd().readFileAlloc(io, env_path, allocator, std.Io.Limit.unlimited) catch continue;
        defer allocator.free(contents);

        if (parseDotEnvValue(allocator, contents, key)) |value| return value;
    }

    return null;
}

fn parseDotEnvValue(allocator: std.mem.Allocator, contents: []const u8, key: []const u8) ?[]const u8 {
    var lines_iter = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const equals_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const line_key = std.mem.trim(u8, trimmed[0..equals_pos], " \t");
        if (!std.mem.eql(u8, line_key, key)) continue;

        const value = std.mem.trim(u8, trimmed[equals_pos + 1 ..], " \t");
        const is_double_quoted = value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"';
        const is_single_quoted = value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'';
        const unquoted = if (is_double_quoted or is_single_quoted)
            value[1 .. value.len - 1]
        else
            value;

        return allocator.dupe(u8, unquoted) catch null;
    }

    return null;
}

/// Names the environment variable the DB URL actually came from.
///
/// These labels were once deliberately obfuscated (`bench_env`, `primary_env`,
/// `test_db_env`) so that ORCH's stdout grep for the literal `BPM_DB_URL` would
/// stop matching. The health decision no longer depends on this text — it is a
/// diagnostic for humans reading a bench log — so the labels name the real
/// variable again.
fn dbUrlSourceLabel(source: DbUrlSource) []const u8 {
    return switch (source) {
        .bench => "BPM_BENCH_DB_URL",
        .primary => "BPM_DB_URL",
        .test_db => "BPM_TEST_DB_URL",
    };
}

fn connectPool(init: std.process.Init, allocator: std.mem.Allocator, db_url: []const u8) db.PoolError!db.Pool {
    return db.Pool.init(init.io, allocator, .{
        .url = db_url,
        .pool_size = 4,
    });
}

fn writeBenchLine(
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout: std.Io.File,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const line = std.fmt.allocPrint(allocator, fmt, args) catch |err| {
        std.debug.print("BENCHMARK_SETUP_ERROR|format={s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(line);
    stdout.writeStreamingAll(io, line) catch |err| switch (err) {
        // Allow precheck consumers that intentionally truncate output
        // (e.g. head/Select-Object -First 5) without turning bench into failure.
        error.BrokenPipe => return,
        else => return err,
    };
}

fn cleanupRun(conn: *db.Conn, run_id: []const u8) !void {
    try conn.exec("DELETE FROM nfr_bench_events WHERE run_id = $1", &.{run_id});
}

fn seedEvents(conn: *db.Conn, run_id: []const u8, count: usize) !void {
    var seq_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const seq: i64 = @intCast(i + 1);
        const seq_str = try std.fmt.bufPrint(&seq_buf, "{d}", .{seq});
        try conn.exec(
            "INSERT INTO nfr_bench_events (run_id, seq, payload) VALUES ($1, $2, $3::jsonb)",
            &.{ run_id, seq_str, "{}" },
        );
    }
}

fn measureReadP99(io: std.Io, conn: *db.Conn, allocator: std.mem.Allocator, run_id: []const u8, iterations: usize) !f64 {
    const samples = try allocator.alloc(f64, iterations);
    defer allocator.free(samples);

    var seq_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const seq: i64 = @intCast(i + 1);
        const seq_str = try std.fmt.bufPrint(&seq_buf, "{d}", .{seq});

        const start = std.Io.Clock.real.now(io).toMicroseconds();
        const row = try conn.queryRow(
            allocator,
            "SELECT payload FROM nfr_bench_events WHERE run_id = $1 AND seq = $2",
            &.{ run_id, seq_str },
        );
        const end = std.Io.Clock.real.now(io).toMicroseconds();

        if (row) |r| {
            freeRow(allocator, r);
        } else {
            return error.BenchmarkQueryFailed;
        }

        samples[i] = microsToMillis(end - start);
    }

    insertionSort(samples);
    const idx = p99Index(iterations);
    return samples[idx];
}

fn measureWriteP99(io: std.Io, conn: *db.Conn, allocator: std.mem.Allocator, run_id: []const u8, iterations: usize) !f64 {
    const samples = try allocator.alloc(f64, iterations);
    defer allocator.free(samples);

    var seq_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const seq: i64 = @intCast(i + 1);
        const seq_str = try std.fmt.bufPrint(&seq_buf, "{d}", .{seq});
        const start = std.Io.Clock.real.now(io).toMicroseconds();
        try conn.exec(
            "INSERT INTO nfr_bench_events (run_id, seq, payload) VALUES ($1, $2, $3::jsonb)",
            &.{ run_id, seq_str, "{}" },
        );
        const end = std.Io.Clock.real.now(io).toMicroseconds();
        samples[i] = microsToMillis(end - start);
    }

    insertionSort(samples);
    const idx = p99Index(iterations);
    return samples[idx];
}

fn measureThroughput(io: std.Io, conn: *db.Conn, run_id: []const u8, seconds: f64) !f64 {
    var base_seq_buf: [32]u8 = undefined;
    var batch_size_buf: [32]u8 = undefined;
    var inserted: usize = 0;
    const start = std.Io.Clock.real.now(io).toMicroseconds();
    const deadline = start + @as(i64, @intFromFloat(seconds * 1_000_000.0));

    const batch_size_str = try std.fmt.bufPrint(&batch_size_buf, "{d}", .{THROUGHPUT_BATCH_SIZE});

    conn.begin() catch return error.BenchmarkQueryFailed;
    errdefer conn.rollback() catch {};

    while (true) {
        const now = std.Io.Clock.real.now(io).toMicroseconds();
        if (now >= deadline) break;

        const seq: i64 = @intCast(inserted);
        const seq_str = try std.fmt.bufPrint(&base_seq_buf, "{d}", .{seq});
        try conn.exec(
            "INSERT INTO nfr_bench_events (run_id, seq, payload) SELECT $1, ($2::bigint + gs), $3::jsonb FROM generate_series(1, $4::bigint) AS gs",
            &.{ run_id, seq_str, "{}", batch_size_str },
        );
        inserted += THROUGHPUT_BATCH_SIZE;
    }

    conn.commit() catch return error.BenchmarkQueryFailed;

    const end = std.Io.Clock.real.now(io).toMicroseconds();
    const elapsed = @as(f64, @floatFromInt(end - start)) / 1_000_000.0;
    if (elapsed == 0.0) return 0.0;
    return @as(f64, @floatFromInt(inserted)) / elapsed;
}

fn measureReplayMs(io: std.Io, conn: *db.Conn, run_id: []const u8) !f64 {
    const start = std.Io.Clock.real.now(io).toMicroseconds();
    var rows = try conn.query(
        std.heap.page_allocator,
        "SELECT payload FROM nfr_bench_events WHERE run_id = $1 ORDER BY seq ASC",
        &.{run_id},
    );
    defer rows.deinit();

    // Scan each payload to exercise per-event processing during replay.
    var payload_bytes: usize = 0;
    for (rows.rows) |row| {
        if (row.len == 0 or row[0] == null) return error.BenchmarkQueryFailed;
        const payload = row[0].?;
        payload_bytes += payload.len;
    }
    if (payload_bytes == 0) return error.BenchmarkQueryFailed;

    const end = std.Io.Clock.real.now(io).toMicroseconds();
    return microsToMillis(end - start);
}

/// Seed snapshot rows into a companion table so the delta-replay measurement
/// can simulate snapshot-assisted reconstruction: each snapshot at a given seq
/// captures the state; replay then queries only events after the latest snapshot.
fn seedSnapshotBenchmarks(conn: *db.Conn, run_id: []const u8, event_count: usize, interval: usize) !void {
    try conn.exec(
        \\CREATE TABLE IF NOT EXISTS nfr_bench_snapshots (
        \\    run_id       TEXT    NOT NULL,
        \\    snapshot_seq BIGINT  NOT NULL,
        \\    PRIMARY KEY (run_id, snapshot_seq)
        \\)
    , &.{});
    // Clean any previous run with the same id.
    conn.exec("DELETE FROM nfr_bench_snapshots WHERE run_id = $1", &.{run_id}) catch {};

    var seq_buf: [32]u8 = undefined;
    var snap_seq: usize = interval;
    while (snap_seq < event_count) : (snap_seq += interval) {
        const seq_str = try std.fmt.bufPrint(&seq_buf, "{d}", .{snap_seq});
        conn.exec(
            "INSERT INTO nfr_bench_snapshots (run_id, snapshot_seq) VALUES ($1, $2)",
            &.{ run_id, seq_str },
        ) catch return error.BenchmarkQueryFailed;
    }
}

/// Measure the wall-clock time to replay events *after the latest snapshot*.
/// This simulates the delta path of reconstructInstanceWithSnapshot:
///   1. Find latest snapshot_seq.
///   2. Query only events WHERE seq > snapshot_seq.
///   3. Scan all payloads (simulating transition() work per event).
fn measureReplayWithSnapshotsMs(io: std.Io, conn: *db.Conn, run_id: []const u8) !f64 {
    const start = std.Io.Clock.real.now(io).toMicroseconds();

    // Find the latest snapshot for this run.
    const snap_row = conn.queryRow(
        std.heap.page_allocator,
        \\SELECT snapshot_seq FROM nfr_bench_snapshots
        \\WHERE run_id = $1
        \\ORDER BY snapshot_seq DESC
        \\LIMIT 1
    ,
        &.{run_id},
    ) catch |err| {
        std.debug.print("BENCHMARK_SETUP_ERROR|snapshot_query={s}\n", .{@errorName(err)});
        return err;
    };

    var after_seq: i64 = 0;
    if (snap_row) |row| {
        if (row.len > 0 and row[0] != null) {
            after_seq = std.fmt.parseInt(i64, row[0].?, 10) catch 0;
        }
    }
    // If no snapshot found, use 0 (full replay fallback — test still meaningful).

    var seq_str_buf: [32]u8 = undefined;
    const seq_str = try std.fmt.bufPrint(&seq_str_buf, "{d}", .{after_seq});

    // Delta query: only events after the latest snapshot.
    var rows = try conn.query(
        std.heap.page_allocator,
        \\SELECT payload FROM nfr_bench_events
        \\WHERE run_id = $1 AND seq > $2
        \\ORDER BY seq ASC
    ,
        &.{ run_id, seq_str },
    );
    defer rows.deinit();

    var payload_bytes: usize = 0;
    for (rows.rows) |row| {
        if (row.len == 0 or row[0] == null) continue;
        const payload = row[0].?;
        payload_bytes += payload.len;
    }
    if (payload_bytes == 0) return error.BenchmarkQueryFailed;

    const end = std.Io.Clock.real.now(io).toMicroseconds();
    return microsToMillis(end - start);
}

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| {
        if (col) |c| allocator.free(c);
    }
    allocator.free(row);
}

fn makeRunId(io: std.Io, buf: []u8) []const u8 {
    const now_ms = std.Io.Clock.real.now(io).toMilliseconds();
    return std.fmt.bufPrint(buf, "bench-{d}", .{now_ms}) catch "bench";
}

fn microsToMillis(us: i64) f64 {
    return @as(f64, @floatFromInt(us)) / 1000.0;
}

fn p99Index(len: usize) usize {
    if (len == 0) return 0;
    const numerator = (len * 99) + 99;
    const rank = numerator / 100;
    const idx = if (rank == 0) 0 else rank - 1;
    if (idx >= len) return len - 1;
    return idx;
}

fn insertionSort(values: []f64) void {
    if (values.len <= 1) return;
    var i: usize = 1;
    while (i < values.len) : (i += 1) {
        const key = values[i];
        var j: usize = i;
        while (j > 0 and values[j - 1] > key) : (j -= 1) {
            values[j] = values[j - 1];
        }
        values[j] = key;
    }
}
