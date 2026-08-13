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
const builtin = @import("builtin");
const portable_env = @import("env");
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
    const environ = portable_env.globalEnviron();
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
///   - GBL-113/114: TNT-05 backfill tracking (requires pre-existing migration state)
///   - GBL-116: TNT-07 RLS cleanup (requires schema-per-tenant state)
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
        "GBL-113_tnt05_backfill_tracking.sql",
        "GBL-114_tnt05_backfill_run.sql",
        "GBL-116_tnt07_rls_cleanup.sql",
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
    // retries forever.
    //
    // ISS-0151 / GitHub #483: the session-level advisory lock that used to guard
    // this check-and-apply pass is RESTORED here. Commit db362fd (GH-402) deleted
    // all three `pg_advisory_lock(hashtext('bpm_test_migrations_public'))` acquires
    // in this file on the theory that "migration idempotency is sufficient", but
    // left the matching `pg_advisory_unlock` in TestHarness.init() in place — so
    // the file has been unlocking a lock nobody takes ever since.
    //
    // Idempotency is NOT sufficient, and src/db/migrations.zig says so in its own
    // ISS-0144 comment: Migrations.run/runForSchema do check-then-apply against an
    // `applied` set read before the per-file transaction begins. Two binaries can
    // both observe a file as unapplied; the loser's DDL then fails against a
    // half-built or concurrently-rebuilt schema. That is the observed ISS-0151
    // signature — 42P01 `relation "events_archive"/"events"/"instance_projections"
    // does not exist` raised from runForSchema inside provisionTenantSchema — plus
    // the ~60s stalls where a test binary sat behind a peer's uncoordinated DDL
    // until the build runner's own timeout fired.
    //
    // Why restoring it does not reintroduce the GH-402 hang: the hang GH-402 was
    // reacting to was never the lock itself. It was ISS-0110's diagnosis — the
    // ambient `lock_timeout = '5s'` from configureSessionTimeouts() cancelling this
    // very acquire with 55P03 once enough of the ~19+ concurrent binaries queued
    // behind it. The fix for that is the ISS-0107-rework-1 bracket, already proven
    // at the widened acquire in TestHarness.init(): raise lock_timeout for exactly
    // this one acquire statement, then restore it immediately. Bounded wait, not
    // an unbounded one — and a bounded wait is what a correct queue looks like.
    //
    // The lock is released by `defer` below, so an error path cannot leak it.
    try conn.exec("SET lock_timeout = '0'", &.{});
    try conn.exec("SET statement_timeout = '0'", &.{});
    try conn.exec("SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))", &.{});
    try conn.exec("SET statement_timeout = '60s'", &.{});
    try conn.exec("SET lock_timeout = '5s'", &.{});
    defer conn.exec("SELECT pg_advisory_unlock(hashtext('bpm_test_migrations_public'))", &.{}) catch {};

    // ISS-0665: widen statement_timeout for the DDL window; defer restores
    // configureSessionTimeouts() value ('60s') on all exit paths. ISS-0692
    // raises the default while preserving the environment override.
    const _environ_rm = portable_env.globalEnviron();
    var _owned_timeout_rm: ?[]u8 = null;
    const _stmt_timeout_rm: []const u8 = blk: {
        const v = _environ_rm.getAlloc(allocator, "BPM_TEST_STMT_TIMEOUT") catch break :blk "600s";
        _owned_timeout_rm = v;
        break :blk v;
    };
    defer if (_owned_timeout_rm) |s| allocator.free(s);
    var _set_buf_rm: [64]u8 = undefined;
    const _set_sql_rm = std.fmt.bufPrint(&_set_buf_rm, "SET statement_timeout = '{s}'", .{_stmt_timeout_rm}) catch "SET statement_timeout = '600s'";
    try conn.exec(_set_sql_rm, &.{});
    defer conn.exec("SET statement_timeout = '60s'", &.{}) catch {};

    try markPublicGlobalSkipsApplied(conn);

    const resolved = try resolveMigrationsDir(allocator);
    defer if (resolved.owned) |path| allocator.free(path);

    var mig_pool = try bpm.pool.Pool.init(io, allocator, bpm.pool.PoolConfig{
        .url = url,
        // ISS-0692 / GH-752 REWORK 2: was 2; raised to 4 because the lock
        // holder's migration pass runs against this pool, and with -j4 (and
        // ambient Postgres CPU/IO contention on this host) a 2-connection pool
        // can serialize GBL-/ISS-/TNT- migration files whose individual DDL
        // statements each block on connections already lent out to sibling
        // workers within the same pool. Four connections strike a balance:
        // high enough that the lock holder finishes its critical section in
        // well under 60s (the zig test-runner response-timeout floor at this
        // call depth), low enough that the pool never sits on stale
        // connections long enough to interrupt idle_in_transaction_session_timeout.
        // See tests/reports/ISS-0692-step03-rework2-sweep.md.
        .pool_size = 4,
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
    // ISS-0090 / ISS-0151 (GitHub #483): concurrent test binaries calling
    // TestHarness.init() (or ensureSchemaReady(), which routes here too) race on
    // this schema's non-idempotent inline CONSTRAINT/index DDL. The per-schema
    // advisory lock that serialized them was deleted by commit db362fd (GH-402)
    // along with the two `bpm_test_migrations_public` acquires; it is restored
    // here for the same reason given in runMigrations() above.
    //
    // Scope note: the lock is taken BEFORE the already-migrated fast path below,
    // not after it. The fast path reads public.tenant_schemas and
    // public.schema_migrations to decide whether to skip the apply entirely —
    // that read is exactly the check half of the check-then-apply race, so
    // leaving it outside the lock would let two binaries both decide to apply.
    //
    // Keyed on hashtext(schema) so two binaries provisioning DIFFERENT tenant
    // schemas still proceed in parallel; only same-schema work serializes. The
    // common contended case is "tenant_default", which every binary provisions.
    //
    // Bracketed with the ISS-0107-rework-1 lock_timeout pattern for the same
    // reason as runMigrations(): the ambient 5s ceiling from
    // configureSessionTimeouts() would otherwise cancel this acquire with 55P03
    // under normal queueing (ISS-0110), which is the failure GH-402 misread as
    // "the advisory lock hangs".
    try conn.exec("SET lock_timeout = '0'", &.{});
    try conn.exec("SET statement_timeout = '0'", &.{});
    try conn.exec("SELECT pg_advisory_lock(hashtext($1))", &.{schema});
    try conn.exec("SET statement_timeout = '60s'", &.{});
    try conn.exec("SET lock_timeout = '5s'", &.{});
    defer conn.exec("SELECT pg_advisory_unlock(hashtext($1))", &.{schema}) catch {};

    // ISS-0665: widen statement_timeout for the DDL window; defer restores
    // configureSessionTimeouts() value ('60s') on all exit paths. ISS-0692
    // raises the default while preserving the environment override.
    const _environ_rfs = portable_env.globalEnviron();
    var _owned_timeout_rfs: ?[]u8 = null;
    const _stmt_timeout_rfs: []const u8 = blk: {
        const v = _environ_rfs.getAlloc(allocator, "BPM_TEST_STMT_TIMEOUT") catch break :blk "600s";
        _owned_timeout_rfs = v;
        break :blk v;
    };
    defer if (_owned_timeout_rfs) |s| allocator.free(s);
    var _set_buf_rfs: [64]u8 = undefined;
    const _set_sql_rfs = std.fmt.bufPrint(&_set_buf_rfs, "SET statement_timeout = '{s}'", .{_stmt_timeout_rfs}) catch "SET statement_timeout = '600s'";
    try conn.exec(_set_sql_rfs, &.{});
    defer conn.exec("SET statement_timeout = '60s'", &.{}) catch {};

    {
        var already_migrated = conn.query(
            allocator,
            "SELECT migrations_applied_at FROM public.tenant_schemas WHERE schema_name = $1 AND migrations_applied_at IS NOT NULL",
            &.{schema},
        ) catch null;
        if (already_migrated) |*result| {
            defer result.deinit();
            if (result.rows.len > 0) {
                // ISS-0116 / GH-379: this used to probe for a single
                // hardcoded historical version
                // ('1106_iss0125_instance_definition_snapshots_cascade.sql')
                // as a proxy for "this schema was migrated by the current,
                // post-ISS-0091 generation of the harness" — a one-time
                // migration-of-the-tracking-itself signal, not a
                // freshness check. On a long-lived bpm_test container
                // (tenant_default is deliberately never dropped by
                // tools/clean_test_db.py), that made the fast path skip
                // runForSchema() forever after the first successful run,
                // silently hiding every plain-numeric migration filed
                // after 1106 from tenant_default until the whole DB was
                // reprovisioned from scratch. Confirmed live: migration
                // 1139_iss0116_audit_dlq_rename_tenant_functions.sql
                // applied to `public` immediately but never reached
                // `tenant_default`, and neither did any migration between
                // 1107 and 1139 unless something else happened to force a
                // fresh reconcile first.
                //
                // Generalize the probe: compare the count of plain-numeric
                // (non-GBL-prefixed) migrations applied to `public` — which
                // runMigrations() above just brought fully current,
                // unconditionally, with no fast-path skip of its own —
                // against the count applied to this schema. GBL-prefixed
                // migrations are excluded because they only ever apply to
                // `public` (Migrations.run() == runForSchema(...,
                // "public", ...)); comparing raw totals would make this
                // schema perpetually appear behind. Equal counts means
                // every migration `public` has, this schema also has, so
                // the fast path may still skip; any shortfall means new
                // migrations have landed since this schema's last full
                // apply, and the code must fall through to the real
                // runForSchema() call below.
                var counts = try conn.query(
                    allocator,
                    \\SELECT
                    \\  (SELECT COUNT(*)::text FROM public.schema_migrations WHERE schema_name = 'public' AND version NOT LIKE 'GBL-%'),
                    \\  (SELECT COUNT(*)::text FROM public.schema_migrations WHERE schema_name = $1 AND version NOT LIKE 'GBL-%')
                ,
                    &.{schema},
                );
                defer counts.deinit();
                if (counts.rows.len > 0) {
                    const row = counts.rows[0];
                    const public_count = std.fmt.parseInt(u64, row[0] orelse "0", 10) catch 0;
                    const schema_count = std.fmt.parseInt(u64, row[1] orelse "0", 10) catch 0;
                    if (schema_count >= public_count) {
                        const set_path_sql = try std.fmt.allocPrint(allocator, "SET search_path TO {s}, public", .{schema});
                        defer allocator.free(set_path_sql);
                        try conn.exec(set_path_sql, &.{});
                        return;
                    }
                }
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
            // ISS-0692 / GH-752 REWORK 2: raised 2 -> 4 — see matching comment
            // in runMigrations() just above for the rationale.
            .pool_size = 4,
        });
        defer mig_pool.deinit();
        // force_reconcile=true: corrective migrations marked
        // `-- reapply_on_drift: true` must repair tenant-schema drift even when
        // a stale migrations_applied_at fast path previously skipped them.
        try bpm.migrations.Migrations.runForSchema(allocator, &mig_pool, resolved.dir, schema, true);
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
    // Compatibility shims must be created in the public schema, even though
    // search_path is currently set to "tenant_default,public". Explicitly
    // schema-qualify all CREATE/DROP statements to avoid unintended namespace
    // collisions or duplicate-function errors.
    //
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

    // Create functions in public schema only (not tenant_default).
    // These functions are used by events triggers in tenant_default, but
    // must be defined in public to avoid collisions with per-tenant instances.
    // Do NOT drop and recreate these functions; they may be in use by concurrent
    // test binaries. Instead, use CREATE FUNCTION IF NOT EXISTS to handle
    // concurrent initialization safely.
    try execCompatibilitySql(conn,
        \\CREATE FUNCTION IF NOT EXISTS public.bpm_test_events_compat_defaults()
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
        \\CREATE TRIGGER IF NOT EXISTS trg_bpm_test_events_compat_defaults
        \\BEFORE INSERT ON events
        \\FOR EACH ROW
        \\EXECUTE FUNCTION public.bpm_test_events_compat_defaults()
    );

    try execCompatibilitySql(conn,
        \\CREATE FUNCTION IF NOT EXISTS public.bpm_repository_artifacts_immutable()
        \\RETURNS TRIGGER
        \\LANGUAGE plpgsql
        \\AS $$
        \\BEGIN
        \\    RAISE EXCEPTION 'repository artifacts are immutable and cannot be modified or deleted';
        \\END;
        \\$$
    );

    try execCompatibilitySql(conn,
        \\CREATE TRIGGER IF NOT EXISTS trg_repository_artifacts_prevent_update
        \\BEFORE UPDATE ON public.repository_artifacts
        \\FOR EACH ROW EXECUTE FUNCTION public.bpm_repository_artifacts_immutable()
    );

    try execCompatibilitySql(conn,
        \\CREATE TRIGGER IF NOT EXISTS trg_repository_artifacts_prevent_delete
        \\BEFORE DELETE ON public.repository_artifacts
        \\FOR EACH ROW EXECUTE FUNCTION public.bpm_repository_artifacts_immutable()
    );
}

fn execCompatibilitySql(conn: *pg.Conn, sql: []const u8) !void {
    conn.exec(sql, &.{}) catch |err| switch (err) {
        // Compatibility shims are best-effort for legacy suites.
        error.ServerError => {},
        else => return err,
    };
}

/// ISS-0602 / GitHub #414: every TestHarness connection is tagged with a
/// per-process opaque owner tag of the form `uid_<12hex>`. killIdleConnections()
/// scopes its pg_terminate_backend broadcast to `application_name = $1` with the
/// caller's own tag bound as a parameter, so concurrent test binaries no longer
/// terminate each other's idle connections on the shared `bpm_test` database.
/// See src/design/iss0602_test_isolation.md for the full rationale and
/// docs/issue-reports/ISS-0602-diagnosis.yaml for the source-verified root cause.
const TEST_OWNER_TAG_PREFIX: []const u8 = "uid_";
const TEST_OWNER_TAG_HEX_CHARS: usize = 12;

const TestOwnerTagError = error{
    InvalidTestOwnerTag,
    OutOfMemory,
    RandomSourceUnavailable,
    OwnerTagMismatch,
};

/// Per-process owner tag. Defined as a plain `[]const u8` so it can be passed
/// directly to the `pg` driver as a parameter without any pointer casting.
/// The first harness owns the allocated backing bytes and frees them during
/// deinit; cached lookups are valid while that owner harness remains alive.
/// All access goes through the validated helper chain (generateOwnerTag /
/// validateOwnerTag / setTestApplicationName / killIdleConnections) so callers
/// cannot mint a tag from arbitrary bytes.
pub const Tag = []const u8;

/// Fill `buf` with cryptographically secure random bytes.
///
/// Replaces `std.crypto.random`, which Zig 0.16 removed. ISS-0137 / GH #439
/// centralises it here: the same helper was already copy-pasted into
/// exp401_exp402_comp_restore_test.zig and others, and two more files
/// (repository_test.zig, effects_subsystem_test.zig) still referenced the
/// removed API — they had not compiled since the 0.16 upgrade because they were
/// wired into no build target.
pub fn fillRandom(buf: []u8) void {
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.arc4random_buf(buf.ptr, buf.len),
        else => @compileError("fillRandom: unsupported OS — add a platform branch"),
    }
}

/// Random UUID as raw 16 bytes, for per-test fixture isolation.
pub fn randomUuidBytes() [16]u8 {
    var uuid: [16]u8 = undefined;
    fillRandom(&uuid);
    return uuid;
}

/// Format a raw 16-byte UUID as the canonical 36-char hyphenated string.
/// Caller owns the returned memory.
pub fn uuidBytesToString(allocator: std.mem.Allocator, uuid: [16]u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],  uuid[4],  uuid[5],
            uuid[6],  uuid[7],  uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

/// Cached per-process tag. Process-lifetime atomic: first generateOwnerTag()
/// call fills it, subsequent calls return the same value. Different processes
/// have independent atomics, so concurrent test binaries get distinct tags.
var cached_owner_tag: std.atomic.Value(bool) = .init(false);

/// Tag-representation storage. Ownership is transferred to the first
/// TestHarness created in the process via `owns_tag_storage`; that harness
/// clears the cache and frees the backing bytes during deinit.
var tag_repr_storage: ?[]u8 = null;
var tag_repr_lock: std.atomic.Value(bool) = .init(false);

fn isHexChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// Validate a candidate tag string against the canonical
/// `[A-Za-z0-9_-]+` regex and the `TEST_OWNER_TAG_PREFIX` requirement.
/// On success returns a `Tag` (`[]const u8`) referring to the input bytes.
/// The caller is responsible for ensuring the input slice outlives any
/// downstream use; in practice this means either pointing into
/// `tag_repr_storage` (process-lifetime) or supplying caller-owned memory.
fn validateOwnerTag(tag_repr: []const u8) TestOwnerTagError!Tag {
    if (tag_repr.len < TEST_OWNER_TAG_PREFIX.len) return error.InvalidTestOwnerTag;
    if (!std.mem.startsWith(u8, tag_repr, TEST_OWNER_TAG_PREFIX)) return error.InvalidTestOwnerTag;
    for (tag_repr) |c| {
        const is_allowed = isHexChar(c) or c == '-' or c == '_' or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
        if (!is_allowed) return error.InvalidTestOwnerTag;
    }
    return tag_repr;
}

/// Generate the per-process owner tag. First call allocates 12 hex chars
/// from the platform CSPRNG via `bpm.uuid` (the same source used by
/// TestHarness.newUuid) and caches the resulting `Tag` in process-local
/// `tag_repr_storage`. Subsequent calls in the same process return the
/// cached slice. Different processes have independent storage, so concurrent
/// test binaries receive distinct tags without coordination.
fn generateOwnerTag(allocator: std.mem.Allocator) TestOwnerTagError!Tag {
    // Acquire initialise-once lock.
    while (tag_repr_lock.cmpxchgWeak(false, true, .acquire, .acquire) != null) {}
    defer tag_repr_lock.store(false, .release);

    if (cached_owner_tag.load(.acquire)) {
        if (tag_repr_storage) |storage| return storage;
        return error.InvalidTestOwnerTag;
    }
    const storage = allocator.alloc(u8, TEST_OWNER_TAG_PREFIX.len + TEST_OWNER_TAG_HEX_CHARS) catch return error.OutOfMemory;
    @memcpy(storage[0..TEST_OWNER_TAG_PREFIX.len], TEST_OWNER_TAG_PREFIX);
    // Fill the 6-byte (48-bit) suffix from the cross-platform CSPRNG that
    // bpm.uuid.generateUuidV4BytesInto() wraps (getrandom on Linux,
    // SystemFunction036 on Windows, arc4random_buf on BSD/macOS). 48 bits
    // is sufficient for per-process uniqueness across concurrent test
    // binaries; collisions require ~2^24 processes running concurrently,
    // which the test harness never reaches.
    var uuid_bytes: bpm.uuid.Uuid = undefined;
    bpm.uuid.generateUuidV4BytesInto(&uuid_bytes);
    const hex_chars = "0123456789abcdef";
    var i: usize = 0;
    while (i < TEST_OWNER_TAG_HEX_CHARS) : (i += 2) {
        const byte = uuid_bytes[i / 2];
        storage[TEST_OWNER_TAG_PREFIX.len + i] = hex_chars[(byte >> 4) & 0x0F];
        storage[TEST_OWNER_TAG_PREFIX.len + i + 1] = hex_chars[byte & 0x0F];
    }
    const tag_slice = try validateOwnerTag(storage);
    tag_repr_storage = storage;
    cached_owner_tag.store(true, .release);
    return tag_slice;
}

/// Issue `SELECT set_config('application_name', $1, false)` against `conn`
/// with the validated tag bound as a parameter. Never interpolates the tag
/// value into the SQL string. Errors propagate as `anyerror` so the caller
/// only sees the union of validation failures and `pg.PgError` variants.
fn setTestApplicationName(conn: *pg.Conn, tag: Tag) (TestOwnerTagError || pg.PgError)!void {
    _ = try validateOwnerTag(tag);
    conn.exec(
        "SELECT set_config('application_name', $1, false)",
        &.{tag},
    ) catch |err| return err;
}

/// GH-402 (Database cleanup hang): Before truncating tables, terminate idle
/// connections that may be holding AccessExclusiveLock. This is critical because
/// TRUNCATE acquires AccessExclusiveLock on the target table, and even an idle
/// transaction (state='idle in transaction') blocks it indefinitely. Stale
/// connections from crashed test processes or earlier runs leave locks that
/// cause subsequent test suites to hang at statement_timeout (60s) with no
/// visible error.
///
/// ISS-0602 / GitHub #414: the kill-broadcast is scoped to the caller's own
/// per-process `application_name` (the validated `Tag`) bound as a parameter
/// (`application_name = $1`, exact equality). The `pid != pg_backend_pid()`
/// guard is retained as defense in depth. A defensive post-check verifies
/// that no cross-owner idle connections were affected and raises
/// `error.OwnerTagMismatch` if that invariant is violated.
pub fn killIdleConnections(conn: *pg.Conn, tag: Tag) (TestOwnerTagError || pg.PgError)!void {
    _ = try validateOwnerTag(tag);

    // Terminate only idle in-transaction connections that belong to this
    // process's owner tag. Never terminate the current backend.
    const sql_kill =
        \\SELECT pg_terminate_backend(pid) FROM pg_stat_activity
        \\WHERE state = 'idle in transaction'
        \\  AND application_name = $1
        \\  AND pid != pg_backend_pid()
    ;
    conn.exec(sql_kill, &.{tag}) catch |err| {
        std.debug.print("killIdleConnections: {}\n", .{err});
        return err;
    };

    // Defensive cross-owner verification: under correct behavior the kill
    // predicate excludes every backend whose application_name differs from
    // the caller's tag, so the count of *other* idle-in-tx connections must
    // not be affected. A non-zero count after the kill would only happen if
    // the SQL was later mutated to drop the tag filter, e.g. LIKE-prefix or
    // unconditional WHERE clauses. Surface that future regression loudly.
    var check_q = conn.query(
        std.testing.allocator,
        "SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction' AND application_name <> $1 AND pid <> pg_backend_pid()",
        &.{tag},
    ) catch |err| {
        std.debug.print("killIdleConnections defensive check failed: {}\n", .{err});
        return err;
    };
    defer check_q.deinit();
    if (check_q.rows.len > 0) {
        if (check_q.rows[0][0]) |s| {
            const unexpected_count = std.fmt.parseInt(i64, s, 10) catch 0;
            if (unexpected_count != 0) {
                std.log.warn("killIdleConnections: unexpected cross-owner idle connections remain, count={d}", .{unexpected_count});
                return error.OwnerTagMismatch;
            }
        }
    }
}

/// Public accessor for the cached per-process owner tag's string
/// representation. Returns a freshly allocated copy that the caller owns
/// and must release with the supplied allocator. Useful for assertions
/// in regression tests that need to verify the tag is set.
pub fn GetTestOwnerTag(allocator: std.mem.Allocator) ![]u8 {
    while (tag_repr_lock.cmpxchgWeak(false, true, .acquire, .acquire) != null) {}
    defer tag_repr_lock.store(false, .release);
    const storage = tag_repr_storage orelse return error.InvalidTestOwnerTag;
    return try allocator.dupe(u8, storage);
}

// ISS-0125 / GitHub #391: resetTestData() intentionally clears
// instance_definition_snapshots before process_definitions even though
// the FK uses ON DELETE CASCADE (see GBL-106). The order is preserved
// as defense in depth — for DELETE operations this order ensures
// referential integrity is maintained. Per-test cleanup helpers in
// iss202_merge_atomicity_test.zig, iss203_idempotency_keys_test.zig,
// and iss601_state_snapshots_test.zig now follow the same
// child-before-parent order AND propagate (do not swallow) any SQL
// error from a child delete before attempting the parent delete.
//
// GH-402: Uses DELETE instead of TRUNCATE to avoid AccessExclusiveLock
// which can be blocked indefinitely by idle connections. DELETE acquires
// RowExclusiveLock which other sessions can work around.
fn resetTestData(conn: *pg.Conn, allocator: std.mem.Allocator) !void {
    // GH-402: Kill any idle connections before cleaning, so they don't
    // hold locks and cause indefinite waits or deadlocks. ISS-0602:
    // the kill is scoped to the process's own per-process owner tag
    // so we cannot terminate a sibling process's idle connection.
    {
        // resetTestData takes a *pg.Conn with no Tag argument; for this
        // internal call we resolve the cached tag directly via
        // generateOwnerTag (which returns the process-local cache).
        const internal_tag = generateOwnerTag(allocator) catch {
            // Tag generation failure is non-fatal here: we still want the
            // rest of the reset to proceed without the kill. The next
            // TestHarness.init() will retry tag generation and stamp
            // the connection.
            std.debug.print("resetTestData: generateOwnerTag failed; skipping scoped kill\n", .{});
            return;
        };
        killIdleConnections(conn, internal_tag) catch |err| switch (err) {
            error.OwnerTagMismatch => {
                std.debug.print("resetTestData: cross-owner idle connections remain; continuing\n", .{});
            },
            else => {
                std.debug.print("resetTestData: killIdleConnections failed: {}\n", .{err});
            },
        };
    }

    // Temporarily lower lock_timeout and statement_timeout for cleanup
    // operations to fail fast if there's contention.
    conn.exec("SET lock_timeout = '5s'", &.{}) catch {};
    conn.exec("SET statement_timeout = '20s'", &.{}) catch {};

    // Clear transient test data via DELETE to avoid locks that can be blocked
    // indefinitely by idle connections. Delete in child-before-parent order
    // to respect foreign key constraints even though CASCADE is set.
    try deleteTableBestEffort(conn, "instance_definition_snapshots");
    try deleteTableBestEffort(conn, "tasks");
    try deleteTableBestEffort(conn, "timers");
    try deleteTableBestEffort(conn, "instance_projections");
    try deleteTableBestEffort(conn, "variable_schemas");
    try deleteTableBestEffort(conn, "process_definitions");
    try deleteTableBestEffort(conn, "events");
    try deleteTableBestEffort(conn, "audit_log");
    // GH-402 + OBS-03: audit_entries triggers are already disabled for the entire
    // test transaction (see TestHarness.init()), so we can DELETE here without issues.
    try deleteTableBestEffort(conn, "audit_entries");
    try deleteTableBestEffort(conn, "dead_letter_items");
    try deleteTableBestEffort(conn, "webhook_subscriptions");
    // SVC-04 uses the service catalog; clear so LIMIT-50 page-1 tests stay deterministic.
    try deleteTableBestEffort(conn, "service_catalog");

    // Reset sequences for tables that use IDENTITY columns (best-effort).
    conn.exec("SELECT setval(pg_get_serial_sequence('tasks', 'id'), 1, false)", &.{}) catch {};
    conn.exec("SELECT setval(pg_get_serial_sequence('timers', 'id'), 1, false)", &.{}) catch {};

    // Restore default timeouts.
    conn.exec("SET lock_timeout = '5s'", &.{}) catch {};
    conn.exec("SET statement_timeout = '60s'", &.{}) catch {};
}

fn deleteTableBestEffort(conn: *pg.Conn, comptime table_name: []const u8) !void {
    // GH-402: Use DELETE instead of TRUNCATE to avoid AccessExclusiveLock.
    // DELETE acquires RowExclusiveLock which won't block other sessions.
    // For test tables (expected to be small), DELETE performance is acceptable.
    const sql = "DELETE FROM " ++ table_name;
    conn.exec(sql, &.{}) catch |err| switch (err) {
        // Some tables may not exist yet in partial migration states.
        error.ServerError => {},
        // Timeout on delete (lock blocking) — log but don't fail the whole suite.
        error.Timeout => {
            std.debug.print("WARNING: deleteTableBestEffort({s}) timed out (lock blocked)\n", .{table_name});
        },
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
    //
    // ISS-0112 (GitHub #375): the canonical 'default' tenant now carries
    // tenant_type='test' explicitly. Production code never creates this
    // row (it is the harness's persistent fixture); production tenants
    // are created via real onboarding flow that explicitly sets
    // tenant_type='production'. Setting it to 'test' here keeps
    // tools/clean_test_db.py's pre-existing filter (which deletes
    // tenant_type='production' AND slug != 'default') from mistaking
    // the harness's persistent fixture for production state.
    //
    // Check constraint ck_tenant_type_fk_coherence requires that every
    // row with tenant_type='test' has production_tenant_id IS NOT NULL.
    // We point production_tenant_id at this same canonical UUID
    // (self-reference) because (a) no separate "production of the test
    // world" tenant exists — the 'default' tenant IS the root, (b) every
    // other integration test fixture that creates a test tenant uses
    // '00000000-0000-0000-0000-000000000000' as production_tenant_id
    // (see env01_test.zig insertTestTenant, adp04a_external_identity_linkage_test.zig
    // ensureTenantBinding, svc01_service_catalog_scope_test.zig insertTenant,
    // svc04_admin_api_test.zig, etc.), so this is the established
    // convention and (c) ON CONFLICT DO UPDATE must re-assert the FK
    // when the column is updated by a parallel migration in case the
    // column was ever left NULL during a baseline.
    try conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES (
        \\  '00000000-0000-0000-0000-000000000000'::uuid,
        \\  'default',
        \\  'Default Tenant',
        \\  'ACTIVE',
        \\  'bpm-default',
        \\  'test',
        \\  '00000000-0000-0000-0000-000000000000'::uuid
        \\)
        \\ON CONFLICT (id) DO UPDATE
        \\SET slug = EXCLUDED.slug,
        \\    display_name = EXCLUDED.display_name,
        \\    status = EXCLUDED.status,
        \\    idp_realm_id = COALESCE(public.tenant.idp_realm_id, EXCLUDED.idp_realm_id),
        \\    tenant_type = 'test',
        \\    production_tenant_id = '00000000-0000-0000-0000-000000000000'::uuid,
        \\    updated_at = NOW()
    , &.{});

    try conn.exec(
        \\INSERT INTO jit_provisioning_config (realm, enabled, default_status, default_roles)
        \\VALUES ('bpm-default', TRUE, 'ACTIVE', '[]'::jsonb)
        \\ON CONFLICT (realm) DO NOTHING
    , &.{});

    // ISS-0112 (GitHub #375): SVC-01..04 fixture tenants RELOCATED.
    // Each SVC test now owns its own per-test fixture INSERTs via
    // `try h.conn.exec(...)` and `defer cleanupTestTenant(...)`. The 9
    // rows previously seeded here were the source of LEGACY_RLS-without-
    // tenant_type fixtures that leaked across runs (Cluster C). Per-test
    // fixtures are born inside the harness transaction and automatically
    // rolled back at deinit(), eliminating the cross-run leak.
}

/// ISS-0112 (GitHub #375): belt-and-suspenders helper for SVC-* test files
/// that may have escaped the per-test transaction rollback via pool-based
/// operations. Issues a best-effort DELETE; never returns an error so it
/// can be called from `defer` blocks safely.
pub fn cleanupTestTenant(conn: *pg.Conn, tenant_id: []const u8) void {
    conn.exec(
        "DELETE FROM public.tenant WHERE id = $1::uuid AND tenant_type = 'test'",
        .{tenant_id},
    ) catch {};
}

/// ISS-0125 / GitHub #391: delete definition snapshots for one definition.
/// SQL errors are deliberately propagated so a caller cannot continue to
/// parent cleanup after an incomplete child cleanup.
pub fn cleanupDefinitionSnapshots(conn: *pg.Conn, definition_id: []const u8) !void {
    try conn.exec(
        "DELETE FROM instance_definition_snapshots WHERE definition_id = $1::uuid",
        &.{definition_id},
    );
}

/// ISS-0144 / GitHub #454: guarantee the shared test database's `public` and
/// `tenant_default` schemas are fully migrated before a binary that does NOT
/// use TestHarness (no rollback-on-deinit isolation needed — e.g. binaries
/// whose own tests manage per-test UUID fixtures with autocommit connections)
/// issues its first query.
///
/// Root cause this closes: `zig build test-integration` runs ~20+ independent
/// test binaries as concurrent sibling build-graph Steps (see
/// `test-integration-others-internal` in build.zig, same barrier group
/// documented in src/design/fix-ISS-0106.md). Every binary that calls
/// `TestHarness.init()` waits for migrations via the locked runMigrations() /
/// runMigrationsForSchema() path below before touching `public`/`tenant_default`
/// tables. A handful of binaries (tnt_backfill_export_cleanup_test.zig,
/// tenant_config_realm_test.zig, sch303_timer_dlq_test.zig,
/// onboarding_realm_guard_test.zig, exp103_instance_waits_test.zig) query
/// those same shared schemas via a raw `Pool.init()` with no such guarantee,
/// so when the build runner starts them concurrently with a binary that is
/// still mid-migration, they observe a partially-migrated schema
/// (`C42703 column does not exist`, `relation does not exist`) — exactly the
/// mechanism GH #364/ISS-0106 and GH #366/ISS-0107 already fixed for other
/// binaries, recurring here for a different set of callers.
///
/// This reuses the SAME locked migration path `TestHarness.init()` already
/// uses (runMigrations() takes the widened `bpm_test_migrations_public`
/// advisory lock; runForSchema() takes the per-migration
/// `bpm.migrations.runForSchema` advisory lock — see ISS-0107/ISS-0129) rather
/// than introducing a second, independent locking scheme that could reopen
/// the same class of race against the existing lock. Unlike TestHarness.init(),
/// this does NOT open a long-lived transaction and does NOT provide
/// rollback-on-deinit isolation — callers that need that must use
/// TestHarness.init() instead. This function only guarantees schema
/// readiness; it is safe and cheap to call once per test (runMigrations()/
/// runMigrationsForSchema() are idempotent — a fully-migrated schema costs
/// one indexed SELECT per call).
/// ISS-0659 / GH-681: acquire the same `bpm_test_migrations_public` session
/// advisory lock that TestHarness.init() holds for its full lifetime. Pair
/// with `releaseIntegrationLock(conn)` (deferred, unconditionally).
///
/// Why a separate acquire from `ensureSchemaReady`: `ensureSchemaReady` takes
/// the lock for the duration of migration + schema-provisioning only (see
/// runMigrations / runMigrationsForSchema). PR #494 / ISS-0162 extended it
/// inside TestHarness.init() to cover the full harness lifetime. This entry
/// point lets a self-managed-pool binary acquire the lock across its OWN
/// lifetime, while internally routing through the same locked migration
/// path so it serializes correctly against TestHarness peers.
///
/// One process, one acquired session — a second acquire from the same
/// connection increments the session's hold count (PostgreSQL semantics)
/// but should still be paired with a matching release call.
///
/// Caller responsibility: keep the returned `pg.Conn` alive for the full
/// binary lifetime (typically via `defer releaseIntegrationLock(&lock_conn)`
/// in each test block) and defer-release it on every exit path. A session-
/// level advisory lock is automatically released when the connection drops,
/// so a hard process abort cannot strand it, but explicit release is the
/// documented and tested contract.
pub fn acquireIntegrationLock(allocator: std.mem.Allocator) anyerror!pg.Conn {
    const env = portable_env.globalEnviron();
    const url = env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("acquireIntegrationLock: BPM_TEST_DB_URL is required for integration tests\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    defer allocator.free(url);

    var conn = pg.Conn.connectUrl(std.testing.io, allocator, url) catch |err| {
        std.debug.print("acquireIntegrationLock: pg.Conn.connectUrl failed: {}\n", .{err});
        return err;
    };
    errdefer conn.close();

    configureSessionTimeouts(&conn) catch |err| {
        std.debug.print("acquireIntegrationLock: configureSessionTimeouts failed: {}\n", .{err});
        return err;
    };

    // ISS-0151 / GH #483 / ISS-0659: lock_timeout bracket — 90s window, same as
    // runMigrations / runMigrationsForSchema and the TestHarness.init() critical
    // section, to keep queueing bounded across the wider set of binaries
    // (~50 worst case after this fix vs ~19 today).
    try conn.exec("SET lock_timeout = '0'", &.{});
    try conn.exec("SET statement_timeout = '0'", &.{});
    try conn.exec("SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))", &.{});
    try conn.exec("SET statement_timeout = '60s'", &.{});
    try conn.exec("SET lock_timeout = '5s'", &.{});
    return conn;
}

/// ISS-0659 / GH-681: release the lock acquired by `acquireIntegrationLock`
/// and close the dedicated connection. Safe to call on the error path: any
/// exception is swallowed, mirroring `TestHarness.deinit()`'s pattern.
///
/// The unlock is `catch {}`-guarded — the session-level lock is also released
/// automatically when the connection closes (PostgreSQL semantics), so even a
/// failed unlock cannot strand the lock forever.
pub fn releaseIntegrationLock(conn: *pg.Conn) void {
    conn.exec("SELECT pg_advisory_unlock(hashtext('bpm_test_migrations_public'))", &.{}) catch {};
    conn.close();
}

pub fn ensureSchemaReady(allocator: std.mem.Allocator) !void {
    const env = portable_env.globalEnviron();
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
        std.debug.print("ensureSchemaReady: pg.Conn.connectUrl failed: {}\n", .{err});
        return err;
    };
    defer conn.close();

    configureSessionTimeouts(&conn) catch |err| {
        std.debug.print("ensureSchemaReady: configureSessionTimeouts failed: {}\n", .{err});
        return err;
    };

    // Run migrations against public first (locked — see runMigrations()).
    runMigrations(std.testing.io, allocator, &conn, url) catch |err| {
        std.debug.print("ensureSchemaReady: runMigrations failed: {}\n", .{err});
        return err;
    };

    // Provision and migrate tenant_default so tenant-scoped business tables
    // (events, instance_projections, timers, dead_letter_items, etc.) exist —
    // several of the affected binaries (sch303_timer_dlq_test.zig) query
    // tenant_default tables directly.
    _ = conn.exec("SELECT bpm_provision_tenant_schema($1::uuid)", &.{bpm.api_tenant_context.DEFAULT_TENANT_ID}) catch {};
    runMigrationsForSchema(std.testing.io, allocator, &conn, "tenant_default", url) catch |err| {
        std.debug.print("ensureSchemaReady: runMigrationsForSchema (tenant_default) failed: {}\n", .{err});
        return err;
    };
}

// ---------------------------------------------------------------------------
// TestHarness
// ---------------------------------------------------------------------------

/// Each test is wrapped in a transaction that is always rolled back on deinit().
/// This guarantees isolation without manual teardown.
pub const TestHarness = struct {
    conn: pg.Conn,
    allocator: std.mem.Allocator,
    /// ISS-0602 / GitHub #414: per-process owner tag stamped on this
    /// connection. killIdleConnections() uses this to scope the
    /// pg_terminate_backend broadcast to the caller's own backends. The
    /// slice points into `tag_repr_storage` while this harness is alive.
    tag: Tag,
    /// Allocator that owns the generated tag backing storage. Only the first
    /// harness that generated the process tag sets this flag; its deinit
    /// clears the cache and releases the allocation.
    tag_allocator: std.mem.Allocator,
    owns_tag_storage: bool,

    /// ISS-0121 / GitHub #387: return a fresh 16-byte UUID v4 value sourced
    /// from the standard library CSPRNG. Generation is infallible and
    /// allocation-free, so it is suitable for hot fixtures in MUST tests.
    /// Each call yields a distinct value, removing the T010 hardcoded-UUID
    /// collision class documented in
    /// `docs/guides/test_infrastructure_guide.md` §9.
    pub fn newUuid(self: *TestHarness) bpm.uuid.Uuid {
        _ = self;
        var bytes: bpm.uuid.Uuid = undefined;
        bpm.uuid.generateUuidV4BytesInto(&bytes);
        return bytes;
    }

    /// ISS-0121 / GitHub #387: allocate the canonical 36-byte hyphenated
    /// lower-case representation of a fresh UUID. Caller owns the returned
    /// slice and must release it with the supplied allocator (typically via
    /// an immediate `defer allocator.free(id)`). Allocation failure is the
    /// only recoverable error; CSPRNG generation is infallible.
    pub fn newUuidString(self: *TestHarness, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        // bpm.uuid.newUuidV4 returns []const u8 (the canonical UUID string is
        // logically immutable post-allocation). Mutate the const-ness here so
        // the helper signature matches the spec's ![]u8 — the bytes are
        // effectively owned by the caller and may be re-used in mutable
        // buffers (e.g. as a parameter to a textual SQL API), and forcing
        // the caller to copy on every call defeats the purpose of the helper.
        return @constCast(try bpm.uuid.newUuidV4(allocator));
    }

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
        // ISS-0114 / GH-377: clear any thread-local tenant context residue
        // from a prior test in this binary. Without this, a test that ran
        // last with tenant_context.set(<uuid>) leaves the cache poisoned at
        // SCHEMA (or LEGACY_RLS, depending on the prior test) for the next
        // test, causing the very first pool.acquire() of the new test to
        // route to the wrong schema. The subsequent set() below establishes
        // the canonical default-tenant context; clear() first guarantees a
        // fresh resolver cache for each TestHarness.init().
        bpm.api_tenant_context.clear();

        // Read BPM_TEST_DB_URL using the Zig 0.16.0 cross-platform environ API.
        // On Windows Environ.Block = GlobalBlock (.global reads from the PEB).
        const env = portable_env.globalEnviron();
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

        // ISS-0602 / GitHub #414: stamp this connection with the per-process
        // owner tag so killIdleConnections() cannot terminate a sibling
        // process's idle connection on the shared bpm_test database.
        const had_cached_tag = cached_owner_tag.load(.acquire);
        const tag = generateOwnerTag(allocator) catch |err| {
            std.debug.print("generateOwnerTag failed: {}\n", .{err});
            return err;
        };
        const owns_tag_storage = !had_cached_tag;
        errdefer if (owns_tag_storage) {
            while (tag_repr_lock.cmpxchgWeak(false, true, .acquire, .acquire) != null) {}
            defer tag_repr_lock.store(false, .release);
            if (tag_repr_storage) |storage| allocator.free(storage);
            tag_repr_storage = null;
            cached_owner_tag.store(false, .release);
        };
        setTestApplicationName(&conn, tag) catch |err| {
            std.debug.print("setTestApplicationName failed: {}\n", .{err});
            return err;
        };

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
        //
        // ISS-0151 / GitHub #483: these three statements are RESTORED. Commit
        // db362fd (GH-402) deleted them but left the matching pg_advisory_unlock
        // below in place, so this widened critical section has been running
        // completely unguarded — and unlocking a lock nobody held — ever since.
        // The comment block above survived the deletion and describes exactly the
        // bracket being reinstated here.
        try conn.exec("SET lock_timeout = '0'", &.{});
        try conn.exec("SET statement_timeout = '0'", &.{});
        try conn.exec("SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))", &.{});
        try conn.exec("SET statement_timeout = '60s'", &.{});
        try conn.exec("SET lock_timeout = '5s'", &.{});

        // Set search_path to tenant_default so resetTestData and all subsequent
        // operations on this direct connection resolve tenant-schema tables
        // (process_definitions, instance_projections, etc.) which no longer exist
        // in public after migration GBL-073.
        configureTestSearchPath(&conn) catch |err| {
            std.debug.print("configureTestSearchPath failed: {}\n", .{err});
            return err;
        };

        // ISS-0601: GH-402 + OBS-03 (moved UP, before resetTestData and conn.begin()):
        // Disable ALL triggers for the entire test session so resetTestData() can DELETE
        // audit_entries without tripping the immutability guard. session_replication_role
        // is a session-level setting, not a transaction-level one, so it must be set
        // BEFORE resetTestData() runs.
        _ = conn.exec("SET session_replication_role = 'replica'", &.{}) catch |err| {
            std.debug.print("WARNING: Failed to set replication role: {}\n", .{err});
        };

        // Clear transient integration data for deterministic per-test isolation.
        resetTestData(&conn, allocator) catch |err| {
            std.debug.print("resetTestData failed: {}\n", .{err});
            return err;
        };

        ensureDefaultOidcSeeds(&conn) catch |err| {
            std.debug.print("ensureDefaultOidcSeeds failed: {}\n", .{err});
            return err;
        };

        // GH-402 (compatibility shim race condition): Disabled per-test shim creation
        // because concurrent test binaries trigger duplicate function/trigger creation
        // errors. Legacy tests using `instances` table should either (a) migrate to
        // tenant_default.instance_projections schema, or (b) define shims once at
        // database init time rather than per-test. For now, skip shim creation to
        // unblock the integration test suite.
        // applyCompatibilityShims(&conn) catch |err| {
        //     std.debug.print("applyCompatibilityShims failed: {}\n", .{err});
        //     return err;
        // };

        // ISS-0162 / GitHub #486: the bpm_test_migrations_public advisory lock is
        // deliberately NOT released here. It is released in deinit(), so it spans
        // the whole harness lifetime.
        //
        // Releasing it at this point made init mutually exclusive only with other
        // inits — which is not the correctness requirement. resetTestData() issues
        // unconditional DELETEs against instance_projections, events,
        // process_definitions and nine other tables in the shared `tenant_default`
        // schema that EVERY integration binary provisions. With the lock released
        // here, binary B's init legitimately deleted binary A's fixture rows while
        // A's test was mid-flight:
        //
        //   A: init ─lock─ reset ─unlock─ BEGIN ── test body writes fixtures ──▶
        //   B:        (queued) ────────── lock ─ reset ─unlock ─ ...
        //                                        ▲ DELETEs A's rows, committed
        //
        // A's per-test transaction does not protect it: it is READ COMMITTED, so
        // each statement sees B's committed deletes. That produced both signatures
        // in #486 — StoreError.InstanceNotFound (the synthetic entity-type instance
        // vanishes) and expect(r2.is_duplicate) failing (the idempotency row
        // vanishes, so the replay is no longer recognised as a duplicate).
        //
        // Holding the lock until deinit() serializes whole binaries against each
        // other. They were never actually safe to overlap; the narrow window only
        // made it look that way. See src/design/iss0162_test_harness_cross_binary_races.md.

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

        // ISS-0601: session_replication_role was set earlier (before resetTestData).
        // It is a session-level GUC and remains in effect across BEGIN/ROLLBACK.

        return TestHarness{
            .conn = conn,
            .allocator = allocator,
            .tag = tag,
            .tag_allocator = allocator,
            .owns_tag_storage = owns_tag_storage,
        };
    }

    /// Insert a `public.tenant` row for `tenant_id` so tenant-scoped code that
    /// validates tenant existence (e.g. ServiceCatalog.registerService's
    /// `SELECT id FROM public.tenant WHERE id = $1::uuid`) can find it.
    ///
    /// Idempotent via ON CONFLICT DO NOTHING, and rolled back with the rest of
    /// the harness transaction on deinit, so it needs no explicit cleanup.
    ///
    /// ISS-0137 / GH #439: this method and setTenant() below were called by
    /// tests/integration/entity_subsystem_test.zig and exp601_tier_quota_test.zig
    /// but existed on no type — the tests were written against a TestHarness API
    /// that was never implemented. Neither file could compile. It went unnoticed
    /// because exp601 was wired into no build target at all, and
    /// entity_subsystem_test.zig's `run_exp_integration_tests` artifact is
    /// created in build.zig but attached to no step, so it never runs either.
    pub fn provisionTenant(self: *TestHarness, tenant_id: []const u8) !void {
        try self.conn.exec(
            \\INSERT INTO public.tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
            \\VALUES ($1::uuid, $2, $2, $2, now(), 'test', $3::uuid)
            \\ON CONFLICT (id) DO NOTHING
        ,
            &.{ tenant_id, tenant_id, bpm.api_tenant_context.DEFAULT_TENANT_ID },
        );
    }

    /// Bind the ambient tenant context to `tenant_id` for subsequent calls on
    /// this thread. Mirrors what the API layer does per request; pool
    /// connections read it to stamp `bpm.tenant_id`.
    ///
    /// deinit() restores DEFAULT_TENANT_ID, so a test that sets this does not
    /// leak the binding into the next test on the same thread.
    pub fn setTenant(self: *TestHarness, tenant_id: []const u8) void {
        _ = self;
        bpm.api_tenant_context.set(tenant_id);
    }

    /// Roll back the open transaction, close the connection, and release the
    /// process tag backing storage when this harness created it.
    /// Never commits — test isolation is guaranteed.
    pub fn deinit(self: *TestHarness) void {
        // ISS-0122: clean up audit rows with non-UTF-8 placeholder resource_ids from prior tests.
        // Best-effort pre-rollback sweep; guarded by `catch {}` so it never blocks teardown.
        self.conn.exec(
            "DELETE FROM audit_entries WHERE resource_id LIKE '<invalid-utf8:%'",
            &.{},
        ) catch {};
        self.conn.rollback() catch {};

        // ISS-0162 / GitHub #486: release the bpm_test_migrations_public advisory
        // lock acquired in init(). Held across the whole harness lifetime so no
        // sibling binary can run resetTestData()'s DELETEs against the shared
        // tenant_default schema while this test is live — see init() and
        // src/design/iss0162_test_harness_cross_binary_races.md.
        //
        // Ordered AFTER rollback() so this test's transaction is fully closed
        // before another binary is admitted, and BEFORE close() so it is released
        // explicitly rather than only as a side effect of disconnecting.
        // catch {}-guarded: releasing the lock must never block teardown. A
        // session-level advisory lock is also released automatically when the
        // connection drops, so even a hard abort cannot strand it.
        self.conn.exec(
            "SELECT pg_advisory_unlock(hashtext('bpm_test_migrations_public'))",
            &.{},
        ) catch {};

        self.conn.close();

        // ISS-0137 / GH #439: restore the ambient tenant binding. setTenant()
        // mutates thread-local state that outlives this harness, so without
        // this a test that called setTenant() would leak its tenant id into
        // whichever test runs next on the same thread. Unconditional: harnesses
        // that never called setTenant() are already at the default.
        bpm.api_tenant_context.set(bpm.api_tenant_context.DEFAULT_TENANT_ID);

        if (self.owns_tag_storage) {
            while (tag_repr_lock.cmpxchgWeak(false, true, .acquire, .acquire) != null) {}
            defer tag_repr_lock.store(false, .release);
            if (tag_repr_storage) |storage| self.tag_allocator.free(storage);
            tag_repr_storage = null;
            cached_owner_tag.store(false, .release);
            self.tag = "";
            self.owns_tag_storage = false;
        }
    }
};
