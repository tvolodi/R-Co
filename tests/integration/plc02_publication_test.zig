//! Integration tests for PLC-02: Catalog entry publication requires a declared interface.
//!
//! Tests:
//!   - Publish succeeds when interface schema declares inputs.
//!   - Publish succeeds when interface schema declares outputs.
//!   - Publish fails when interface schema is empty object.
//!   - Publish fails when module is already ACTIVE.
//!   - Publish fails when module does not exist.
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
            std.debug.print("BPM_TEST_DB_URL not set — skipping PLC-02 integration tests\n", .{});
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

test "TC-PLC-02-01: publish succeeds when interface schema declares inputs" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid = try randomUuid(alloc);
    const tenant_uuid = try randomUuid(alloc);
    const module_id = try bpm.uuid.newUuidV4(alloc);
    defer alloc.free(module_id);

    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_uuid, "tenant-plc2-01");
    }

    const params = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_uuid,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "{\"inputs\": [{\"name\": \"param1\", \"type\": \"string\"}]}",
        .exportable = true,
    };
    const reg_e = try catalog.registerModule(alloc, params);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_e);

    const result = try catalog.publishModule(alloc, module_id, "1.0.0", try randomUuid(alloc));
    defer {
        alloc.free(result.entry.module_id);
        alloc.free(result.entry.version);
        alloc.free(result.entry.interface_schema_json);
    }

    try std.testing.expectEqual(bpm.process_module_catalog.ModuleStatus.active, result.entry.status);
}

test "TC-PLC-02-02: publish succeeds when interface schema declares outputs" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid = try randomUuid(alloc);
    const tenant_uuid = try randomUuid(alloc);
    const module_id = try bpm.uuid.newUuidV4(alloc);
    defer alloc.free(module_id);

    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_uuid, "tenant-plc2-02");
    }

    const params = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_uuid,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "{\"outputs\": [{\"name\": \"result\", \"type\": \"string\"}]}",
        .exportable = false,
    };
    const reg_e = try catalog.registerModule(alloc, params);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_e);

    const result = try catalog.publishModule(alloc, module_id, "1.0.0", try randomUuid(alloc));
    defer {
        alloc.free(result.entry.module_id);
        alloc.free(result.entry.version);
        alloc.free(result.entry.interface_schema_json);
    }

    try std.testing.expectEqual(bpm.process_module_catalog.ModuleStatus.active, result.entry.status);
}

test "TC-PLC-02-03: publish fails when interface schema is empty object" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid = try randomUuid(alloc);
    const tenant_uuid = try randomUuid(alloc);
    const module_id = try bpm.uuid.newUuidV4(alloc);
    defer alloc.free(module_id);

    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_uuid, "tenant-plc2-03");
    }

    // Empty interface schema — cannot be published.
    const params = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_uuid,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "{}",
        .exportable = true,
    };
    const reg_e = try catalog.registerModule(alloc, params);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_e);

    const result = catalog.publishModule(alloc, module_id, "1.0.0", try randomUuid(alloc));
    try std.testing.expectError(bpm.process_module_catalog.ModuleCatalogError.InterfaceNotDeclared, result);
}

test "TC-PLC-02-04: publish fails when interface schema is absent (empty string)" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid = try randomUuid(alloc);
    const tenant_uuid = try randomUuid(alloc);
    const module_id = try bpm.uuid.newUuidV4(alloc);
    defer alloc.free(module_id);

    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_uuid, "tenant-plc2-04");
    }

    const params = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_uuid,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "",
        .exportable = true,
    };
    const reg_e = try catalog.registerModule(alloc, params);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_e);

    const result = catalog.publishModule(alloc, module_id, "1.0.0", try randomUuid(alloc));
    try std.testing.expectError(bpm.process_module_catalog.ModuleCatalogError.InterfaceNotDeclared, result);
}

test "TC-PLC-02-05: publish fails when module is already ACTIVE" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid = try randomUuid(alloc);
    const tenant_uuid = try randomUuid(alloc);
    const module_id = try bpm.uuid.newUuidV4(alloc);
    defer alloc.free(module_id);

    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_uuid, "tenant-plc2-05");
    }

    const params = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_uuid,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "{\"inputs\": []}",
        .exportable = true,
    };
    const reg_e = try catalog.registerModule(alloc, params);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_e);
    const pub_r = try catalog.publishModule(alloc, module_id, "1.0.0", try randomUuid(alloc));
    defer bpm.process_module_catalog.freeEntry(alloc, pub_r.entry);

    // Publish again — already active.
    const result = catalog.publishModule(alloc, module_id, "1.0.0", try randomUuid(alloc));
    try std.testing.expectError(bpm.process_module_catalog.ModuleCatalogError.ModuleAlreadyActive, result);
}

test "TC-PLC-02-06: publish fails when module does not exist" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const result = catalog.publishModule(alloc, "non-existent-module", "1.0.0", try randomUuid(alloc));
    try std.testing.expectError(bpm.process_module_catalog.ModuleCatalogError.ModuleNotFound, result);
}
