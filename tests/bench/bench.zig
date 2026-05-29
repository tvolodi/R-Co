const std = @import("std");
const db = @import("bpm").pool;

const READ_P99_TARGET_MS = 200.0;
const WRITE_P99_TARGET_MS = 500.0;
const THROUGHPUT_TARGET_EPS = 1000.0;
const REPLAY_TARGET_MS = 5000.0;

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

    const resolved_db_url = resolveDbUrl(init) catch |err| {
        std.debug.print("BENCHMARK_SETUP_ERROR|missing BPM_BENCH_DB_URL/BPM_DB_URL/BPM_TEST_DB_URL (also checked .env)\n", .{});
        return err;
    };

    std.debug.print("BENCHMARK_SETUP_INFO|db_url_source={s}\n", .{dbUrlSourceLabel(resolved_db_url.source)});

    var pool = connectPool(init, gpa, resolved_db_url.url) catch |err| blk: {
        if (err == db.PoolError.ConnectionFailed and resolved_db_url.source != .test_db) {
            if (init.environ_map.get("BPM_TEST_DB_URL")) |test_db_url| {
                std.debug.print("BENCHMARK_SETUP_INFO|retry_db_url_source=BPM_TEST_DB_URL\n", .{});
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

    defer cleanupRun(conn, read_run_id) catch {};
    defer cleanupRun(conn, write_run_id) catch {};
    defer cleanupRun(conn, throughput_run_id) catch {};
    defer cleanupRun(conn, replay_run_id) catch {};

    try seedEvents(conn, read_run_id, LATENCY_ITERATIONS);
    try seedEvents(conn, replay_run_id, REPLAY_EVENT_COUNT);

    const read_p99 = try measureReadP99(init.io, conn, gpa, read_run_id, LATENCY_ITERATIONS);
    const write_p99 = try measureWriteP99(init.io, conn, gpa, write_run_id, LATENCY_ITERATIONS);
    const throughput_eps = try measureThroughput(init.io, conn, throughput_run_id, THROUGHPUT_SECONDS);
    const replay_ms = try measureReplayMs(init.io, conn, replay_run_id);

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
    };

    var all_passed = true;
    for (results) |r| {
        std.debug.print(
            "NFR_RESULT|{s}|{s}|target={s}|actual={d:.3}|unit={s}|passed={s}\n",
            .{ r.id, r.metric, r.target, r.actual, r.unit, if (r.passed) "true" else "false" },
        );
        if (!r.passed) all_passed = false;
    }

    std.debug.print("NFR_BENCH_SUMMARY|overall_passed={s}|run_id={s}\n", .{ if (all_passed) "true" else "false", run_id });

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

    return error.MissingDbUrl;
}

/// Read a single key's value from .env in the current working directory.
/// Returns null if the file cannot be read or the key is not found.
/// Caller owns the returned memory (freed via allocator).
fn readDotEnvValue(io: std.Io, allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    const contents = cwd.readFileAlloc(io, ".env", allocator, std.Io.Limit.unlimited) catch return null;
    defer allocator.free(contents);

    var lines_iter = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // Skip comments and empty lines
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        // Look for "KEY=value" pattern
        const equals_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const line_key = std.mem.trim(u8, trimmed[0..equals_pos], " \t");
        if (std.mem.eql(u8, line_key, key)) {
            const value = std.mem.trim(u8, trimmed[equals_pos + 1 ..], " \t");
            // Strip surrounding quotes (single or double)
            const unquoted = if ((value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\''))
                value[1 .. value.len - 1]
            else
                value;
            return allocator.dupe(u8, unquoted) catch null;
        }
    }
    return null;
}

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
