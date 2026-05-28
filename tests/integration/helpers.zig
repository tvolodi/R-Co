//! Integration test helpers — TestHarness with rollback-on-deinit isolation.
//!
//! Each test gets a fresh transaction that is always rolled back on deinit(),
//! guaranteeing that no test data leaks into subsequent tests or the schema.
//!
//! Usage:
//!   var h = try TestHarness.init(allocator);
//!   defer h.deinit();
//!   // h.conn is a *db.Conn inside an open transaction.
//!
//! Requirement traceability: DB-01, DB-02, DB-03
const std = @import("std");
const pg = @import("pg");
const root = @import("root");

// ---------------------------------------------------------------------------
// Internal helper: ensure schema_migrations exists, then apply all .sql files
// in the "migrations/" directory against the given connection.
// ---------------------------------------------------------------------------

fn runMigrations(io: std.Io, allocator: std.mem.Allocator, conn: *pg.Conn) !void {
    // Bootstrap table.
    try conn.exec(
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\  version    TEXT        PRIMARY KEY,
        \\  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        \\)
    ,
        &.{},
    );

    var dir = try std.Io.Dir.cwd().openDir(io, "migrations", .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const copy = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(copy);
        try names.append(allocator, copy);
    }

    std.sort.block([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // Collect already-applied versions.
    var applied = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = applied.keyIterator();
        while (key_iter.next()) |key| allocator.free(key.*);
        applied.deinit();
    }

    var existing = try conn.query(
        allocator,
        "SELECT version FROM schema_migrations ORDER BY version",
        &.{},
    );
    defer existing.deinit();
    for (existing.rows) |row| {
        if (row.len > 0) {
            if (row[0]) |ver| {
                const ver_copy = try allocator.dupe(u8, ver);
                errdefer allocator.free(ver_copy);
                try applied.put(ver_copy, {});
            }
        }
    }

    // Apply pending migrations.
    for (names.items) |filename| {
        if (applied.contains(filename)) continue;

        const sql_bytes = try dir.readFileAlloc(io, filename, allocator, std.Io.Limit.limited(16 * 1024 * 1024));
        defer allocator.free(sql_bytes);

        try conn.begin();
        conn.simpleQuery(sql_bytes) catch |err| {
            conn.rollback() catch {};
            return err;
        };
        conn.exec(
            "INSERT INTO schema_migrations (version) VALUES ($1)",
            &.{filename},
        ) catch |err| {
            conn.rollback() catch {};
            return err;
        };
        try conn.commit();
    }
}

// ---------------------------------------------------------------------------
// TestHarness
// ---------------------------------------------------------------------------

/// Each test is wrapped in a transaction that is always rolled back on deinit().
/// This guarantees isolation without manual teardown.
pub const TestHarness = struct {
    conn: pg.Conn,
    allocator: std.mem.Allocator,

    /// Initialise the harness:
    ///  1. Reads BPM_TEST_DB_URL from the environment.
    ///  2. Connects directly to the test database (no pool overhead needed).
    ///  3. Runs all pending migrations (idempotent; via schema_migrations table).
    ///  4. Ensures test tenant context is initialized (for pool connections).
    ///  5. Begins an open transaction that deinit() will always roll back.
    ///
    /// Caller must call deinit() to roll back the transaction and close the
    /// connection.
    pub fn init(allocator: std.mem.Allocator) !TestHarness {
        // Read BPM_TEST_DB_URL using the Zig 0.16.0 cross-platform environ API.
        // On Windows Environ.Block = GlobalBlock (.global reads from the PEB).
        const env: std.process.Environ = .{ .block = .global };
        const url = env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
            error.EnvironmentVariableMissing => {
                std.debug.print("BPM_TEST_DB_URL is not set — skipping integration test\n", .{});
                return error.SkipZigTest;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => return err,
        };
        defer allocator.free(url);

        var conn = pg.Conn.connectUrl(std.testing.io, allocator, url) catch |err| {
            std.debug.print("pg.Conn.connectUrl failed: {}\n", .{err});
            return err;
        };
        errdefer conn.close();

        // Run migrations against the test database.
        runMigrations(std.testing.io, allocator, &conn) catch |err| {
            std.debug.print("runMigrations failed: {}\n", .{err});
            return err;
        };

        // Initialize test tenant context for all pool connections.
        // This ensures PostgreSQL has bpm.tenant_id set when pool connections are acquired.
        if (@hasDecl(root, "setTestTenantContext")) {
            root.setTestTenantContext();
        }

        // Begin a transaction; deinit() always rolls it back.
        conn.begin() catch |err| {
            std.debug.print("BEGIN failed: {}\n", .{err});
            return err;
        };

        return TestHarness{
            .conn = conn,
            .allocator = allocator,
        };
    }

    /// Roll back the open transaction and close the connection.
    /// Never commits — test isolation is guaranteed.
    pub fn deinit(self: *TestHarness) void {
        self.conn.rollback() catch {};
        self.conn.close();
    }
};
