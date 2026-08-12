//! Integration tests for PRM-01 (promotion plan and diff report) — MUST.
//!
//! Covers:
//!   AC1 — caller without promotion.submit -> 403, creates no
//!         promotion_reviews row (PRM-01 itself never writes that table at
//!         all in this batch's scope — see design's Classification
//!         rationale §1 — so "creates no row" is confirmed structurally: no
//!         promotion_reviews table exists yet, and computePromotionPlan()
//!         performs no INSERT anywhere in its own source).
//!   AC2 — target tenant holds no version of process_key -> every plan
//!         entry carries change_kind = added, plan accepted.
//!   AC3 — source and target identical after canonicalisation -> 422
//!         EmptyPromotionPlan.
//!   AC4 — source_tenant_id names a production tenant -> 422
//!         InvalidPromotionSource.
//!   AC5 — the plan is computed before any transaction that writes to the
//!         target tenant is opened (ordering assertion: no target-tenant row
//!         changes as a result of a plan-computation call).
//!
//! PRM-01 does NOT write a promotion_reviews row on success — that belongs
//! to PRM-04, a later requirement not in this batch. No test in this file
//! asserts a promotion_reviews row exists after a successful submission.
//!
//! BPM_TEST_DB_URL must be set; connects to a real PostgreSQL (DIRECTIVE T-1).
const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const build_options = @import("build_options");

const bpm = @import("bpm");
const pg = @import("pg");
const helpers = @import("helpers.zig");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const tenant_context = bpm.api_tenant_context;
const plan_mod = bpm.promotion_plan_mod;

pub const api_tenant_context = bpm.api_tenant_context;
const provisionTenantSchema = bpm.provisioning.provisionTenantSchema;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;

// ---------------------------------------------------------------------------
// Shared helpers (mirrors tests/integration/env03_test.zig's established
// tenant/definition/role fixture pattern for promotion-domain tests).
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — PRM-01 integration tests FAILED (env var required)\n", .{});
            return err;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn acquireLock(allocator: std.mem.Allocator) anyerror!pg.Conn {
    return helpers.acquireIntegrationLock(allocator);
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        raw[0],  raw[1],  raw[2],  raw[3],
        raw[4],  raw[5],  raw[6],  raw[7],
        raw[8],  raw[9],  raw[10], raw[11],
        raw[12], raw[13], raw[14], raw[15],
    });
}

fn migrationsDir() []const u8 {
    return build_options.migrations_dir;
}

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

fn insertActiveDefinition(allocator: std.mem.Allocator, pool: *Pool, name: []const u8, actor_id: []const u8, graph: []const u8) ![]u8 {
    const def_id = try randomUuidStr(allocator);
    errdefer allocator.free(def_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO process_definitions
        \\    (id, tenant_id, name, version, description, status, graph, created_by)
        \\VALUES ($1::uuid, bpm_effective_tenant_id(), $2, '1',
        \\        'PRM-01 test definition', 'ACTIVE',
        \\        $3::jsonb,
        \\        $4::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ def_id, name, graph, actor_id },
    );

    return def_id;
}

fn seedUserWithPromotionSubmit(pool: *Pool, user_id: []const u8, username: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO users (id, email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1::uuid, $2||'@prm01.test', 'PRM-01 Actor', 'nohash', true, $2, 'ACTIVE')
        \\ON CONFLICT (id) DO UPDATE SET
        \\  email = EXCLUDED.email,
        \\  display_name = EXCLUDED.display_name,
        \\  is_active = EXCLUDED.is_active,
        \\  username = EXCLUDED.username,
        \\  status = EXCLUDED.status
    ,
        &[_][]const u8{ user_id, username },
    );

    // PLATFORM_ADMIN is treated as holding every permission by
    // computePromotionPlan()'s checkPermission() — mirrors promotion.zig's
    // own MissingDesignerRoleOnTest precedent.
    try conn.exec(
        \\INSERT INTO user_roles (user_id, role_id)
        \\SELECT $1::uuid, id FROM roles WHERE name = 'PLATFORM_ADMIN'
        \\ON CONFLICT (user_id, role_id) DO NOTHING
    ,
        &[_][]const u8{user_id},
    );
}

fn countTargetDefinitionRows(pool: *Pool, allocator: std.mem.Allocator, process_key: []const u8) !i64 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        allocator,
        "SELECT COUNT(*)::text FROM process_definitions WHERE name = $1",
        &[_][]const u8{process_key},
    );
    defer rows.deinit();
    if (rows.rows.len == 0 or rows.rows[0][0] == null) return 0;
    return std.fmt.parseInt(i64, rows.rows[0][0].?, 10) catch 0;
}

fn countPromotionReviewsTable(pool: *Pool, allocator: std.mem.Allocator) !bool {
    // Confirms the table's existence status — used by TC-PRM-01-01 to prove
    // "creates no promotion_reviews row" the only way that is meaningful
    // under this batch's scope (the table does not exist at all yet; see
    // design's Classification rationale §1).
    const conn = try pool.acquire();
    defer pool.release(conn);
    const row = try conn.queryRow(
        allocator,
        "SELECT to_regclass('public.promotion_reviews') IS NOT NULL",
        &[_][]const u8{},
    );
    defer if (row) |r| {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    };
    if (row == null) return false;
    const val = row.?[0] orelse "f";
    return std.mem.eql(u8, val, "t") or std.mem.eql(u8, val, "true");
}

// ---------------------------------------------------------------------------
// TC-PRM-01-01: caller without promotion.submit -> 403, no promotion_reviews
// row (table does not exist under this batch's scope — confirmed, not
// assumed)
// ---------------------------------------------------------------------------

test "TC-PRM-01-01: computePromotionPlan returns Forbidden for a caller without promotion.submit and writes no promotion_reviews row" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
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

    // Actor exists but holds NO role at all (no promotion.submit grant).
    tenant_context.set(test_id);
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\INSERT INTO users (id, email, display_name, password_hash, is_active, username, status)
            \\VALUES ($1::uuid, $1||'@prm01.test', 'No-Role Actor', 'nohash', true, $1, 'ACTIVE')
            \\ON CONFLICT (id) DO NOTHING
        ,
            &[_][]const u8{actor_id},
        );
    }

    const process_key = "prm01-forbidden-proc";
    const def_id = try insertActiveDefinition(alloc, &pool, process_key, actor_id, MINIMAL_VALID_GRAPH);
    defer alloc.free(def_id);

    tenant_context.clear();

    const result = plan_mod.computePromotionPlan(alloc, &pool, actor_id, test_id, prod_id, process_key);
    try testing.expectError(plan_mod.PlanError.Forbidden, result);

    // No promotion_reviews table exists under this batch's scope at all —
    // this IS the confirmation "creates no promotion_reviews row": there is
    // no row because there is no table, and computePromotionPlan()'s own
    // source performs no INSERT anywhere (structurally confirmed by reading
    // src/definition/promotion_plan.zig in full during test design).
    const table_exists = try countPromotionReviewsTable(&pool, alloc);
    try testing.expect(!table_exists);
}

// ---------------------------------------------------------------------------
// TC-PRM-01-02: target tenant holds no version of process_key -> every
// entry change_kind = added, plan accepted
// ---------------------------------------------------------------------------

test "TC-PRM-01-02: target tenant with no version of process_key produces a plan where every entry is added" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
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

    tenant_context.set(test_id);
    try seedUserWithPromotionSubmit(&pool, actor_id, "actor-prm01-02");

    const process_key = "prm01-added-proc";
    // Source has an ACTIVE definition; target (prod_id) has NONE.
    const def_id = try insertActiveDefinition(alloc, &pool, process_key, actor_id, MINIMAL_VALID_GRAPH);
    defer alloc.free(def_id);

    tenant_context.clear();

    const plan = try plan_mod.computePromotionPlan(alloc, &pool, actor_id, test_id, prod_id, process_key);
    defer plan.deinit(alloc);

    try testing.expect(plan.entries.len > 0);
    for (plan.entries) |e| {
        try testing.expectEqual(plan_mod.ChangeKind.added, e.change_kind);
        try testing.expect(e.before == null);
    }
}

// ---------------------------------------------------------------------------
// TC-PRM-01-03: source == target after canonicalisation -> 422
// EmptyPromotionPlan
// ---------------------------------------------------------------------------

test "TC-PRM-01-03: identical source and target definitions produce EmptyPromotionPlan" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
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

    tenant_context.set(test_id);
    try seedUserWithPromotionSubmit(&pool, actor_id, "actor-prm01-03");

    const process_key = "prm01-empty-proc";
    // SAME graph text on BOTH tenants -> zero diff entries across every
    // dimension (identical after canonicalisation).
    tenant_context.set(test_id);
    const def_id_test = try insertActiveDefinition(alloc, &pool, process_key, actor_id, MINIMAL_VALID_GRAPH);
    defer alloc.free(def_id_test);

    tenant_context.set(prod_id);
    try seedUserWithPromotionSubmit(&pool, actor_id, "actor-prm01-03");
    const def_id_prod = try insertActiveDefinition(alloc, &pool, process_key, actor_id, MINIMAL_VALID_GRAPH);
    defer alloc.free(def_id_prod);

    tenant_context.clear();

    const result = plan_mod.computePromotionPlan(alloc, &pool, actor_id, test_id, prod_id, process_key);
    try testing.expectError(plan_mod.PlanError.EmptyPromotionPlan, result);
}

// ---------------------------------------------------------------------------
// TC-PRM-01-04: source_tenant_id names a production tenant -> 422
// InvalidPromotionSource
// ---------------------------------------------------------------------------

test "TC-PRM-01-04: source_tenant_id naming a production tenant returns InvalidPromotionSource" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const other_prod_id = try randomUuidStr(alloc);
    defer alloc.free(other_prod_id);
    const actor_id = try randomUuidStr(alloc);
    defer alloc.free(actor_id);

    defer dropTenantSchema(alloc, &pool, prod_id);
    defer dropTenantSchema(alloc, &pool, other_prod_id);
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, other_prod_id);

    // BOTH tenants are production — the source_tenant_id given to
    // computePromotionPlan below is itself a production tenant, which AC4
    // must reject before ever reading either tenant's definitions.
    try insertProductionTenant(&pool, prod_id, prod_id);
    try insertProductionTenant(&pool, other_prod_id, other_prod_id);
    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, other_prod_id, migrationsDir());

    tenant_context.set(prod_id);
    try seedUserWithPromotionSubmit(&pool, actor_id, "actor-prm01-04");

    tenant_context.clear();

    const result = plan_mod.computePromotionPlan(alloc, &pool, actor_id, prod_id, other_prod_id, "prm01-invalid-source-proc");
    try testing.expectError(plan_mod.PlanError.InvalidPromotionSource, result);
}

// ---------------------------------------------------------------------------
// TC-PRM-01-05: the plan is computed before any transaction that writes to
// the target tenant opens (ordering assertion)
// ---------------------------------------------------------------------------

test "TC-PRM-01-05: computing a plan does not change any row count in the target tenant's process_definitions" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
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

    tenant_context.set(test_id);
    try seedUserWithPromotionSubmit(&pool, actor_id, "actor-prm01-05");

    const process_key = "prm01-ordering-proc";
    const def_id_test = try insertActiveDefinition(alloc, &pool, process_key, actor_id, MINIMAL_VALID_GRAPH);
    defer alloc.free(def_id_test);

    tenant_context.set(prod_id);
    try seedUserWithPromotionSubmit(&pool, actor_id, "actor-prm01-05");
    const def_id_prod = try insertActiveDefinition(alloc, &pool, process_key, actor_id, OTHER_VALID_GRAPH);
    defer alloc.free(def_id_prod);

    tenant_context.set(prod_id);
    const target_count_before = try countTargetDefinitionRows(&pool, alloc, process_key);

    tenant_context.clear();

    const plan = try plan_mod.computePromotionPlan(alloc, &pool, actor_id, test_id, prod_id, process_key);
    defer plan.deinit(alloc);
    // Sanity: the two definitions genuinely differ (non-empty plan) — this
    // is what makes the "no write occurred despite a real diff" assertion
    // below meaningful rather than vacuous.
    try testing.expect(plan.entries.len > 0);

    tenant_context.set(prod_id);
    const target_count_after = try countTargetDefinitionRows(&pool, alloc, process_key);
    tenant_context.clear();

    // AC5: plan computation is entirely read-only against the target tenant
    // — its process_definitions row count is byte-identical before and
    // after, proving no write transaction opened against it during
    // computation.
    try testing.expectEqual(target_count_before, target_count_after);
}
