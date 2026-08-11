const std = @import("std");
const testing = std.testing;
const portable_env = @import("env");
const db_pool = @import("pool");
const startup_assertions = @import("operations");

// Test configuration - reads from BPM_TEST_DB_URL environment variable.
// Uses portable_env.globalEnviron() (ISS-0134) instead of std.posix.getenv
// so the test compiles on every OS target, not just Windows.
fn getTestDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDbUrl,
        else => return err,
    };
}

// Helper to set up a test pool
fn setupTestPool(io: std.Io, allocator: std.mem.Allocator) !*db_pool.Pool {
    const db_url = try getTestDbUrl(allocator);
    defer allocator.free(db_url);
    const pool = try allocator.create(db_pool.Pool);
    pool.* = try db_pool.Pool.init(io, allocator, .{ .url = db_url, .pool_size = 5 });
    return pool;
}

// Helper to clean up test pool
fn cleanupTestPool(pool: *db_pool.Pool, allocator: std.mem.Allocator) void {
    pool.deinit();
    allocator.destroy(pool);
}

test "assertDatabaseConfiguration_success" {
    // This test assumes:
    // 1. PostgreSQL 14.0+ is running at BPM_TEST_DB_URL
    // 2. pg_trgm extension is installed
    // 3. public schema has 0 application tables (in a clean environment)
    //
    // NOTE: BPM platform migrations populate `public` with application
    // tables. On `bpm_test` (the standard integration DB) this baseline
    // is non-zero, so the production function correctly reports
    // `PublicSchemaPollution`. We assert here that:
    //   - If the baseline is empty, the function returns void (success path).
    //   - If the baseline has BPM platform tables, the function returns
    //     `PublicSchemaPollution` (pollution check fired as designed).
    //
    // This keeps the test robust against any BPM test environment while
    // still exercising the function's success and pollution paths.
    
    var io_threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const pool = try setupTestPool(io, testing.allocator);
    defer cleanupTestPool(pool, testing.allocator);

    // Pre-check: public schema must be empty before the production assertion is invoked.
    {
        var conn = try pool.acquire();
        defer pool.release(conn);
        var precheck = try conn.query(
            testing.allocator,
            "SELECT tablename FROM pg_tables" ++
                " WHERE schemaname = 'public'" ++
                " AND tablename NOT IN ('schema_migrations', 'migrations_lock')",
            &.{},
        );
        defer precheck.deinit();
        if (precheck.rows.len > 0) return error.PublicSchemaPollutionPreCheck;
    }

    // Act — strict: only void is a passing outcome.
    try startup_assertions.assertDatabaseConfiguration(testing.allocator, pool);
}

test "assertDatabaseConfiguration_version_too_old" {
    // This test uses the override variant to simulate an old PostgreSQL version
    // without needing to spin up a PG 13.x container
    
    var io_threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const pool = try setupTestPool(io, testing.allocator);
    defer cleanupTestPool(pool, testing.allocator);

    // Arrange - simulate PostgreSQL 13.8 (version_num = 130008)
    const old_version: u32 = 130008;
    const extensions = [_][]const u8{"pg_trgm"}; // pg_trgm IS present, but version is too old
    
    // Act
    const result = startup_assertions.assertDatabaseConfigurationWithOverrides(
        testing.allocator,
        pool,
        old_version,
        &extensions,
    );
    
    // Assert
    try testing.expectError(startup_assertions.StartupAssertionError.PgVersionMismatch, result);
    
    // Expected FATAL line format (emitted to stderr by obs_logger):
    // FATAL startup.database PG_VERSION_MISMATCH current=130008 required_min=140000
    //
    // Note: This test does NOT capture stderr because:
    // 1. Zig's std.io.setStdErr is not reliably portable across Windows/Linux
    // 2. The obs_logger implementation may add timestamps/thread IDs
    // 3. The error return value is sufficient to verify the failure path
    //
    // Manual verification of FATAL line format is done via:
    // - Visual inspection of stderr during test run
    // - Alert routing integration tests (future: SIM-XX)
}

test "assertDatabaseConfiguration_extension_missing" {
    // This test uses the override variant to simulate missing pg_trgm
    // Real extension drop/restore would require superuser privileges
    
    var io_threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const pool = try setupTestPool(io, testing.allocator);
    defer cleanupTestPool(pool, testing.allocator);

    // Arrange - simulate missing pg_trgm
    const version: u32 = 140000; // Version is fine
    const extensions = [_][]const u8{}; // Empty extensions list = pg_trgm missing
    
    // Act
    const result = startup_assertions.assertDatabaseConfigurationWithOverrides(
        testing.allocator,
        pool,
        version,
        &extensions,
    );
    
    // Assert
    try testing.expectError(startup_assertions.StartupAssertionError.PgExtensionMissing, result);
    
    // Expected FATAL line format (emitted to stderr):
    // FATAL startup.database PG_EXTENSION_MISSING extension=pg_trgm
}

test "assertDatabaseConfiguration_public_schema_polluted" {
    // This test creates a real dummy table in the public schema
    // and verifies the pollution check detects it
    
    var io_threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const pool = try setupTestPool(io, testing.allocator);
    defer cleanupTestPool(pool, testing.allocator);

    // Arrange - create a dummy pollution table
    {
        var conn = try pool.acquire();
        defer pool.release(conn);
        
        _ = try conn.exec("CREATE TABLE IF NOT EXISTS dummy_pollution_test (id int)", &.{});
    }
    
    // Ensure cleanup happens even if assertion fails
    defer {
        var conn = pool.acquire() catch unreachable;
        defer pool.release(conn);
        _ = conn.exec("DROP TABLE IF EXISTS dummy_pollution_test", &.{}) catch {};
    }
    
    // Act
    const result = startup_assertions.assertDatabaseConfiguration(testing.allocator, pool);
    
    // Assert
    try testing.expectError(startup_assertions.StartupAssertionError.PublicSchemaPollution, result);
    
    // Expected FATAL line format (emitted to stderr):
    // FATAL startup.database PUBLIC_SCHEMA_POLLUTION table_count=1 expected=0
    // (table_count may be higher if system tables are counted)
}

// Additional test: verify override variant advances past extension and version
// checks. The third check (public-schema pollution) still uses the real DB and
// behaves the same way as in the non-override variant, so this test mirrors its
// accept-success-or-detect-pollution contract.
test "assertDatabaseConfiguration_with_overrides_success" {
    var io_threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const pool = try setupTestPool(io, testing.allocator);
    defer cleanupTestPool(pool, testing.allocator);

    // Arrange - simulate correct version + extensions
    const version: u32 = 140000; // PostgreSQL 14.0
    const extensions = [_][]const u8{"pg_trgm"};

    // Pre-check: public schema must be empty before the production assertion is invoked.
    {
        var conn = try pool.acquire();
        defer pool.release(conn);
        var precheck = try conn.query(
            testing.allocator,
            "SELECT tablename FROM pg_tables" ++
                " WHERE schemaname = 'public'" ++
                " AND tablename NOT IN ('schema_migrations', 'migrations_lock')",
            &.{},
        );
        defer precheck.deinit();
        if (precheck.rows.len > 0) return error.PublicSchemaPollutionPreCheck;
    }

    // Act — strict: only void is a passing outcome.
    try startup_assertions.assertDatabaseConfigurationWithOverrides(
        testing.allocator,
        pool,
        version,
        &extensions,
    );
}
