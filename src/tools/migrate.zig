const std = @import("std");
const pg = @import("pg");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Read BPM_DB_URL from the environment map provided by the runtime.
    const url = init.environ_map.get("BPM_DB_URL") orelse {
        std.log.err("BPM_DB_URL environment variable is not set", .{});
        std.process.exit(1);
    };

    // Open a direct connection (no pool needed for a CLI migration runner).
    var conn = pg.Conn.connectUrl(init.io, allocator, url) catch |err| {
        std.log.err("Failed to connect to database: {}", .{err});
        std.process.exit(1);
    };
    defer conn.close();

    // Ensure schema_migrations table exists.
    conn.exec(
        \\CREATE TABLE IF NOT EXISTS schema_migrations (
        \\  version    TEXT        PRIMARY KEY,
        \\  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        \\)
        ,
        &.{},
    ) catch |err| {
        std.log.err("Failed to create schema_migrations: {}", .{err});
        std.process.exit(1);
    };

    // Open the migrations directory.
    var dir = std.Io.Dir.cwd().openDir(init.io, "migrations", .{ .iterate = true }) catch |err| {
        std.log.err("Cannot open migrations directory: {}", .{err});
        std.process.exit(1);
    };
    defer dir.close(init.io);

    // Collect and sort migration filenames.
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (it.next(init.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const name_copy = allocator.dupe(u8, entry.name) catch {
            std.log.err("Out of memory", .{});
            std.process.exit(1);
        };
        names.append(allocator, name_copy) catch {
            allocator.free(name_copy);
            std.log.err("Out of memory", .{});
            std.process.exit(1);
        };
    }

    std.sort.block([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Fetch already-applied versions.
    var applied = std.StringHashMap(void).init(allocator);
    defer {
        var key_it = applied.keyIterator();
        while (key_it.next()) |k| allocator.free(k.*);
        applied.deinit();
    }

    var result = conn.query(
        allocator,
        "SELECT version FROM schema_migrations ORDER BY version",
        &.{},
    ) catch |err| {
        std.log.err("Failed to query schema_migrations: {}", .{err});
        std.process.exit(1);
    };
    defer result.deinit();

    for (result.rows) |row| {
        if (row.len > 0) {
            if (row[0]) |ver| {
                const ver_copy = allocator.dupe(u8, ver) catch continue;
                applied.put(ver_copy, {}) catch {
                    allocator.free(ver_copy);
                };
            }
        }
    }

    // Apply pending migrations.
    var max_applied: []const u8 = "";
    var applied_iter = applied.keyIterator();
    while (applied_iter.next()) |k| {
        if (std.mem.lessThan(u8, max_applied, k.*)) max_applied = k.*;
    }

    var applied_count: u32 = 0;
    for (names.items) |filename| {
        if (applied.contains(filename)) {
            std.log.info("  skip  {s}", .{filename});
            continue;
        }

        if (max_applied.len > 0 and std.mem.lessThan(u8, filename, max_applied)) {
            std.log.err("Out-of-order migration: {s} (max applied: {s})", .{ filename, max_applied });
            std.process.exit(1);
        }

        const sql_bytes = dir.readFileAlloc(init.io, filename, allocator, std.Io.Limit.limited(16 * 1024 * 1024)) catch |err| {
            std.log.err("Cannot read {s}: {}", .{ filename, err });
            std.process.exit(1);
        };
        defer allocator.free(sql_bytes);

        conn.exec("BEGIN", &.{}) catch |err| {
            std.log.err("BEGIN failed for {s}: {}", .{ filename, err });
            std.process.exit(1);
        };

        conn.simpleQuery(sql_bytes) catch |err| {
            conn.exec("ROLLBACK", &.{}) catch {};
            std.log.err("Migration {s} failed: {}", .{ filename, err });
            std.process.exit(1);
        };

        conn.exec(
            "INSERT INTO schema_migrations (version) VALUES ($1)",
            &.{filename},
        ) catch |err| {
            conn.exec("ROLLBACK", &.{}) catch {};
            std.log.err("Failed to record migration {s}: {}", .{ filename, err });
            std.process.exit(1);
        };

        conn.exec("COMMIT", &.{}) catch |err| {
            std.log.err("COMMIT failed for {s}: {}", .{ filename, err });
            std.process.exit(1);
        };

        std.log.info("  apply {s}", .{filename});
        if (std.mem.lessThan(u8, max_applied, filename)) max_applied = filename;
        applied_count += 1;
    }

    if (applied_count == 0) {
        std.log.info("No new migrations to apply.", .{});
    } else {
        std.log.info("{d} migration(s) applied successfully.", .{applied_count});
    }
}
