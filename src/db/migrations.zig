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
// ISS-0129 / GH-419 advisory lock SQL (acquired inside the per-migration
// transaction in runForSchema, auto-released on COMMIT/ROLLBACK).
// ---------------------------------------------------------------------------
//
// ISS-0129: stable advisory-lock SQL. Acquired at the start of every
// per-migration transaction inside `runForSchema` and auto-released on
// COMMIT/ROLLBACK. Keyspace disjoint from the audit-trigger's per-tenant
// pg_advisory_xact_lock(hashtext('bpm.audit.chain.' || tenant_id::text))
// — see src/design/iss0129_migration_runner_advisory_lock.md.
//
// Single key for all tenants: every concurrent migrate-step caller
// (regardless of `schema_name`) queues on this one advisory lock. The
// audit-INSERT path uses a completely different keyspace, so concurrent
// audit inserts remain unblocked.
const MIGRATIONS_LOCK_KEY_SQL =
    "SELECT pg_advisory_xact_lock(hashtext('bpm.migrations.runForSchema')::bigint)";

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
        return runForSchema(allocator, pool, migrations_dir, "public", false);
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
        force_reconcile: bool,
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

        // ISS-0114 / GH-377: post-condition assertion.
        // After setting search_path, verify SHOW search_path returns a value
        // that includes the tenant schema name. This guards against any future
        // regression where applyRequestStorageRouting()'s LEGACY_RLS fallback
        // (or any other code path) overwrites the migration runner's
        // search_path before the runner has finished its work.
        var sp_result = conn.query(
            allocator,
            "SHOW search_path",
            &.{},
        ) catch return MigrationError.SchemaSetupFailed;
        defer sp_result.deinit();

        if (sp_result.rows.len == 0 or sp_result.rows[0].len == 0 or
            sp_result.rows[0][0] == null)
        {
            return MigrationError.SchemaSetupFailed;
        }
        const sp_val = sp_result.rows[0][0].?;
        if (std.mem.indexOf(u8, sp_val, schema_name) == null) {
            return MigrationError.SchemaSetupFailed;
        }

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
        defer {
            // Free the duplicated version-string keys (see ver_copy below) before
            // tearing down the map; deinit() only releases the map's own storage.
            var applied_key_it = applied.keyIterator();
            while (applied_key_it.next()) |k| allocator.free(k.*);
            applied.deinit();
        }

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
            // GBL-prefixed migrations are global (public-schema) operations that
            // must ONLY run against the public schema.  They must never be applied
            // to per-tenant schemas (tenant_default, tenant_<uuid>, etc.) because
            // they perform DDL on public.tenant_schemas, public.tnt05_progress,
            // onboarding_registry and other global tables that do not exist in
            // tenant schemas.  Silently skip them when schema_name != "public".
            if (!std.mem.eql(u8, schema_name, "public") and
                std.mem.startsWith(u8, filename, "GBL-"))
            {
                continue;
            }

            // Skip already-applied migrations (idempotent).
            if (applied.contains(filename)) continue;

            // ISS-0112 applier guard (Change 2 of src/design/fix-iss0112.md).
            // Read the migration file's first 1 KiB to detect the
            // `-- reapply_on_drift: true` header convention. When set on a
            // corrective migration, the applier supports a second skip
            // predicate: if the ledger row is missing AND the migration's
            // target objects already exist in the target schema (heuristic:
            // any later migration has already been applied for this schema,
            // which proves a downstream object is present that the
            // corrective itself would also have created), log a notice
            // and skip to avoid duplicate DDL. When `force_reconcile=true`,
            // the applier re-runs every flagged corrective regardless of
            // object presence and re-records the ledger row.
            //
            // `force_reconcile` is the verifier-driven reconcile mode and
            // is the OFF switch for this guard.
            const reapply_on_drift: bool = blk: {
                const probe = dir.readFileAlloc(
                    pool.io,
                    filename,
                    allocator,
                    std.Io.Limit.limited(1024),
                ) catch break :blk false;
                if (probe.len == 0) break :blk false;
                defer allocator.free(probe);
                const needle = "-- reapply_on_drift: true";
                break :blk std.mem.indexOf(u8, probe, needle) != null;
            };

            if (reapply_on_drift and !force_reconcile) {
                // Heuristic for "objects already present": if some later
                // migration has been applied for this schema, the corrective's
                // effects are downstream of that and assumed already in
                // place (because every migration in the chain is itself
                // idempotent, and the corrective is idempotent too).
                const has_late_row = blk: {
                    var has_it = false;
                    var ait = applied.keyIterator();
                    while (ait.next()) |k| {
                        if (migrationOrder(k.*) > migrationOrder(filename)) {
                            has_it = true;
                            break;
                        }
                    }
                    break :blk has_it;
                };
                if (has_late_row) {
                    conn.exec("SELECT 'MigrationLedgerSync: ' || $1 || ': row missing but later migrations applied, skipping re-apply to avoid duplicate DDL.'", &.{filename}) catch {};
                    continue;
                }
            }

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

            // ISS-0129 / GH-419: Acquire the canonical migration-runner
            // advisory lock immediately after BEGIN so concurrent migrate-step
            // callers serialize on this key for the duration of this
            // transaction. The lock is transaction-scoped (auto-released on
            // COMMIT/ROLLBACK), so it never leaks across pool-release
            // boundaries and never requires explicit cleanup.
            //
            // Keyspace is disjoint from the audit-trigger's per-tenant
            // pg_advisory_xact_lock(hashtext('bpm.audit.chain.' || tenant_id
            // ::text)) — see src/design/iss0129_migration_runner_advisory_lock.md.
            //
            // On any lock-acquisition failure: ROLLBACK so the lock is
            // released by the surrounding transaction semantics, then
            // return MigrationFailed (the migration will be retried on the
            // next runForSchema call).
            conn.exec(MIGRATIONS_LOCK_KEY_SQL, &.{}) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return MigrationError.MigrationFailed;
            };

            // ISS-0144 / GitHub #454: `applied` (used by the `if
            // (applied.contains(filename)) continue;` check above) was
            // captured by a single query BEFORE this loop began and BEFORE
            // any lock was held. Two concurrent runForSchema() callers
            // targeting the SAME schema_name (e.g. every test-integration
            // binary that provisions "tenant_default") can both read
            // `applied` as not-yet-containing this filename, both reach
            // BEGIN, and then simply queue on the advisory lock above rather
            // than being turned away — so the second caller, once granted
            // the lock, would attempt this file's DDL and INSERT again after
            // the first caller already committed it, producing C23505 on
            // schema_migrations_schema_version_uq (observed live: GBL-084
            // "tenant_<uuid>", 001_event_store.sql already exists"). Holding
            // the lock is necessary but not sufficient — it only serializes
            // the two transactions relative to each other, it does not
            // un-stale the first transaction's read of `applied`. Re-check
            // directly under lock protection, immediately before doing any
            // work, and skip this file if a concurrent holder already
            // recorded it while we were waiting.
            const already_applied_under_lock = blk: {
                var recheck = conn.query(
                    allocator,
                    "SELECT 1 FROM public.schema_migrations WHERE schema_name = $1 AND version = $2",
                    &.{ schema_name, filename },
                ) catch break :blk false;
                defer recheck.deinit();
                break :blk recheck.rows.len > 0;
            };
            if (already_applied_under_lock) {
                conn.exec("COMMIT", &.{}) catch return MigrationError.MigrationFailed;
                if (file_order > max_applied_order) {
                    max_applied_order = file_order;
                    max_applied = filename;
                }
                continue;
            }

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
