//! Integration tests for ISS-503 — GBL-084 RLS removal migration.
//!
//! migrations/GBL-084_rls_removal.sql drops legacy RLS policies, tenant_id
//! columns on public business tables, and the bpm_effective_tenant_id()
//! helper function — but only after a pre-flight guard confirms zero tenants
//! remain in storage_mode = 'LEGACY_RLS'. The guard is a single `DO $$ ... $$`
//! block: if the pre-flight RAISE EXCEPTION fires, the whole block (guard +
//! every DDL statement after it) aborts atomically — nothing after the guard
//! ever executes, so no DROP POLICY/COLUMN/FUNCTION happens, and the caller
//! (the migration runner in src/tools/migrate.zig) never records the file in
//! public.schema_migrations because it rolls back its own wrapping
//! transaction on error.
//!
//! Requires a real PostgreSQL database reachable at BPM_TEST_DB_URL.
//! Every test creates its own fixtures with per-test UUIDs and cleans up via
//! defer (even on failure paths) — no cross-test shared state.
//!
//! IMPORTANT — shared `public` schema semantics:
//! GBL-084 is a GBL-prefixed (global/public-schema) migration. The regular
//! test harness (tests/integration/helpers.zig runMigrations()) applies it
//! unconditionally to the shared test database's `public` schema and records
//! it in `public.schema_migrations`, so by the time these tests run it has
//! almost certainly already been applied once, globally, and re-applying it
//! via the real migration runner would be a permanent no-op (`applied.contains`
//! short-circuits it). That real-runner behaviour is NOT what TC-ISS503-01/02
//! need to exercise — they need to observe the *migration SQL's own*
//! pre-flight guard and DDL behaviour directly, independent of whichever
//! global schema_migrations bookkeeping row already exists.
//!
//! To do that, every test here opens its own **direct pg.Conn** (bypassing
//! the pool and the TestHarness rollback-per-test convention) and executes
//! the GBL-084 SQL file's contents via simpleQuery() inside an explicit
//! BEGIN/COMMIT or BEGIN/ROLLBACK it manages itself — mirroring the exact
//! pattern used to validate migrations 1:1 against a live database elsewhere
//! in this codebase (see the GBL-077 smoke-test precedent). All assertions
//! are relative (before vs. after snapshots of pg_policies /
//! information_schema.columns / pg_proc), so the tests are correct regardless
//! of whether GBL-084 already ran once, globally, before this suite started.
//!
//! Requirement traceability:
//!   ISS-503 → TC-ISS503-01 .. TC-ISS503-04

const std = @import("std");
const testing = std.testing;
const pg = @import("pg");
const helpers = @import("helpers.zig");
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-503 integration tests\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
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

/// Reads migrations/GBL-084_rls_removal.sql from disk. Tries several relative
/// paths so the test works whether the test binary's cwd is the repo root
/// (normal `zig build test-integration` invocation, cwd set via setCwd in
/// build.zig) or a nested test-runner cwd.
fn readGbl084Sql(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const candidates = [_][]const u8{
        "migrations",
        "../migrations",
        "../../migrations",
        "../../../migrations",
    };

    var dir: std.Io.Dir = std.Io.Dir.cwd().openDir(io, "migrations", .{ .iterate = true }) catch blk: {
        for (candidates[1..]) |candidate| {
            const opened = std.Io.Dir.cwd().openDir(io, candidate, .{ .iterate = true }) catch |err| {
                if (err == error.FileNotFound) continue;
                return err;
            };
            break :blk opened;
        }
        return error.FileNotFound;
    };
    defer dir.close(io);

    return dir.readFileAlloc(io, "GBL-084_rls_removal.sql", allocator, std.Io.Limit.limited(16 * 1024 * 1024));
}

/// Insert a temporary tenant row with the given storage_mode and a unique
/// slug/realm so it cannot collide with any pre-existing tenant row.
fn createTenantRow(
    allocator: std.mem.Allocator,
    conn: *pg.Conn,
    tenant_id_str: []const u8,
    slug_suffix: []const u8,
    storage_mode: []const u8,
) !void {
    const slug = try std.fmt.allocPrint(allocator, "iss503-{s}", .{slug_suffix[0..8]});
    defer allocator.free(slug);
    const realm = try std.fmt.allocPrint(allocator, "realm-iss503-{s}", .{slug_suffix[0..8]});
    defer allocator.free(realm);

    try conn.exec(
        "INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, storage_mode) VALUES ($1::uuid, $2, 'ISS-503 Test Tenant', 'ACTIVE', $3, $4)",
        &.{ tenant_id_str, slug, realm, storage_mode },
    );
}

fn deleteTenantRow(conn: *pg.Conn, tenant_id_str: []const u8) void {
    conn.exec(
        "DELETE FROM public.tenant WHERE id = $1::uuid",
        &.{tenant_id_str},
    ) catch |err| {
        std.debug.print("cleanup: DELETE tenant {s} failed: {}\n", .{ tenant_id_str, err });
    };
}

fn countLegacyRlsTenants(allocator: std.mem.Allocator, conn: *pg.Conn) !usize {
    var result = try conn.query(
        allocator,
        "SELECT count(*) FROM public.tenant WHERE storage_mode = 'LEGACY_RLS'",
        &.{},
    );
    defer result.deinit();
    if (result.rows.len == 0) return 0;
    const raw = result.rows[0][0] orelse return 0;
    return std.fmt.parseInt(usize, raw, 10) catch 0;
}

/// Count RLS policies on public business tables that GBL-084 is responsible
/// for removing (the six RLS-protected tables from Group 1).
fn countRlsPolicies(allocator: std.mem.Allocator, conn: *pg.Conn) !usize {
    var result = try conn.query(
        allocator,
        \\SELECT count(*) FROM pg_policies
        \\WHERE schemaname = 'public'
        \\  AND tablename IN ('process_definitions', 'instance_projections', 'tasks', 'tokens', 'audit_entries', 'audit_log')
    ,
        &.{},
    );
    defer result.deinit();
    if (result.rows.len == 0) return 0;
    const raw = result.rows[0][0] orelse return 0;
    return std.fmt.parseInt(usize, raw, 10) catch 0;
}

/// Count tenant_id columns remaining across every business table GBL-084
/// touches (Group 1 + Group 2 from the migration file).
fn countTenantIdColumns(allocator: std.mem.Allocator, conn: *pg.Conn) !usize {
    var result = try conn.query(
        allocator,
        \\SELECT count(*) FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\  AND column_name = 'tenant_id'
        \\  AND table_name IN (
        \\    'process_definitions', 'instance_projections', 'tasks', 'tokens',
        \\    'audit_entries', 'audit_log', 'events', 'events_archive',
        \\    'instance_sequence', 'event_type_registry', 'event_retention_policies',
        \\    'timers', 'users', 'groups', 'group_members', 'roles', 'user_roles',
        \\    'api_tokens', 'webhook_subscriptions', 'webhook_deliveries',
        \\    'dead_letter_items', 'repository_form_schemas'
        \\  )
    ,
        &.{},
    );
    defer result.deinit();
    if (result.rows.len == 0) return 0;
    const raw = result.rows[0][0] orelse return 0;
    return std.fmt.parseInt(usize, raw, 10) catch 0;
}

/// Counts only the `public` schema's copy of bpm_effective_tenant_id().
/// GBL-084 drops the public-schema function; SCHEMA-mode tenant schemas
/// (e.g. tenant_default) legitimately keep their own per-schema copy, so
/// this MUST filter by namespace like its siblings countRlsPolicies() and
/// countTenantIdColumns() do, or it over-counts once any tenant schema
/// exists (see ISS-503-TESTBUG-01).
fn countEffectiveTenantIdFunction(allocator: std.mem.Allocator, conn: *pg.Conn) !usize {
    var result = try conn.query(
        allocator,
        "SELECT count(*) FROM pg_proc WHERE proname = 'bpm_effective_tenant_id' AND pronamespace = 'public'::regnamespace",
        &.{},
    );
    defer result.deinit();
    if (result.rows.len == 0) return 0;
    const raw = result.rows[0][0] orelse return 0;
    return std.fmt.parseInt(usize, raw, 10) catch 0;
}

fn countSchemaMigrationsRows(allocator: std.mem.Allocator, conn: *pg.Conn, version: []const u8) !usize {
    var result = try conn.query(
        allocator,
        "SELECT count(*) FROM public.schema_migrations WHERE version = $1",
        &.{version},
    );
    defer result.deinit();
    if (result.rows.len == 0) return 0;
    const raw = result.rows[0][0] orelse return 0;
    return std.fmt.parseInt(usize, raw, 10) catch 0;
}

const GBL084_FILENAME = "GBL-084_rls_removal.sql";

// ---------------------------------------------------------------------------
// TC-ISS503-01: GBL-084 pre-flight blocks when a LEGACY_RLS tenant exists
// ---------------------------------------------------------------------------

test "TC-ISS503-01: GBL-084 pre-flight blocks when LEGACY_RLS tenants exist" {
    const alloc = testing.allocator;

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var conn = try pg.Conn.connectUrl(std.testing.io, alloc, url);
    defer conn.close();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);

    // Precondition: at least one tenant with storage_mode = 'LEGACY_RLS'.
    try createTenantRow(alloc, &conn, tenant_id, tenant_id, "LEGACY_RLS");
    defer deleteTenantRow(&conn, tenant_id);

    const legacy_count = try countLegacyRlsTenants(alloc, &conn);
    try testing.expect(legacy_count > 0);

    // Snapshot DDL-relevant state before attempting the migration.
    const policies_before = try countRlsPolicies(alloc, &conn);
    const tenant_id_cols_before = try countTenantIdColumns(alloc, &conn);
    const function_count_before = try countEffectiveTenantIdFunction(alloc, &conn);
    const recorded_before = try countSchemaMigrationsRows(alloc, &conn, GBL084_FILENAME);

    const sql_bytes = try readGbl084Sql(std.testing.io, alloc);
    defer alloc.free(sql_bytes);

    // Run the migration's own SQL text directly (not through the migration
    // runner) inside a transaction we control, so we can assert on the
    // exact failure and guarantee no side effects survive regardless of
    // outcome.
    try conn.exec("BEGIN", &.{});
    const migration_result = conn.simpleQuery(sql_bytes);

    // Expected: the pre-flight RAISE EXCEPTION aborts the DO $$ ... $$ block.
    // pg.zig surfaces this as error.ServerError (message text is printed to
    // stderr by pg.zig's readUntilReady(), not returned structurally).
    try testing.expectError(pg.PgError.ServerError, migration_result);

    // A failed statement inside a transaction leaves it aborted; ROLLBACK is
    // required before the connection can run further statements. This also
    // guarantees zero DDL from this attempt is ever committed, regardless of
    // whether the pre-flight guard did its job.
    try conn.exec("ROLLBACK", &.{});

    // No DDL changes applied: RLS-policy count, tenant_id column count, and
    // the helper function count must all be unchanged.
    const policies_after = try countRlsPolicies(alloc, &conn);
    const tenant_id_cols_after = try countTenantIdColumns(alloc, &conn);
    const function_count_after = try countEffectiveTenantIdFunction(alloc, &conn);
    try testing.expectEqual(policies_before, policies_after);
    try testing.expectEqual(tenant_id_cols_before, tenant_id_cols_after);
    try testing.expectEqual(function_count_before, function_count_after);

    // Not recorded in schema_migrations as a NEW row from this attempt.
    const recorded_after = try countSchemaMigrationsRows(alloc, &conn, GBL084_FILENAME);
    try testing.expectEqual(recorded_before, recorded_after);
}

// ---------------------------------------------------------------------------
// TC-ISS503-02: GBL-084 succeeds when zero LEGACY_RLS tenants remain
// ---------------------------------------------------------------------------

test "TC-ISS503-02: GBL-084 succeeds when zero LEGACY_RLS tenants remain" {
    const alloc = testing.allocator;

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var conn = try pg.Conn.connectUrl(std.testing.io, alloc, url);
    defer conn.close();

    // ISS-503-TESTISO-01 fix: this test used to snapshot/mutate/restore
    // whichever rows happened to be LEGACY_RLS in public.tenant (including
    // the shared default tenant row) directly on the connection, then
    // COMMIT the migration's DDL for real. That is the documented "shared
    // mutable tenant fixture" anti-pattern (docs/anti-patterns.md): a
    // restore-via-defer that silently swallows an UPDATE failure
    // (`catch |err| { std.debug.print(...) }`) can leave the shared default
    // tenant's storage_mode corrupted for whichever test — in this run or
    // the *next* invocation of this binary, since clean_test_db.py never
    // resets storage_mode — depends on it next (TC-ISS503-03's idempotent
    // re-apply case observed exactly this once in 8 runs).
    //
    // Fix: do everything — the temporary flip-to-SCHEMA, the migration DDL,
    // and every assertion — inside ONE transaction that is always rolled
    // back at the end, regardless of pass or fail. Every statement GBL-084
    // runs is ordinary transactional DDL (ALTER TABLE / DROP POLICY / DROP
    // COLUMN / DROP FUNCTION — see migrations/GBL-084_rls_removal.sql), so
    // Postgres guarantees the ROLLBACK fully undoes both the temporary mode
    // flip and the migration's DDL. This still exercises the pre-flight
    // guard's real global condition (zero LEGACY_RLS tenants table-wide)
    // end-to-end against the real public.tenant table, but leaves provably
    // zero residue for the next test in this file or the next invocation of
    // this binary — no defer-based manual restore, no swallowed errors, no
    // dependency on a fixture this test doesn't own.
    try conn.exec("BEGIN", &.{});
    errdefer conn.exec("ROLLBACK", &.{}) catch {};

    try conn.exec("UPDATE public.tenant SET storage_mode = 'SCHEMA' WHERE storage_mode = 'LEGACY_RLS'", &.{});

    const legacy_count = try countLegacyRlsTenants(alloc, &conn);
    try testing.expectEqual(@as(usize, 0), legacy_count);

    const sql_bytes = try readGbl084Sql(std.testing.io, alloc);
    defer alloc.free(sql_bytes);

    // Run the migration's DDL inside this same transaction. It is idempotent
    // (IF EXISTS everywhere), so applying it here even if a prior global run
    // already applied it once is always safe.
    try conn.simpleQuery(sql_bytes);

    // All RLS policies on the six RLS-protected business tables are gone.
    const policies_after = try countRlsPolicies(alloc, &conn);
    try testing.expectEqual(@as(usize, 0), policies_after);

    // All tenant_id columns dropped from every business table in scope.
    const tenant_id_cols_after = try countTenantIdColumns(alloc, &conn);
    try testing.expectEqual(@as(usize, 0), tenant_id_cols_after);

    // bpm_effective_tenant_id() function dropped.
    const function_count_after = try countEffectiveTenantIdFunction(alloc, &conn);
    try testing.expectEqual(@as(usize, 0), function_count_after);

    // Always roll back: this test must leave zero trace in public.tenant or
    // on any business table for the next test in this file, or the next
    // invocation of this binary, to observe.
    try conn.exec("ROLLBACK", &.{});
}

// ---------------------------------------------------------------------------
// TC-ISS503-03: GBL-084 is idempotent on re-apply
// ---------------------------------------------------------------------------

test "TC-ISS503-03: GBL-084 is idempotent on re-apply" {
    const alloc = testing.allocator;

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var conn = try pg.Conn.connectUrl(std.testing.io, alloc, url);
    defer conn.close();

    // ISS-503-TESTISO-01 fix: same shared-mutable-tenant-fixture anti-pattern
    // as TC-ISS503-02 (see its comment above for the full root-cause trace —
    // a silently-swallowed restore-via-defer UPDATE on the shared default
    // tenant row could leave storage_mode corrupted for a later test or the
    // next invocation of this binary). Fix is identical: run the temporary
    // flip-to-SCHEMA precondition, BOTH migration applies, and every
    // assertion inside one transaction, rolled back unconditionally at the
    // end. GBL-084's DDL is ordinary transactional DDL, so ROLLBACK fully
    // undoes both applies and the mode flip — this test owns nothing beyond
    // its own transaction and leaves zero residue either way.
    try conn.exec("BEGIN", &.{});
    errdefer conn.exec("ROLLBACK", &.{}) catch {};

    try conn.exec("UPDATE public.tenant SET storage_mode = 'SCHEMA' WHERE storage_mode = 'LEGACY_RLS'", &.{});

    const sql_bytes = try readGbl084Sql(std.testing.io, alloc);
    defer alloc.free(sql_bytes);

    // First apply (establishes the "already applied" precondition for this test).
    try conn.simpleQuery(sql_bytes);

    const policies_after_first = try countRlsPolicies(alloc, &conn);
    const tenant_id_cols_after_first = try countTenantIdColumns(alloc, &conn);
    const function_count_after_first = try countEffectiveTenantIdFunction(alloc, &conn);
    try testing.expectEqual(@as(usize, 0), policies_after_first);
    try testing.expectEqual(@as(usize, 0), tenant_id_cols_after_first);
    try testing.expectEqual(@as(usize, 0), function_count_after_first);

    // Re-apply must succeed with no errors (IF EXISTS everywhere no-ops).
    // Same transaction, no nested BEGIN/COMMIT — a second failed statement
    // here would abort the (single) enclosing transaction, which the
    // errdefer above rolls back exactly like any other failure path.
    try conn.simpleQuery(sql_bytes);

    // State is unchanged and still fully torn down after the second apply.
    const policies_after_second = try countRlsPolicies(alloc, &conn);
    const tenant_id_cols_after_second = try countTenantIdColumns(alloc, &conn);
    const function_count_after_second = try countEffectiveTenantIdFunction(alloc, &conn);
    try testing.expectEqual(@as(usize, 0), policies_after_second);
    try testing.expectEqual(@as(usize, 0), tenant_id_cols_after_second);
    try testing.expectEqual(@as(usize, 0), function_count_after_second);

    // Always roll back: this test must leave zero trace in public.tenant or
    // on any business table for the next test in this file, or the next
    // invocation of this binary, to observe.
    try conn.exec("ROLLBACK", &.{});
}

// ---------------------------------------------------------------------------
// TC-ISS503-04: SCHEMA-path CRUD requests work after RLS removal, with no
// remaining references to bpm.tenant_id in query plans.
// ---------------------------------------------------------------------------

test "TC-ISS503-04: SCHEMA-path CRUD requests work after RLS removal with no bpm.tenant_id in query plans" {
    const alloc = testing.allocator;

    // TestHarness provisions and migrates tenant_default (a real SCHEMA-mode
    // per-tenant schema) via the same code path production uses, then sets
    // the pool's request tenant context to the default tenant for the
    // duration of the test. This exercises the exact SCHEMA branch of
    // applyRequestStorageRouting() in src/db/pool.zig.
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Force storage-mode resolution to be re-done on this pool's first
    // acquire (a fresh Pool has its own connections; the thread-local
    // storage-mode cache from a previous test could otherwise leak across
    // tests since it's keyed per-thread, not per-pool).
    bpm.api_tenant_context.clear();
    bpm.api_tenant_context.set(bpm.api_tenant_context.DEFAULT_TENANT_ID);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // storage_mode must have resolved to SCHEMA for the default tenant
    // (provisionTenantSchema/TestHarness sets this during setup — see
    // helpers.zig and src/db/provisioning.zig).
    try testing.expectEqual(bpm.api_tenant_context.StorageMode.SCHEMA, bpm.api_tenant_context.getStorageMode());

    // CRUD: create a process definition row through the tenant schema (a
    // real business table). tenant_default.process_definitions still has a
    // NOT NULL tenant_id column backed by tenant_default's own
    // bpm_effective_tenant_id() (GBL-084 only drops the public-schema
    // copy — see countEffectiveTenantIdFunction's doc comment), so we
    // populate it via that function exactly like the other integration
    // tests in this suite do (see adp02/adp03/env02/env03/env05 tests).
    // The important assertion is not that tenant_id is absent from this
    // schema, but that no bpm.tenant_id RLS predicate appears in the query
    // plan below, and that the tenant scoping is enforced by the SCHEMA
    // path (search_path), not by a public-schema RLS policy GBL-084 removed.
    const def_id = try randomUuidStr(alloc);
    defer alloc.free(def_id);

    try conn.exec(
        \\INSERT INTO process_definitions (id, tenant_id, name, version, status, graph, created_by)
        \\VALUES ($1::uuid, bpm_effective_tenant_id(), $2, '1', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, '00000000-0000-0000-0000-000000000099'::uuid)
    ,
        &.{ def_id, def_id[0..8] },
    );

    // Read it back (SELECT — CRUD "R").
    {
        var rows = try conn.query(
            alloc,
            "SELECT id::text, status FROM process_definitions WHERE id = $1::uuid",
            &.{def_id},
        );
        defer rows.deinit();
        try testing.expectEqual(@as(usize, 1), rows.rows.len);
        const status = rows.rows[0][1] orelse "";
        try testing.expectEqualStrings("DRAFT", status);
    }

    // Update it (CRUD "U").
    try conn.exec(
        "UPDATE process_definitions SET status = 'ACTIVE' WHERE id = $1::uuid",
        &.{def_id},
    );
    {
        var rows = try conn.query(
            alloc,
            "SELECT status FROM process_definitions WHERE id = $1::uuid",
            &.{def_id},
        );
        defer rows.deinit();
        try testing.expectEqual(@as(usize, 1), rows.rows.len);
        const status = rows.rows[0][0] orelse "";
        try testing.expectEqualStrings("ACTIVE", status);
    }

    // No references to bpm.tenant_id in the query plan: EXPLAIN the same
    // SELECT and scan the plan text for the RLS session-variable expression
    // that LEGACY_RLS policies used to inject
    // (current_setting('bpm.tenant_id', ...)). A SCHEMA-mode connection with
    // RLS policies/columns dropped must show no trace of it.
    {
        var plan_rows = try conn.query(
            alloc,
            "EXPLAIN SELECT id, status FROM process_definitions WHERE id = $1::uuid",
            &.{def_id},
        );
        defer plan_rows.deinit();

        for (plan_rows.rows) |row| {
            const line = row[0] orelse continue;
            try testing.expect(std.mem.indexOf(u8, line, "bpm.tenant_id") == null);
            try testing.expect(std.mem.indexOf(u8, line, "tenant_id") == null);
        }
    }

    // Delete it (CRUD "D").
    try conn.exec(
        "DELETE FROM process_definitions WHERE id = $1::uuid",
        &.{def_id},
    );
    {
        var rows = try conn.query(
            alloc,
            "SELECT id FROM process_definitions WHERE id = $1::uuid",
            &.{def_id},
        );
        defer rows.deinit();
        try testing.expectEqual(@as(usize, 0), rows.rows.len);
    }

    // NOTE: unlike `public`, tenant_default.process_definitions DOES keep a
    // NOT NULL tenant_id column backed by its own per-schema
    // bpm_effective_tenant_id() default (confirmed live via `\d
    // tenant_default.process_definitions`) — GBL-084 only removes the
    // public-schema copies of the tenant_id columns and the RLS helper
    // function; per-tenant schemas provisioned by TNT-01/GBL-077 retain
    // their own tenant_id + RLS policy by design, scoped to that one schema.
    // So the correct regression guard here is NOT "tenant_id is absent from
    // tenant_default" (it isn't, and never was) — it is that the
    // *public*-schema copy stays gone, which countTenantIdColumns() and
    // countEffectiveTenantIdFunction() already assert against `public`
    // earlier in this suite (TC-ISS503-02/03). This block instead confirms
    // the per-tenant column that IS expected to remain is still exactly
    // one column (i.e. GBL-084 did not accidentally cascade into
    // tenant_default and drop it too).
    {
        var rows = try conn.query(
            alloc,
            \\SELECT count(*) FROM information_schema.columns
            \\WHERE table_schema = 'tenant_default'
            \\  AND table_name = 'process_definitions'
            \\  AND column_name = 'tenant_id'
        ,
            &.{},
        );
        defer rows.deinit();
        try testing.expectEqual(@as(usize, 1), rows.rows.len);
        const count_str = rows.rows[0][0] orelse "0";
        const count = std.fmt.parseInt(usize, count_str, 10) catch 0;
        try testing.expectEqual(@as(usize, 1), count);
    }
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 3,
    });
}
