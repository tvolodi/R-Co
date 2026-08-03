const std = @import("std");
const pg = @import("pg");
const pool_mod = @import("pool");
const db_provisioning = @import("db_provisioning");
const build_options = @import("build_options");

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
    // ISS-0091: use the composite (schema_name, version) key so the CLI migration
    // runner and test harness (tests/integration/helpers.zig) both track progress
    // against the same canonical table. Per-tenant schemas are identified by
    // schema_name; the public schema uses schema_name='public'.
    conn.exec(
        \\CREATE TABLE IF NOT EXISTS public.schema_migrations (
        \\  schema_name TEXT        NOT NULL DEFAULT 'public',
        \\  version     TEXT        NOT NULL,
        \\  applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        \\  PRIMARY KEY (schema_name, version)
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

    // Fetch already-applied versions for the public schema.
    var applied = std.StringHashMap(void).init(allocator);
    defer applied.deinit();

    var result = conn.query(
        allocator,
        "SELECT version FROM public.schema_migrations WHERE schema_name = 'public' ORDER BY version",
        &.{},
    ) catch |err| {
        std.log.err("Failed to query schema_migrations: {}", .{err});
        std.process.exit(1);
    };
    defer result.deinit();

    for (result.rows) |row| {
        if (row.len > 0) {
            if (row[0]) |ver| {
                applied.put(ver, {}) catch {};
            }
        }
    }

    // Apply pending migrations.
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

    var applied_count: u32 = 0;
    var provisioned_default_tenant = false;
    for (names.items) |filename| {
        // ISS-502 fresh-bootstrap fix: provision (or re-verify) the default
        // tenant's schema-per-tenant schema before the FIRST GBL-prefixed
        // migration runs. GBL- migrations include gated pre-flight checks
        // (e.g. GBL-077/TNT-07, GBL-084/ISS-503) that require every tenant in
        // public.tenant to already be fully cut over — specifically
        // public.tenant_schemas.migrations_applied_at IS NOT NULL and (for
        // GBL-077) a COMPLETED public.tnt05_progress row per business table.
        //
        // On a from-scratch database the default tenant
        // (00000000-0000-0000-0000-000000000000) is seeded by migration 031
        // via raw INSERT, bypassing provisionTenantSchema() entirely, so
        // without this step migrations_applied_at stays NULL forever on a
        // migrate-only bootstrap. In production this is normally set the
        // first time the API server starts (see the identical call in
        // runApiServer() / main.zig) — but GBL- gated migrations run during
        // `zig build migrate`, before the server ever starts, so a
        // migrate-only bootstrap must perform this step too.
        //
        // Placed here (immediately before the first GBL- file, rather than
        // after the whole loop) because the loop aborts the process on the
        // first migration failure — running this only at the very end would
        // never be reached once GBL-077/GBL-084 fail. Runs at most once per
        // invocation. Idempotent and non-fatal by design, same as main.zig:
        // a provisioning failure here must not turn an otherwise-successful
        // public-schema migration run into a hard CLI failure — the gated
        // migration below will simply re-report the real unready-tenant
        // reason if this step did not succeed.
        if (!provisioned_default_tenant and std.mem.startsWith(u8, filename, "GBL-")) {
            provisioned_default_tenant = true;
            var provision_pool = pool_mod.Pool.init(init.io, allocator, .{ .url = url, .pool_size = 2 }) catch |err| {
                std.log.warn("default tenant schema provisioning skipped: could not open pool: {}", .{err});
                return;
            };
            defer provision_pool.deinit();

            const default_tenant_id = "00000000-0000-0000-0000-000000000000";
            db_provisioning.provisionTenantSchema(allocator, &provision_pool, default_tenant_id, build_options.migrations_dir) catch |err| {
                std.log.warn("default tenant schema provisioning failed: {} (tenant_id={s})", .{ err, default_tenant_id });
            };
        }

        if (applied.contains(filename)) {
            std.log.info("  skip  {s}", .{filename});
            continue;
        }

        const file_order = migrationOrder(filename);
        if (max_applied.len > 0 and file_order < max_applied_order) {
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
            "INSERT INTO public.schema_migrations (schema_name, version) VALUES ('public', $1)",
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
        if (file_order > max_applied_order) {
            max_applied_order = file_order;
            max_applied = filename;
        }
        applied_count += 1;
    }

    if (applied_count == 0) {
        std.log.info("No new migrations to apply.", .{});
    } else {
        std.log.info("{d} migration(s) applied successfully.", .{applied_count});
    }

    // Fallback: if no GBL- migration was pending this run (e.g. all GBL-
    // migrations were already applied in a prior invocation), the in-loop
    // provisioning hook above never fired. Run it once here too so a
    // migrate-only bootstrap that resumes from a partially-migrated database
    // still ends up with the default tenant provisioned. Idempotent — see
    // the detailed rationale in the in-loop hook above.
    if (!provisioned_default_tenant) {
        var provision_pool = pool_mod.Pool.init(init.io, allocator, .{ .url = url, .pool_size = 2 }) catch |err| {
            std.log.warn("default tenant schema provisioning skipped: could not open pool: {}", .{err});
            return;
        };
        defer provision_pool.deinit();

        const default_tenant_id = "00000000-0000-0000-0000-000000000000";
        db_provisioning.provisionTenantSchema(allocator, &provision_pool, default_tenant_id, build_options.migrations_dir) catch |err| {
            std.log.warn("default tenant schema provisioning failed: {} (tenant_id={s})", .{ err, default_tenant_id });
        };
    }
}

fn migrationOrder(filename: []const u8) u32 {
    // GBL-NNN_... files: skip "GBL-" prefix then parse the numeric part.
    // We add an offset (1000) for GBL migrations so they don't clash with
    // regular NNN prefix migrations numerically.
    var start: usize = 0;
    var offset: u32 = 0;
    if (std.mem.startsWith(u8, filename, "GBL-")) {
        start = 4;
        offset = 1000;
    }
    var i: usize = start;
    while (i < filename.len and std.ascii.isDigit(filename[i])) : (i += 1) {}
    if (i == start) return 0;
    const base_order = std.fmt.parseInt(u32, filename[start..i], 10) catch 0;
    return base_order + offset;
}
