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

    // ISS-0603 / GH-467: Order by migrationOrder(), NOT by raw filename bytes.
    //
    // This is the sort that `zig build migrate` actually executes, and it must
    // stay identical to the one in src/db/migrations.zig runForSchema().
    //
    // Previously a plain std.mem.lessThan on the filename: '1' (0x31) sorts
    // before 'G' (0x47), so EVERY GBL-* file was applied after EVERY 1xxx_*
    // file. GBL-119_env01_tenant_type_field.sql adds public.tenant.tenant_type,
    // which 1135_iss0114_backfill_public_tenant_storage_mode.sql writes to, so
    // bootstrapping a fresh database died with C42703 'column "tenant_type" of
    // relation "tenant" does not exist'.
    //
    // Filename is the tiebreak for equal orders so the sequence is fully
    // deterministic (migrations/ contains real duplicate-order pairs, e.g.
    // 050_tenant_hostnames.sql / 050_xc01_trace_id_audit.sql).
    std.sort.block([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            const oa = migrationOrder(a);
            const ob = migrationOrder(b);
            if (oa != ob) return oa < ob;
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
    //
    // ISS-0603 / GH-467: `walked_order` is the highest migrationOrder() this run
    // has already passed while walking `names.items` in correctly-sorted order.
    // The out-of-order check below compares against it rather than against a
    // global max-applied watermark.
    //
    // Rationale: before this fix the sort ran in raw filename order, so every
    // GBL-* file was applied AFTER every 1xxx_* file. Databases provisioned
    // under that old order legitimately have a backlog of pending GBL files
    // (orders 1112..1133) sitting below an already-applied 1134/1135. Judging
    // that backlog against a global watermark would abort with "Out-of-order
    // migration" and permanently brick every pre-existing environment. Scoping
    // the check to inversions encountered *within this pass* grandfathers the
    // legacy backlog in while still catching a genuinely misnumbered new file.
    var walked_order: u32 = 0;
    var walked_name: []const u8 = "";

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
            // ISS-0603 / GH-467: walking past an applied file advances the
            // watermark, so an applied migration only constrains files that come
            // AFTER it in correct sort order. A pending file sorting BEFORE every
            // applied one (the legacy GBL backlog) is never compared against it.
            const applied_order = migrationOrder(filename);
            if (applied_order > walked_order) {
                walked_order = applied_order;
                walked_name = filename;
            }
            continue;
        }

        const file_order = migrationOrder(filename);
        if (walked_order > 0 and file_order < walked_order) {
            std.log.err("Out-of-order migration: {s} (already applied past: {s})", .{ filename, walked_name });
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
        if (file_order > walked_order) {
            walked_order = file_order;
            walked_name = filename;
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

/// Migration ordering rule for the CLI runner.
///
/// ISS-0603 / GH-467: this is a byte-for-byte duplicate of
/// `migrationOrder` in src/db/migrations.zig. The two MUST stay identical —
/// `zig build migrate` runs this copy while the server/test harness runs the
/// other, so any drift between them means the CLI and the runtime disagree
/// about migration order, which is the class of defect ISS-0603 fixed.
/// If you change one, change both (and the sort comparators that call them).
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
