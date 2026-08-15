//! Integration tests for PRM-02: conflict pre-flight rejection.
//!
//! Covers every MUST acceptance criterion of PRM-02:
//!   AC1 — target active version > base_version -> HTTP 409 PROMOTION_CONFLICT
//!         with a per-definition body {definition_id, source_change, target_change}
//!   AC2 — exactly one DEFINITION_PROMOTION_REJECTED event appended; target
//!         active version pointer unchanged
//!   AC3 — no promotion_reviews / promotion_assertion_runs row created on conflict
//!   AC4 — the rejection event is committed in its own independent transaction
//!         (no transaction held open against the target tenant schema)
//!   AC5 — the conflict check runs before the digest/review insert (no review
//!         row and no approval/apply event can exist when the conflict fires)
//!
//! Tenant strategy: domain-level tests route through the default tenant
//! (all-zeros UUID -> tenant_default, provisioned by helpers.ensureSchemaReady),
//! which is the platform's shared test tenant. Every fixture uses a random
//! process_key / promotion_id so no two tests or runs collide; every test
//! cleans up its rows via `defer`. The HTTP 409 test provisions two real test
//! tenants (source + target) because the full submit path (computePromotionPlan)
//! requires a test source tenant with an ACTIVE definition.
//!
//! No error.SkipZigTest on MUST requirements. BPM_TEST_DB_URL must be set;
//! tests fail with error.MissingTestDatabaseUrl when absent (DIRECTIVE T-1).
//!
//! Build: `zig build test-integration-prm02`

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const build_options = @import("build_options");

const bpm = @import("bpm");
const helpers = @import("helpers.zig");

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const api_tenant_context = bpm.api_tenant_context;

const conflict_mod = bpm.promotion_conflict_mod;
const review_routes = bpm.promotion_review_routes;
const auth = bpm.api_auth;

const provisionTenantSchema = bpm.provisioning.provisionTenantSchema;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;

const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

// ---------------------------------------------------------------------------
// DB URL + pool helpers
// ---------------------------------------------------------------------------

fn getDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — PRM-02 integration tests FAILED (env var required)\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    api_tenant_context.set(DEFAULT_TENANT_ID);
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]const u8 {
    return helpers.uuidBytesToString(allocator, helpers.randomUuidBytes());
}

fn migrationsDir() []const u8 {
    return build_options.migrations_dir;
}

// ---------------------------------------------------------------------------
// Default-tenant fixture helpers (domain-level tests)
// ---------------------------------------------------------------------------

/// Insert an ACTIVE process definition into the default tenant schema.
fn insertActiveProcessDef(pool: *Pool, def_id: []const u8, name: []const u8, version: u32) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    const version_str = try std.fmt.allocPrint(testing.allocator, "{d}", .{version});
    defer testing.allocator.free(version_str);
    try conn.exec(
        \\INSERT INTO process_definitions
        \\    (id, tenant_id, name, version, description, status, graph, created_by)
        \\VALUES ($1::uuid, $2::uuid, $3, $4, 'PRM-02 test', 'ACTIVE',
        \\        '{"nodes":[],"edges":[]}'::jsonb, $2::uuid)
        \\ON CONFLICT (id) DO UPDATE SET status = 'ACTIVE', version = EXCLUDED.version
    ,
        &[_][]const u8{ def_id, DEFAULT_TENANT_ID, name, version_str },
    );
}

fn deleteProcessDefById(pool: *Pool, def_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE id = $1::uuid", &[_][]const u8{def_id}) catch {};
}

// ---------------------------------------------------------------------------
// Count helpers (tenant_default)
// ---------------------------------------------------------------------------

fn countRows(pool: *Pool, allocator: std.mem.Allocator, sql: []const u8, params: []const []const u8) !i64 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(allocator, sql, params);
    defer rows.deinit();
    if (rows.rows.len == 0 or rows.rows[0][0] == null) return 0;
    return std.fmt.parseInt(i64, rows.rows[0][0].?, 10) catch 0;
}

fn countRejectionEvents(pool: *Pool, allocator: std.mem.Allocator, promotion_id: []const u8) !i64 {
    const idem_key = try std.fmt.allocPrint(allocator, "DEFINITION_PROMOTION_REJECTED-{s}", .{promotion_id});
    defer allocator.free(idem_key);
    return countRows(pool, allocator,
        \\SELECT COUNT(*)::text FROM events
        \\WHERE event_type = 'DEFINITION_PROMOTION_REJECTED' AND idempotency_key = $1
    , &.{idem_key});
}

fn countRejectionIdemRows(pool: *Pool, allocator: std.mem.Allocator, promotion_id: []const u8) !i64 {
    const idem_key = try std.fmt.allocPrint(allocator, "DEFINITION_PROMOTION_REJECTED-{s}", .{promotion_id});
    defer allocator.free(idem_key);
    return countRows(pool, allocator,
        \\SELECT COUNT(*)::text FROM plat_event_idempotency WHERE idempotency_key = $1
    , &.{idem_key});
}

fn countReviewsForProcess(pool: *Pool, allocator: std.mem.Allocator, process_key: []const u8) !i64 {
    return countRows(pool, allocator,
        \\SELECT COUNT(*)::text FROM promotion_reviews
        \\WHERE tenant_id = $1::uuid AND def_id = $2
    , &.{ DEFAULT_TENANT_ID, process_key });
}

fn countAssertionRunsForProcess(pool: *Pool, allocator: std.mem.Allocator, process_key: []const u8) !i64 {
    return countRows(pool, allocator,
        \\SELECT COUNT(*)::text FROM promotion_assertion_runs
        \\WHERE tenant_id = $1::uuid AND review_id IN (
        \\    SELECT id FROM promotion_reviews WHERE tenant_id = $1::uuid AND def_id = $2
        \\)
    , &.{ DEFAULT_TENANT_ID, process_key });
}

fn countPromotionEventsForProcess(pool: *Pool, allocator: std.mem.Allocator, process_key: []const u8) !i64 {
    // Counts DEFINITION_PROMOTION_APPROVED / APPLIED for this process — must be 0 on conflict.
    return countRows(pool, allocator,
        \\SELECT COUNT(*)::text FROM events
        \\WHERE tenant_id = $1::uuid
        \\  AND event_type IN ('DEFINITION_PROMOTION_APPROVED','DEFINITION_PROMOTION_APPLIED')
        \\  AND payload->>'process_key' = $2
    , &.{ DEFAULT_TENANT_ID, process_key });
}

fn getActiveVersion(pool: *Pool, allocator: std.mem.Allocator, process_key: []const u8) !?u32 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    const row = try conn.queryRow(allocator,
        \\SELECT (version::int)::text FROM process_definitions
        \\WHERE tenant_id = $1::uuid AND name = $2 AND status = 'ACTIVE' LIMIT 1
    , &.{ DEFAULT_TENANT_ID, process_key });
    defer if (row) |r| {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    };
    if (row == null or row.?[0] == null) return null;
    return std.fmt.parseInt(u32, row.?[0].?, 10) catch null;
}

fn cleanupRejectionEvent(pool: *Pool, allocator: std.mem.Allocator, promotion_id: []const u8) void {
    const idem_key = std.fmt.allocPrint(allocator, "DEFINITION_PROMOTION_REJECTED-{s}", .{promotion_id}) catch return;
    defer allocator.free(idem_key);
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM plat_event_idempotency WHERE idempotency_key = $1", &.{idem_key}) catch {};
    conn.exec("DELETE FROM events WHERE idempotency_key = $1", &.{idem_key}) catch {};
}

// ---------------------------------------------------------------------------
// Provisioned-tenant fixture helpers (HTTP 409 test)
// ---------------------------------------------------------------------------

fn insertProductionTenant(pool: *Pool, tenant_id: []const u8, slug: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', NULL, 'production', NULL)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_id, slug, slug },
    );
}

fn insertTestTenant(pool: *Pool, tenant_id: []const u8, slug: []const u8, production_tenant_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', NULL, 'test', $4::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_id, slug, slug, production_tenant_id },
    );
}

fn cleanupTenantById(pool: *Pool, tenant_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM public.tenant WHERE id = $1::uuid", &[_][]const u8{tenant_id}) catch {};
}

fn dropTenantSchema(allocator: std.mem.Allocator, pool: *Pool, tenant_id: []const u8) void {
    var schema_buf: [80]u8 = undefined;
    const schema_name = schemaNameForTenant(tenant_id, &schema_buf);
    const drop_sql = std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_name}) catch return;
    defer allocator.free(drop_sql);

    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(drop_sql, &[_][]const u8{}) catch {};
    conn.exec("DELETE FROM public.tenant_schemas WHERE tenant_id = $1::uuid", &[_][]const u8{tenant_id}) catch {};
    conn.exec("DELETE FROM public.schema_migrations WHERE schema_name = $1", &[_][]const u8{schema_name}) catch {};
}

fn insertDefinitionInTenant(pool: *Pool, tenant_id: []const u8, name: []const u8, version: []const u8, graph: []const u8) !void {
    api_tenant_context.set(tenant_id);
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO process_definitions
        \\    (id, tenant_id, name, version, description, status, graph, created_by)
        \\VALUES (gen_random_uuid(), $1::uuid, $2, $3, 'PRM-02 test', 'ACTIVE',
        \\        $4::jsonb, $1::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_id, name, version, graph },
    );
}

fn seedUserWithPromotionSubmit(pool: *Pool, user_id: []const u8, username: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO users (id, email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1::uuid, $1||'@prm02.test', 'PRM-02 Actor', 'nohash', true, $2, 'ACTIVE')
        \\ON CONFLICT (id) DO UPDATE SET
        \\  email = EXCLUDED.email, display_name = EXCLUDED.display_name,
        \\  is_active = EXCLUDED.is_active, username = EXCLUDED.username, status = EXCLUDED.status
    ,
        &[_][]const u8{ user_id, username },
    );
    try conn.exec(
        \\INSERT INTO user_roles (user_id, role_id)
        \\SELECT $1::uuid, id FROM roles WHERE name = 'PLATFORM_ADMIN'
        \\ON CONFLICT (user_id, role_id) DO NOTHING
    ,
        &[_][]const u8{user_id},
    );
}

const MINIMAL_VALID_GRAPH =
    \\{"nodes":[
    \\  {"id":"S","node_type":"START","label":null,"attributes":null},
    \\  {"id":"T","node_type":"HUMAN_TASK","label":null,"attributes":"{\"role\":\"tester\"}"},
    \\  {"id":"E","node_type":"END","label":null,"attributes":null}
    \\],"edges":[
    \\  {"id":"e1","source":"S","target":"T","condition":null,"is_default":false},
    \\  {"id":"e2","source":"T","target":"E","condition":null,"is_default":false}
    \\]}
;

const OTHER_VALID_GRAPH =
    \\{"nodes":[
    \\  {"id":"S","node_type":"START","label":null,"attributes":null},
    \\  {"id":"T","node_type":"HUMAN_TASK","label":null,"attributes":"{\"role\":\"reviewer\"}"},
    \\  {"id":"E","node_type":"END","label":null,"attributes":null}
    \\],"edges":[
    \\  {"id":"e1","source":"S","target":"T","condition":null,"is_default":false},
    \\  {"id":"e2","source":"T","target":"E","condition":null,"is_default":false}
    \\]}
;

// ---------------------------------------------------------------------------
// TC-PRM-02-01: No conflict when target has no ACTIVE version
// ---------------------------------------------------------------------------

test "TC-PRM-02-01: no conflict when target has no ACTIVE version" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const process_key = try randomUuidStr(alloc);
    defer alloc.free(process_key);
    const promotion_id = try randomUuidStr(alloc);
    defer alloc.free(promotion_id);
    const actor_id = try randomUuidStr(alloc);
    defer alloc.free(actor_id);

    api_tenant_context.set(DEFAULT_TENANT_ID);

    const result = try conflict_mod.rejectIfConflicts(
        alloc,
        &pool,
        DEFAULT_TENANT_ID,
        process_key,
        1,
        promotion_id,
        DEFAULT_TENANT_ID,
        actor_id,
    );
    try testing.expect(result == null);

    // No rejection event may exist.
    const ev = try countRejectionEvents(&pool, alloc, promotion_id);
    try testing.expectEqual(@as(i64, 0), ev);
}

// ---------------------------------------------------------------------------
// TC-PRM-02-02: No conflict when target_version == base_version
// ---------------------------------------------------------------------------

test "TC-PRM-02-02: no conflict when target_version equals base_version" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const process_key = try randomUuidStr(alloc);
    defer alloc.free(process_key);
    const promotion_id = try randomUuidStr(alloc);
    defer alloc.free(promotion_id);
    const actor_id = try randomUuidStr(alloc);
    defer alloc.free(actor_id);
    const def_id = try randomUuidStr(alloc);
    defer alloc.free(def_id);

    defer deleteProcessDefById(&pool, def_id);

    try insertActiveProcessDef(&pool, def_id, process_key, 3);
    api_tenant_context.set(DEFAULT_TENANT_ID);

    const result = try conflict_mod.rejectIfConflicts(
        alloc,
        &pool,
        DEFAULT_TENANT_ID,
        process_key,
        3,
        promotion_id,
        DEFAULT_TENANT_ID,
        actor_id,
    );
    try testing.expect(result == null);

    const ev = try countRejectionEvents(&pool, alloc, promotion_id);
    try testing.expectEqual(@as(i64, 0), ev);
}

// ---------------------------------------------------------------------------
// TC-PRM-02-03: Conflict when target_version > base_version
// ---------------------------------------------------------------------------

test "TC-PRM-02-03: conflict when target_version > base_version returns typed rejection" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const process_key = try randomUuidStr(alloc);
    defer alloc.free(process_key);
    const promotion_id = try randomUuidStr(alloc);
    defer alloc.free(promotion_id);
    const actor_id = try randomUuidStr(alloc);
    defer alloc.free(actor_id);
    const def_id = try randomUuidStr(alloc);
    defer alloc.free(def_id);

    defer deleteProcessDefById(&pool, def_id);
    defer cleanupRejectionEvent(&pool, alloc, promotion_id);

    try insertActiveProcessDef(&pool, def_id, process_key, 5);
    api_tenant_context.set(DEFAULT_TENANT_ID);

    const result = try conflict_mod.rejectIfConflicts(
        alloc,
        &pool,
        DEFAULT_TENANT_ID,
        process_key,
        3,
        promotion_id,
        DEFAULT_TENANT_ID,
        actor_id,
    );
    try testing.expect(result != null);
    const rejection = result.?;
    defer rejection.deinit(alloc);

    try testing.expectEqual(@as(u32, 5), rejection.target_version);
    try testing.expectEqualStrings(def_id, rejection.target_definition_id);
    try testing.expect(std.mem.eql(u8, rejection.source_change, "branched from version 3"));
    try testing.expect(std.mem.eql(u8, rejection.target_change, "target is now at version 5"));
}

// ---------------------------------------------------------------------------
// TC-PRM-02-04: Multi-definition conflict names each conflicting definition
// ---------------------------------------------------------------------------

test "TC-PRM-02-04: rejectIfConflictsMulti returns one rejection per conflicting key" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conflict_key = try randomUuidStr(alloc);
    defer alloc.free(conflict_key);
    const clean_key = try randomUuidStr(alloc);
    defer alloc.free(clean_key);
    const promotion_id = try randomUuidStr(alloc);
    defer alloc.free(promotion_id);
    const actor_id = try randomUuidStr(alloc);
    defer alloc.free(actor_id);
    const def_id_conflict = try randomUuidStr(alloc);
    defer alloc.free(def_id_conflict);
    const def_id_clean = try randomUuidStr(alloc);
    defer alloc.free(def_id_clean);

    defer deleteProcessDefById(&pool, def_id_conflict);
    defer deleteProcessDefById(&pool, def_id_clean);
    defer cleanupRejectionEvent(&pool, alloc, promotion_id);

    // conflict_key is at version 4 (> base 2); clean_key is at version 2 (== base 2).
    try insertActiveProcessDef(&pool, def_id_conflict, conflict_key, 4);
    try insertActiveProcessDef(&pool, def_id_clean, clean_key, 2);
    api_tenant_context.set(DEFAULT_TENANT_ID);

    const keys = [_][]const u8{ conflict_key, clean_key };
    const base_versions = [_]u32{ 2, 2 };

    const rejections = try conflict_mod.rejectIfConflictsMulti(
        alloc,
        &pool,
        DEFAULT_TENANT_ID,
        &keys,
        &base_versions,
        promotion_id,
        DEFAULT_TENANT_ID,
        actor_id,
    );
    defer {
        for (rejections) |*r| r.deinit(alloc);
        alloc.free(rejections);
    }

    try testing.expectEqual(@as(usize, 1), rejections.len);
    try testing.expectEqualStrings(def_id_conflict, rejections[0].target_definition_id);
    try testing.expectEqual(@as(u32, 4), rejections[0].target_version);
}

// ---------------------------------------------------------------------------
// TC-PRM-02-05: HTTP 409 PROMOTION_CONFLICT body shape on conflict
// ---------------------------------------------------------------------------

test "TC-PRM-02-05: submit with conflict returns HTTP 409 with per-definition body and no review row" {
    // ORDER MATTERS (deadlock fix, TEST-RUNNER WF02-prm02-05-20260816 Step 4):
    // ensureSchemaReady MUST run BEFORE acquireIntegrationLock. Both acquire the
    // same `bpm_test_migrations_public` session advisory lock; acquireIntegrationLock
    // holds it for this test's full lifetime on a dedicated connection. If
    // ensureSchemaReady ran after it, its separate connection would block forever
    // on the lock the dedicated connection already holds — a deterministic
    // self-deadlock (observed live: connection A held the lock, connection B stuck
    // on pg_advisory_lock until the run was terminated).
    try helpers.ensureSchemaReady(testing.allocator);
    var lock_conn = try helpers.acquireIntegrationLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);
    const actor_id = try randomUuidStr(alloc);
    defer alloc.free(actor_id);

    defer dropTenantSchema(alloc, &pool, prod_id);
    defer dropTenantSchema(alloc, &pool, test_id);
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(&pool, prod_id, prod_id);
    try insertTestTenant(&pool, test_id, test_id, prod_id);
    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, test_id, migrationsDir());

    // Actor with promotion.submit (PLATFORM_ADMIN) in the source tenant.
    api_tenant_context.set(test_id);
    try seedUserWithPromotionSubmit(&pool, actor_id, "actor-prm02-05");

    const process_key = "prm02-conflict-proc";
    // Source ACTIVE at version 1 with MINIMAL_VALID_GRAPH.
    try insertDefinitionInTenant(&pool, test_id, process_key, "1", MINIMAL_VALID_GRAPH);
    // Target ACTIVE at version 3 with a DIFFERENT graph (plan non-empty) -> conflict with base_version=1.
    try insertDefinitionInTenant(&pool, prod_id, process_key, "3", OTHER_VALID_GRAPH);

    api_tenant_context.set(DEFAULT_TENANT_ID);

    const body = try std.fmt.allocPrint(alloc,
        \\{{"source_tenant_id":"{s}","target_tenant_id":"{s}","process_key":"{s}","base_version":1}}
    , .{ test_id, prod_id, process_key });
    defer alloc.free(body);

    const actor = auth.AuthContext{
        .user_id = actor_id,
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "test-token-prm02-05",
        .principal = "test-token-prm02-05",
    };
    const result = review_routes.handleSubmitPromotion(&pool, alloc, actor, body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 409), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "PROMOTION_CONFLICT") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "Target tenant has advanced past base_version") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "target_definition_id") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "source_change") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "target_change") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, process_key) != null);

    // AC3/AC5: no review row for the process anywhere.
    api_tenant_context.set(prod_id);
    const reviews = try countRows(&pool, alloc, "SELECT COUNT(*)::text FROM promotion_reviews WHERE tenant_id = $1::uuid AND def_id = $2", &.{ prod_id, process_key });
    try testing.expectEqual(@as(i64, 0), reviews);
}

// ---------------------------------------------------------------------------
// TC-PRM-02-06: Exactly one rejection event; target active pointer unchanged
// ---------------------------------------------------------------------------

test "TC-PRM-02-06: exactly one rejection event per promotion_id and target pointer unchanged" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const process_key = try randomUuidStr(alloc);
    defer alloc.free(process_key);
    const promotion_id = try randomUuidStr(alloc);
    defer alloc.free(promotion_id);
    const actor_id = try randomUuidStr(alloc);
    defer alloc.free(actor_id);
    const def_id = try randomUuidStr(alloc);
    defer alloc.free(def_id);

    defer deleteProcessDefById(&pool, def_id);
    defer cleanupRejectionEvent(&pool, alloc, promotion_id);

    try insertActiveProcessDef(&pool, def_id, process_key, 5);
    api_tenant_context.set(DEFAULT_TENANT_ID);

    // First call -> conflict + event appended.
    const r1 = try conflict_mod.rejectIfConflicts(alloc, &pool, DEFAULT_TENANT_ID, process_key, 3, promotion_id, DEFAULT_TENANT_ID, actor_id);
    try testing.expect(r1 != null);
    if (r1) |*rr| rr.deinit(alloc);

    // Second call with the same promotion_id -> idempotency: rejection returned, NO second event.
    const r2 = try conflict_mod.rejectIfConflicts(alloc, &pool, DEFAULT_TENANT_ID, process_key, 3, promotion_id, DEFAULT_TENANT_ID, actor_id);
    try testing.expect(r2 != null);
    if (r2) |*rr| rr.deinit(alloc);

    const ev = try countRejectionEvents(&pool, alloc, promotion_id);
    try testing.expectEqual(@as(i64, 1), ev);
    const idem = try countRejectionIdemRows(&pool, alloc, promotion_id);
    try testing.expectEqual(@as(i64, 1), idem);

    // Target active version pointer unchanged.
    const version = try getActiveVersion(&pool, alloc, process_key);
    try testing.expectEqual(@as(?u32, 5), version);
}

// ---------------------------------------------------------------------------
// TC-PRM-02-07: No promotion_reviews / promotion_assertion_runs row on conflict
// ---------------------------------------------------------------------------

test "TC-PRM-02-07: conflict creates no promotion_reviews or promotion_assertion_runs row" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const process_key = try randomUuidStr(alloc);
    defer alloc.free(process_key);
    const promotion_id = try randomUuidStr(alloc);
    defer alloc.free(promotion_id);
    const actor_id = try randomUuidStr(alloc);
    defer alloc.free(actor_id);
    const def_id = try randomUuidStr(alloc);
    defer alloc.free(def_id);

    defer deleteProcessDefById(&pool, def_id);
    defer cleanupRejectionEvent(&pool, alloc, promotion_id);

    try insertActiveProcessDef(&pool, def_id, process_key, 7);
    api_tenant_context.set(DEFAULT_TENANT_ID);

    const result = try conflict_mod.rejectIfConflicts(alloc, &pool, DEFAULT_TENANT_ID, process_key, 1, promotion_id, DEFAULT_TENANT_ID, actor_id);
    try testing.expect(result != null);
    if (result) |*rr| rr.deinit(alloc);

    const reviews = try countReviewsForProcess(&pool, alloc, process_key);
    try testing.expectEqual(@as(i64, 0), reviews);
    const runs = try countAssertionRunsForProcess(&pool, alloc, process_key);
    try testing.expectEqual(@as(i64, 0), runs);
}

// ---------------------------------------------------------------------------
// TC-PRM-02-08: Rejection event committed in its own independent transaction
// (AC4 + AC5 ordering)
// ---------------------------------------------------------------------------

test "TC-PRM-02-08: rejection event committed independently; no approval/apply event exists" {
    try helpers.ensureSchemaReady(testing.allocator);
    const alloc = testing.allocator;
    const url = try getDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const process_key = try randomUuidStr(alloc);
    defer alloc.free(process_key);
    const promotion_id = try randomUuidStr(alloc);
    defer alloc.free(promotion_id);
    const actor_id = try randomUuidStr(alloc);
    defer alloc.free(actor_id);
    const def_id = try randomUuidStr(alloc);
    defer alloc.free(def_id);

    defer deleteProcessDefById(&pool, def_id);
    defer cleanupRejectionEvent(&pool, alloc, promotion_id);

    try insertActiveProcessDef(&pool, def_id, process_key, 6);
    api_tenant_context.set(DEFAULT_TENANT_ID);

    const result = try conflict_mod.rejectIfConflicts(alloc, &pool, DEFAULT_TENANT_ID, process_key, 2, promotion_id, DEFAULT_TENANT_ID, actor_id);
    try testing.expect(result != null);
    if (result) |*rr| rr.deinit(alloc);

    // The event is committed in its own independent transaction: visible from a
    // fresh pool connection immediately (no open transaction against the target
    // schema at conflict time — AC4), exactly once.
    const ev = try countRejectionEvents(&pool, alloc, promotion_id);
    try testing.expectEqual(@as(i64, 1), ev);

    // Ordering (AC5): because the conflict fired first, no approval/apply event
    // and no review row can exist for this process.
    const promo_events = try countPromotionEventsForProcess(&pool, alloc, process_key);
    try testing.expectEqual(@as(i64, 0), promo_events);
    const reviews = try countReviewsForProcess(&pool, alloc, process_key);
    try testing.expectEqual(@as(i64, 0), reviews);
}
