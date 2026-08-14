//! Integration tests for SOL-03 — Role-mapping activation gate.
//!
//! Covers:
//!   TC-SOL03-01: Pack-installed def, 2 of 3 roles unbound → allowed=false, 2 listed
//!   TC-SOL03-02: Pack-installed def, all roles bound → allowed=true
//!   TC-SOL03-03: Non-pack definition → allowed=true (gate does not apply)
//!
//! Per-test isolation: every test uses per-test UUID pack_ids and role names.
//! All fixtures are cleaned up via defer blocks. No error.SkipZigTest on MUST tests.
//!
//! BPM_TEST_DB_URL must be set; tests fail with a clear error when absent.
//!
//! Requirement traceability: SOL-03 AC1..AC3 → TC-SOL03-01..03

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const helpers = @import("helpers.zig");
const pool_mod = bpm.pool;

const SolutionPackStore = bpm.solution_pack_store.SolutionPackStore;
const SolutionPackError = bpm.solution_pack_store.SolutionPackError;
const SolutionPackDocument = bpm.solution_pack_store.SolutionPackDocument;
const PackedDefinition = bpm.solution_pack_store.PackedDefinition;
const PackManifest = bpm.solution_pack_store.PackManifest;
const PACK_SCHEMA_VERSION = bpm.solution_pack_store.PACK_SCHEMA_VERSION;

const ACTOR_ID = "00000000-0000-0000-0000-000000000000";

const MINIMAL_GRAPH =
    \\{"nodes":[{"id":"S","node_type":"START","label":null,"attributes":null},{"id":"E","node_type":"END","label":null,"attributes":null}],"edges":[{"id":"e1","source":"S","target":"E","condition":null,"is_default":false}]}
;

// ---------------------------------------------------------------------------
// Test infrastructure
// ---------------------------------------------------------------------------

fn testDbUrl(alloc: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — SOL-03 integration tests FAILED (env var required)\n",
                .{},
            );
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(alloc: std.mem.Allocator, url: []const u8) !pool_mod.Pool {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return pool_mod.Pool.init(std.testing.io, alloc, pool_mod.PoolConfig{
        .url = url,
        .pool_size = 4,
    });
}

fn cleanupInstall(pool: *pool_mod.Pool, pack_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        \\DELETE FROM process_definitions
        \\WHERE solution_pack_install_id IN (
        \\  SELECT id FROM solution_pack_installs WHERE pack_id = $1
        \\)
    ,
        &[_][]const u8{pack_id},
    ) catch {};
    conn.exec(
        "DELETE FROM solution_pack_installs WHERE pack_id = $1",
        &[_][]const u8{pack_id},
    ) catch {};
}

fn cleanupTenantRole(pool: *pool_mod.Pool, role_name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM tenant_role WHERE name = $1", &[_][]const u8{role_name}) catch {};
}

fn cleanupGroup(pool: *pool_mod.Pool, group_name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM groups WHERE name = $1", &[_][]const u8{group_name}) catch {};
}

fn cleanupDefinitionById(pool: *pool_mod.Pool, def_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE id = $1::uuid", &[_][]const u8{def_id}) catch {};
}

/// Insert a group and return its UUID string. Caller owns the returned slice.
fn insertGroup(pool: *pool_mod.Pool, alloc: std.mem.Allocator, group_name: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    const row = try conn.queryRow(
        alloc,
        \\INSERT INTO groups (name, display_name, is_system)
        \\VALUES ($1, $1, false)
        \\ON CONFLICT (name) DO UPDATE SET display_name = EXCLUDED.display_name
        \\RETURNING id::text
    ,
        &[_][]const u8{group_name},
    );
    const r = row orelse return error.InsertFailed;
    defer {
        for (r) |c| if (c) |v| alloc.free(v);
        alloc.free(r);
    }
    return alloc.dupe(u8, r[0] orelse return error.InsertFailed);
}

/// Insert (or upsert) a tenant_role binding.
fn insertTenantRole(pool: *pool_mod.Pool, role_name: []const u8, group_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO tenant_role (name, group_id)
        \\VALUES ($1, $2::uuid)
        \\ON CONFLICT (name) DO UPDATE SET group_id = EXCLUDED.group_id
    ,
        &[_][]const u8{ role_name, group_id },
    );
}

/// Install a pack and return the new definition_id for the first definition.
/// Caller owns the returned slice.
fn installTestPack(
    pool: *pool_mod.Pool,
    alloc: std.mem.Allocator,
    pack_id: []const u8,
    manifest_roles: []const []const u8,
) ![]u8 {
    const src_def_id = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(src_def_id);

    const defs = [_]PackedDefinition{.{
        .definition_id = src_def_id,
        .process_key = "sol03-gate-process",
        .name = "sol03-gate-process",
        .version = pack_id[0..8], // use pack prefix as version for uniqueness
        .graph = MINIMAL_GRAPH,
        .variable_schema = "{}",
    }};

    const doc = SolutionPackDocument{
        .pack_id = pack_id,
        .version = "1.0.0",
        .bpm_export_schema_version = PACK_SCHEMA_VERSION,
        .exported_at = "2026-08-14T00:00:00Z",
        .definitions = &defs,
        .service_catalog_entries = &.{},
        .variable_schemas = &.{},
        .manifest = PackManifest{ .required_roles = manifest_roles },
    };

    var store = SolutionPackStore.init(pool);
    const result = try store.installPack(alloc, doc, ACTOR_ID);
    defer {
        for (result.installed_definitions) |d| {
            alloc.free(d.source_definition_id);
            // Don't free new_definition_id — we return it to caller.
            alloc.free(d.process_key);
        }
        alloc.free(result.installed_definitions);
        for (result.role_mapping_checklist) |e| alloc.free(e.role_name);
        alloc.free(result.role_mapping_checklist);
        for (result.warnings) |w| alloc.free(w);
        alloc.free(result.warnings);
        alloc.free(result.pack_id);
        alloc.free(result.version);
    }

    if (result.installed_definitions.len == 0) return error.NoDefinitionInstalled;
    return alloc.dupe(u8, result.installed_definitions[0].new_definition_id);
}

// ---------------------------------------------------------------------------
// TC-SOL03-01: 2 of 3 manifest roles unbound → allowed=false, 2 listed.
// ---------------------------------------------------------------------------

test "TC-SOL03-01: checkRoleGate returns allowed=false when 2 of 3 manifest roles are unbound" {
    const alloc = testing.allocator;
    var lock_conn = try helpers.acquireIntegrationLock(alloc);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const uuid_bytes = helpers.randomUuidBytes();
    const pack_id = try helpers.uuidBytesToString(alloc, uuid_bytes);
    defer alloc.free(pack_id);

    // Role names include unique suffix to avoid cross-test name collisions.
    const pfx = pack_id[0..8];
    const role_a = try std.fmt.allocPrint(alloc, "sol03-tc01-RoleA-{s}", .{pfx});
    defer alloc.free(role_a);
    const role_b = try std.fmt.allocPrint(alloc, "sol03-tc01-RoleB-{s}", .{pfx});
    defer alloc.free(role_b);
    const role_c = try std.fmt.allocPrint(alloc, "sol03-tc01-RoleC-{s}", .{pfx});
    defer alloc.free(role_c);
    const group_name = try std.fmt.allocPrint(alloc, "sol03-tc01-grp-{s}", .{pfx});
    defer alloc.free(group_name);

    defer cleanupInstall(&pool, pack_id);
    defer cleanupTenantRole(&pool, role_a);
    defer cleanupTenantRole(&pool, role_b);
    defer cleanupTenantRole(&pool, role_c);
    defer cleanupGroup(&pool, group_name);

    // Install the pack with 3 manifest roles.
    const roles = [_][]const u8{ role_a, role_b, role_c };
    const def_id = try installTestPack(&pool, alloc, pack_id, &roles);
    defer alloc.free(def_id);

    // Bind only role_a.
    const group_id = try insertGroup(&pool, alloc, group_name);
    defer alloc.free(group_id);
    try insertTenantRole(&pool, role_a, group_id);

    var store = SolutionPackStore.init(&pool);
    const gate = store.checkRoleGate(alloc, def_id) catch |err| {
        std.debug.print("TC-SOL03-01: checkRoleGate failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (gate.unbound_roles) |r| alloc.free(r);
        alloc.free(gate.unbound_roles);
    }

    try testing.expect(!gate.allowed);
    try testing.expectEqual(@as(usize, 2), gate.unbound_roles.len);

    // Unbound roles must be role_b and role_c (alphabetical order from SQL ORDER BY).
    // Both are in the unbound list; role_a is bound so it must NOT appear.
    for (gate.unbound_roles) |unbound| {
        try testing.expect(!std.mem.eql(u8, unbound, role_a));
    }
    var found_b = false;
    var found_c = false;
    for (gate.unbound_roles) |unbound| {
        if (std.mem.eql(u8, unbound, role_b)) found_b = true;
        if (std.mem.eql(u8, unbound, role_c)) found_c = true;
    }
    try testing.expect(found_b);
    try testing.expect(found_c);
}

// ---------------------------------------------------------------------------
// TC-SOL03-02: All manifest roles bound → allowed=true.
// ---------------------------------------------------------------------------

test "TC-SOL03-02: checkRoleGate returns allowed=true when all manifest roles are bound" {
    const alloc = testing.allocator;
    var lock_conn = try helpers.acquireIntegrationLock(alloc);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const uuid_bytes = helpers.randomUuidBytes();
    const pack_id = try helpers.uuidBytesToString(alloc, uuid_bytes);
    defer alloc.free(pack_id);

    const pfx = pack_id[0..8];
    const role_x = try std.fmt.allocPrint(alloc, "sol03-tc02-RoleX-{s}", .{pfx});
    defer alloc.free(role_x);
    const group_name = try std.fmt.allocPrint(alloc, "sol03-tc02-grp-{s}", .{pfx});
    defer alloc.free(group_name);

    defer cleanupInstall(&pool, pack_id);
    defer cleanupTenantRole(&pool, role_x);
    defer cleanupGroup(&pool, group_name);

    // Install pack with 1 manifest role.
    const roles = [_][]const u8{role_x};
    const def_id = try installTestPack(&pool, alloc, pack_id, &roles);
    defer alloc.free(def_id);

    // Bind role_x.
    const group_id = try insertGroup(&pool, alloc, group_name);
    defer alloc.free(group_id);
    try insertTenantRole(&pool, role_x, group_id);

    var store = SolutionPackStore.init(&pool);
    const gate = store.checkRoleGate(alloc, def_id) catch |err| {
        std.debug.print("TC-SOL03-02: checkRoleGate failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (gate.unbound_roles) |r| alloc.free(r);
        alloc.free(gate.unbound_roles);
    }

    try testing.expect(gate.allowed);
    try testing.expectEqual(@as(usize, 0), gate.unbound_roles.len);
}

// ---------------------------------------------------------------------------
// TC-SOL03-03: Non-pack definition → gate does not apply, allowed=true.
// ---------------------------------------------------------------------------

test "TC-SOL03-03: checkRoleGate returns allowed=true for a definition not created via installPack" {
    const alloc = testing.allocator;
    var lock_conn = try helpers.acquireIntegrationLock(alloc);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const uuid_bytes = helpers.randomUuidBytes();
    const uuid_str = try helpers.uuidBytesToString(alloc, uuid_bytes);
    defer alloc.free(uuid_str);

    const def_name = try std.fmt.allocPrint(alloc, "sol03-tc03-plain-{s}", .{uuid_str[0..8]});
    defer alloc.free(def_name);

    // Insert a normal (non-pack) definition — no solution_pack_install_id.
    const conn = try pool.acquire();
    const def_id: []u8 = blk: {
        defer pool.release(conn);
        const row = try conn.queryRow(
            alloc,
            \\INSERT INTO process_definitions (name, version, description, status, graph, created_by)
            \\VALUES ($1, '1.0.0', 'plain def', 'DRAFT', $2::jsonb, $3::uuid)
            \\RETURNING id::text
        ,
            &[_][]const u8{ def_name, MINIMAL_GRAPH, ACTOR_ID },
        );
        const r = row orelse return error.InsertFailed;
        defer {
            for (r) |c| if (c) |v| alloc.free(v);
            alloc.free(r);
        }
        break :blk try alloc.dupe(u8, r[0] orelse return error.InsertFailed);
    };
    defer alloc.free(def_id);
    defer cleanupDefinitionById(&pool, def_id);

    var store = SolutionPackStore.init(&pool);
    const gate = store.checkRoleGate(alloc, def_id) catch |err| {
        std.debug.print("TC-SOL03-03: checkRoleGate failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (gate.unbound_roles) |r| alloc.free(r);
        alloc.free(gate.unbound_roles);
    }

    try testing.expect(gate.allowed);
    try testing.expectEqual(@as(usize, 0), gate.unbound_roles.len);
}
