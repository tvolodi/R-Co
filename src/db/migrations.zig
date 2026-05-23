//! Migration runner — DB-01, DB-03
//!
//! Discovers numbered SQL files in a migrations directory, applies each in
//! lexicographic order, and records successful application in the
//! schema_migrations table.  Each migration runs in its own transaction.
//!
//! Design artefact: src/design/db.md
const std = @import("std");
const pool_mod = @import("pool.zig");
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
};

// ---------------------------------------------------------------------------
// Migrations
// ---------------------------------------------------------------------------

pub const Migrations = struct {
    /// Discover, order, and apply pending migrations from migrations_dir.
    ///
    /// Algorithm (DB-01, DB-03):
    ///  1. List all *.sql files in migrations_dir; sort lexicographically.
    ///  2. Query schema_migrations for already-applied versions.
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
        // Acquire connection.
        const conn = pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return MigrationError.PoolExhausted,
            else => return MigrationError.MigrationFailed,
        };
        defer pool.release(conn);

        // Verify PostgreSQL >= 15.
        if (pool.pg_version < 150000) return MigrationError.UnsupportedPgVersion;

        // Ensure schema_migrations table exists (idempotent bootstrap).
        conn.exec(
            \\CREATE TABLE IF NOT EXISTS schema_migrations (
            \\  version    TEXT        PRIMARY KEY,
            \\  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            \\)
        ,
            &.{},
        ) catch return MigrationError.MigrationFailed;

        // Open the migrations directory.
        var dir = std.fs.openDirAbsolute(migrations_dir, .{ .iterate = true }) catch
            return MigrationError.MigrationsDirectoryNotFound;
        defer dir.close();

        // Collect *.sql filenames.
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
        }

        var it = dir.iterate();
        while (it.next() catch return MigrationError.MigrationsDirectoryNotFound) |entry| {
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

        // Fetch already-applied versions from schema_migrations.
        // Schema: version TEXT PRIMARY KEY
        //
        // Parameterised query — no string interpolation of user data.
        // Since pg.zig is a stub, conn.query returns an empty result;
        // all migrations will be treated as pending.
        var applied = std.StringHashMap(void).init(allocator);
        defer applied.deinit();

        const existing = conn.query(
            allocator,
            "SELECT version FROM schema_migrations ORDER BY version",
            &.{},
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

        // Determine the highest already-applied version for out-of-order detection.
        var max_applied: []const u8 = "";
        var applied_iter = applied.keyIterator();
        while (applied_iter.next()) |k| {
            if (std.mem.lessThan(u8, max_applied, k.*)) max_applied = k.*;
        }

        // Apply pending migrations in order.
        for (names.items) |filename| {
            // Skip already-applied migrations (idempotent).
            if (applied.contains(filename)) continue;

            // Out-of-order check: if this file < max_applied, it was skipped.
            if (max_applied.len > 0 and std.mem.lessThan(u8, filename, max_applied)) {
                return MigrationError.OutOfOrderMigration;
            }

            // Read SQL file contents.
            const sql_bytes = dir.readFileAlloc(allocator, filename, 16 * 1024 * 1024) catch
                return MigrationError.MigrationFailed;
            defer allocator.free(sql_bytes);

            // BEGIN transaction.
            conn.exec("BEGIN", &.{}) catch return MigrationError.MigrationFailed;

            // Execute the migration SQL.  On failure, roll back.
            conn.exec(sql_bytes, &.{}) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return MigrationError.MigrationFailed;
            };

            // Record successful application.
            // Uses $1 placeholder — no string interpolation. (DB-03, security)
            conn.exec(
                "INSERT INTO schema_migrations (version) VALUES ($1)",
                &.{filename},
            ) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return MigrationError.MigrationFailed;
            };

            // COMMIT.
            conn.exec("COMMIT", &.{}) catch return MigrationError.MigrationFailed;

            // Update local tracking so subsequent out-of-order checks are accurate.
            if (std.mem.lessThan(u8, max_applied, filename)) max_applied = filename;
        }
    }
};
