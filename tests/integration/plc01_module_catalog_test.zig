//! Integration tests for PLC-01: Process module catalog — registration and resolution.
//!
//! Tests:
//!   - Register a new module version in DRAFT status.
//!   - Duplicate (module_id, version) pair is rejected.
//!   - Empty module_id / version are rejected at registration.
//!   - resolveModuleRef resolves the owning tenant's own ACTIVE module.
//!   - resolveModuleRef returns unresolved when no version satisfies constraint.
//!   - resolveModuleRef selects highest semver when multiple ACTIVE versions exist.
//!   - module_id is globally unique across tenants.
//!
//! BPM_TEST_DB_URL must be set; connects to a real PostgreSQL (DIRECTIVE T-1).
//! Uses per-test UUID fixtures; no hardcoded IDs.

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
    return std.fmt.allocPrint(allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
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
            std.debug.print("BPM_TEST_DB_URL not set — skipping PLC-01 integration tests\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer allocator.free(url);
    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 3 });
}

/// Insert a fixture tenant into `public.tenant` via `conn` (committed immediately).
/// This is needed for foreign-key checks and for pool connections that look up
/// tenant existence.
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

test "TC-PLC-01-01: register a new module version in DRAFT status" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid = try randomUuid(alloc);
    const tenant_uuid = try randomUuid(alloc);

    // Insert the owning tenant via pool connection (committed so catalog sees it).
    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_uuid, "tenant-a");
    }

    const params = RegisterModuleParams{
        .module_id = try bpm.uuid.newUuidV4(alloc),
        .version = "1.0.0",
        .owning_tenant_id = tenant_uuid,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "{}",
        .exportable = true,
    };
    defer alloc.free(params.module_id);

    const entry = try catalog.registerModule(alloc, params);
    defer {
        alloc.free(entry.module_id);
        alloc.free(entry.version);
        alloc.free(entry.interface_schema_json);
    }

    try std.testing.expectEqualStrings("1.0.0", entry.version);
    try std.testing.expectEqual(bpm.process_module_catalog.ModuleStatus.draft, entry.status);
    try std.testing.expect(entry.exportable);
}

test "TC-PLC-01-02: registerModule rejects duplicate (module_id, version)" {
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
        try insertTenant(conn, alloc, tenant_uuid, "tenant-dup");
    }

    const params1 = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_uuid,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "{}",
        .exportable = true,
    };

    // First registration succeeds.
    const reg_entry_1 = try catalog.registerModule(alloc, params1);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_entry_1);

    // Second registration with same module_id + version is rejected.
    const params2 = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_uuid,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "{}",
        .exportable = false,
    };

    const result = catalog.registerModule(alloc, params2);
    try std.testing.expectError(bpm.process_module_catalog.ModuleCatalogError.DuplicateModuleVersion, result);
}

test "TC-PLC-01-03: registerModule rejects empty module_id" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const params = RegisterModuleParams{
        .module_id = "",
        .version = "1.0.0",
        .owning_tenant_id = try randomUuid(alloc),
        .owning_definition_id = try randomUuid(alloc),
        .interface_schema_json = "{}",
        .exportable = true,
    };

    const result = catalog.registerModule(alloc, params);
    try std.testing.expectError(bpm.process_module_catalog.ModuleCatalogError.UnresolvedModuleRef, result);
}

test "TC-PLC-01-04: registerModule rejects empty version" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const params = RegisterModuleParams{
        .module_id = try bpm.uuid.newUuidV4(alloc),
        .version = "",
        .owning_tenant_id = try randomUuid(alloc),
        .owning_definition_id = try randomUuid(alloc),
        .interface_schema_json = "{}",
        .exportable = true,
    };
    defer alloc.free(params.module_id);

    const result = catalog.registerModule(alloc, params);
    try std.testing.expectError(bpm.process_module_catalog.ModuleCatalogError.InvalidVersionConstraint, result);
}

test "TC-PLC-01-05: resolveModuleRef resolves own tenant's ACTIVE module" {
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
        try insertTenant(conn, alloc, tenant_uuid, "tenant-resolve");
    }

    // Register and publish.
    const params = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_uuid,
        .owning_definition_id = def_uuid,
        .interface_schema_json = "{\"inputs\": [{\"name\": \"x\", \"type\": \"string\"}]}",
        .exportable = true,
    };
    const reg_entry = try catalog.registerModule(alloc, params);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_entry);
    const pub_result = try catalog.publishModule(alloc, module_id, "1.0.0", try randomUuid(alloc));
    defer bpm.process_module_catalog.freeEntry(alloc, pub_result.entry);

    // Resolve from the same tenant.
    const ref = ModuleRef{ .module_id = module_id, .version_constraint = "*" };
    const result = try catalog.resolveModuleRef(alloc, ref, tenant_uuid);
    defer {
        if (result.entry) |e| {
            alloc.free(e.module_id);
            alloc.free(e.version);
            alloc.free(e.interface_schema_json);
        }
    }

    try std.testing.expect(result.resolved);
    try std.testing.expect(result.entry != null);
    try std.testing.expectEqualStrings("1.0.0", result.entry.?.version);
}

test "TC-PLC-01-06: resolveModuleRef returns unresolved when no version satisfies constraint" {
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
        try insertTenant(conn, alloc, tenant_uuid, "tenant-unres");
    }

    const params = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_uuid,
        .owning_definition_id = def_uuid,
        // TC-PLC-01-06: a version that no constraint can satisfy. Per PLC-02
        // (publishModule), "{}" is not a declared interface — must have at
        // least one of inputs/outputs to publish. Use a valid empty-inputs
        // schema so the module can be published; the assertion below only
        // cares about constraint non-satisfaction, not the schema shape.
        .interface_schema_json = "{\"inputs\": []}",
        .exportable = true,
    };
    const reg_entry = try catalog.registerModule(alloc, params);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_entry);
    const pub_result = try catalog.publishModule(alloc, module_id, "1.0.0", try randomUuid(alloc));
    defer bpm.process_module_catalog.freeEntry(alloc, pub_result.entry);

    // Constraint that no version satisfies.
    const ref = ModuleRef{ .module_id = module_id, .version_constraint = ">=2.0.0" };
    const result = try catalog.resolveModuleRef(alloc, ref, tenant_uuid);

    try std.testing.expect(!result.resolved);
    try std.testing.expect(result.entry == null);
    try std.testing.expect(result.error_code != null);
    try std.testing.expectEqualStrings("UNRESOLVED_MODULE_REF", result.error_code.?);
}

test "TC-PLC-01-07: resolveModuleRef prefers highest semver when multiple ACTIVE exist" {
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
        try insertTenant(conn, alloc, tenant_uuid, "tenant-semver");
    }

    // TC-PLC-01-07: per PLC-01 spec, module_id is unique per publishing tenant,
    // so multiple ACTIVE versions of the same module_id may coexist. This
    // migration (1162) relaxed the (incorrect) global uniqueness constraint.
    inline for (&.{ "1.0.0", "1.1.0", "2.0.0" }) |ver| {
        const p = RegisterModuleParams{
            .module_id = module_id,
            .version = ver,
            .owning_tenant_id = tenant_uuid,
            .owning_definition_id = def_uuid,
            .interface_schema_json = "{\"inputs\": []}",
            .exportable = true,
        };
        const reg_e = try catalog.registerModule(alloc, p);
        defer bpm.process_module_catalog.freeEntry(alloc, reg_e);
        const pub_r = try catalog.publishModule(alloc, module_id, ver, try randomUuid(alloc));
        defer bpm.process_module_catalog.freeEntry(alloc, pub_r.entry);
    }

    const ref = ModuleRef{ .module_id = module_id, .version_constraint = "*" };
    const result = try catalog.resolveModuleRef(alloc, ref, tenant_uuid);
    defer {
        if (result.entry) |e| {
            alloc.free(e.module_id);
            alloc.free(e.version);
            alloc.free(e.interface_schema_json);
        }
    }

    try std.testing.expect(result.resolved);
    try std.testing.expectEqualStrings("2.0.0", result.entry.?.version);
}

test "TC-PLC-01-08: module_id is globally unique (not per-tenant)" {
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    var alloc = std.testing.allocator;
    var pool = try makePool(alloc);
    defer pool.deinit();

    var catalog = ProcessModuleCatalog.init(alloc, &pool);

    const def_uuid_a = try randomUuid(alloc);
    const def_uuid_b = try randomUuid(alloc);
    const tenant_a = try randomUuid(alloc);
    const tenant_b = try randomUuid(alloc);
    const module_id = try bpm.uuid.newUuidV4(alloc);
    defer alloc.free(module_id);

    {
        var conn = try pool.acquire();
        _ = &conn;
        defer pool.release(conn);
        try insertTenant(conn, alloc, tenant_a, "tenant-ga");
        try insertTenant(conn, alloc, tenant_b, "tenant-gb");
    }

    // Tenant A registers the module.
    const params_a = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_a,
        .owning_definition_id = def_uuid_a,
        .interface_schema_json = "{}",
        .exportable = true,
    };
    const reg_entry_a = try catalog.registerModule(alloc, params_a);
    defer bpm.process_module_catalog.freeEntry(alloc, reg_entry_a);

    // Tenant B attempts the same module_id — must fail with DuplicateModuleVersion.
    const params_b = RegisterModuleParams{
        .module_id = module_id,
        .version = "1.0.0",
        .owning_tenant_id = tenant_b,
        .owning_definition_id = def_uuid_b,
        .interface_schema_json = "{}",
        .exportable = true,
    };
    const result = catalog.registerModule(alloc, params_b);
    try std.testing.expectError(bpm.process_module_catalog.ModuleCatalogError.DuplicateModuleVersion, result);
}
