//! Migration runner — DB-01, DB-03
//!
//! Discovers numbered SQL files in a migrations directory, applies each in
//! lexicographic order, and records successful application in the
//! schema_migrations table.  Each migration runs in its own transaction.
//!
//! Design artefact: src/design/db.md
//! SPT-01: extended with runForSchema to support schema-per-tenant migrations.
const std = @import("std");
const pool_mod = @import("pool");
const Pool = pool_mod.Pool;
const PoolError = pool_mod.PoolError;

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const MigrationError = error{
    /// migrations_dir path does not exist or is not readable.
    MigrationsDirectoryNotFound,
    /// DB-01: a migration M > current N is already applied — applying N+1
    /// before N would create an out-of-order sequence.
    OutOfOrderMigration,
    /// DB-01: SQL execution failed; the migration transaction was rolled back.
    MigrationFailed,
    /// DB-01: PostgreSQL major version < 15; fatal.
    UnsupportedPgVersion,
    /// Cannot acquire pool connection to run migrations.
    PoolExhausted,
    /// SET search_path failed for the target schema.
    SchemaSetupFailed,
};

// ---------------------------------------------------------------------------
// Migrations
// ---------------------------------------------------------------------------

pub const Migrations = struct {
    /// Discover, order, and apply pending migrations from migrations_dir.
    ///
    /// Re-expressed as a thin wrapper around runForSchema("public") for
    /// backward compatibility.  All callers are unaffected.
    ///
    /// Algorithm (DB-01, DB-03):
    ///  1. List all *.sql files in migrations_dir; sort lexicographically.
    ///  2. Query schema_migrations for already-applied versions (schema='public').
    ///  3. For each file in sorted order:
    ///     - If already in schema_migrations → skip (idempotent).
    ///     - If any version M > this file's N is in schema_migrations →
    ///       return OutOfOrderMigration.
    ///     - Otherwise: BEGIN; execute file; INSERT INTO schema_migrations;
    ///       COMMIT.  On any error: ROLLBACK; return MigrationFailed.
    pub fn run(
        allocator: std.mem.Allocator,
        pool: *Pool,
        migrations_dir: []const u8,
    ) MigrationError!void {
        return runForSchema(allocator, pool, migrations_dir, "public");
    }

    /// Apply pending migrations inside a specific PostgreSQL schema.
    ///
    /// TNT-02 PROTOCOL (must be preserved):
    ///   1. Acquire a single connection from the pool.
    ///   2. Issue: SET search_path TO <schema_name>,public
    ///      as the FIRST statement on that connection, before any migration SQL.
    ///   3. Execute each pending migration file via conn.simpleQuery().
    ///      Because search_path is set, unqualified table names resolve to
    ///      <schema_name>; the migration files need no public. qualifiers.
    ///   4. Track completion in public.schema_migrations using the composite
    ///      key (schema_name, version) — always fully qualified to public.
    ///   5. Release the connection.
    ///
    /// schema_name is UUID-derived (via schemaNameForTenant), never user-supplied.
    /// It contains only [a-z0-9_] characters and is safe to interpolate into
    /// SET search_path TO ... — see §5 Safety Note in
    /// src/design/spt-01-schema-per-tenant-provisioning.md.
    pub fn runForSchema(
        allocator: std.mem.Allocator,
        pool: *Pool,
        migrations_dir: []const u8,
        schema_name: []const u8,
    ) MigrationError!void {
        // Acquire connection.
        const conn = pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return MigrationError.PoolExhausted,
            else => return MigrationError.MigrationFailed,
        };
        defer pool.release(conn);

        // Verify PostgreSQL >= 15.
        if (pool.pg_version < 150000) return MigrationError.UnsupportedPgVersion;

        // Set search_path so unqualified references resolve to the target schema.
        // schema_name is UUID-derived and never user-supplied; interpolation is safe.
        var path_buf: [128]u8 = undefined;
        const search_path_sql = std.fmt.bufPrint(
            &path_buf,
            "SET search_path TO {s},public",
            .{schema_name},
        ) catch return MigrationError.SchemaSetupFailed;
        conn.exec(search_path_sql, &.{}) catch return MigrationError.SchemaSetupFailed;

        // Ensure schema_migrations table exists (idempotent bootstrap).
        // Always qualified as public.schema_migrations so this works regardless
        // of the current search_path.
        conn.exec(
            \\CREATE TABLE IF NOT EXISTS public.schema_migrations (
            \\  schema_name TEXT        NOT NULL DEFAULT 'public',
            \\  version     TEXT        NOT NULL,
            \\  applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            \\  PRIMARY KEY (schema_name, version)
            \\)
        ,
            &.{},
        ) catch return MigrationError.MigrationFailed;

        // Open the migrations directory.
        var dir = std.Io.Dir.openDirAbsolute(pool.io, migrations_dir, .{ .iterate = true }) catch
            return MigrationError.MigrationsDirectoryNotFound;
        defer dir.close(pool.io);

        // Collect *.sql filenames.
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
        }

        var it = dir.iterate();
        while (it.next(pool.io) catch return MigrationError.MigrationsDirectoryNotFound) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
            const name_copy = allocator.dupe(u8, entry.name) catch
                return MigrationError.MigrationFailed;
            names.append(allocator, name_copy) catch {
                allocator.free(name_copy);
                return MigrationError.MigrationFailed;
            };
        }

        // Sort lexicographically (zero-padded NNN_ prefix ensures numeric order).
        std.sort.block([]u8, names.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        // Fetch already-applied versions for this specific schema.
        // Filters by schema_name so per-tenant migration state is independent.
        var applied = std.StringHashMap(void).init(allocator);
        defer applied.deinit();

        const existing = conn.query(
            allocator,
            "SELECT version FROM public.schema_migrations WHERE schema_name = $1 ORDER BY version",
            &.{schema_name},
        ) catch return MigrationError.MigrationFailed;
        defer {
            var mutable_existing = existing;
            mutable_existing.deinit();
        }

        for (existing.rows) |row| {
            if (row.len > 0) {
                if (row[0]) |ver| {
                    const ver_copy = allocator.dupe(u8, ver) catch
                        return MigrationError.MigrationFailed;
                    applied.put(ver_copy, {}) catch {
                        allocator.free(ver_copy);
                        return MigrationError.MigrationFailed;
                    };
                }
            }
        }

        // Determine the highest already-applied numeric order for out-of-order detection.
        var max_applied: []const u8 = "";
        var max_applied_order: u32 = 0;
        var applied_iter = applied.keyIterator();
        while (applied_iter.next()) |k| {
            const order = migrationOrder(k.*);
            if (order > max_applied_order) {
                max_applied_order = order;
                max_applied = k.*;
            }
        }

        // Apply pending migrations in order.
        for (names.items) |filename| {
            // Skip already-applied migrations (idempotent).
            if (applied.contains(filename)) continue;

            // Out-of-order check: a lower numeric migration order cannot be applied
            // after a higher order has already been recorded for this schema.
            const file_order = migrationOrder(filename);
            if (max_applied.len > 0 and file_order < max_applied_order) {
                return MigrationError.OutOfOrderMigration;
            }

            // Read SQL file contents.
            const sql_bytes = dir.readFileAlloc(pool.io, filename, allocator, std.Io.Limit.limited(16 * 1024 * 1024)) catch
                return MigrationError.MigrationFailed;
            defer allocator.free(sql_bytes);

            // BEGIN transaction.
            conn.exec("BEGIN", &.{}) catch return MigrationError.MigrationFailed;

            // Execute the migration SQL via the simple query protocol.
            // Migration files contain multi-statement DDL separated by semicolons;
            // the extended query protocol (used by exec()) rejects multi-statement
            // input, so simpleQuery() is required here.
            conn.simpleQuery(sql_bytes) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return MigrationError.MigrationFailed;
            };

            // Record successful application with schema_name.
            // Uses $1, $2 placeholders — no string interpolation. (DB-03, security)
            conn.exec(
                "INSERT INTO public.schema_migrations (schema_name, version) VALUES ($1, $2)",
                &.{ schema_name, filename },
            ) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return MigrationError.MigrationFailed;
            };

            // COMMIT.
            conn.exec("COMMIT", &.{}) catch return MigrationError.MigrationFailed;

            // Update local tracking so subsequent out-of-order checks are accurate.
            if (file_order > max_applied_order) {
                max_applied_order = file_order;
                max_applied = filename;
            }
        }
    }
};

fn migrationOrder(filename: []const u8) u32 {
    var i: usize = 0;
    while (i < filename.len and std.ascii.isDigit(filename[i])) : (i += 1) {}
    if (i == 0) return 0;
    return std.fmt.parseInt(u32, filename[0..i], 10) catch 0;
}
