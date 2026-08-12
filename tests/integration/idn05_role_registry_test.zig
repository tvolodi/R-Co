//! Integration tests for IDN-05 — Named role registry and ROLE assignee resolution.
//!
//! Tests cover:
//!   TC-IDN05-01: POST /roles creates a binding (200, correct body)
//!   TC-IDN05-02: POST /roles with unknown group_id → 404 GROUP_NOT_FOUND
//!   TC-IDN05-03: POST /roles upserts — same name, different group_id → 200
//!   TC-IDN05-04: GET /roles lists all bindings for calling tenant
//!   TC-IDN05-05: Tenant isolation — role in tenant A invisible to tenant B
//!   TC-IDN05-06: ROLE assignee resolved at task activation → GROUP semantics
//!   TC-IDN05-07: ROLE assignee unresolved → Task in PENDING (not ERROR)
//!
//! Requires BPM_TEST_DB_URL. Fails with a clear error when absent.
//! All fixtures use per-test UUIDs; defer cleanup runs even on failure.
//!
//! Requirement traceability:
//!   IDN-05 → TC-IDN05-01 .. TC-IDN05-07

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const pg = @import("pg");
const helpers = @import("helpers.zig");
const pool_mod = bpm.db_pool;
const auth_mod = bpm.api_auth;
const identity_registry = bpm.identity_registry;
const identity_service = bpm.identity_service;
const identity_routes = bpm.identity_routes;
const role_registry = bpm.role_registry;
const definition_mod = bpm.definition;
const snapshot_mod = bpm.snapshot;
const instance_mod = bpm.engine;
const task_mod = bpm.tasks;
const build_options = @import("build_options");
const provisioning_mod = bpm.provisioning;

fn makeCreatorUuid() [16]u8 {
    var bytes: bpm.uuid.Uuid = undefined;
    bpm.uuid.generateUuidV4BytesInto(&bytes);
    return bytes;
}

/// Read BPM_TEST_DB_URL; fails the test with a named error when absent.
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — IDN-05 integration tests FAILED (env var required)\n",
                .{},
            );
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !pool_mod.Pool {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return pool_mod.Pool.init(std.testing.io, allocator, .{ .url = url, .pool_size = 5 });
}

fn acquireLock(allocator: std.mem.Allocator) anyerror!pg.Conn {
    return helpers.acquireIntegrationLock(allocator);
}

fn adminActor() auth_mod.AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000001",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "integration-idn05-admin",
        .principal = "integration-idn05-admin",
    };
}

fn freeRouteBody(alloc: std.mem.Allocator, body: []const u8) void {
    const static_fallback = "{\"error\":\"internal_error\"}";
    if (!std.mem.eql(u8, body, static_fallback)) {
        alloc.free(body);
    }
}

fn uuidToHexStr(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

fn expectUuidLike(value: []const u8) !void {
    try testing.expectEqual(@as(usize, 36), value.len);
    try testing.expectEqual(@as(u8, '-'), value[8]);
    try testing.expectEqual(@as(u8, '-'), value[13]);
    try testing.expectEqual(@as(u8, '-'), value[18]);
    try testing.expectEqual(@as(u8, '-'), value[23]);
}

fn extractStringField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const value = parsed.value.object.get(field) orelse return error.FieldNotFound;
    if (value != .string) return error.FieldNotString;
    return allocator.dupe(u8, value.string);
}

/// Create a group via the identity route; returns caller-owned group_id string.
fn createGroupId(service: *identity_service.Service, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\"}}", .{name});
    defer allocator.free(body);
    const result = identity_routes.handleCreateGroup(service, allocator, adminActor(), body);
    defer freeRouteBody(allocator, result.body);
    try testing.expectEqual(@as(u16, 201), result.status_code);
    return extractStringField(allocator, result.body, "group_id");
}

fn cleanupGroupByName(pool: *pool_mod.Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM group_members WHERE group_id IN (SELECT id FROM groups WHERE name = $1)",
        &[_][]const u8{name},
    ) catch {};
    conn.exec("DELETE FROM groups WHERE name = $1", &[_][]const u8{name}) catch {};
}

fn cleanupRoleByName(pool: *pool_mod.Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM tenant_role WHERE name = $1", &[_][]const u8{name}) catch {};
}

fn cleanupDefinitionByName(pool: *pool_mod.Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &[_][]const u8{name}) catch {};
}

fn cleanupTenantSchema(allocator: std.mem.Allocator, pool: *pool_mod.Pool, tenant_id: []const u8, schema_name_str: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    const drop_sql = std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_name_str}) catch return;
    defer allocator.free(drop_sql);
    conn.exec(drop_sql, &.{}) catch {};
    conn.exec("DELETE FROM public.tenant_schemas WHERE tenant_id = $1::uuid", &[_][]const u8{tenant_id}) catch {};
    conn.exec("DELETE FROM public.tenant WHERE id = $1::uuid", &[_][]const u8{tenant_id}) catch {};
}

fn cleanupInstanceAndTasks(pool: *pool_mod.Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &[_][]const u8{instance_id_hex}) catch {};
    conn.exec("DELETE FROM tokens WHERE instance_id = $1::uuid", &[_][]const u8{instance_id_hex}) catch {};
    conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &[_][]const u8{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &[_][]const u8{instance_id_hex}) catch {};
    conn.exec("DELETE FROM process_snapshots WHERE instance_id = $1::uuid", &[_][]const u8{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_sequence WHERE instance_id = $1::uuid", &[_][]const u8{instance_id_hex}) catch {};
}

// ---------------------------------------------------------------------------
// TC-IDN05-01: POST /roles creates a binding — 200 with correct body
// ---------------------------------------------------------------------------

test "TC-IDN05-01: POST /roles creates a binding — 200 with id/name/group_id/created_at" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-idn05-01-group";
    const role_name = "TC-IDN05-01 Finance Approver";
    cleanupRoleByName(&pool, role_name);
    cleanupGroupByName(&pool, group_name);
    defer cleanupRoleByName(&pool, role_name);
    defer cleanupGroupByName(&pool, group_name);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_id = try createGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);

    var store = role_registry.TenantRoleStore.init(&pool);
    const req_body = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"group_id\":\"{s}\"}}", .{ role_name, group_id });
    defer alloc.free(req_body);
    const result = identity_routes.handleUpsertRole(&store, alloc, adminActor(), req_body);
    const body_owned = result.body;
    defer freeRouteBody(alloc, body_owned);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body_owned, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const obj = parsed.value.object;

    const id_val = obj.get("id") orelse return error.MissingField;
    const name_val = obj.get("name") orelse return error.MissingField;
    const gid_val = obj.get("group_id") orelse return error.MissingField;
    const cat_val = obj.get("created_at") orelse return error.MissingField;

    try testing.expect(id_val == .string);
    try expectUuidLike(id_val.string);
    try testing.expect(name_val == .string);
    try testing.expectEqualStrings(role_name, name_val.string);
    try testing.expect(gid_val == .string);
    try testing.expectEqualStrings(group_id, gid_val.string);
    try testing.expect(cat_val == .string);
    try testing.expect(cat_val.string.len > 0);
}

// ---------------------------------------------------------------------------
// TC-IDN05-02: POST /roles with unknown group_id → 404 GROUP_NOT_FOUND
// ---------------------------------------------------------------------------

test "TC-IDN05-02: POST /roles with unknown group_id returns 404 GROUP_NOT_FOUND" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Generate a fresh UUID that provably does not exist in the groups table.
    var nonexistent_raw: [16]u8 = undefined;
    bpm.uuid.generateUuidV4BytesInto(&nonexistent_raw);
    const nonexistent_group_id = try uuidToHexStr(alloc, nonexistent_raw);
    defer alloc.free(nonexistent_group_id);
    const role_name = "TC-IDN05-02 Nonexistent Role";

    var store = role_registry.TenantRoleStore.init(&pool);
    const body_str = try std.fmt.allocPrint(
        alloc,
        "{{\"name\":\"{s}\",\"group_id\":\"{s}\"}}",
        .{ role_name, nonexistent_group_id },
    );
    defer alloc.free(body_str);

    const result = identity_routes.handleUpsertRole(&store, alloc, adminActor(), body_str);
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 404), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "GROUP_NOT_FOUND") != null);
}

// ---------------------------------------------------------------------------
// TC-IDN05-03: POST /roles upserts — same name, different group_id → 200
// ---------------------------------------------------------------------------

test "TC-IDN05-03: POST /roles upserts — same name rebinds to new group_id" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_a_name = "tc-idn05-03-group-a";
    const group_b_name = "tc-idn05-03-group-b";
    const role_name = "TC-IDN05-03 IT Reviewer";
    cleanupRoleByName(&pool, role_name);
    cleanupGroupByName(&pool, group_a_name);
    cleanupGroupByName(&pool, group_b_name);
    defer cleanupRoleByName(&pool, role_name);
    defer cleanupGroupByName(&pool, group_a_name);
    defer cleanupGroupByName(&pool, group_b_name);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_a_id = try createGroupId(&service, alloc, group_a_name);
    defer alloc.free(group_a_id);
    const group_b_id = try createGroupId(&service, alloc, group_b_name);
    defer alloc.free(group_b_id);

    var store = role_registry.TenantRoleStore.init(&pool);

    // First upsert: create binding role_name → group_a.
    const body_a = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"group_id\":\"{s}\"}}", .{ role_name, group_a_id });
    defer alloc.free(body_a);
    const result_a = identity_routes.handleUpsertRole(&store, alloc, adminActor(), body_a);
    defer freeRouteBody(alloc, result_a.body);
    try testing.expectEqual(@as(u16, 200), result_a.status_code);

    // Second upsert: rebind role_name → group_b.
    const body_b = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"group_id\":\"{s}\"}}", .{ role_name, group_b_id });
    defer alloc.free(body_b);
    const result_b = identity_routes.handleUpsertRole(&store, alloc, adminActor(), body_b);
    defer freeRouteBody(alloc, result_b.body);
    try testing.expectEqual(@as(u16, 200), result_b.status_code);

    // Assert second response reflects new group_id.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result_b.body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const gid_val = parsed.value.object.get("group_id") orelse return error.MissingField;
    try testing.expect(gid_val == .string);
    try testing.expectEqualStrings(group_b_id, gid_val.string);
}

// ---------------------------------------------------------------------------
// TC-IDN05-04: GET /roles lists all bindings for calling tenant
// ---------------------------------------------------------------------------

test "TC-IDN05-04: GET /roles lists all bindings for calling tenant" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_alpha_name = "tc-idn05-04-group-alpha";
    const group_beta_name = "tc-idn05-04-group-beta";
    const role_alpha = "TC-IDN05-04 Role Alpha";
    const role_beta = "TC-IDN05-04 Role Beta";
    cleanupRoleByName(&pool, role_alpha);
    cleanupRoleByName(&pool, role_beta);
    cleanupGroupByName(&pool, group_alpha_name);
    cleanupGroupByName(&pool, group_beta_name);
    defer cleanupRoleByName(&pool, role_alpha);
    defer cleanupRoleByName(&pool, role_beta);
    defer cleanupGroupByName(&pool, group_alpha_name);
    defer cleanupGroupByName(&pool, group_beta_name);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const gid_alpha = try createGroupId(&service, alloc, group_alpha_name);
    defer alloc.free(gid_alpha);
    const gid_beta = try createGroupId(&service, alloc, group_beta_name);
    defer alloc.free(gid_beta);

    var store = role_registry.TenantRoleStore.init(&pool);

    const body_alpha = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"group_id\":\"{s}\"}}", .{ role_alpha, gid_alpha });
    defer alloc.free(body_alpha);
    const r_alpha = identity_routes.handleUpsertRole(&store, alloc, adminActor(), body_alpha);
    defer freeRouteBody(alloc, r_alpha.body);
    try testing.expectEqual(@as(u16, 200), r_alpha.status_code);

    const body_beta = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"group_id\":\"{s}\"}}", .{ role_beta, gid_beta });
    defer alloc.free(body_beta);
    const r_beta = identity_routes.handleUpsertRole(&store, alloc, adminActor(), body_beta);
    defer freeRouteBody(alloc, r_beta.body);
    try testing.expectEqual(@as(u16, 200), r_beta.status_code);

    // GET /roles: list all bindings.
    const list_result = identity_routes.handleListRoles(&store, alloc, adminActor());
    defer freeRouteBody(alloc, list_result.body);
    try testing.expectEqual(@as(u16, 200), list_result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, list_result.body, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const roles_val = parsed.value.object.get("roles") orelse return error.MissingRolesField;
    try testing.expect(roles_val == .array);

    var found_alpha = false;
    var found_beta = false;
    for (roles_val.array.items) |item| {
        if (item != .object) continue;
        const name_val = item.object.get("name") orelse continue;
        if (name_val != .string) continue;
        if (std.mem.eql(u8, name_val.string, role_alpha)) found_alpha = true;
        if (std.mem.eql(u8, name_val.string, role_beta)) found_beta = true;
    }
    try testing.expect(found_alpha);
    try testing.expect(found_beta);
}

// ---------------------------------------------------------------------------
// TC-IDN05-05: Tenant isolation — role in tenant A invisible to tenant B
// ---------------------------------------------------------------------------

test "TC-IDN05-05: tenant isolation — tenant_role row invisible to other schema" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    // Tenant A pool: uses the default tenant context (tenant_default schema).
    var pool_a = try makePool(alloc, url);
    defer pool_a.deinit();

    const group_name = "tc-idn05-05-group";
    const role_name = "TC-IDN05-05 Shared Name";
    cleanupRoleByName(&pool_a, role_name);
    cleanupGroupByName(&pool_a, group_name);
    defer cleanupRoleByName(&pool_a, role_name);
    defer cleanupGroupByName(&pool_a, group_name);

    var registry = identity_registry.Registry.init(&pool_a);
    var service = identity_service.Service.init(&registry);

    const group_id = try createGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);

    var store = role_registry.TenantRoleStore.init(&pool_a);
    const body = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"group_id\":\"{s}\"}}", .{ role_name, group_id });
    defer alloc.free(body);
    const r = identity_routes.handleUpsertRole(&store, alloc, adminActor(), body);
    defer freeRouteBody(alloc, r.body);
    try testing.expectEqual(@as(u16, 200), r.status_code);

    // Confirm tenant A can see the role.
    const list_a = identity_routes.handleListRoles(&store, alloc, adminActor());
    defer freeRouteBody(alloc, list_a.body);
    try testing.expectEqual(@as(u16, 200), list_a.status_code);
    const parsed_a = try std.json.parseFromSlice(std.json.Value, alloc, list_a.body, .{ .allocate = .alloc_always });
    defer parsed_a.deinit();
    const roles_a = parsed_a.value.object.get("roles") orelse return error.MissingRolesField;
    var found_in_a = false;
    for (roles_a.array.items) |item| {
        if (item != .object) continue;
        const n = item.object.get("name") orelse continue;
        if (n != .string) continue;
        if (std.mem.eql(u8, n.string, role_name)) {
            found_in_a = true;
            break;
        }
    }
    try testing.expect(found_in_a);

    // ----- Tenant B isolation check -----
    // Provision a fresh schema so tenant_role exists in that schema but has no rows.
    var tenant_b_raw: [16]u8 = undefined;
    bpm.uuid.generateUuidV4BytesInto(&tenant_b_raw);
    const tenant_b_id = try uuidToHexStr(alloc, tenant_b_raw);
    defer alloc.free(tenant_b_id);

    var schema_buf_b: [80]u8 = undefined;
    const schema_b = pool_mod.schemaNameForTenant(tenant_b_id, &schema_buf_b);
    try provisioning_mod.provisionTenantSchema(alloc, &pool_a, tenant_b_id, build_options.migrations_dir);
    defer cleanupTenantSchema(alloc, &pool_a, tenant_b_id, schema_b);

    // Switch context to tenant B; pool.acquire() routes to tenant B's schema.
    bpm.api_tenant_context.set(tenant_b_id);
    defer bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");

    const conn_b = try pool_a.acquire();
    defer pool_a.release(conn_b);

    // tenant_role in tenant B's schema must be empty — the role from tenant A is invisible.
    var count_qr = try conn_b.query(
        alloc,
        "SELECT COUNT(*) FROM tenant_role WHERE name = $1",
        &[_][]const u8{role_name},
    );
    defer count_qr.deinit();

    try testing.expect(count_qr.rows.len > 0);
    const count_str_b = count_qr.rows[0][0] orelse return error.CountNull;
    const count_b = try std.fmt.parseInt(u64, count_str_b, 10);
    try testing.expectEqual(@as(u64, 0), count_b);
}

// ---------------------------------------------------------------------------
// TC-IDN05-06: ROLE assignee resolved at task activation → GROUP semantics
// ---------------------------------------------------------------------------

test "TC-IDN05-06: ROLE assignee resolved at task activation — task has GROUP type" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const group_name = "tc-idn05-06-qa-team";
    const role_name = "TC-IDN05-06 QA Reviewer";
    const def_name = "tc-idn05-06-def";
    cleanupRoleByName(&pool, role_name);
    cleanupGroupByName(&pool, group_name);
    cleanupDefinitionByName(&pool, def_name);
    defer cleanupRoleByName(&pool, role_name);
    defer cleanupGroupByName(&pool, group_name);
    defer cleanupDefinitionByName(&pool, def_name);

    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);

    const group_id = try createGroupId(&service, alloc, group_name);
    defer alloc.free(group_id);

    // Register ROLE binding: "TC-IDN05-06 QA Reviewer" → group_id
    var store = role_registry.TenantRoleStore.init(&pool);
    const upsert_body = try std.fmt.allocPrint(
        alloc,
        "{{\"name\":\"{s}\",\"group_id\":\"{s}\"}}",
        .{ role_name, group_id },
    );
    defer alloc.free(upsert_body);
    const upsert_r = identity_routes.handleUpsertRole(&store, alloc, adminActor(), upsert_body);
    defer freeRouteBody(alloc, upsert_r.body);
    try testing.expectEqual(@as(u16, 200), upsert_r.status_code);

    // Build a process definition with a HUMAN_TASK whose assignee_type=ROLE
    const attrs = try std.fmt.allocPrint(
        alloc,
        "{{\"assignee_type\":\"ROLE\",\"assignee_ref\":\"{s}\"}}",
        .{role_name},
    );
    defer alloc.free(attrs);

    const nodes = [_]definition_mod.GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Role task", .attributes = attrs },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]definition_mod.GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
    };
    const graph = definition_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    var def_store = definition_mod.Store.init(alloc, &pool);
    const created_by = makeCreatorUuid();
    const def = try def_store.create(alloc, .{
        .name = def_name,
        .version = "1.0",
        .description = null,
        .stage = null,
        .created_by = created_by,
        .graph = graph,
    });
    defer {
        alloc.free(def.name);
        alloc.free(def.version);
        bpm.definition.freeDefinitionGraph(alloc, def.graph);
    }

    const activated = try def_store.activate(alloc, def.id);
    defer {
        alloc.free(activated.name);
        alloc.free(activated.version);
        if (activated.description) |d| alloc.free(d);
        if (activated.stage) |s| alloc.free(s);
        bpm.definition.freeDefinitionGraph(alloc, activated.graph);
    }

    var snap_store = snapshot_mod.SnapshotStore{ .pool = &pool };
    var inst_store = instance_mod.InstanceStore.init(&pool, &snap_store);

    const inst = try inst_store.create(alloc, def.id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    defer {
        alloc.free(inst.initial_variables);
        alloc.free(inst.definition_snapshot);
        if (inst.correlation_key) |ck| alloc.free(ck);
    }
    defer cleanupInstanceAndTasks(&pool, inst_id_hex);

    // Query the created task directly from the DB.
    const conn = try pool.acquire();
    defer pool.release(conn);

    const task_row = try conn.queryRow(
        alloc,
        "SELECT assignee_type, assignee_ref FROM tasks WHERE instance_id = $1::uuid LIMIT 1",
        &[_][]const u8{inst_id_hex},
    );
    if (task_row) |row| {
        defer {
            for (row) |col| if (col) |c| alloc.free(c);
            alloc.free(row);
        }
        // The ROLE should be resolved to GROUP at task creation time.
        const at = row[0] orelse return error.AssigneeTypeNull;
        const ar = row[1] orelse return error.AssigneeRefNull;
        try testing.expectEqualStrings("GROUP", at);
        try testing.expectEqualStrings(group_id, ar);
    } else {
        return error.NoTaskCreated;
    }
}

// ---------------------------------------------------------------------------
// TC-IDN05-07: ROLE assignee unresolved → Task created PENDING, not ERROR
// ---------------------------------------------------------------------------

test "TC-IDN05-07: unresolved ROLE assignee — task created, instance stays ACTIVE" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "tc-idn05-07-def";
    const role_name = "TC-IDN05-07 Nonexistent Role";
    cleanupDefinitionByName(&pool, def_name);
    defer cleanupDefinitionByName(&pool, def_name);

    // Ensure no binding for this role name exists.
    cleanupRoleByName(&pool, role_name);

    const attrs = try std.fmt.allocPrint(
        alloc,
        "{{\"assignee_type\":\"ROLE\",\"assignee_ref\":\"{s}\"}}",
        .{role_name},
    );
    defer alloc.free(attrs);

    const nodes = [_]definition_mod.GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Unresolved task", .attributes = attrs },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]definition_mod.GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
    };
    const graph = definition_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    var def_store = definition_mod.Store.init(alloc, &pool);
    const created_by = makeCreatorUuid();
    const def = try def_store.create(alloc, .{
        .name = def_name,
        .version = "1.0",
        .description = null,
        .stage = null,
        .created_by = created_by,
        .graph = graph,
    });
    defer {
        alloc.free(def.name);
        alloc.free(def.version);
        bpm.definition.freeDefinitionGraph(alloc, def.graph);
    }

    const activated = try def_store.activate(alloc, def.id);
    defer {
        alloc.free(activated.name);
        alloc.free(activated.version);
        if (activated.description) |d| alloc.free(d);
        if (activated.stage) |s| alloc.free(s);
        bpm.definition.freeDefinitionGraph(alloc, activated.graph);
    }

    var snap_store = snapshot_mod.SnapshotStore{ .pool = &pool };
    var inst_store = instance_mod.InstanceStore.init(&pool, &snap_store);

    // Instance creation must succeed even when the ROLE is unbound.
    const inst = try inst_store.create(alloc, def.id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    defer {
        alloc.free(inst.initial_variables);
        alloc.free(inst.definition_snapshot);
        if (inst.correlation_key) |ck| alloc.free(ck);
    }
    defer cleanupInstanceAndTasks(&pool, inst_id_hex);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // The instance must remain ACTIVE (not ERROR).
    const inst_row = try conn.queryRow(
        alloc,
        "SELECT status FROM instance_projections WHERE instance_id = $1::uuid",
        &[_][]const u8{inst_id_hex},
    );
    if (inst_row) |row| {
        defer {
            for (row) |col| if (col) |c| alloc.free(c);
            alloc.free(row);
        }
        const status = row[0] orelse return error.StatusNull;
        try testing.expectEqualStrings("ACTIVE", status);
    } else {
        return error.InstanceNotFound;
    }

    // The task must exist — unresolved ROLE keeps assignee_type as "ROLE".
    const task_row = try conn.queryRow(
        alloc,
        "SELECT assignee_type FROM tasks WHERE instance_id = $1::uuid LIMIT 1",
        &[_][]const u8{inst_id_hex},
    );
    if (task_row) |row| {
        defer {
            for (row) |col| if (col) |c| alloc.free(c);
            alloc.free(row);
        }
        const at = row[0] orelse return error.AssigneeTypeNull;
        // Unresolved ROLE → task stays with assignee_type "ROLE" (not converted to GROUP).
        try testing.expectEqualStrings("ROLE", at);
    } else {
        return error.NoTaskCreated;
    }
}
