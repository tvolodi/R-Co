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
const build_options = @import("build_options");

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

    const environ: std.process.Environ = .{ .block = .global };
    const env_migrations_dir = environ.getAlloc(allocator, "BPM_MIGRATIONS_DIR") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => unreachable,
    };
    defer if (env_migrations_dir) |path| allocator.free(path);

    const migrations_dir = if (env_migrations_dir) |path| path else build_options.migrations_dir;
    const migration_candidates = [_][]const u8{
        "migrations",
        "../migrations",
        "../../migrations",
        "../../../migrations",
        "../../../../migrations",
    };

    const dir: std.Io.Dir = blk: {
        const opened_absolute = std.Io.Dir.openDirAbsolute(io, migrations_dir, .{ .iterate = true }) catch {
            const opened_relative = std.Io.Dir.cwd().openDir(io, migrations_dir, .{ .iterate = true }) catch {
                for (migration_candidates) |candidate| {
                    const opened_candidate = std.Io.Dir.cwd().openDir(io, candidate, .{ .iterate = true }) catch |candidate_open_err| {
                        if (candidate_open_err == error.FileNotFound) continue;
                        return candidate_open_err;
                    };
                    break :blk opened_candidate;
                }
                return error.FileNotFound;
            };
            break :blk opened_relative;
        };
        break :blk opened_absolute;
    };
    defer dir.close(io);

    var names = std.ArrayList([]u8).empty;
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
            "INSERT INTO schema_migrations(version) VALUES ($1)",
            &.{filename},
        ) catch |err| {
            conn.rollback() catch {};
            return err;
        };
        try conn.commit();
    }

    return;
}

fn configureSessionTimeouts(conn: *pg.Conn) !void {
    // Keep integration runs deterministic under contention: prefer explicit timeout
    // failures to indefinite waits on locks/statements.
    try conn.exec("SET lock_timeout = '5s'", &.{});
    try conn.exec("SET statement_timeout = '60s'", &.{});
    try conn.exec("SET idle_in_transaction_session_timeout = '120s'", &.{});
}

fn applyCompatibilityShims(conn: *pg.Conn) !void {
    // Legacy XC integration fixtures still reference `instances` and omit
    // newer mandatory event fields. These shims preserve test intent while
    // keeping production schema unchanged.
    try execCompatibilitySql(conn,
        \\CREATE TABLE IF NOT EXISTS instances (
        \\  instance_id UUID PRIMARY KEY,
        \\  tenant_id UUID NOT NULL,
        \\  definition_artifact_hash TEXT,
        \\  status TEXT NOT NULL DEFAULT 'ACTIVE',
        \\  variables JSONB NOT NULL DEFAULT '{}',
        \\  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        \\)
    );

    try execCompatibilitySql(conn,
        \\DROP FUNCTION IF EXISTS bpm_test_events_compat_defaults() CASCADE
    );

    try execCompatibilitySql(conn,
        \\CREATE OR REPLACE FUNCTION bpm_test_events_compat_defaults()
        \\RETURNS TRIGGER
        \\LANGUAGE plpgsql
        \\AS $$
        \\BEGIN
        \\    IF NEW.tenant_id IS NULL THEN
        \\        NEW.tenant_id := '00000000-0000-0000-0000-000000000000'::uuid;
        \\    END IF;
        \\
        \\    IF NEW.actor_id IS NULL THEN
        \\        NEW.actor_id := NEW.tenant_id;
        \\    END IF;
        \\
        \\    IF NEW.sequence_number IS NULL THEN
        \\        SELECT COALESCE(MAX(e.sequence_number), 0) + 1
        \\          INTO NEW.sequence_number
        \\          FROM events e
        \\         WHERE e.instance_id = NEW.instance_id;
        \\    END IF;
        \\
        \\    RETURN NEW;
        \\END;
        \\$$
    );

    try execCompatibilitySql(conn,
        \\DROP TRIGGER IF EXISTS trg_bpm_test_events_compat_defaults ON events
    );

    try execCompatibilitySql(conn,
        \\CREATE TRIGGER trg_bpm_test_events_compat_defaults
        \\BEFORE INSERT ON events
        \\FOR EACH ROW
        \\EXECUTE FUNCTION bpm_test_events_compat_defaults()
    );

    try execCompatibilitySql(conn,
        \\DROP FUNCTION IF EXISTS bpm_repository_artifacts_immutable() CASCADE
    );

    try execCompatibilitySql(conn,
        \\CREATE OR REPLACE FUNCTION bpm_repository_artifacts_immutable()
        \\RETURNS TRIGGER
        \\LANGUAGE plpgsql
        \\AS $$
        \\BEGIN
        \\    RAISE EXCEPTION 'repository artifacts are immutable and cannot be modified or deleted';
        \\END;
        \\$$
    );

    try execCompatibilitySql(conn,
        \\DROP TRIGGER IF EXISTS trg_repository_artifacts_prevent_update ON repository_artifacts
    );
    try execCompatibilitySql(conn,
        \\CREATE TRIGGER trg_repository_artifacts_prevent_update
        \\BEFORE UPDATE ON repository_artifacts
        \\FOR EACH ROW EXECUTE FUNCTION bpm_repository_artifacts_immutable()
    );

    try execCompatibilitySql(conn,
        \\DROP TRIGGER IF EXISTS trg_repository_artifacts_prevent_delete ON repository_artifacts
    );
    try execCompatibilitySql(conn,
        \\CREATE TRIGGER trg_repository_artifacts_prevent_delete
        \\BEFORE DELETE ON repository_artifacts
        \\FOR EACH ROW EXECUTE FUNCTION bpm_repository_artifacts_immutable()
    );
}

fn execCompatibilitySql(conn: *pg.Conn, sql: []const u8) !void {
    conn.exec(sql, &.{}) catch |err| switch (err) {
        // Compatibility shims are best-effort for legacy suites.
        error.ServerError => {},
        else => return err,
    };
}

fn resetTestData(conn: *pg.Conn) !void {
    // Keep migration/seed/config tables intact and only clear transient test data.
    // Truncate tables one-by-one so one missing legacy table does not skip cleanup.
    try truncateTableBestEffort(conn, "instance_definition_snapshots");
    try truncateTableBestEffort(conn, "process_events");
    try truncateTableBestEffort(conn, "tasks");
    try truncateTableBestEffort(conn, "timers");
    try truncateTableBestEffort(conn, "instance_projections");
    try truncateTableBestEffort(conn, "variable_schemas");
    try truncateTableBestEffort(conn, "process_definitions");
    try truncateTableBestEffort(conn, "events");
    try truncateTableBestEffort(conn, "event_store");
    try truncateTableBestEffort(conn, "audit_log");
    try truncateTableBestEffort(conn, "audit_entries");
    try truncateTableBestEffort(conn, "dlq");
    try truncateTableBestEffort(conn, "webhook_subscriptions");
}

fn truncateTableBestEffort(conn: *pg.Conn, comptime table_name: []const u8) !void {
    const sql = "TRUNCATE TABLE " ++ table_name ++ " RESTART IDENTITY CASCADE";
    conn.exec(sql, &.{}) catch |err| switch (err) {
        // Some tables may not exist yet in partial migration states.
        error.ServerError => {},
        else => return err,
    };
}

fn ensureDefaultOidcSeeds(conn: *pg.Conn) !void {
    try conn.exec(
        \\INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
        \\VALUES (
        \\  '00000000-0000-0000-0000-000000000000'::uuid,
        \\  'default',
        \\  'Default Tenant',
        \\  'ACTIVE',
        \\  'bpm-default'
        \\)
        \\ON CONFLICT (id) DO UPDATE
        \\SET slug = EXCLUDED.slug,
        \\    display_name = EXCLUDED.display_name,
        \\    status = EXCLUDED.status,
        \\    idp_realm_id = COALESCE(tenant.idp_realm_id, EXCLUDED.idp_realm_id),
        \\    updated_at = NOW()
    , &.{});

    try conn.exec(
        \\INSERT INTO jit_provisioning_config (realm, enabled, default_status, default_roles)
        \\VALUES ('bpm-default', TRUE, 'ACTIVE', '[]'::jsonb)
        \\ON CONFLICT (realm) DO NOTHING
    , &.{});
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
                std.debug.print("BPM_TEST_DB_URL is required for integration tests\n", .{});
                return error.MissingTestDatabaseUrl;
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

        configureSessionTimeouts(&conn) catch |err| {
            std.debug.print("configureSessionTimeouts failed: {}\n", .{err});
            return err;
        };

        // Run migrations against the test database.
        runMigrations(std.testing.io, allocator, &conn) catch |err| {
            std.debug.print("runMigrations failed: {}\n", .{err});
            return err;
        };

        // Clear transient integration data for deterministic per-test isolation.
        resetTestData(&conn) catch |err| {
            std.debug.print("resetTestData failed: {}\n", .{err});
            return err;
        };

        ensureDefaultOidcSeeds(&conn) catch |err| {
            std.debug.print("ensureDefaultOidcSeeds failed: {}\n", .{err});
            return err;
        };

        applyCompatibilityShims(&conn) catch |err| {
            std.debug.print("applyCompatibilityShims failed: {}\n", .{err});
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
