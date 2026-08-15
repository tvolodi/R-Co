//! Integration tests for PLC-04: Cross-tenant module distribution.
//!
//! Tests:
//!   - Tenant A's module is invisible to tenant B without a grant.
//!   - Grant makes module visible to receiving tenant.
//!   - grantModuleVisibility creates a share grant row.
//!   - Duplicate grant returns SharingGrantAlreadyExists.
//!   - revokeModuleVisibility removes the grant.
//!   - revokeModuleVisibility returns error for unknown grant.
//!   - listVisibleModules shows only owned and shared ACTIVE modules.
//!   - Grant does not allow B to see A's other modules.
//!
//! BPM_TEST_DB_URL must be set; connects to a real PostgreSQL (DIRECTIVE T-1).

const std = @import("std");
const portable_env = @import("env");
const pg = @import("pg");
const bpm = @import("bpm");
const helpers = @import("helpers.zig");

pub const api_tenant_context = bpm.api_tenant_context;

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const ProcessModuleCatalog = bpm.process_module_catalog.ProcessModuleCatalog;
const RegisterModuleParams = bpm.process_module_catalog.RegisterModuleParams;
const ShareGrantParams = bpm.process_module_catalog.ShareGrantParams;
const ModuleRef = bpm.process_module_catalog.ModuleRef;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fillRandom(buf: []u8) void {
    const builtin = @import("builtin");
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.arc4random_buf(buf.ptr, buf.len),
        else => @compileError("fillRandom: unsupported OS"),
    }
}

fn randomUuid(allocator: std.mem.Allocator) ![16]u8 {
    _ = allocator;
    var raw: [16]u8 = undefined;
    fillRandom(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return raw;
}

fn uuidToString(allocator: std.mem.Allocator, uuid: [16]u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        uuid[0],  uuid[1],  uuid[2],  uuid[3],
        uuid[4],  uuid[5],  uuid[6],  uuid[7],
        uuid[8],  uuid[9],  uuid[10], uuid[11],
        uuid[12], uuid[13], uuid[14], uuid[15],
    });
}

fn makePool(allocator: std.mem.Allocator) !Pool {
    const env = portable_env.globalEnviron();
    const url = env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping PLC-04 integration tests\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer allocator.free(url);
    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 3 });
}

fn insertTenant(conn: *bpm.pool.Conn, allocator: std.mem.Allocator, tenant_id: [16]u8, label: []const u8) !void {
    const id_str = try uuidToString(allocator, tenant_id);
    defer allocator.free(id_str);
    try conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, $4, now(), 'test', $5::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ id_str, id_str, label, id_str, "00000000-0000-0000-0000-000000000000" },
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TC-PLC-04-01: tenant A's module is invisible to tenant B without a grant" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid = try randomUuid(alloc);
    const tenant_a = try randomUuid(alloc);
    const tenant_b = try randomUuid(alloc);
    const module_id = try bpm.uuid.newUuidV4(alloc);
    defer alloc.free(module_id);

    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_a, "tenant-plc4-a");
        try insertTenant(conn, alloc, tenant_b, "tenant-plc4-b");
    }

    // Tenant A registers and publishes a module.
    const p_a = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_a,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "{\"inputs\": []}",
        .exportable = true,
    };
    const reg_e_a = try catalog.registerModule(alloc, p_a);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_e_a);
    const pub_r_a = try catalog.publishModule(alloc, module_id, "1.0.0", try randomUuid(alloc));
    defer bpm.process_module_catalog.freeEntry(alloc, pub_r_a.entry);

    // Tenant B tries to resolve — must fail with UNRESOLVED_MODULE_REF.
    const ref = ModuleRef{ .module_id = module_id, .version_constraint = "*" };
    const result = try catalog.resolveModuleRef(alloc, ref, tenant_b);

    try std.testing.expect(!result.resolved);
    try std.testing.expectEqualStrings("UNRESOLVED_MODULE_REF", result.error_code.?);
}

test "TC-PLC-04-02: grant makes module visible to receiving tenant" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid = try randomUuid(alloc);
    const tenant_a = try randomUuid(alloc);
    const tenant_b = try randomUuid(alloc);
    const actor_id = try randomUuid(alloc);
    const module_id = try bpm.uuid.newUuidV4(alloc);
    defer alloc.free(module_id);

    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_a, "tenant-plc4-ga");
        try insertTenant(conn, alloc, tenant_b, "tenant-plc4-gb");
    }

    // Tenant A registers and publishes.
    const p_a = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_a,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "{\"inputs\": []}",
        .exportable = true,
    };
    const reg_e_a = try catalog.registerModule(alloc, p_a);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_e_a);
    const pub_r_a = try catalog.publishModule(alloc, module_id, "1.0.0", actor_id);
    defer bpm.process_module_catalog.freeEntry(alloc, pub_r_a.entry);

    // Grant tenant B visibility.
    const grant = ShareGrantParams{
        .granting_tenant_id = tenant_a,
        .module_id = module_id,
        .receiving_tenant_id = tenant_b,
        .granted_by = actor_id,
    };
    try catalog.grantModuleVisibility(alloc, grant);

    // Tenant B can now resolve.
    const ref = ModuleRef{ .module_id = module_id, .version_constraint = "*" };
    const result = try catalog.resolveModuleRef(alloc, ref, tenant_b);
    defer {
        if (result.entry) |e| {
            alloc.free(e.module_id);
            alloc.free(e.version);
            alloc.free(e.interface_schema_json);
        }
    }

    try std.testing.expect(result.resolved);
    try std.testing.expectEqualStrings("1.0.0", result.entry.?.version);
}

test "TC-PLC-04-03: grantModuleVisibility creates a share grant row" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid = try randomUuid(alloc);
    const tenant_a = try randomUuid(alloc);
    const tenant_b = try randomUuid(alloc);
    const actor_id = try randomUuid(alloc);
    const module_id = try bpm.uuid.newUuidV4(alloc);
    defer alloc.free(module_id);

    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_a, "tenant-plc4-03a");
        try insertTenant(conn, alloc, tenant_b, "tenant-plc4-03b");
    }

    const p = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_a,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "{\"inputs\": []}",
        .exportable = true,
    };
    const reg_e = try catalog.registerModule(alloc, p);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_e);
    const pub_r = try catalog.publishModule(alloc, module_id, "1.0.0", actor_id);
    defer bpm.process_module_catalog.freeEntry(alloc, pub_r.entry);

    const grant = ShareGrantParams{
        .granting_tenant_id = tenant_a,
        .module_id = module_id,
        .receiving_tenant_id = tenant_b,
        .granted_by = actor_id,
    };
    try catalog.grantModuleVisibility(alloc, grant);

    // Verify grant row exists via direct SQL.
    var conn = try pool.acquire();
    _ = &conn;
    defer pool.release(conn);

    const id_str = try uuidToString(alloc, tenant_a);
    defer alloc.free(id_str);
    const mod_str = module_id;
    const recv_str = try uuidToString(alloc, tenant_b);
    defer alloc.free(recv_str);

    var rows = try conn.query(
        alloc,
        \\SELECT grant_id FROM public.process_module_catalog_share
        \\WHERE granting_tenant_id = $1::uuid AND module_id = $2 AND receiving_tenant_id = $3::uuid
    ,
        &.{ id_str, mod_str, recv_str },
    );
    defer rows.deinit();

    try std.testing.expect(rows.rows.len == 1);
}

test "TC-PLC-04-04: duplicate grant returns SharingGrantAlreadyExists" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid = try randomUuid(alloc);
    const tenant_a = try randomUuid(alloc);
    const tenant_b = try randomUuid(alloc);
    const actor_id = try randomUuid(alloc);
    const module_id = try bpm.uuid.newUuidV4(alloc);
    defer alloc.free(module_id);

    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_a, "tenant-plc4-04a");
        try insertTenant(conn, alloc, tenant_b, "tenant-plc4-04b");
    }

    const p = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_a,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "{\"inputs\": []}",
        .exportable = true,
    };
    const reg_e = try catalog.registerModule(alloc, p);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_e);
    const pub_r = try catalog.publishModule(alloc, module_id, "1.0.0", actor_id);
    defer bpm.process_module_catalog.freeEntry(alloc, pub_r.entry);

    const grant = ShareGrantParams{
        .granting_tenant_id = tenant_a,
        .module_id = module_id,
        .receiving_tenant_id = tenant_b,
        .granted_by = actor_id,
    };
    try catalog.grantModuleVisibility(alloc, grant);

    // Second grant with same params — idempotent ON CONFLICT DO NOTHING.
    const result = catalog.grantModuleVisibility(alloc, grant);
    try std.testing.expectError(bpm.process_module_catalog.ModuleCatalogError.SharingGrantAlreadyExists, result);
}

test "TC-PLC-04-05: revokeModuleVisibility removes the grant" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid = try randomUuid(alloc);
    const tenant_a = try randomUuid(alloc);
    const tenant_b = try randomUuid(alloc);
    const actor_id = try randomUuid(alloc);
    const module_id = try bpm.uuid.newUuidV4(alloc);
    defer alloc.free(module_id);

    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_a, "tenant-plc4-05a");
        try insertTenant(conn, alloc, tenant_b, "tenant-plc4-05b");
    }

    const p = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_a,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "{\"inputs\": []}",
        .exportable = true,
    };
    const reg_e = try catalog.registerModule(alloc, p);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_e);
    const pub_r = try catalog.publishModule(alloc, module_id, "1.0.0", actor_id);
    defer bpm.process_module_catalog.freeEntry(alloc, pub_r.entry);

    const grant = ShareGrantParams{
        .granting_tenant_id = tenant_a,
        .module_id = module_id,
        .receiving_tenant_id = tenant_b,
        .granted_by = actor_id,
    };
    try catalog.grantModuleVisibility(alloc, grant);

    // Get the grant_id from the share table.
    const id_str = try uuidToString(alloc, tenant_a);
    defer alloc.free(id_str);
    const recv_str = try uuidToString(alloc, tenant_b);
    defer alloc.free(recv_str);

    var conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        alloc,
        \\SELECT grant_id FROM public.process_module_catalog_share
        \\WHERE granting_tenant_id = $1::uuid AND module_id = $2 AND receiving_tenant_id = $3::uuid
    ,
        &.{ id_str, module_id, recv_str },
    );
    defer rows.deinit();
    // Postgres returns UUIDs in canonical 8-4-4-4-12 dashed form (36 chars),
    // not 32-char hex — strip the dashes before decoding.
    const grant_id_row = rows.rows[0][0].?;
    var grant_id_hex_no_dash: [32]u8 = undefined;
    var gi: usize = 0;
    for (grant_id_row) |c| {
        if (c == '-') continue;
        if (gi >= 32) break;
        grant_id_hex_no_dash[gi] = c;
        gi += 1;
    }
    var grant_id_bytes: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&grant_id_bytes, &grant_id_hex_no_dash);

    // Revoke.
    try catalog.revokeModuleVisibility(alloc, grant_id_bytes, actor_id);

    // Tenant B can no longer resolve.
    const ref = ModuleRef{ .module_id = module_id, .version_constraint = "*" };
    const result = try catalog.resolveModuleRef(alloc, ref, tenant_b);
    try std.testing.expect(!result.resolved);
}

test "TC-PLC-04-06: revokeModuleVisibility returns error for unknown grant" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const unknown_grant_id = try randomUuid(alloc);
    const actor_id = try randomUuid(alloc);

    const result = catalog.revokeModuleVisibility(alloc, unknown_grant_id, actor_id);
    try std.testing.expectError(bpm.process_module_catalog.ModuleCatalogError.SharingGrantNotFound, result);
}

test "TC-PLC-04-07: listVisibleModules shows only owned and shared ACTIVE modules" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid_a = try randomUuid(alloc);
    _ = try randomUuid(alloc);
    const tenant_a = try randomUuid(alloc);
    const tenant_b = try randomUuid(alloc);
    const actor_id = try randomUuid(alloc);
    const module_x = try bpm.uuid.newUuidV4(alloc);
    const module_y = try bpm.uuid.newUuidV4(alloc);
    defer {
        alloc.free(module_x);
        alloc.free(module_y);
    }

    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_a, "tenant-plc4-07a");
        try insertTenant(conn, alloc, tenant_b, "tenant-plc4-07b");
    }

    // Tenant A owns 2 modules.
    inline for (&.{ module_x, module_y }) |mid| {
        const p = RegisterModuleParams{
            .module_id = mid,
            .version = "1.0.0",
            .owning_tenant_id = tenant_a,
            .owning_definition_id = def_uuid_a,
            .interface_schema_json = "{\"inputs\": []}",
            .exportable = true,
        };
        const reg_e = try catalog.registerModule(alloc, p);
        defer bpm.process_module_catalog.freeEntry(alloc, reg_e);
        const pub_r = try catalog.publishModule(alloc, mid, "1.0.0", actor_id);
        defer bpm.process_module_catalog.freeEntry(alloc, pub_r.entry);
    }

    // Grant tenant B visibility to module_x only.
    const grant = ShareGrantParams{
        .granting_tenant_id = tenant_a,
        .module_id = module_x,
        .receiving_tenant_id = tenant_b,
        .granted_by = actor_id,
    };
    try catalog.grantModuleVisibility(alloc, grant);

    // Tenant B lists — sees only module_x (shared), not module_y.
    const page = try catalog.listVisibleModules(alloc, tenant_b, null, 50);
    defer {
        for (page.records) |rec| {
            alloc.free(rec.module_id);
            alloc.free(rec.version);
            alloc.free(rec.interface_schema_json);
        }
        alloc.free(page.records);
        if (page.next_cursor) |c| alloc.free(c);
    }

    try std.testing.expect(page.records.len == 1);
    try std.testing.expectEqualStrings(module_x, page.records[0].module_id);
}

test "TC-PLC-04-08: grant does not allow B to see A's other modules" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid = try randomUuid(alloc);
    const tenant_a = try randomUuid(alloc);
    const tenant_b = try randomUuid(alloc);
    const actor_id = try randomUuid(alloc);
    const module_granted = try bpm.uuid.newUuidV4(alloc);
    const module_not_granted = try bpm.uuid.newUuidV4(alloc);
    defer {
        alloc.free(module_granted);
        alloc.free(module_not_granted);
    }

    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_a, "tenant-plc4-08a");
        try insertTenant(conn, alloc, tenant_b, "tenant-plc4-08b");
    }

    // Tenant A publishes two modules.
    inline for (&.{ module_granted, module_not_granted }) |mid| {
        const p = RegisterModuleParams{
            .module_id = mid,
            .version = "1.0.0",
            .owning_tenant_id = tenant_a,
            .owning_definition_id = def_uuid,
            .interface_schema_json = "{\"inputs\": []}",
            .exportable = true,
        };
        const reg_e = try catalog.registerModule(alloc, p);
        defer bpm.process_module_catalog.freeEntry(alloc, reg_e);
        const pub_r = try catalog.publishModule(alloc, mid, "1.0.0", actor_id);
        defer bpm.process_module_catalog.freeEntry(alloc, pub_r.entry);
    }

    // Grant only module_granted to tenant B.
    const grant = ShareGrantParams{
        .granting_tenant_id = tenant_a,
        .module_id = module_granted,
        .receiving_tenant_id = tenant_b,
        .granted_by = actor_id,
    };
    try catalog.grantModuleVisibility(alloc, grant);

    // Tenant B lists — sees only module_granted.
    const page = try catalog.listVisibleModules(alloc, tenant_b, null, 50);
    defer {
        for (page.records) |rec| {
            alloc.free(rec.module_id);
            alloc.free(rec.version);
            alloc.free(rec.interface_schema_json);
        }
        alloc.free(page.records);
        if (page.next_cursor) |c| alloc.free(c);
    }

    try std.testing.expect(page.records.len == 1);
    try std.testing.expectEqualStrings(module_granted, page.records[0].module_id);

    // Tenant B specifically cannot resolve module_not_granted.
    const ref = ModuleRef{ .module_id = module_not_granted, .version_constraint = "*" };
    const result = try catalog.resolveModuleRef(alloc, ref, tenant_b);
    try std.testing.expect(!result.resolved);
}
