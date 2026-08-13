//! Integration tests for PRM-09 (solution pack update planning, SHOULD).
//!
//! Covers:
//!   PRM-09 AC1  — unmodified tenant + Vn offered -> every changed artefact = clean_update
//!   PRM-09 AC4  — local_only classification (tenant modified, pack did not)
//!   PRM-09 AC5  — absent install record OR per-artefact missing base -> conflict
//!                  (broken into TC-PRM-09-02 for PackNotInstalled and TC-PRM-09-03
//!                   for per-artefact conflict classification)
//!
//! Per-test isolation: every test creates its own tenant UUID via
//! helpers.randomUuidBytes / helpers.TestHarness.newUuidString. No
//! hardcoded UUID literals. Every test cleans up its fixture via
//! `defer cleanupXxx()`. No `error.SkipZigTest` on ACs marked implemented.
//!
//! BPM_TEST_DB_URL must be set; tests fail with `error.MissingTestDatabaseUrl`
//! when the env var is absent (DIRECTIVE T-1).
//!
//! Build: `zig build test-integration-prm09`

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const build_options = @import("build_options");

const bpm = @import("bpm");
const helpers = @import("helpers.zig");

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const api_tenant_context = bpm.api_tenant_context;

const pack_update = bpm.pack_update;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — PRM-09 integration tests FAILED (env var required)\n", .{});
            return err;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            raw[0],  raw[1],  raw[2],  raw[3],
            raw[4],  raw[5],  raw[6],  raw[7],
            raw[8],  raw[9],  raw[10], raw[11],
            raw[12], raw[13], raw[14], raw[15],
        },
    );
}

fn insertTestTenant(pool: *Pool, tenant_id: []const u8, slug: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $2, 'ACTIVE', NULL, 'test',
        \\        '00000000-0000-0000-0000-000000000000'::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_id, slug },
    );
}

fn insertPackInstall(
    pool: *Pool,
    tenant_id: []const u8,
    pack_id: []const u8,
    installed_version: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    // installed_by = tenant_id as placeholder; unique on (tenant_id, pack_id, installed_version).
    try conn.exec(
        \\INSERT INTO solution_pack_installs
        \\    (tenant_id, pack_id, installed_version, installed_by)
        \\VALUES ($1::uuid, $2, $3, $1::uuid)
        \\ON CONFLICT (tenant_id, pack_id, installed_version) DO NOTHING
    ,
        &[_][]const u8{ tenant_id, pack_id, installed_version },
    );
}

fn insertPackArtefactBase(
    pool: *Pool,
    tenant_id: []const u8,
    pack_id: []const u8,
    artefact_id: []const u8,
    base_content: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    // Resolve install_id by looking up the most recent install for this tenant+pack.
    const row = try conn.queryRow(
        std.testing.allocator,
        "SELECT id::text FROM solution_pack_installs WHERE tenant_id = $1::uuid AND pack_id = $2 LIMIT 1",
        &[_][]const u8{ tenant_id, pack_id },
    );
    defer if (row) |r| {
        for (r) |col| if (col) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(r);
    };
    const install_id = if (row) |r| (r[0] orelse return) else return;
    try conn.exec(
        \\INSERT INTO solution_pack_artefact_bases (install_id, artefact_id, artefact_kind, base_content)
        \\VALUES ($1::uuid, $2, 'process_definition', $3::jsonb)
        \\ON CONFLICT (install_id, artefact_id) DO UPDATE SET base_content = EXCLUDED.base_content
    ,
        &[_][]const u8{ install_id, artefact_id, base_content },
    );
}

fn insertTenantProcessDefinition(
    pool: *Pool,
    tenant_id: []const u8,
    def_id: []const u8,
    graph_json: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO process_definitions
        \\    (id, tenant_id, name, version, description, status, graph, created_by)
        \\VALUES ($1::uuid, $2::uuid, 'prm09-artefact', '1',
        \\        'PRM-09 tenant copy', 'ACTIVE',
        \\        $3::jsonb, $2::uuid)
        \\ON CONFLICT (id) DO UPDATE SET graph = EXCLUDED.graph, status = 'ACTIVE'
    ,
        &[_][]const u8{ def_id, tenant_id, graph_json },
    );
}

fn dropTenantFixtures(pool: *Pool, tenant_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    _ = conn.exec(
        "DELETE FROM process_definitions WHERE tenant_id = $1::uuid",
        &[_][]const u8{tenant_id},
    ) catch {};
    _ = conn.exec(
        "DELETE FROM solution_pack_installs WHERE tenant_id = $1::uuid",
        &[_][]const u8{tenant_id},
    ) catch {};
    _ = conn.exec(
        "DELETE FROM public.tenant WHERE id = $1::uuid",
        &[_][]const u8{tenant_id},
    ) catch {};
}

// ---------------------------------------------------------------------------
// TC-PRM-09-01 — AC1 unmodified tenant + Vn offered -> clean_update
// ---------------------------------------------------------------------------

test "TC-PRM-09-01: computePackUpdatePlan classifies the changed artefact as clean_update when tenant has not modified it" {
    const alloc = testing.allocator;
    const url = getDbUrl(alloc) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDatabaseUrl,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    const def_id = try randomUuidStr(alloc);
    defer alloc.free(def_id);
    const artefact_id = try randomUuidStr(alloc);
    defer alloc.free(artefact_id);
    const slug = try std.fmt.allocPrint(alloc, "prm09-{s}", .{tenant_id});
    defer alloc.free(slug);

    try insertTestTenant(&pool, tenant_id, slug);
    try insertPackInstall(&pool, tenant_id, "prm09-pack-A", "1.0");
    try insertPackArtefactBase(&pool, tenant_id, "prm09-pack-A", artefact_id,
        \\{"nodes":[],"edges":[]}
    );
    try insertTenantProcessDefinition(&pool, tenant_id, def_id,
        \\{"nodes":[],"edges":[]}
    );
    defer dropTenantFixtures(&pool, tenant_id);

    const base_content =
        \\{"nodes":[],"edges":[]}
    ;
    const incoming_content =
        \\{"nodes":[{"id":"X","node_type":"START","label":null,"attributes":null}],"edges":[]}
    ;

    const incoming_artefacts = [_]pack_update.IncomingArtefact{
        .{
            .artefact_id = artefact_id,
            .artefact_kind = "process_definition",
            .content = incoming_content,
        },
    };

    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    const plan = pack_update.computePackUpdatePlan(
        alloc,
        &pool,
        tenant_id,
        "prm09-pack-A",
        "2.0",
        &incoming_artefacts,
    ) catch |err| {
        std.debug.print("computePackUpdatePlan failed: {any}\n", .{err});
        return err;
    };
    defer plan.deinit(alloc);

    try testing.expectEqualStrings("1.0", plan.base_pack_version);
    try testing.expectEqualStrings("2.0", plan.incoming_pack_version);
    try testing.expectEqual(@as(usize, 1), plan.artefacts.len);
    try testing.expect(plan.artefacts[0].classification == pack_update.ArtefactClassification.clean_update);
    try testing.expect(!plan.has_unresolved_conflicts);
    _ = base_content;
}

// ---------------------------------------------------------------------------
// TC-PRM-09-02 — AC5 absent install record -> PackNotInstalled
// ---------------------------------------------------------------------------

test "TC-PRM-09-02: computePackUpdatePlan returns PackNotInstalled when no solution_pack_installs row exists" {
    const alloc = testing.allocator;
    const url = getDbUrl(alloc) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDatabaseUrl,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    const def_id = try randomUuidStr(alloc);
    defer alloc.free(def_id);
    const slug = try std.fmt.allocPrint(alloc, "prm09-noinstall-{s}", .{tenant_id});
    defer alloc.free(slug);

    try insertTestTenant(&pool, tenant_id, slug);
    try insertTenantProcessDefinition(&pool, tenant_id, def_id,
        \\{"nodes":[],"edges":[]}
    );
    defer dropTenantFixtures(&pool, tenant_id);

    const incoming_artefacts = [_]pack_update.IncomingArtefact{
        .{
            .artefact_id = "non-existent-artefact",
            .artefact_kind = "process_definition",
            .content = "any content",
        },
    };

    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    const result = pack_update.computePackUpdatePlan(
        alloc,
        &pool,
        tenant_id,
        "prm09-pack-MISSING",
        "2.0",
        &incoming_artefacts,
    );
    try testing.expectError(pack_update.PackUpdateError.PackNotInstalled, result);
}

// ---------------------------------------------------------------------------
// TC-PRM-09-03 — per-artefact missing base row -> conflict classification
// ---------------------------------------------------------------------------

test "TC-PRM-09-03: computePackUpdatePlan classifies per-artefact conflict when solution_pack_artefact_bases row is missing" {
    const alloc = testing.allocator;
    const url = getDbUrl(alloc) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDatabaseUrl,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    const def_id = try randomUuidStr(alloc);
    defer alloc.free(def_id);
    const missing_base_artefact_id = try randomUuidStr(alloc);
    defer alloc.free(missing_base_artefact_id);
    const slug = try std.fmt.allocPrint(alloc, "prm09-conflict-{s}", .{tenant_id});
    defer alloc.free(slug);

    try insertTestTenant(&pool, tenant_id, slug);
    try insertPackInstall(&pool, tenant_id, "prm09-pack-conflict", "1.0");
    // NO artefact_base row inserted — this is the trigger for conflict classification
    try insertTenantProcessDefinition(&pool, tenant_id, def_id,
        \\{"nodes":[],"edges":[]}
    );
    defer dropTenantFixtures(&pool, tenant_id);

    const incoming_artefacts = [_]pack_update.IncomingArtefact{
        .{
            .artefact_id = missing_base_artefact_id,
            .artefact_kind = "process_definition",
            .content = "new content",
        },
    };

    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    const plan = pack_update.computePackUpdatePlan(
        alloc,
        &pool,
        tenant_id,
        "prm09-pack-conflict",
        "2.0",
        &incoming_artefacts,
    ) catch |err| {
        std.debug.print("computePackUpdatePlan conflict path failed: {any}\n", .{err});
        return err;
    };
    defer plan.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), plan.artefacts.len);
    try testing.expect(plan.artefacts[0].classification == pack_update.ArtefactClassification.conflict);
    try testing.expect(plan.has_unresolved_conflicts);
}

// ---------------------------------------------------------------------------
// TC-PRM-09-04 — AC4 local_only classification
// ---------------------------------------------------------------------------

test "TC-PRM-09-04: computePackUpdatePlan classifies local_only when tenant modified the artefact but pack did not" {
    const alloc = testing.allocator;
    const url = getDbUrl(alloc) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDatabaseUrl,
        else => return err,
    };
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);
    const def_id = try randomUuidStr(alloc);
    defer alloc.free(def_id);
    const artefact_id = try randomUuidStr(alloc);
    defer alloc.free(artefact_id);
    const slug = try std.fmt.allocPrint(alloc, "prm09-local-{s}", .{tenant_id});
    defer alloc.free(slug);

    try insertTestTenant(&pool, tenant_id, slug);
    try insertPackInstall(&pool, tenant_id, "prm09-pack-local", "1.0");

    // Base content = "A"
    try insertPackArtefactBase(
        &pool,
        tenant_id,
        "prm09-pack-local",
        artefact_id,
        "A",
    );
    // Tenant has modified to "B"
    try insertTenantProcessDefinition(
        &pool,
        tenant_id,
        def_id,
        "B",
    );
    defer dropTenantFixtures(&pool, tenant_id);

    // Incoming is "A" — same as base, so pack did not change it
    const incoming_artefacts = [_]pack_update.IncomingArtefact{
        .{
            .artefact_id = artefact_id,
            .artefact_kind = "process_definition",
            .content = "A",
        },
    };

    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    const plan = pack_update.computePackUpdatePlan(
        alloc,
        &pool,
        tenant_id,
        "prm09-pack-local",
        "2.0",
        &incoming_artefacts,
    ) catch |err| {
        std.debug.print("computePackUpdatePlan local_only path failed: {any}\n", .{err});
        return err;
    };
    defer plan.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), plan.artefacts.len);
    try testing.expect(plan.artefacts[0].classification == pack_update.ArtefactClassification.local_only);
    try testing.expect(!plan.has_unresolved_conflicts);
}

