//! Integration tests for ENV-03 — Process definition promotion from test tenant
//! to production tenant.
//!
//! POST /api/v1/tenants/:test_tenant_id/promote/:definition_name
//!
//! Covers the domain function promoteDefinition() directly (no HTTP server required).
//! Calls exercise the full DB-backed promotion flow against a real PostgreSQL instance.
//!
//! Requires a real PostgreSQL database reachable at BPM_TEST_DB_URL.
//! Every test creates its own fixtures with per-test UUIDs and cleans up via defer.
//!
//! Requirement traceability:
//!   ENV-03 → TC-ENV-03-01 .. TC-ENV-03-06

const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const tenant_context = bpm.api_tenant_context;

// Root-level export required so pool connections apply tenant-schema search_path
// instead of falling back to search_path=public (see audit_iss103_test.zig).
pub const api_tenant_context = bpm.api_tenant_context;
const provisionTenantSchema = bpm.provisioning.provisionTenantSchema;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;
const promotion_mod = bpm.promotion_mod;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — ENV-03 integration tests FAILED (env var required)\n",
                .{},
            );
            return err;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 10xx
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

/// Insert a production tenant row into public.tenant.
/// Security: all values bound as parameters — no SQL string interpolation.
fn insertProductionTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
    slug: []const u8,
) !void {
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
    _ = allocator;
}

/// Insert a test tenant row into public.tenant.
/// Security: all values bound as parameters — no SQL string interpolation.
fn insertTestTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
    slug: []const u8,
    production_tenant_id: []const u8,
) !void {
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
    _ = allocator;
}

fn cleanupTenantById(pool: *Pool, tenant_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM public.tenant WHERE id = $1::uuid",
        &[_][]const u8{tenant_id},
    ) catch {};
}

fn dropTenantSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
) void {
    var schema_buf: [80]u8 = undefined;
    const schema_name = schemaNameForTenant(tenant_id, &schema_buf);
    const drop_sql = std.fmt.allocPrint(
        allocator,
        "DROP SCHEMA IF EXISTS {s} CASCADE",
        .{schema_name},
    ) catch return;
    defer allocator.free(drop_sql);

    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(drop_sql, &[_][]const u8{}) catch {};
    conn.exec(
        "DELETE FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &[_][]const u8{tenant_id},
    ) catch {};
    conn.exec(
        "DELETE FROM public.schema_migrations WHERE schema_name = $1",
        &[_][]const u8{schema_name},
    ) catch {};
}

/// A minimal graph that passes validateGraph() and validateNodeAttributes():
/// START → HUMAN_TASK (role=tester) → END
/// Note: attributes must be a JSON *string* (not a JSON object) because GraphNode.attributes
/// is ?[]const u8. Store the JSON-encoded object as a string literal.
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

/// Insert a process definition row directly in the active tenant schema.
/// Caller must have set tenant_context before acquiring the conn passed here.
/// Security: all values bound as parameters — no SQL string interpolation.
fn insertActiveDefinition(
    allocator: std.mem.Allocator,
    pool: *Pool,
    name: []const u8,
    actor_id: []const u8,
) ![]u8 {
    const def_id = try randomUuidStr(allocator);
    errdefer allocator.free(def_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO process_definitions
        \\    (id, tenant_id, name, version, description, status, graph, created_by)
        \\VALUES ($1::uuid, bpm_effective_tenant_id(), $2, '1',
        \\        'ENV-03 test definition', 'ACTIVE',
        \\        $3::jsonb,
        \\        $4::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ def_id, name, MINIMAL_VALID_GRAPH, actor_id },
    );

    return def_id;
}

/// Seed a user and grant them PROCESS_DESIGNER in the active tenant schema.
/// Caller must have set tenant_context before calling.
/// Security: user_id bound as $1::uuid — no SQL string interpolation.
fn seedUserWithDesignerRole(
    pool: *Pool,
    user_id: []const u8,
    username: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO users (id, email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1::uuid, $2||'@env03.test', 'ENV-03 Actor', 'nohash', true, $2, 'ACTIVE')
        \\ON CONFLICT (id) DO UPDATE SET
        \\  email = EXCLUDED.email,
        \\  display_name = EXCLUDED.display_name,
        \\  is_active = EXCLUDED.is_active,
        \\  username = EXCLUDED.username,
        \\  status = EXCLUDED.status
    ,
        &[_][]const u8{ user_id, username },
    );

    try conn.exec(
        \\INSERT INTO user_roles (user_id, role_id)
        \\SELECT $1::uuid, id FROM roles WHERE name = 'PROCESS_DESIGNER'
        \\ON CONFLICT (user_id, role_id) DO NOTHING
    ,
        &[_][]const u8{user_id},
    );
}

// ---------------------------------------------------------------------------
// TC-ENV-03-01 + TC-ENV-03-02 (happy path + audit entries)
// ---------------------------------------------------------------------------

test "TC-ENV-03-01: promoteDefinition returns DRAFT PromotionResult with valid definition_id" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);
    const actor_id = "00000000-0000-0000-0000-000000000099";

    // LIFO: prod_id must be declared FIRST so it runs LAST (after test_id is deleted).
    // ON DELETE RESTRICT blocks deleting a production tenant while test tenants reference it.
    defer dropTenantSchema(alloc, &pool, prod_id);
    defer dropTenantSchema(alloc, &pool, test_id);
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(alloc, &pool, prod_id, prod_id);
    try insertTestTenant(alloc, &pool, test_id, test_id, prod_id);

    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, test_id, migrationsDir());

    // Seed actor with PROCESS_DESIGNER on both schemas.
    tenant_context.set(test_id);
    try seedUserWithDesignerRole(&pool, actor_id, "actor-env03-01");

    tenant_context.set(prod_id);
    try seedUserWithDesignerRole(&pool, actor_id, "actor-env03-01");

    // Insert ACTIVE definition in T-test's schema.
    tenant_context.set(test_id);
    const def_id = try insertActiveDefinition(alloc, &pool, "env03-happy-proc", actor_id);
    defer alloc.free(def_id);

    tenant_context.clear();

    // Call promoteDefinition.
    const result = try promotion_mod.promoteDefinition(
        alloc,
        &pool,
        test_id,
        "env03-happy-proc",
        actor_id,
    );
    defer result.deinit(alloc);

    // Verify result.
    try testing.expectEqualStrings("DRAFT", result.status);
    try testing.expect(result.definition_id.len > 0);

    // Verify the promoted definition exists in T's schema with status='DRAFT'.
    tenant_context.set(prod_id);
    const conn = try pool.acquire();
    defer pool.release(conn);

    const check_row = try conn.queryRow(
        alloc,
        \\SELECT status FROM process_definitions
        \\WHERE id = $1::uuid
    ,
        &[_][]const u8{result.definition_id},
    );
    defer if (check_row) |r| {
        for (r) |col| if (col) |v| alloc.free(v);
        alloc.free(r);
    };

    try testing.expect(check_row != null);
    const status = check_row.?[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("DRAFT", status);

    tenant_context.clear();
}

test "TC-ENV-03-02: promoteDefinition writes DEFINITION_PROMOTED audit entries on both tenants" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);
    const actor_id = "00000000-0000-0000-0000-000000000098";

    // LIFO: prod_id declared first so it runs LAST (after test_id deleted) — ON DELETE RESTRICT
    defer dropTenantSchema(alloc, &pool, prod_id);
    defer dropTenantSchema(alloc, &pool, test_id);
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(alloc, &pool, prod_id, prod_id);
    try insertTestTenant(alloc, &pool, test_id, test_id, prod_id);

    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, test_id, migrationsDir());

    tenant_context.set(test_id);
    try seedUserWithDesignerRole(&pool, actor_id, "actor-env03-02");

    tenant_context.set(prod_id);
    try seedUserWithDesignerRole(&pool, actor_id, "actor-env03-02");

    tenant_context.set(test_id);
    const def_id = try insertActiveDefinition(alloc, &pool, "env03-audit-proc", actor_id);
    defer alloc.free(def_id);

    tenant_context.clear();

    const result = try promotion_mod.promoteDefinition(
        alloc,
        &pool,
        test_id,
        "env03-audit-proc",
        actor_id,
    );
    defer result.deinit(alloc);

    // Check audit entry on T-test schema.
    tenant_context.set(test_id);
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const audit_row = try conn.queryRow(
            alloc,
            \\SELECT COUNT(*)::text
            \\FROM audit_entries
            \\WHERE action = 'DEFINITION_PROMOTED'
        ,
            &[_][]const u8{},
        );
        defer if (audit_row) |r| {
            for (r) |col| if (col) |v| alloc.free(v);
            alloc.free(r);
        };
        try testing.expect(audit_row != null);
        const cnt_str = audit_row.?[0] orelse "0";
        const cnt = try std.fmt.parseInt(i64, cnt_str, 10);
        try testing.expect(cnt > 0);
    }

    // Check audit entry on T (production) schema.
    tenant_context.set(prod_id);
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const audit_row = try conn.queryRow(
            alloc,
            \\SELECT COUNT(*)::text
            \\FROM audit_entries
            \\WHERE action = 'DEFINITION_PROMOTED'
        ,
            &[_][]const u8{},
        );
        defer if (audit_row) |r| {
            for (r) |col| if (col) |v| alloc.free(v);
            alloc.free(r);
        };
        try testing.expect(audit_row != null);
        const cnt_str = audit_row.?[0] orelse "0";
        const cnt = try std.fmt.parseInt(i64, cnt_str, 10);
        try testing.expect(cnt > 0);
    }

    tenant_context.clear();
}

// ---------------------------------------------------------------------------
// TC-ENV-03-03
// ---------------------------------------------------------------------------

test "TC-ENV-03-03: promoteDefinition returns ActiveDefinitionNotFound when name does not exist" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);
    const actor_id = "00000000-0000-0000-0000-000000000097";

    // LIFO: prod_id declared first so it runs LAST — ON DELETE RESTRICT
    defer dropTenantSchema(alloc, &pool, prod_id);
    defer dropTenantSchema(alloc, &pool, test_id);
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(alloc, &pool, prod_id, prod_id);
    try insertTestTenant(alloc, &pool, test_id, test_id, prod_id);

    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, test_id, migrationsDir());

    tenant_context.set(test_id);
    try seedUserWithDesignerRole(&pool, actor_id, "actor-env03-03");

    tenant_context.set(prod_id);
    try seedUserWithDesignerRole(&pool, actor_id, "actor-env03-03");

    tenant_context.clear();

    // No ACTIVE definition named "nonexistent" in T-test.
    const result = promotion_mod.promoteDefinition(
        alloc,
        &pool,
        test_id,
        "nonexistent-process",
        actor_id,
    );

    try testing.expectError(promotion_mod.PromotionError.ActiveDefinitionNotFound, result);
}

// ---------------------------------------------------------------------------
// TC-ENV-03-04
// ---------------------------------------------------------------------------

test "TC-ENV-03-04: promoteDefinition returns MissingDesignerRoleOnProd when actor lacks role on prod" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);
    const actor_id = "00000000-0000-0000-0000-000000000096";

    // LIFO: prod_id declared first so it runs LAST — ON DELETE RESTRICT
    defer dropTenantSchema(alloc, &pool, prod_id);
    defer dropTenantSchema(alloc, &pool, test_id);
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(alloc, &pool, prod_id, prod_id);
    try insertTestTenant(alloc, &pool, test_id, test_id, prod_id);

    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, test_id, migrationsDir());

    // Seed actor with PROCESS_DESIGNER ONLY on T-test — NOT on T (production).
    tenant_context.set(test_id);
    try seedUserWithDesignerRole(&pool, actor_id, "actor-env03-04");

    // Insert ACTIVE definition in T-test.
    const def_id = try insertActiveDefinition(alloc, &pool, "env03-role-test-proc", actor_id);
    defer alloc.free(def_id);

    tenant_context.clear();

    // Call without role on production → must return MissingDesignerRoleOnProd.
    const result = promotion_mod.promoteDefinition(
        alloc,
        &pool,
        test_id,
        "env03-role-test-proc",
        actor_id,
    );

    try testing.expectError(promotion_mod.PromotionError.MissingDesignerRoleOnProd, result);
}

// ---------------------------------------------------------------------------
// TC-ENV-03-05 (version increment)
// ---------------------------------------------------------------------------

test "TC-ENV-03-05: promoteDefinition increments version when name already exists on production" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);
    const actor_id = "00000000-0000-0000-0000-000000000095";

    // LIFO: prod_id declared first so it runs LAST — ON DELETE RESTRICT
    defer dropTenantSchema(alloc, &pool, prod_id);
    defer dropTenantSchema(alloc, &pool, test_id);
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(alloc, &pool, prod_id, prod_id);
    try insertTestTenant(alloc, &pool, test_id, test_id, prod_id);

    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, test_id, migrationsDir());

    tenant_context.set(test_id);
    try seedUserWithDesignerRole(&pool, actor_id, "actor-env03-05");
    tenant_context.set(prod_id);
    try seedUserWithDesignerRole(&pool, actor_id, "actor-env03-05");

    // Pre-seed an existing DRAFT on production with version='1'.
    // Security: all values bound as parameters.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const pre_id = try randomUuidStr(alloc);
        defer alloc.free(pre_id);
        try conn.exec(
            \\INSERT INTO process_definitions
            \\    (id, tenant_id, name, version, description, status, graph, created_by)
            \\VALUES ($1::uuid, bpm_effective_tenant_id(), 'env03-version-proc', '1',
            \\        'pre-existing', 'DRAFT',
            \\        $2::jsonb,
            \\        $3::uuid)
            \\ON CONFLICT (id) DO NOTHING
        ,
            &[_][]const u8{ pre_id, MINIMAL_VALID_GRAPH, actor_id },
        );
    }

    // Insert ACTIVE definition in T-test.
    tenant_context.set(test_id);
    const def_id = try insertActiveDefinition(alloc, &pool, "env03-version-proc", actor_id);
    defer alloc.free(def_id);

    tenant_context.clear();

    const result = try promotion_mod.promoteDefinition(
        alloc,
        &pool,
        test_id,
        "env03-version-proc",
        actor_id,
    );
    defer result.deinit(alloc);

    // Version must be > 1 (incremented past the existing '1').
    const version_num = try std.fmt.parseInt(u32, result.version, 10);
    try testing.expect(version_num > 1);
    try testing.expectEqualStrings("DRAFT", result.status);
}

// ---------------------------------------------------------------------------
// TC-ENV-03-06
// ---------------------------------------------------------------------------

test "TC-ENV-03-06: promoteDefinition returns ProductionTenantInactive when prod tenant is INACTIVE" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);
    const actor_id = "00000000-0000-0000-0000-000000000094";

    // LIFO: prod_id declared first so it runs LAST — ON DELETE RESTRICT
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    // Insert production tenant with status='INACTIVE'.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\INSERT INTO public.tenant
            \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
            \\VALUES ($1::uuid, $1::text, $1::text, 'INACTIVE', NULL, 'production', NULL)
            \\ON CONFLICT (id) DO NOTHING
        ,
            &[_][]const u8{prod_id},
        );
    }
    try insertTestTenant(alloc, &pool, test_id, test_id, prod_id);

    // No schema provisioning needed — check fails before any schema access.
    tenant_context.clear();

    const result = promotion_mod.promoteDefinition(
        alloc,
        &pool,
        test_id,
        "any-process",
        actor_id,
    );

    try testing.expectError(promotion_mod.PromotionError.ProductionTenantInactive, result);
}
