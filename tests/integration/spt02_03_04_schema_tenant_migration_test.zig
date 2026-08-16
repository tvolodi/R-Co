//! Integration tests for SPT-02, SPT-03, SPT-04 — schema-per-tenant migration
//! run WF02-spt02-04-20260816.
//!
//!   SPT-02 — data migration 061/062/063: per-tenant data copy + marker,
//!           legacy tenancy removal from public, idempotency, interrupted-copy
//!           detection via tenant_schemas.data_migrated_at.
//!   SPT-03 — schema-only connection routing (search_path only, no
//!           bpm.tenant_id session variable), tenant isolation between
//!           concurrent connections, no-tenant/reset path.
//!   SPT-04 — per-test provisioned schemas via provisionTestTenantSchema()/
//!           dropTestTenantSchema() (no explicit tenant_id fixtures in this
//!           suite), cleanup without leakage, and the ADP-12 regression
//!           against tenant_default.
//!
//! Design authority: src/design/spt-02-03-04-schema-per-tenant-migration.md.
//! Specs: tests/specs/SPT-02.md, SPT-03.md, SPT-04.md.
//!
//! Requires a real PostgreSQL database reachable at BPM_TEST_DB_URL; the test
//! fails with error.MissingTestDatabaseUrl (never silently skips) when the
//! env var is absent.
//!
//! The migration-SQL re-execution tests (TC-SPT-02-04/05/06) open their own
//! direct pg.Conn and run the migration files' SQL text via simpleQuery()
//! inside explicit BEGIN/COMMIT|ROLLBACK transactions they manage themselves —
//! the same 1:1-migration-validation pattern as test_iss503_rls_removal.zig.
//! build.zig chains this binary behind the test-integration-others barrier so
//! its public-schema DDL transactions never run concurrently with a sibling.
//!
//! Requirement traceability:
//!   SPT-02 -> TC-SPT-02-01 .. TC-SPT-02-07
//!   SPT-03 -> TC-SPT-03-01 .. TC-SPT-03-05
//!   SPT-04 -> TC-SPT-04-01 .. TC-SPT-04-05

const std = @import("std");
const testing = std.testing;
const portable_env = @import("env");
const pg = @import("pg");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;

// ADP-12 regression (TC-SPT-04-03) support modules — same as
// adp12_default_tenant_regression_test.zig.
const matrix_mod = @import("support/regression_matrix.zig");
const orchestrator = @import("support/migration_window_orchestrator.zig");
const canonical = @import("support/response_canonicalizer.zig");

const default_tenant_id = "00000000-0000-0000-0000-000000000000";
const spt_run_id = "WF02-spt02-04-20260816";

// Class-G registry allow-list — mirrors migrations/062 and 063 exactly
// (design §8.2 R4). Every public table that legitimately keeps a tenant_id
// column must be in this list.
const class_g_tables = [_][]const u8{
    "tenant_schemas",
    "tenant_hostnames",
    "tenant_realm_binding",
    "onboarding_registry",
    "platform_migrations_control_table",
    "rate_limit_buckets",
    "secrets",
    "repository_artifacts",
    "tenant_artifact_activations",
    "promotion_assertion_runs",
    "pack_update_resolutions",
    "solution_pack_installs",
    "tnt05_orphans",
    "tnt05_progress",
};

const migration_061_filename = "061_data_copy_into_tenant_schemas.sql";
const migration_062_filename = "062_remove_tenant_id_rls_from_public.sql";
const migration_063_filename = "063_rls_policy_idempotency_recheck.sql";

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Read BPM_TEST_DB_URL from the environment. Fails with a named error when
/// absent — no silent skip.
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — SPT-02/03/04 integration tests FAILED (env var required)\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn migrationsDir() []const u8 {
    return build_options.migrations_dir;
}

/// Create a fresh pool pointing at the test database.
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

/// Generate a fresh v4 UUID string for per-test fixture isolation. NOT a
/// hardcoded literal.
fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 10xx
    return std.fmt.allocPrint(allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            raw[0],  raw[1],  raw[2],  raw[3],
            raw[4],  raw[5],
            raw[6],  raw[7],
            raw[8],  raw[9],
            raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
        });
}

/// Reads a migration SQL file from disk (relative to the repo root).
fn readMigrationSql(io: std.Io, allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, "migrations", .{ .iterate = true });
    defer dir.close(io);
    return dir.readFileAlloc(io, filename, allocator, std.Io.Limit.limited(16 * 1024 * 1024));
}

/// Reads a repo-root file as text (source-assertion helper).
fn readRepoFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        std.Io.Limit.limited(16 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
}

/// Walk a directory tree and return every .zig file path (relative to repo
/// root, joined). Caller frees the returned slices and deinits the list.
fn collectZigFiles(allocator: std.mem.Allocator, dir_path: []const u8) !std.ArrayList([]u8) {
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const full = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        errdefer allocator.free(full);
        try out.append(allocator, full);
    }
    return out;
}

/// Returns the 1-based line number of the first occurrence of `literal` in
/// `contents`, or 0 if absent.
fn lineOf(contents: []const u8, literal: []const u8) usize {
    const offset = std.mem.indexOf(u8, contents, literal) orelse return 0;
    var line: usize = 1;
    var i: usize = 0;
    while (i < offset) : (i += 1) {
        if (contents[i] == '\n') line += 1;
    }
    return line;
}

/// Query a single scalar text value into a caller-provided buffer. Returns
/// null when no rows. The returned slice aliases `buf` — no allocation, no
/// free needed, no use-after-free. Generic over the connection type
/// (pg.Conn for direct connections, pool.Conn for pool-acquired ones).
fn scalarText(
    allocator: std.mem.Allocator,
    conn: anytype,
    sql: []const u8,
    params: []const []const u8,
    buf: []u8,
) !?[]const u8 {
    var result = try conn.query(allocator, sql, params);
    defer result.deinit();
    if (result.rows.len == 0) return null;
    const v = result.rows[0][0] orelse return null;
    if (v.len > buf.len) return error.ValueTooLong;
    @memcpy(buf[0..v.len], v);
    return buf[0..v.len];
}

/// Query a single numeric scalar (COUNT(*) etc.). Returns 0 when no rows or
/// when the value is not an integer.
fn count(allocator: std.mem.Allocator, conn: anytype, sql: []const u8, params: []const []const u8) !i64 {
    var buf: [64]u8 = undefined;
    const v = (try scalarText(allocator, conn, sql, params, &buf)) orelse return 0;
    return std.fmt.parseInt(i64, v, 10) catch 0;
}

/// Public-schema tables that still carry a tenant_id column (any table —
/// Class G included). Returns a list of table names owned by the caller.
fn publicTenantIdTables(allocator: std.mem.Allocator, conn: anytype) !std.ArrayList([]u8) {
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |t| allocator.free(t);
        out.deinit(allocator);
    }
    var result = try conn.query(
        allocator,
        \\SELECT table_name::text FROM information_schema.columns
        \\WHERE table_schema = 'public' AND column_name = 'tenant_id'
        \\ORDER BY table_name
    , &.{});
    defer result.deinit();
    for (result.rows) |row| {
        if (row[0]) |name| {
            try out.append(allocator, try allocator.dupe(u8, name));
        }
    }
    return out;
}

fn isClassG(table_name: []const u8) bool {
    for (class_g_tables) |g| {
        if (std.mem.eql(u8, table_name, g)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// SPT-02 — data migration 061/062/063
// ---------------------------------------------------------------------------

// TC-SPT-02-01 (SPT-02 AC1): N distinct tenant IDs -> N tenant_schemas rows
// and N schemas.
test "TC-SPT-02-01: every tenant_schemas row is marked migrated and its schema exists" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    var rows = try h.conn.query(
        alloc,
        \\SELECT tenant_id::text, schema_name, (data_migrated_at IS NOT NULL)::text
        \\FROM public.tenant_schemas
        \\ORDER BY tenant_id
    , &.{});
    defer rows.deinit();

    // tenant_default is always provisioned by TestHarness.init(), so the
    // registry is never empty on a migrated database.
    try testing.expect(rows.rows.len > 0);

    for (rows.rows) |row| {
        // boolean::text yields 'true'/'false' in PostgreSQL.
        const marked = row[2] orelse "";
        try testing.expectEqualStrings("true", marked); // 061 set data_migrated_at

        const schema_name = row[1] orelse continue;
        const exists = try count(alloc, &h.conn,
            "SELECT count(*) FROM information_schema.schemata WHERE schema_name = $1",
            &.{schema_name});
        try testing.expectEqual(@as(i64, 1), exists);
    }
}

// TC-SPT-02-02 (SPT-02 AC2): each tenant schema table holds exactly that
// tenant's rows — no cross-tenant contamination, no data loss.
test "TC-SPT-02-02: per-test schemas hold exactly their own rows (no cross-tenant contamination)" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_a = try randomUuidStr(alloc);
    defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc);
    defer alloc.free(tenant_b);

    const cleanup_conn = try pool.acquire();
    defer pool.release(cleanup_conn);
    defer helpers.dropTestTenantSchema(cleanup_conn, alloc, tenant_a);
    defer helpers.dropTestTenantSchema(cleanup_conn, alloc, tenant_b);

    try helpers.provisionTestTenantSchema(alloc, &pool, tenant_a, migrationsDir());
    const conn_a = try pool.acquire(); // search_path = tenant_a schema
    defer pool.release(conn_a);

    try helpers.provisionTestTenantSchema(alloc, &pool, tenant_b, migrationsDir());
    const conn_b = try pool.acquire(); // search_path = tenant_b schema
    defer pool.release(conn_b);

    // Unique definition name per test (no collision with uq_definition_tenant_version).
    const def_name = try std.fmt.allocPrint(alloc, "spt02-iso-{s}", .{tenant_a[0..8]});
    defer alloc.free(def_name);
    const actor = try randomUuidStr(alloc);
    defer alloc.free(actor);

    // Insert exactly one definition row into schema A's process_definitions.
    try conn_a.exec(
        \\INSERT INTO process_definitions (tenant_id, name, version, description, status, graph, created_by)
        \\VALUES ($1::uuid, $2, '1.0.0', '', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, $3::uuid)
    , &.{ tenant_a, def_name, actor });

    // Schema B must not see it (no cross-tenant contamination).
    const b_count = try count(alloc, conn_b,
        "SELECT count(*) FROM process_definitions WHERE name = $1",
        &.{def_name});
    try testing.expectEqual(@as(i64, 0), b_count);

    // Schema A sees exactly the row it was given (no data loss).
    const a_count = try count(alloc, conn_a,
        "SELECT count(*) FROM process_definitions WHERE name = $1",
        &.{def_name});
    try testing.expectEqual(@as(i64, 1), a_count);
}

// TC-SPT-02-03 (SPT-02 AC3): after 062 — no tenant_id column, no
// bpm_effective_tenant_id(), no RLS, no composite indexes in public.
test "TC-SPT-02-03: public schema has no Class-B tenant_id column, no function, no RLS, no tenant_id indexes" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // (a) every public table still carrying tenant_id is Class G (allow-list).
    var tid_tables = try publicTenantIdTables(alloc, &h.conn);
    defer {
        for (tid_tables.items) |t| alloc.free(t);
        tid_tables.deinit(alloc);
    }
    for (tid_tables.items) |table_name| {
        try testing.expect(isClassG(table_name));
    }

    // (b) bpm_effective_tenant_id() absent from public.
    const fn_count = try count(alloc, &h.conn,
        "SELECT count(*) FROM pg_proc WHERE proname = 'bpm_effective_tenant_id' AND pronamespace = 'public'::regnamespace",
        &.{});
    try testing.expectEqual(@as(i64, 0), fn_count);

    // (c) no RLS policies on public tables.
    const pol_count = try count(alloc, &h.conn,
        "SELECT count(*) FROM pg_policies WHERE schemaname = 'public'",
        &.{});
    try testing.expectEqual(@as(i64, 0), pol_count);

    // (d) no public index references a tenant_id column on a non-Class-G table.
    var idx_rows = try h.conn.query(
        alloc,
        \\SELECT DISTINCT t.relname::text
        \\FROM pg_class t
        \\JOIN pg_index ix ON t.oid = ix.indrelid
        \\JOIN pg_class i ON i.oid = ix.indexrelid
        \\JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
        \\WHERE t.relnamespace = 'public'::regnamespace
        \\  AND a.attname = 'tenant_id'
        \\ORDER BY 1
    , &.{});
    defer idx_rows.deinit();
    for (idx_rows.rows) |row| {
        const tbl = row[0] orelse continue;
        try testing.expect(isClassG(tbl));
    }
}

// TC-SPT-02-04 (SPT-02 AC4): 063 belt-and-suspenders policy re-check —
// DROP POLICY IF EXISTS is a no-op success on an already-clean public schema
// and 063's raw SQL exits 0.
test "TC-SPT-02-04: 063 DROP POLICY IF EXISTS re-check is idempotent and clean" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var conn = try pg.Conn.connectUrl(std.testing.io, alloc, url);
    defer conn.close();

    // A literal DROP POLICY IF EXISTS on a live public table (Class G
    // registry table) must be a no-op success even though the policy does not
    // exist — the belt-and-suspenders primitive 063 re-issues.
    try conn.exec("DROP POLICY IF EXISTS spt02_nonexistent_policy ON public.tenant_schemas", &.{});

    // Run 063's own SQL text directly; must exit 0 (idempotent re-check).
    const sql_063 = try readMigrationSql(std.testing.io, alloc, migration_063_filename);
    defer alloc.free(sql_063);

    try conn.exec("BEGIN", &.{});
    try conn.simpleQuery(sql_063); // no exception = exit 0
    try conn.exec("COMMIT", &.{});

    // End state: still zero policies on public.
    const pol_count = try count(alloc, &conn,
        "SELECT count(*) FROM pg_policies WHERE schemaname = 'public'",
        &.{});
    try testing.expectEqual(@as(i64, 0), pol_count);
}

// TC-SPT-02-05 (SPT-02 AC5): re-running 061/062/063 raises no error and
// leaves the state unchanged (full idempotency).
test "TC-SPT-02-05: re-running migrations 061/062/063 is idempotent (exit 0, state unchanged)" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var conn = try pg.Conn.connectUrl(std.testing.io, alloc, url);
    defer conn.close();

    // Snapshot invariants before the re-run.
    const unmarked_before = try count(alloc, &conn,
        "SELECT count(*) FROM public.tenant_schemas WHERE data_migrated_at IS NULL",
        &.{});
    const policies_before = try count(alloc, &conn,
        "SELECT count(*) FROM pg_policies WHERE schemaname = 'public'",
        &.{});

    const sql_061 = try readMigrationSql(std.testing.io, alloc, migration_061_filename);
    defer alloc.free(sql_061);
    const sql_062 = try readMigrationSql(std.testing.io, alloc, migration_062_filename);
    defer alloc.free(sql_062);
    const sql_063 = try readMigrationSql(std.testing.io, alloc, migration_063_filename);
    defer alloc.free(sql_063);

    // Re-run all three against the already-migrated database; each must
    // complete without error (idempotent DDL/DO-blocks make them no-ops).
    try conn.exec("BEGIN", &.{});
    try conn.simpleQuery(sql_061);
    try conn.simpleQuery(sql_062);
    try conn.simpleQuery(sql_063);
    try conn.exec("COMMIT", &.{});

    // State unchanged: no unmarked tenant, no public policies, no Class-B
    // tenant_id column.
    const unmarked_after = try count(alloc, &conn,
        "SELECT count(*) FROM public.tenant_schemas WHERE data_migrated_at IS NULL",
        &.{});
    const policies_after = try count(alloc, &conn,
        "SELECT count(*) FROM pg_policies WHERE schemaname = 'public'",
        &.{});

    try testing.expectEqual(unmarked_before, unmarked_after);
    try testing.expectEqual(policies_before, policies_after);

    var tid_tables = try publicTenantIdTables(alloc, &conn);
    defer {
        for (tid_tables.items) |t| alloc.free(t);
        tid_tables.deinit(alloc);
    }
    for (tid_tables.items) |table_name| {
        try testing.expect(isClassG(table_name));
    }
}

// TC-SPT-02-06 (SPT-02 AC6): interrupted copy detected via the
// tenant_schemas.data_migrated_at row — 062's pre-flight gates on a NULL
// marker; a marked row proceeds cleanly (skip / clean re-attempt).
test "TC-SPT-02-06: 062 pre-flight gates on an unmarked tenant_schemas row and passes when marked" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var conn = try pg.Conn.connectUrl(std.testing.io, alloc, url);
    defer conn.close();

    const synthetic_tenant = try randomUuidStr(alloc);
    defer alloc.free(synthetic_tenant);
    var schema_buf: [80]u8 = undefined;
    const synthetic_schema = schemaNameForTenant(synthetic_tenant, &schema_buf);

    const sql_062 = try readMigrationSql(std.testing.io, alloc, migration_062_filename);
    defer alloc.free(sql_062);

    // (a) Unmarked synthetic tenant (simulated interruption): 062 pre-flight
    //     must abort with a server error.
    try conn.exec("BEGIN", &.{});
    try conn.exec(
        "INSERT INTO public.tenant_schemas (tenant_id, schema_name) VALUES ($1::uuid, $2)",
        &.{ synthetic_tenant, synthetic_schema },
    );
    const blocked = conn.simpleQuery(sql_062);
    try testing.expectError(pg.PgError.ServerError, blocked);
    try conn.exec("ROLLBACK", &.{}); // discarded — no side effects persist

    // (b) Marked synthetic tenant (copy completed): 062 pre-flight passes and
    //     the migration runs cleanly (skip / clean re-attempt).
    try conn.exec("BEGIN", &.{});
    try conn.exec(
        "INSERT INTO public.tenant_schemas (tenant_id, schema_name, data_migrated_at) VALUES ($1::uuid, $2, NOW())",
        &.{ synthetic_tenant, synthetic_schema },
    );
    try conn.simpleQuery(sql_062); // no exception = pre-flight passed
    try conn.exec("ROLLBACK", &.{});

    // Neither synthetic row survived.
    const leftover = try count(alloc, &conn,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{synthetic_tenant});
    try testing.expectEqual(@as(i64, 0), leftover);
}

// TC-SPT-02-07 (SPT-02 release-blocker regression): migration 062 must be able
// to drop Class-B tenant_id columns even when a public view (v_active_configs
// from migration 052) depends on them — the dependent view is dropped BEFORE
// the DROP COLUMN and recreated AFTER with its original definition semantics
// minus the removed tenant_id projection. This reproduces the exact state
// RELEASE-VALIDATOR hit on the fresh-DB path (migration order 052 < 062 <
// GBL-123/1123): before the BACKEND-DEV fix, 062 aborted with 'cannot drop
// column tenant_id of table artifact_activations because other objects depend
// on it — view v_active_configs depends on column tenant_id'.
test "TC-SPT-02-07: 062 applies cleanly when public.v_active_configs depends on a Class-B tenant_id column" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var conn = try pg.Conn.connectUrl(std.testing.io, alloc, url);
    defer conn.close();

    const sql_062 = try readMigrationSql(std.testing.io, alloc, migration_062_filename);
    defer alloc.free(sql_062);

    // Reproduce the fresh-DB pre-062 state inside a transaction. The shared
    // bpm_test is already fully migrated (062 already dropped the column and
    // recreated the view without tenant_id), so we restore the pre-062 state:
    // (a) re-add tenant_id to public.artifact_activations, and (b) recreate
    // public.v_active_configs with its migration-052 definition (which projects
    // aa.tenant_id). This is the exact dependent-view state 062 must handle.
    try conn.exec("BEGIN", &.{});
    try conn.exec(
        "ALTER TABLE public.artifact_activations ADD COLUMN tenant_id uuid",
        &.{},
    );
    try conn.exec("DROP VIEW IF EXISTS public.v_active_configs", &.{});
    try conn.exec(
        \\CREATE VIEW public.v_active_configs AS
        \\SELECT
        \\    aa.tenant_id,
        \\    aa.artifact_kind,
        \\    aa.artifact_name,
        \\    aa.active_version_id,
        \\    encode(ra.content_hash, 'hex') AS content_hash_hex,
        \\    aa.activated_at
        \\FROM public.artifact_activations aa
        \\JOIN public.artifact_versions av
        \\    ON aa.active_version_id = av.version_id
        \\JOIN public.repository_artifacts ra
        \\    ON av.content_hash = ra.content_hash
        \\WHERE aa.artifact_kind = 'config'
    , &.{});

    // Pre-assert the dependent-view state is actually reproduced — the test
    // must exercise the failure path, not silently pass on a no-op setup.
    const aa_tid_pre = try count(alloc, &conn,
        "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'artifact_activations' AND column_name = 'tenant_id'",
        &.{});
    try testing.expectEqual(@as(i64, 1), aa_tid_pre);
    var def_buf: [4096]u8 = undefined;
    const viewdef_pre = (try scalarText(alloc, &conn,
        "SELECT pg_get_viewdef('public.v_active_configs'::regclass, true)", &.{}, &def_buf)) orelse "";
    try testing.expect(std.mem.indexOf(u8, viewdef_pre, "tenant_id") != null);

    // (1) Migration 062 must apply cleanly over the dependent view. A server
    //     error here — the pre-fix 'cannot drop column tenant_id of table
    //     artifact_activations because other objects depend on it' — fails the
    //     test via the propagated PgError.
    try conn.simpleQuery(sql_062);

    // (2) public.v_active_configs exists after with its post-062 definition:
    //     the version-chain traversal is preserved but the tenant_id projection
    //     is gone (public business tables no longer carry it).
    const pub_reg = try count(alloc, &conn,
        "SELECT count(*) FROM pg_class WHERE relname = 'v_active_configs' AND relnamespace = 'public'::regnamespace AND relkind = 'v'",
        &.{});
    try testing.expectEqual(@as(i64, 1), pub_reg);

    const viewdef_post = (try scalarText(alloc, &conn,
        "SELECT pg_get_viewdef('public.v_active_configs'::regclass, true)", &.{}, &def_buf)) orelse "";
    try testing.expect(std.mem.indexOf(u8, viewdef_post, "tenant_id") == null);
    try testing.expect(std.mem.indexOf(u8, viewdef_post, "artifact_activations") != null);

    const aa_tid_post = try count(alloc, &conn,
        "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'artifact_activations' AND column_name = 'tenant_id'",
        &.{});
    try testing.expectEqual(@as(i64, 0), aa_tid_post);

    // (3) tenant_default.v_active_configs (052's tenant-schema copy) keeps
    //     tenant_id — schema isolation is the tenant boundary going forward,
    //     and 062 must leave the tenant-schema copies untouched.
    const td_reg = try count(alloc, &conn,
        "SELECT count(*) FROM pg_class WHERE relname = 'v_active_configs' AND relnamespace = 'tenant_default'::regnamespace AND relkind = 'v'",
        &.{});
    try testing.expectEqual(@as(i64, 1), td_reg);
    const td_tid = try count(alloc, &conn,
        "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'tenant_default' AND table_name = 'v_active_configs' AND column_name = 'tenant_id'",
        &.{});
    try testing.expectEqual(@as(i64, 1), td_tid);

    // ROLLBACK: the shared bpm_test database must be returned to its real
    // migrated state (DDL is transactional in PostgreSQL).
    try conn.exec("ROLLBACK", &.{});
}

// ---------------------------------------------------------------------------
// SPT-03 — schema-only routing, no bpm.tenant_id session variable
// ---------------------------------------------------------------------------

// TC-SPT-03-01 (SPT-03 AC1, scoped): no bpm.tenant_id / set_config.*tenant in
// src/ and no Class-B tenant_id column in public.
test "TC-SPT-03-01: no bpm.tenant_id session variable in src/; public Class-B tables have no tenant_id" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // Source-assertion: walk src/**/*.zig for the legacy session-variable
    // literal. Both `set_config('bpm.tenant_id', ...)` and `SET bpm.tenant_id`
    // contain the substring `bpm.tenant_id`.
    const literal = "bpm.tenant_id";
    var files = try collectZigFiles(alloc, "src");
    defer {
        for (files.items) |p| alloc.free(p);
        files.deinit(alloc);
    }

    var hits: std.ArrayList([]u8) = .empty;
    defer {
        for (hits.items) |hit| alloc.free(hit);
        hits.deinit(alloc);
    }

    for (files.items) |file_path| {
        const contents = readRepoFile(alloc, file_path) catch continue;
        defer alloc.free(contents);
        const line = lineOf(contents, literal);
        if (line > 0) {
            try hits.append(alloc, try std.fmt.allocPrint(alloc, "{s}:{d}", .{ file_path, line }));
        }
    }

    if (hits.items.len > 0) {
        std.debug.print("\nSPT-03 AC1 (scoped): legacy `bpm.tenant_id` literal found in {d} file(s):\n", .{hits.items.len});
        for (hits.items) |hit| std.debug.print("  {s}\n", .{hit});
        return error.TestUnexpectedResult;
    }

    // DB-level half of the scoped AC1b: no public Class-B table has a
    // tenant_id column (only Class-G registry tables may retain it).
    var tid_tables = try publicTenantIdTables(alloc, &h.conn);
    defer {
        for (tid_tables.items) |t| alloc.free(t);
        tid_tables.deinit(alloc);
    }
    for (tid_tables.items) |table_name| {
        try testing.expect(isClassG(table_name));
    }
}

// TC-SPT-03-02 (SPT-03 AC2): collapsed routing compiles and routes via
// search_path only — a provisioned schema is reachable end-to-end.
test "TC-SPT-03-02: collapsed routing provisions and reaches a tenant schema via search_path" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    var schema_buf: [80]u8 = undefined;
    const schema_name = schemaNameForTenant(tenant_id, &schema_buf);

    const cleanup_conn = try pool.acquire();
    defer pool.release(cleanup_conn);
    defer helpers.dropTestTenantSchema(cleanup_conn, alloc, tenant_id);

    try helpers.provisionTestTenantSchema(alloc, &pool, tenant_id, migrationsDir());
    const conn = try pool.acquire();
    defer pool.release(conn);

    var buf: [256]u8 = undefined;
    const sp = (try scalarText(alloc, conn, "SHOW search_path", &.{}, &buf)) orelse "";
    try testing.expect(std.mem.indexOf(u8, sp, schema_name) != null);

    // Unqualified query resolves to the tenant schema's table (proves the
    // collapsed routing + migrations inside the schema work end-to-end).
    const table_count = try count(alloc, conn,
        "SELECT count(*) FROM process_definitions", &.{});
    try testing.expectEqual(@as(i64, 0), table_count);
}

// TC-SPT-03-03 (SPT-03 AC3): tenant context -> correct current_schema() and
// no bpm.tenant_id session variable is set on checkout.
test "TC-SPT-03-03: tenant context routes to current_schema() with no bpm.tenant_id session variable" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    var schema_buf: [80]u8 = undefined;
    const schema_name = schemaNameForTenant(tenant_id, &schema_buf);

    const cleanup_conn = try pool.acquire();
    defer pool.release(cleanup_conn);
    defer helpers.dropTestTenantSchema(cleanup_conn, alloc, tenant_id);

    try helpers.provisionTestTenantSchema(alloc, &pool, tenant_id, migrationsDir());
    const conn = try pool.acquire();
    defer pool.release(conn);

    var buf: [256]u8 = undefined;
    const current_schema = (try scalarText(alloc, conn, "SELECT current_schema()::text", &.{}, &buf)) orelse "";
    try testing.expectEqualStrings(schema_name, current_schema);

    // The bpm.tenant_id session variable must never be set on checkout.
    const var_setting = try scalarText(alloc, conn,
        "SELECT current_setting('bpm.tenant_id', true)", &.{}, &buf);
    try testing.expect(var_setting == null);
}

// TC-SPT-03-04 (SPT-03 AC4): two concurrent connections for different tenants
// have independent search_paths; neither can read the other's rows.
test "TC-SPT-03-04: two concurrent tenant connections are isolated via search_path" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_a = try randomUuidStr(alloc);
    defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc);
    defer alloc.free(tenant_b);

    const cleanup_conn = try pool.acquire();
    defer pool.release(cleanup_conn);
    defer helpers.dropTestTenantSchema(cleanup_conn, alloc, tenant_a);
    defer helpers.dropTestTenantSchema(cleanup_conn, alloc, tenant_b);

    try helpers.provisionTestTenantSchema(alloc, &pool, tenant_a, migrationsDir());
    const conn_a = try pool.acquire(); // search_path = A
    defer pool.release(conn_a);

    try helpers.provisionTestTenantSchema(alloc, &pool, tenant_b, migrationsDir());
    const conn_b = try pool.acquire(); // search_path = B
    defer pool.release(conn_b);

    var buf_a: [256]u8 = undefined;
    var buf_b: [256]u8 = undefined;
    const sp_a = (try scalarText(alloc, conn_a, "SHOW search_path", &.{}, &buf_a)) orelse "";
    const sp_b = (try scalarText(alloc, conn_b, "SHOW search_path", &.{}, &buf_b)) orelse "";
    var schema_buf_a: [80]u8 = undefined;
    var schema_buf_b: [80]u8 = undefined;
    const schema_a = schemaNameForTenant(tenant_a, &schema_buf_a);
    const schema_b = schemaNameForTenant(tenant_b, &schema_buf_b);
    try testing.expect(std.mem.indexOf(u8, sp_a, schema_a) != null);
    try testing.expect(std.mem.indexOf(u8, sp_b, schema_b) != null);

    const def_name = try std.fmt.allocPrint(alloc, "spt03-conc-{s}", .{tenant_a[0..8]});
    defer alloc.free(def_name);
    const actor = try randomUuidStr(alloc);
    defer alloc.free(actor);

    try conn_a.exec(
        \\INSERT INTO process_definitions (tenant_id, name, version, description, status, graph, created_by)
        \\VALUES ($1::uuid, $2, '1.0.0', '', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, $3::uuid)
    , &.{ tenant_a, def_name, actor });

    // B must not see A's row.
    const b_count = try count(alloc, conn_b,
        "SELECT count(*) FROM process_definitions WHERE name = $1",
        &.{def_name});
    try testing.expectEqual(@as(i64, 0), b_count);

    // A sees its own row.
    const a_count = try count(alloc, conn_a,
        "SELECT count(*) FROM process_definitions WHERE name = $1",
        &.{def_name});
    try testing.expectEqual(@as(i64, 1), a_count);
}

// TC-SPT-03-05 (SPT-03 AC5): no-tenant and reset paths return to public-only
// search_path (existing routing preserved — no regression).
test "TC-SPT-03-05: no-tenant and reset paths restore public-only search_path" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // No-tenant path: empty context -> search_path is public only.
    bpm.api_tenant_context.set("");
    const conn1 = try pool.acquire();
    defer pool.release(conn1);
    var buf: [256]u8 = undefined;
    const sp_no_tenant = (try scalarText(alloc, conn1, "SHOW search_path", &.{}, &buf)) orelse "";
    try testing.expect(std.mem.indexOf(u8, sp_no_tenant, "public") != null);
    try testing.expect(std.mem.indexOf(u8, sp_no_tenant, "tenant_") == null);

    // Route to a real tenant schema, then reset: re-acquire with no tenant
    // context must come back to public-only (no search_path leakage).
    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    const cleanup_conn = try pool.acquire();
    defer pool.release(cleanup_conn);
    defer helpers.dropTestTenantSchema(cleanup_conn, alloc, tenant_id);

    try helpers.provisionTestTenantSchema(alloc, &pool, tenant_id, migrationsDir());
    const conn2 = try pool.acquire();
    defer pool.release(conn2);
    const sp_tenant = (try scalarText(alloc, conn2, "SHOW search_path", &.{}, &buf)) orelse "";
    var schema_buf: [80]u8 = undefined;
    const schema_name = schemaNameForTenant(tenant_id, &schema_buf);
    try testing.expect(std.mem.indexOf(u8, sp_tenant, schema_name) != null);

    bpm.api_tenant_context.set("");
    const conn3 = try pool.acquire();
    defer pool.release(conn3);
    const sp_reset = (try scalarText(alloc, conn3, "SHOW search_path", &.{}, &buf)) orelse "";
    try testing.expect(std.mem.indexOf(u8, sp_reset, "public") != null);
    try testing.expect(std.mem.indexOf(u8, sp_reset, "tenant_") == null);
}

// ---------------------------------------------------------------------------
// SPT-04 — test-suite update and ADP-12 regression
// ---------------------------------------------------------------------------

// TC-SPT-04-01 (SPT-04 AC1, scoped): the SPT suite + helpers use per-test
// provisioned schemas and introduce no legacy tenant_id fixture patterns.
test "TC-SPT-04-01: SPT suite uses provisionTestTenantSchema/dropTestTenantSchema, no set_config('bpm.tenant_id')" {
    const alloc = testing.allocator;

    const helpers_src = try readRepoFile(alloc, "tests/integration/helpers.zig");
    defer alloc.free(helpers_src);
    try testing.expect(lineOf(helpers_src, "pub fn provisionTestTenantSchema") > 0);
    try testing.expect(lineOf(helpers_src, "pub fn dropTestTenantSchema") > 0);

    const this_src = try readRepoFile(alloc, "tests/integration/spt02_03_04_schema_tenant_migration_test.zig");
    defer alloc.free(this_src);

    // No legacy session-variable fixture in this suite. The needle is built
    // at runtime so this assertion's own literal cannot self-match.
    const sc_literal = "set_config('bpm.tenant_id'";
    const sc_needle = try std.fmt.allocPrint(alloc, "SELECT {s},", .{sc_literal});
    defer alloc.free(sc_needle);
    try testing.expectEqual(@as(usize, 0), lineOf(this_src, sc_needle));

    // Every provisioned schema in this suite pairs with a drop-cleanup
    // (defer dropTestTenantSchema). Count the helper call sites.
    const provision_calls = std.mem.count(u8, this_src, "provisionTestTenantSchema(");
    const drop_calls = std.mem.count(u8, this_src, "dropTestTenantSchema(");
    try testing.expect(provision_calls >= 6); // TC-SPT-02-02, 03-02/03/04/05 + TC-SPT-04-04
    try testing.expect(drop_calls >= provision_calls);
}

// TC-SPT-04-02 (SPT-04 AC2): this suite covers all 17 SPT ACs as runnable,
// non-skipped test blocks.
test "TC-SPT-04-02: suite has 17 runnable SPT test blocks and no error.SkipZigTest" {
    const alloc = testing.allocator;
    const this_src = try readRepoFile(alloc, "tests/integration/spt02_03_04_schema_tenant_migration_test.zig");
    defer alloc.free(this_src);

    const block_count = std.mem.count(u8, this_src, "test \"TC-SPT-");
    try testing.expectEqual(@as(usize, 17), block_count);

    // No MUST test may skip. The needle is built at runtime so this
    // assertion's own literal ("return {s};") can never self-match.
    const skip_literal = "error.SkipZigTest";
    const skip_needle = try std.fmt.allocPrint(alloc, "return {s};", .{skip_literal});
    defer alloc.free(skip_needle);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, this_src, skip_needle));
}

// TC-SPT-04-03 (SPT-04 AC3): ADP-12 regression passes against the default
// tenant (tenant_default) with no BLOCKER/MAJOR.
test "TC-SPT-04-03: ADP-12 regression matrix passes against tenant_default" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc); // routes to tenant_default
    defer h.deinit();

    const matrix = try matrix_mod.loadStageCoverageMatrix(alloc);
    defer alloc.free(matrix);
    try testing.expect(matrix.len >= 44);

    const run = try orchestrator.runRegressionSuite(
        alloc,
        spt_run_id,
        build_options.adp12_phase,
        matrix,
        adp12Allowlist(),
    );
    defer {
        var owned = run;
        orchestrator.deinitRegressionRun(alloc, &owned);
    }

    try testing.expect(run.report.pre_case_count == matrix.len);
    try testing.expect(run.report.post_case_count == matrix.len);
    try testing.expect(run.report.pair_count == matrix.len);
    try testing.expect(run.report.zero_diff_pass);
    try testing.expect(!run.report.flaky_signals_detected);
    try testing.expectEqualStrings(default_tenant_id, run.report.default_tenant_id);
}

// TC-SPT-04-04 (SPT-04 AC4): a provisioned schema + its tenant_schemas row
// are cleaned up after the test (no schema leakage).
test "TC-SPT-04-04: dropTestTenantSchema removes schema, tenant_schemas, schema_migrations, and tenant rows" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    var schema_buf: [80]u8 = undefined;
    const schema_name = schemaNameForTenant(tenant_id, &schema_buf);

    try helpers.provisionTestTenantSchema(alloc, &pool, tenant_id, migrationsDir());

    // Verify the fixture exists before cleanup.
    const schema_before = try count(alloc, &h.conn,
        "SELECT count(*) FROM information_schema.schemata WHERE schema_name = $1",
        &.{schema_name});
    try testing.expectEqual(@as(i64, 1), schema_before);
    const ts_before = try count(alloc, &h.conn,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{tenant_id});
    try testing.expectEqual(@as(i64, 1), ts_before);

    // Cleanup (runs even if the assertions above failed — but here explicit).
    const cleanup_conn = try pool.acquire();
    defer pool.release(cleanup_conn);
    helpers.dropTestTenantSchema(cleanup_conn, alloc, tenant_id);

    const schema_after = try count(alloc, &h.conn,
        "SELECT count(*) FROM information_schema.schemata WHERE schema_name = $1",
        &.{schema_name});
    try testing.expectEqual(@as(i64, 0), schema_after);

    const ts_after = try count(alloc, &h.conn,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{tenant_id});
    try testing.expectEqual(@as(i64, 0), ts_after);

    const sm_after = try count(alloc, &h.conn,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = $1",
        &.{schema_name});
    try testing.expectEqual(@as(i64, 0), sm_after);

    const tenant_row_after = try count(alloc, &h.conn,
        "SELECT count(*) FROM public.tenant WHERE id = $1::uuid",
        &.{tenant_id});
    try testing.expectEqual(@as(i64, 0), tenant_row_after);
}

// TC-SPT-04-05 (SPT-04 AC5): helpers + suite compile clean and are usable
// from a real integration test (the unit-suite compile gate's consequence).
test "TC-SPT-04-05: helper imports and helper symbols are present and wired (compile-clean)" {
    const alloc = testing.allocator;

    const this_src = try readRepoFile(alloc, "tests/integration/spt02_03_04_schema_tenant_migration_test.zig");
    defer alloc.free(this_src);

    // The suite imports helpers.zig and the bpm module (compile graph intact).
    try testing.expect(lineOf(this_src, "@import(\"helpers.zig\")") > 0);
    try testing.expect(lineOf(this_src, "@import(\"bpm\")") > 0);
    // helpers.zig imports the bpm module and exposes the SPT-04 helpers.
    const helpers_src = try readRepoFile(alloc, "tests/integration/helpers.zig");
    defer alloc.free(helpers_src);
    try testing.expect(lineOf(helpers_src, "@import(\"bpm\")") > 0);
    try testing.expect(lineOf(helpers_src, "provisionTestTenantSchema") > 0);
    try testing.expect(lineOf(helpers_src, "dropTestTenantSchema") > 0);
}

// ---------------------------------------------------------------------------
// ADP-12 allowlist (mirrors adp12_default_tenant_regression_test.zig)
// ---------------------------------------------------------------------------

const header_allowlist = [_][]const u8{
    "date",
    "server",
    "x-trace-id",
    "x-request-id",
    "content-length",
    "transfer-encoding",
    "connection",
    "keep-alive",
};

const json_pointer_allowlist = [_][]const u8{
    "/trace_id",
    "/timestamp",
    "/now",
    "/generated_at",
    "/uptime_ms",
    "/duration_ms",
};

fn adp12Allowlist() canonical.InformationalAllowlist {
    return .{
        .header_names = header_allowlist[0..],
        .json_pointer_paths = json_pointer_allowlist[0..],
    };
}
