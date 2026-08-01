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
const bpm = @import("bpm");

// ---------------------------------------------------------------------------
// Internal helper: apply all pending migrations against the given connection,
// via the real bpm.migrations.Migrations.run()/runForSchema() — the same
// canonical migrator every production caller uses.
//
// ISS-0091 (GitHub #343): this harness used to maintain its own schema-local
// schema_migrations tracking table, entirely independent from the canonical
// public.schema_migrations(schema_name, version) table that
// Migrations.runForSchema() consults (the single source of truth per ISS-504,
// src/design/iss504_migration_tracking.md). Because both trackers applied the
// same migration files but never consulted each other, a migration recorded
// "applied" by one was invisible to the other — any test file whose own
// makePool() called Migrations.runForSchema() directly (bypassing this
// harness, e.g. tests/integration/iss102_claim_test.zig) would then re-attempt
// a migration whose non-idempotent inline named constraint had already been
// claimed by a downstream rename, producing a deterministic "already exists"
// failure. Delegating to the real migrator here eliminates the second
// tracker entirely: there is now exactly one bookkeeping table for every
// caller, test or production. See src/design/iss0091_harness_migration_tracker_unification.md.
// ---------------------------------------------------------------------------

fn resolveMigrationsDir(allocator: std.mem.Allocator) !struct { dir: []const u8, owned: ?[]u8 } {
    const environ: std.process.Environ = .{ .block = .global };
    const env_migrations_dir = environ.getAlloc(allocator, "BPM_MIGRATIONS_DIR") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => unreachable,
    };
    // BPM_MIGRATIONS_DIR (set by build.zig for every test target) and
    // build_options.migrations_dir (b.path("migrations").getPath(b)) are both
    // always absolute paths — no relative-candidate fallback is needed here,
    // unlike the pre-ISS-0091 implementation. Migrations.runForSchema() opens
    // this directory via std.Io.Dir.openDirAbsolute(), so an absolute path is
    // required.
    if (env_migrations_dir) |path| return .{ .dir = path, .owned = path };
    return .{ .dir = build_options.migrations_dir, .owned = null };
}

/// ISS-0091: pre-record the given filenames as already-applied for
/// schema_name='public' in public.schema_migrations, so the canonical
/// migrator (which has no per-caller skip-list hook) silently treats them as
/// done. These migrations have data pre-conditions in production that
/// isolated integration test runs don't set up:
///   - GBL-074/075: TNT-05 backfill tracking (requires pre-existing migration state)
///   - GBL-077: TNT-07 RLS cleanup (requires schema-per-tenant state)
/// Idempotent: ON CONFLICT DO NOTHING means re-running this is a no-op once
/// the rows already exist.
fn markPublicGlobalSkipsApplied(conn: *pg.Conn) !void {
    try conn.exec(
        \\CREATE TABLE IF NOT EXISTS public.schema_migrations (
        \\  schema_name TEXT        NOT NULL DEFAULT 'public',
        \\  version     TEXT        NOT NULL,
        \\  applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        \\  PRIMARY KEY (schema_name, version)
        \\)
    , &.{});
    const skip_files = [_][]const u8{
        "GBL-074_tnt05_backfill_tracking.sql",
        "GBL-075_tnt05_backfill_run.sql",
        "GBL-077_tnt07_rls_cleanup.sql",
    };
    for (skip_files) |filename| {
        try conn.exec(
            \\INSERT INTO public.schema_migrations (schema_name, version) VALUES ('public', $1)
            \\ON CONFLICT (schema_name, version) DO NOTHING
        , &.{filename});
    }
}

fn runMigrations(io: std.Io, allocator: std.mem.Allocator, conn: *pg.Conn, url: []const u8) !void {
    // ISS-0090: every integration test binary calls TestHarness.init() ->
    // runMigrations() independently and concurrently against the same shared
    // `public` schema. Without serialization, two processes can both pass the
    // "not yet applied" check for the same migration and both attempt to
    // apply it; some migrations use inline named constraints/indexes that a
    // bare `CREATE TABLE IF NOT EXISTS` cannot deduplicate under a true race,
    // so one loses with "already exists" — and because the failure rolls
    // back before the schema_migrations row commits, every subsequent run
    // retries forever. Hold a session-level advisory lock for the whole
    // check-and-apply pass so only one process migrates `public` at a time;
    // the rest wait, then see the migration already recorded and skip it.
    // GH-366 / ISS-0107 regression: bracket this acquire with the same
    // '90s'/'5s' lock_timeout scoping that fc5884b's ISS-0107 Rework-1
    // already applies at the (different) line-487 widened acquire. The
    // line-99 critical section's "narrow" assumption no longer holds under
    // the post-fc5884b queue depth: the lock holder is now busy in the
    // line-487 widened section, so the back of the queue legitimately needs
    // more than the ambient 5s ceiling to acquire this lock. See
    // src/design/fix-ISS-0110.md for full analysis and src/design/fix-ISS-0107.md
    // for the proven Rework-1 pattern this brackets. Plain sequential SET
    // (not SET LOCAL — the connection is not inside a transaction at this
    // point; not defer/errdefer — errdefer conn.close() on the caller already
    // discards the whole connection on any error path, and a function-scope
    // defer would not fire until after the function returned, which is too
    // late).
    try conn.exec("SET lock_timeout = '90s'", &.{});
    try conn.exec("SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))", &.{});
    try conn.exec("SET lock_timeout = '5s'", &.{});

    defer conn.exec("SELECT pg_advisory_unlock(hashtext('bpm_test_migrations_public'))", &.{}) catch {};

    try markPublicGlobalSkipsApplied(conn);

    const resolved = try resolveMigrationsDir(allocator);
    defer if (resolved.owned) |path| allocator.free(path);

    var mig_pool = try bpm.pool.Pool.init(io, allocator, bpm.pool.PoolConfig{
        .url = url,
        .pool_size = 2,
    });
    defer mig_pool.deinit();

    try bpm.migrations.Migrations.run(allocator, &mig_pool, resolved.dir);
}

fn runMigrationsForSchema(io: std.Io, allocator: std.mem.Allocator, conn: *pg.Conn, schema: []const u8, url: []const u8) !void {
    // ISS-502 fresh-bootstrap fix follow-up: `zig build migrate` now calls the
    // real Zig-side provisionTenantSchema()/runForSchema() for the default
    // tenant so gated migrations (GBL-077/TNT-07, GBL-084/ISS-503) can pass
    // their pre-flight checks (see src/tools/migrate.zig). That real path
    // tracks completion in public.schema_migrations using the composite key
    // (schema_name, version) and marks public.tenant_schemas.migrations_applied_at.
    //
    // ISS-0091 (GitHub #343): this test-harness bootstrapper used to predate
    // that and keep its own independent, version-only `schema_migrations`
    // tracking table local to the tenant schema, with no knowledge of what the
    // real migrator already applied — see the runMigrations() doc comment
    // above and src/design/iss0091_harness_migration_tracker_unification.md
    // for the full root-cause writeup. It now delegates to the real
    // Migrations.runForSchema(), which is the single source of truth for both
    // this harness and every direct-pool test caller.
    //
    // The already-migrated fast path below queries public.tenant_schemas (the
    // canonical provisioning-state table, unaffected by this fix) and is kept
    // as-is: if the real migrator has already fully migrated this schema, we
    // can skip straight to setting search_path.
    //
    // ISS-0090: also serialize the check-and-apply pass with a session-level
    // advisory lock keyed by schema name, for the same reason as runMigrations
    // above — concurrent test binaries calling TestHarness.init() otherwise
    // race on this schema's non-idempotent inline CONSTRAINT/index DDL, and a
    // failed racer's rolled-back transaction means the migration is retried
    // (and re-raced) by every subsequent test run indefinitely.
    try conn.exec("SELECT pg_advisory_lock(hashtext($1))", &.{schema});
    defer conn.exec("SELECT pg_advisory_unlock(hashtext($1))", &.{schema}) catch {};

    {
        var already_migrated = conn.query(
            allocator,
            "SELECT migrations_applied_at FROM public.tenant_schemas WHERE schema_name = $1 AND migrations_applied_at IS NOT NULL",
            &.{schema},
        ) catch null;
        if (already_migrated) |*result| {
            defer result.deinit();
            if (result.rows.len > 0) {
                const set_path_sql = try std.fmt.allocPrint(allocator, "SET search_path TO {s}, public", .{schema});
                defer allocator.free(set_path_sql);
                try conn.exec(set_path_sql, &.{});
                return;
            }
        }
    }

    const resolved = try resolveMigrationsDir(allocator);
    defer if (resolved.owned) |path| allocator.free(path);

    // Migrations.runForSchema() already skips GBL-prefixed migrations for any
    // schema_name != "public" (src/db/migrations.zig), and sets
    // `SET search_path TO <schema_name>,public` on its own pool connection
    // before applying migration SQL — so unqualified table references inside
    // migration files still resolve correctly. It does NOT set search_path on
    // `conn` (the harness's own connection), so we do that explicitly below
    // for the rest of TestHarness.init() (compatibility shims, resetTestData,
    // etc. operate on `conn`, not on the migration pool).
    {
        var mig_pool = try bpm.pool.Pool.init(io, allocator, bpm.pool.PoolConfig{
            .url = url,
            .pool_size = 2,
        });
        defer mig_pool.deinit();
        try bpm.migrations.Migrations.runForSchema(allocator, &mig_pool, resolved.dir, schema);
    }

    const set_path_sql = try std.fmt.allocPrint(allocator, "SET search_path TO {s}, public", .{schema});
    defer allocator.free(set_path_sql);
    try conn.exec(set_path_sql, &.{});
}

fn configureTestSearchPath(conn: *pg.Conn) !void {
    // TNT-02/TNT-03: Integration tests always run against the 'default' tenant
    // (UUID 00000000-0000-0000-0000-000000000000 → schema 'tenant_default').
    // The direct harness connection is not a pool connection so it does not go
    // through applyRequestTenantContext(). Set search_path explicitly so that
    // unqualified table references (process_definitions, instance_projections,
    // etc.) resolve to the tenant schema rather than public — where they no
    // longer exist after migration GBL-073.
    try conn.exec("SET search_path TO tenant_default,public", &.{});
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
    try truncateTableBestEffort(conn, "tasks");
    try truncateTableBestEffort(conn, "timers");
    try truncateTableBestEffort(conn, "instance_projections");
    try truncateTableBestEffort(conn, "variable_schemas");
    try truncateTableBestEffort(conn, "process_definitions");
    try truncateTableBestEffort(conn, "events");
    try truncateTableBestEffort(conn, "audit_log");
    try truncateTableBestEffort(conn, "audit_entries");
    try truncateTableBestEffort(conn, "dead_letter_items");
    try truncateTableBestEffort(conn, "webhook_subscriptions");
    // SVC-04 uses the service catalog; truncate so LIMIT-50 page-1 tests stay deterministic.
    try truncateTableBestEffort(conn, "service_catalog");
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
    // ISS-0100 (GitHub #357): schema-qualify every reference to `tenant` in
    // this function as `public.tenant`. By the time this function runs,
    // TestHarness.init() has already set search_path to
    // "tenant_default,public" (configureTestSearchPath()), and some
    // long-lived test databases carry a stray, out-of-date `tenant` table
    // inside the tenant_default schema (created by the historically
    // unqualified `CREATE TABLE tenant` in migration
    // 031_adp04b_tenant_realm_binding.sql, which — unlike GBL-prefixed
    // migrations — is NOT skipped for non-public schemas). That shadow
    // table never received later ALTER TABLE ADD COLUMN changes that are
    // GBL-prefixed (e.g. tenant_type from GBL-080), so an unqualified
    // `INSERT INTO tenant (...)` here can silently resolve against the
    // shadow table instead of public.tenant and fail once a GBL-only
    // column is referenced. Schema-qualifying eliminates the ambiguity
    // regardless of search_path or shadow-table drift.
    try conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id)
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
        \\    idp_realm_id = COALESCE(public.tenant.idp_realm_id, EXCLUDED.idp_realm_id),
        \\    updated_at = NOW()
    , &.{});

    try conn.exec(
        \\INSERT INTO jit_provisioning_config (realm, enabled, default_status, default_roles)
        \\VALUES ('bpm-default', TRUE, 'ACTIVE', '[]'::jsonb)
        \\ON CONFLICT (realm) DO NOTHING
    , &.{});

    // SVC-01..04 integration test fixture tenants.
    // These are committed before each test's transaction begins so that
    // pool-based catalog operations (registerService, etc.) can see them.
    // SVC-04 per-test tenant fixtures are also included here; the test code
    // re-inserts them inside the harness transaction (ON CONFLICT DO NOTHING
    // makes those re-inserts no-ops) to keep the test SQL self-documenting.
    try conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES
        \\  ('eeeeeeee-0000-0000-0000-000000000001'::uuid, 'svc-t1',       'SVC Test Tenant 1',       'ACTIVE', 'svc-realm-t1',      'test', '00000000-0000-0000-0000-000000000000'::uuid),
        \\  ('eeeeeeee-0000-0000-0000-000000000002'::uuid, 'svc-t2',       'SVC Test Tenant 2',       'ACTIVE', 'svc-realm-t2',      'test', '00000000-0000-0000-0000-000000000000'::uuid),
        \\  ('b4200000-0000-0000-0000-000000000001'::uuid, 'svc04-upd-tn', 'SVC04 Update Tenant',     'ACTIVE', 'realm-svc04-upd',   'test', '00000000-0000-0000-0000-000000000000'::uuid),
        \\  ('c4300000-0000-0000-0000-000000000001'::uuid, 'svc04-cnf-ow', 'SVC04 Conflict Owner',    'ACTIVE', 'realm-svc04-cnf-ow','test', '00000000-0000-0000-0000-000000000000'::uuid),
        \\  ('c4300000-0000-0000-0000-000000000002'::uuid, 'svc04-cnf-ot', 'SVC04 Conflict Other',    'ACTIVE', 'realm-svc04-cnf-ot','test', '00000000-0000-0000-0000-000000000000'::uuid),
        \\  ('d4400000-0000-0000-0000-000000000001'::uuid, 'svc04-inuse-t','SVC04 InUse Tenant',      'ACTIVE', 'realm-svc04-inuse', 'test', '00000000-0000-0000-0000-000000000000'::uuid),
        \\  ('e4500000-0000-0000-0000-000000000001'::uuid, 'svc04-lst-ta', 'SVC04 List TA',           'ACTIVE', 'realm-svc04-ta',    'test', '00000000-0000-0000-0000-000000000000'::uuid),
        \\  ('e4500000-0000-0000-0000-000000000002'::uuid, 'svc04-lst-tb', 'SVC04 List TB',           'ACTIVE', 'realm-svc04-tb',    'test', '00000000-0000-0000-0000-000000000000'::uuid),
        \\  ('f4600000-0000-0000-0000-000000000001'::uuid, 'svc04-all-t',  'SVC04 All Tenant',        'ACTIVE', 'realm-svc04-all',   'test', '00000000-0000-0000-0000-000000000000'::uuid)
        \\ON CONFLICT (id) DO NOTHING
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

        // Run migrations against public first.
        // Must run BEFORE tenant search_path is set.
        runMigrations(std.testing.io, allocator, &conn, url) catch |err| {
            std.debug.print("runMigrations failed: {}\n", .{err});
            return err;
        };

        // Provision and migrate tenant_default so tenant-scoped business tables
        // (events, entity_record_latest, dead_letter_items, etc.) always exist.
        _ = conn.exec("SELECT bpm_provision_tenant_schema($1::uuid)", &.{bpm.api_tenant_context.DEFAULT_TENANT_ID}) catch {};
        runMigrationsForSchema(std.testing.io, allocator, &conn, "tenant_default", url) catch |err| {
            std.debug.print("runMigrationsForSchema (tenant_default) failed: {}\n", .{err});
            return err;
        };

        // ISS-0107 (GitHub #366): configureTestSearchPath(), resetTestData(), and
        // applyCompatibilityShims() below all run against the shared, per-process
        // `tenant_default` schema that every one of the ~19+ test-integration
        // binaries provisions and writes into. resetTestData() issues eleven
        // sequential TRUNCATE ... RESTART IDENTITY CASCADE statements (always
        // promoted to AccessExclusiveLock by Postgres) and applyCompatibilityShims()
        // issues DROP/CREATE TRIGGER/FUNCTION DDL against shared tables — with no
        // cross-process ordering, concurrently-running binaries produced genuine
        // N-way circular AccessExclusiveLock waits (40P01 "deadlock detected"),
        // corroborated by 42710 ("already exists") and 23505 (unique-violation)
        // errors from the unprotected DROP/CREATE-trigger race.
        //
        // Widen the same, already-correct, already-battle-tested
        // 'bpm_test_migrations_public' advisory lock (see runMigrations() above)
        // to also cover this section, rather than introducing a second lock key:
        // the actual correctness requirement is mutual exclusion of the *entire*
        // TestHarness.init() pipeline across binaries, not just the migration
        // passes. See src/design/fix-ISS-0107.md for the full analysis of why a
        // distinct key would reopen the same race (two keys only provide mutual
        // exclusion within each key's own critical section, never across them).
        //
        // ISS-0107 rework 1: widening this critical section means every one of
        // the ~19+ binaries must now queue through it, which grows this specific
        // acquire's worst-case wait well past the ambient 5s lock_timeout set by
        // configureSessionTimeouts() above -- Postgres was cancelling the acquire
        // itself with 55P03 once enough binaries queued behind it. Raise
        // lock_timeout to a generously-bounded 90s for exactly this one acquire
        // statement, then restore it to 5s immediately after (plain sequential
        // SET, not defer/errdefer -- see src/design/fix-ISS-0107.md
        // "Failure-path correctness" for why a deferred restore is both
        // unnecessary, given errdefer conn.close() above already discards the
        // whole connection on any error, and actively harmful, since a
        // function-scope defer would not fire until after conn.begin() below).
        try conn.exec("SET lock_timeout = '90s'", &.{});
        try conn.exec("SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))", &.{});
        try conn.exec("SET lock_timeout = '5s'", &.{});

        // Set search_path to tenant_default so resetTestData and all subsequent
        // operations on this direct connection resolve tenant-schema tables
        // (process_definitions, instance_projections, etc.) which no longer exist
        // in public after migration GBL-073.
        configureTestSearchPath(&conn) catch |err| {
            std.debug.print("configureTestSearchPath failed: {}\n", .{err});
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

        // Release the widened bpm_test_migrations_public advisory lock now that
        // resetTestData()/applyCompatibilityShims() have completed. Explicit
        // unlock (rather than defer) matches the fix design's required release
        // point: after applyCompatibilityShims() but before tenant context is
        // set and the per-test transaction begins.
        conn.exec("SELECT pg_advisory_unlock(hashtext('bpm_test_migrations_public'))", &.{}) catch {};

        // Initialize test tenant context for all pool connections.
        // Pool.acquire() calls applyRequestTenantContext() which reads this thread-local.
        // Without it, search_path stays on 'public' and all tenant-schema tables
        // (process_definitions, instance_projections, etc.) are invisible.
        // DEFAULT_TENANT_ID ("00000000-0000-0000-0000-000000000000") matches the
        // 'default' tenant seeded by ensureDefaultOidcSeeds() above.
        bpm.api_tenant_context.set(bpm.api_tenant_context.DEFAULT_TENANT_ID);

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
