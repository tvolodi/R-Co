//! Migration runner — DB-01, DB-03
//!
//! Discovers numbered SQL files in a migrations directory, applies each in
//! migrationOrder() order (numeric prefix, with "GBL-" prefixed files offset by
//! +1000 so they interleave with the 1xxx_ series rather than sorting after
//! them — ISS-0603 / GH-467), and records successful application in the
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
    /// ISS-0604 / GH-470: a migration declares `-- scope: public` (or carries the
    /// GBL- prefix) but its body performs unqualified, search_path-resolved table
    /// work that genuinely belongs in the per-tenant pass. Applying it would
    /// silently skip that work for every tenant, so the runner refuses.
    MigrationScopeMismatch,
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
    ///  1. List all *.sql files in migrations_dir; sort by migrationOrder(),
    ///     with the filename as a deterministic tiebreak (ISS-0603 / GH-467).
    ///  2. Query schema_migrations for already-applied versions (schema='public').
    ///  3. For each file in sorted order:
    ///     - If already in schema_migrations → skip (idempotent).
    ///     - If a HIGHER-ordered migration was already walked past in this pass →
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

        // ISS-0603 / GH-467: Order by migrationOrder(), NOT by raw filename bytes.
        //
        // This sort previously used a plain std.mem.lessThan on the filename and
        // was commented "zero-padded NNN_ prefix ensures numeric order". That
        // stopped being true the moment GBL- prefixed migrations were introduced:
        // '1' (0x31) sorts before 'G' (0x47), so EVERY GBL-* file was applied
        // after EVERY 1xxx_* file. GBL-119_env01_tenant_type_field.sql adds
        // public.tenant.tenant_type, which 1135_iss0114_backfill_public_tenant_
        // storage_mode.sql writes to — so bootstrapping any fresh database died
        // with C42703 'column "tenant_type" of relation "tenant" does not exist'.
        //
        // migrationOrder() already encoded the INTENDED ordering (strip "GBL-",
        // add a 1000 offset => GBL-119 -> 1119, correctly before 1135) and was
        // already used by the out-of-order detection check below. The sort and
        // the detection check disagreed, and the sort governed execution.
        // Both now agree: migrationOrder() is the single ordering authority.
        //
        // Filename is the tiebreak when two files share an order, so the
        // sequence is fully deterministic (e.g. 050_tenant_hostnames.sql and
        // 050_xc01_trace_id_audit.sql, and 056_onboarding_registry.sql and
        // 056_xc03_configuration_repository_fix.sql, are real duplicate-order
        // pairs in migrations/).
        std.sort.block([]u8, names.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                const oa = migrationOrder(a);
                const ob = migrationOrder(b);
                if (oa != ob) return oa < ob;
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

        // ISS-0603 / GH-467: Establish the pre-existing-database baseline.
        //
        // Before this fix the apply sort ran in raw filename order, so every
        // GBL-* file was applied AFTER every 1xxx_* file. Databases provisioned
        // under that old order therefore legitimately contain ledger rows whose
        // migrationOrder() is *lower* than a previously applied one — e.g. a DB
        // with 1134 applied but GBL-112..GBL-133 (orders 1112..1133) still
        // pending, which is exactly the state this workspace's bpm_dev is in.
        //
        // Judging those pending files against the global `max_applied_order`
        // watermark would return OutOfOrderMigration and permanently brick every
        // such environment — a fix that bootstraps fresh databases but breaks
        // every existing developer database is not an acceptable fix.
        //
        // So the out-of-order check below is scoped to genuine NEW inversions:
        // a file is only rejected when a HIGHER-ordered migration was applied
        // that this run has already walked past in sorted order. Migrations that
        // were left pending by the old, wrong sort are grandfathered in and are
        // simply applied now, in their correct relative order.
        //
        // `walked_order` is the highest migrationOrder() this run has already
        // passed while walking `names.items` in correctly-sorted order. It starts
        // at 0 and only advances, so it measures inversions *within this pass*
        // rather than against the whole historical ledger.
        var walked_order: u32 = 0;

        // Apply pending migrations in order.
        for (names.items) |filename| {
            // ISS-0604 / GH-470: skip public-only migrations in per-tenant passes.
            //
            // Public-only migrations are global operations that must ONLY run
            // against the public schema. They must never be applied to per-tenant
            // schemas (tenant_default, tenant_<uuid>, ...) because they perform
            // DDL/DML on public.tenant_schemas, public.tenant, public.tnt05_progress,
            // onboarding_registry and other global tables.
            //
            // Scope comes from migrationScope(): the historical `GBL-` filename
            // prefix, OR an explicit `-- scope: public` header. Before ISS-0604
            // only the GBL- prefix was honoured, so numeric-but-public-only files
            // (1135 and friends) were wrongly executed in tenant passes. For 1135
            // that was fatal on a fresh database: it writes public.tenant.tenant_type,
            // a column added by GBL-119, which tenant passes skip — so it failed
            // C42703, left the default tenant unready, and that in turn tripped
            // GBL-116's TNT-07 pre-flight, deadlocking bootstrap at 86/106.
            const is_public_pass = std.mem.eql(u8, schema_name, "public");
            if (!is_public_pass) {
                const scope_header = blk: {
                    const probe = dir.readFileAlloc(
                        pool.io,
                        filename,
                        allocator,
                        std.Io.Limit.limited(4096),
                    ) catch break :blk &[_]u8{};
                    break :blk probe;
                };
                defer if (scope_header.len > 0) allocator.free(scope_header);
                if (migrationScope(filename, scope_header) == .public_only) continue;
            }

            // Skip already-applied migrations (idempotent).
            //
            // ISS-0603 / GH-467: walking past an applied file advances
            // `walked_order`. This is what gives the out-of-order check below its
            // meaning: an applied migration only constrains files that come AFTER
            // it in correct sort order. A pending file that sorts BEFORE every
            // applied one (the legacy GBL backlog) is never compared against it,
            // so pre-existing databases apply their backlog instead of erroring.
            if (applied.contains(filename)) {
                const applied_order = migrationOrder(filename);
                if (applied_order > walked_order) walked_order = applied_order;
                continue;
            }

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
            //
            // ISS-0603 / GH-467: compared against `walked_order` — the highest
            // order this run has already passed in correctly-sorted order — and
            // not against the raw global `max_applied_order` watermark. Because
            // `names.items` is now sorted by migrationOrder(), reaching a pending
            // file whose order is below something we already walked past is a
            // genuine inversion (a newly authored migration numbered beneath the
            // existing chain), which is what this check is for.
            //
            // Applied migrations that sort ABOVE the whole pending backlog are
            // the legacy artefact of the old lexicographic sort (see the
            // `walked_order` rationale above) and must NOT trip this check,
            // or every database provisioned before this fix would fail forever.
            const file_order = migrationOrder(filename);
            if (walked_order > 0 and file_order < walked_order) {
                return MigrationError.OutOfOrderMigration;
            }

            // Read SQL file contents.
            const sql_bytes = dir.readFileAlloc(pool.io, filename, allocator, std.Io.Limit.limited(16 * 1024 * 1024)) catch
                return MigrationError.MigrationFailed;
            defer allocator.free(sql_bytes);

            // ISS-0604 / GH-470: misclassification guard — fail LOUDLY.
            //
            // A migration marked public-only whose body does unqualified,
            // search_path-resolved table work would silently skip that work for
            // every tenant schema, drifting tenant data shape apart with no error
            // — exactly the silent-wrong-pass failure mode this issue is about.
            // Checked in the public pass (where every migration is seen) so a bad
            // header is caught on the very first run, not months later.
            if (is_public_pass and
                declaresPublicScopeHeader(filename, sql_bytes) and
                declaresUnqualifiedTableWork(sql_bytes))
            {
                return MigrationError.MigrationScopeMismatch;
            }

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
                if (file_order > walked_order) walked_order = file_order;
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
            if (file_order > walked_order) walked_order = file_order;
        }
    }
};

/// The single ordering authority for migration application (ISS-0603 / GH-467).
///
/// Both the apply sort in `runForSchema` and its out-of-order detection check
/// use this function. Made public so the ordering contract is directly testable
/// — see TC-DB-01-03 / TC-DB-01-06 in tests/unit/db_test.zig. Keeping the sort
/// and the detection check on two different notions of "order" is precisely the
/// defect ISS-0603 fixed; do not reintroduce a second ordering rule.
pub fn migrationOrder(filename: []const u8) u32 {
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

// ---------------------------------------------------------------------------
// ISS-0604 / GH-470: migration scope classification
// ---------------------------------------------------------------------------

/// Which migration pass a file belongs to.
///
/// The runner applies migrations twice over: once against the `public` schema,
/// and once per tenant schema (`tenant_default`, `tenant_<uuid>`, ...). A
/// migration that runs in the wrong pass is the ISS-0604 defect class.
pub const MigrationScope = enum {
    /// Runs in the public pass ONLY. Never applied to a tenant schema.
    public_only,
    /// Runs in every pass — public and per-tenant. The default for numeric
    /// migrations that create/alter unqualified (search_path-resolved) tables.
    all_schemas,
};

/// The declared scope header a migration may carry, e.g.
///     -- scope: public
pub const SCOPE_PUBLIC_HEADER = "-- scope: public";

/// The explicit opt-in for the default, useful to silence the misclassification
/// guard on a migration that genuinely is public-qualified but must still run
/// per-tenant (rare — e.g. it reads public config to write tenant tables).
pub const SCOPE_ALL_HEADER = "-- scope: all_schemas";

/// Classify a migration from its filename and header text.
///
/// ISS-0604 / GH-470. Two mechanisms, in precedence order:
///   1. The `GBL-` filename prefix — the pre-existing, implicit marker. Always
///      public-only. Kept for backward compatibility; every existing GBL file
///      relies on it and renaming them would rewrite ledger keys.
///   2. An explicit `-- scope: public` / `-- scope: all_schemas` header in the
///      first KiB of the file — the preferred, self-evident marker for numeric
///      migrations.
///
/// Scope is deliberately declared IN THE MIGRATION FILE rather than in a list
/// inside the runner. ISS-0603 happened precisely because a file's ordering
/// classification lived only in runner logic and drifted out of agreement with
/// the files; keeping scope next to the SQL it describes means a future author
/// sees it while writing the migration, and reviewers see it in the diff.
pub fn migrationScope(filename: []const u8, header: []const u8) MigrationScope {
    if (std.mem.startsWith(u8, filename, "GBL-")) return .public_only;
    if (std.mem.indexOf(u8, header, SCOPE_ALL_HEADER) != null) return .all_schemas;
    if (std.mem.indexOf(u8, header, SCOPE_PUBLIC_HEADER) != null) return .public_only;
    return .all_schemas;
}

/// True when public-only scope came from an explicit `-- scope: public` header
/// rather than from the historical `GBL-` filename prefix.
///
/// ISS-0604 / GH-470: the misclassification guard keys off THIS, not off
/// migrationScope(), because unqualified table names are a legitimate
/// long-standing convention inside GBL files (they run only in the public pass,
/// where search_path already resolves to public). Only the newly introduced
/// header carries the stricter "must be public.-qualified" contract.
pub fn declaresPublicScopeHeader(filename: []const u8, header: []const u8) bool {
    if (std.mem.startsWith(u8, filename, "GBL-")) return false;
    if (std.mem.indexOf(u8, header, SCOPE_ALL_HEADER) != null) return false;
    return std.mem.indexOf(u8, header, SCOPE_PUBLIC_HEADER) != null;
}

/// Heuristic misclassification detector (ISS-0604 / GH-470).
///
/// Returns true when a migration body performs schema-resolved DDL/DML — i.e.
/// it references at least one table WITHOUT a `public.` qualifier and without
/// dynamic `%I` schema interpolation. Such a migration genuinely needs the
/// per-tenant pass, so declaring it `-- scope: public` is a misclassification
/// and the runner refuses to proceed rather than silently skipping tenant work.
///
/// This is the "fail loudly" half of the contract: the scope header is cheap to
/// write and therefore cheap to get wrong, so a wrong value must not degrade
/// into silent data-shape drift across tenant schemas the way ISS-0604 did.
///
/// SCOPE OF THE GUARD — applies to the `-- scope: public` header ONLY, never to
/// the `GBL-` prefix. 13 existing GBL files (GBL-114/116/117/119/120/123/125/126/
/// 127/128/129/130/131) legitimately write unqualified table names and rely on
/// search_path resolving to `public` during the public pass. That is a valid,
/// long-standing convention for GBL files, so applying this heuristic to them
/// would hard-fail every migration run. Verified by auditing all 106 files in
/// migrations/ before enabling the guard.
pub fn declaresUnqualifiedTableWork(body: []const u8) bool {
    // Statement heads that introduce a table reference we care about.
    const heads = [_][]const u8{
        "CREATE TABLE IF NOT EXISTS ",
        "CREATE TABLE ",
        "ALTER TABLE IF EXISTS ",
        "ALTER TABLE ",
        "DROP TABLE IF EXISTS ",
        "DROP TABLE ",
        "INSERT INTO ",
    };
    var line_it = std.mem.splitScalar(u8, body, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        // Skip comments — a scope header or prose must never trip the guard.
        if (std.mem.startsWith(u8, line, "--")) continue;
        // Skip dynamic SQL: EXECUTE format('... %I ...') targets a schema
        // computed at runtime, which is the sanctioned cross-schema pattern.
        if (std.mem.indexOf(u8, line, "%I") != null) continue;
        for (heads) |head| {
            const idx = std.mem.indexOf(u8, line, head) orelse continue;
            const rest = std.mem.trimStart(u8, line[idx + head.len ..], " \t");
            if (rest.len == 0) continue;
            // Qualified with an explicit schema? Then it is not search_path work.
            if (std.mem.startsWith(u8, rest, "public.")) break;
            if (std.mem.startsWith(u8, rest, "pg_")) break;
            if (std.mem.startsWith(u8, rest, "information_schema.")) break;
            // A quoted or bare identifier with no schema qualifier: this
            // resolves through search_path, so it is per-tenant work.
            return true;
        }
    }
    return false;
}
