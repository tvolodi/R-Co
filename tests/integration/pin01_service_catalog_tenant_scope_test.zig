// Integration tests for the PIN-01 REWORK 1 fix (SECURITY-REVIEWER INV-1):
// PinResolver.resolveServiceCatalogRef() must bind the requesting tenant as a
// parameterized ::uuid against service_catalog.owner_tenant_id, not rely on
// the dropped bpm_effective_tenant_id() SQL function (removed by the
// LEGACY_RLS-to-SCHEMA cutover migrations GBL-116/123/130/131) or on a
// session GUC that SCHEMA mode never sets.
//
// Mirrors the existing SVC-01 coverage in svc01_service_catalog_scope_test.zig
// (TC-SVC-01-07 getServiceForTenant cross-tenant test) but exercises the
// PinResolver.resolve() code path directly — the live POST /api/v1/instances
// path reached via src/engine/instance.zig InstanceStore.create() Step d.5.
//
// Tests:
//   - PinResolver.resolve() cannot resolve tenant B's tenant-scoped
//     service_catalog entry when called with tenant A's tenant_id
//     (returns ResolutionError.UnresolvedCatalogRef, not a 42883 crash).
//   - PinResolver.resolve() DOES resolve a tenant-scoped service_catalog
//     entry for its own owning tenant.
//   - PinResolver.resolve() resolves a scope='global' service_catalog entry
//     for any tenant.

const std = @import("std");
const portable_env = @import("env");
const pg = @import("pg");
const bpm = @import("bpm");
const helpers = @import("helpers.zig");

// Root-level export required so pool connections apply tenant-schema search_path
// instead of falling back to search_path=public (see audit_iss103_test.zig).
pub const api_tenant_context = bpm.api_tenant_context;

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const PinResolver = bpm.pin_resolver.PinResolver;
const ResolutionInput = bpm.pin_resolver.ResolutionInput;
const ResolutionError = bpm.pin_resolver.ResolutionError;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const GraphNode = bpm.definition.GraphNode;

// ---------------------------------------------------------------------------
// Helpers (local copies matching svc01_service_catalog_scope_test.zig's
// conventions — per-test random fixtures, no hardcoded UUIDs/slugs).
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

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    fillRandom(&raw);
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

fn parseUuid36(s: []const u8) ![16]u8 {
    if (s.len != 36) return error.InvalidUuid;
    var buf: [32]u8 = undefined;
    var j: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (j >= 32) return error.InvalidUuid;
        buf[j] = c;
        j += 1;
    }
    if (j != 32) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, buf[0..32]);
    return out;
}

/// Insert a fixture tenant via `pool` (NOT TestHarness's h.conn, which lives
/// inside a rolled-back transaction — see ISS-0144 / GH-454, the same
/// pitfall documented in svc01_service_catalog_scope_test.zig's
/// insertTenantViaPool()). PinResolver.resolve() acquires its own connection
/// from `pool`, so any fixture it must see has to be committed through the
/// same pool.
fn insertTenantViaPool(alloc: std.mem.Allocator, pool: *Pool, id_hex: []const u8, label: []const u8) !void {
    const unique_slug = try std.fmt.allocPrint(alloc, "{s}-{s}", .{ label, id_hex });
    defer alloc.free(unique_slug);

    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, $2, now(), 'test', $4::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ id_hex, unique_slug, label, "00000000-0000-0000-0000-000000000000" },
    );
}

fn insertScopedServiceViaPool(pool: *Pool, svc_id: []const u8, owner_hex: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.service_catalog
        \\  (service_id, endpoint_url, request_schema, response_schema,
        \\   required_auth, timeout_ms, retry_policy, scope, owner_tenant_id)
        \\VALUES ($1, 'https://example.com', '{}', '{}', 'NONE', 5000, '{}', 'tenant', $2::uuid)
        \\ON CONFLICT (service_id) DO NOTHING
    ,
        &.{ svc_id, owner_hex },
    );
}

fn insertGlobalServiceViaPool(pool: *Pool, svc_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.service_catalog
        \\  (service_id, endpoint_url, request_schema, response_schema,
        \\   required_auth, timeout_ms, retry_policy, scope, owner_tenant_id)
        \\VALUES ($1, 'https://example.com', '{}', '{}', 'NONE', 5000, '{}', 'global', NULL)
        \\ON CONFLICT (service_id) DO NOTHING
    ,
        &.{svc_id},
    );
}

fn deleteServiceCatalogEntry(pool: *Pool, svc_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM public.service_catalog WHERE service_id = $1", &.{svc_id}) catch {};
}

fn randomId(buf: *[8]u8) []const u8 {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    fillRandom(buf);
    for (buf) |*b| b.* = chars[@as(usize, b.*) % chars.len];
    return buf;
}

/// A minimal DefinitionGraph carrying exactly one SERVICE_TASK node whose
/// attributes name `service_id` — the shape PinResolver.resolve() Step 2/3
/// scans for (pin_resolver.zig extractStringField(attrs, "service_id")).
fn oneServiceTaskGraph(allocator: std.mem.Allocator, service_id: []const u8) !DefinitionGraph {
    const attrs = try std.fmt.allocPrint(allocator, "{{\"service_id\":\"{s}\"}}", .{service_id});
    const nodes = try allocator.alloc(GraphNode, 1);
    nodes[0] = GraphNode{
        .id = try allocator.dupe(u8, "svc-task-1"),
        .node_type = .SERVICE_TASK,
        .label = null,
        .attributes = attrs,
    };
    return DefinitionGraph{ .nodes = nodes, .edges = &.{} };
}

fn freeOneServiceTaskGraph(allocator: std.mem.Allocator, graph: DefinitionGraph) void {
    allocator.free(graph.nodes[0].id);
    if (graph.nodes[0].attributes) |a| allocator.free(a);
    allocator.free(graph.nodes);
}

fn testPool(alloc: std.mem.Allocator) !Pool {
    const env = portable_env.globalEnviron();
    const url = env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping pin01 tenant scope test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer alloc.free(url);
    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
}

fn freePinnedVersions(alloc: std.mem.Allocator, pins: []bpm.pin_resolver.PinnedVersion) void {
    for (pins) |p| {
        alloc.free(p.ref);
        alloc.free(p.resolved_id);
        alloc.free(p.version);
    }
    alloc.free(pins);
}

// ---------------------------------------------------------------------------
// TC-PIN01-RW1-01: cross-tenant resolution is rejected
// ---------------------------------------------------------------------------

test "pin01 rework1: resolveServiceCatalogRef cannot resolve another tenant's scoped service" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var pool = try testPool(alloc);
    defer pool.deinit();

    // Owner tenant (B) owns the service; caller tenant (A) is the attacker.
    const owner_hex = try randomUuidStr(alloc);
    defer alloc.free(owner_hex);
    const caller_hex = try randomUuidStr(alloc);
    defer alloc.free(caller_hex);
    try insertTenantViaPool(alloc, &pool, owner_hex, "pin01-rw1-owner");
    try insertTenantViaPool(alloc, &pool, caller_hex, "pin01-rw1-caller");

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin01-xt-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertScopedServiceViaPool(&pool, svc_id, owner_hex);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    const tid_caller = try parseUuid36(caller_hex);

    var resolver = PinResolver.init(&pool);
    const graph = try oneServiceTaskGraph(alloc, svc_id);
    defer freeOneServiceTaskGraph(alloc, graph);

    const conn = try pool.acquire();
    defer pool.release(conn);

    var def_id_bytes: [16]u8 = undefined;
    fillRandom(&def_id_bytes);

    // Caller (tenant A, NOT the owner) must NOT be able to resolve tenant B's
    // scoped service_catalog entry. Before the REWORK 1 fix this either
    // crashed with Postgres 42883 (bpm_effective_tenant_id() undefined) or,
    // if that function still existed, could never correctly scope at all
    // under SCHEMA mode. After the fix it must cleanly return
    // UnresolvedCatalogRef — proving the SQL predicate is actually bound to
    // the caller's tenant, not silently permissive.
    const result = resolver.resolve(alloc, conn, ResolutionInput{
        .definition_id = def_id_bytes,
        .tenant_id = tid_caller,
        .graph = graph,
        .initial_variables = "{}",
        .pin_overrides = null,
    });
    try std.testing.expectError(ResolutionError.UnresolvedCatalogRef, result);
}

// ---------------------------------------------------------------------------
// TC-PIN01-RW1-02: same-tenant resolution still works
// ---------------------------------------------------------------------------

test "pin01 rework1: resolveServiceCatalogRef resolves the owning tenant's own scoped service" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var pool = try testPool(alloc);
    defer pool.deinit();

    const owner_hex = try randomUuidStr(alloc);
    defer alloc.free(owner_hex);
    try insertTenantViaPool(alloc, &pool, owner_hex, "pin01-rw1-same");

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin01-st-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertScopedServiceViaPool(&pool, svc_id, owner_hex);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    const tid_owner = try parseUuid36(owner_hex);

    var resolver = PinResolver.init(&pool);
    const graph = try oneServiceTaskGraph(alloc, svc_id);
    defer freeOneServiceTaskGraph(alloc, graph);

    const conn = try pool.acquire();
    defer pool.release(conn);

    var def_id_bytes: [16]u8 = undefined;
    fillRandom(&def_id_bytes);

    const pins = try resolver.resolve(alloc, conn, ResolutionInput{
        .definition_id = def_id_bytes,
        .tenant_id = tid_owner,
        .graph = graph,
        .initial_variables = "{}",
        .pin_overrides = null,
    });
    defer freePinnedVersions(alloc, pins);

    var found_catalog_pin = false;
    for (pins) |p| {
        if (p.kind == .catalog_entry) {
            try std.testing.expectEqualStrings(svc_id, p.ref);
            found_catalog_pin = true;
        }
    }
    try std.testing.expect(found_catalog_pin);
}

// ---------------------------------------------------------------------------
// TC-PIN01-RW1-03: global-scope service resolves for any tenant
// ---------------------------------------------------------------------------

test "pin01 rework1: resolveServiceCatalogRef resolves a global-scope service for any tenant" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var pool = try testPool(alloc);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin01-gl-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    // Any tenant — deliberately NOT inserted as a fixture row, proving the
    // global branch does not require the caller's tenant to exist either.
    const caller_hex = try randomUuidStr(alloc);
    defer alloc.free(caller_hex);
    const tid_caller = try parseUuid36(caller_hex);

    var resolver = PinResolver.init(&pool);
    const graph = try oneServiceTaskGraph(alloc, svc_id);
    defer freeOneServiceTaskGraph(alloc, graph);

    const conn = try pool.acquire();
    defer pool.release(conn);

    var def_id_bytes: [16]u8 = undefined;
    fillRandom(&def_id_bytes);

    const pins = try resolver.resolve(alloc, conn, ResolutionInput{
        .definition_id = def_id_bytes,
        .tenant_id = tid_caller,
        .graph = graph,
        .initial_variables = "{}",
        .pin_overrides = null,
    });
    defer freePinnedVersions(alloc, pins);

    var found_catalog_pin = false;
    for (pins) |p| {
        if (p.kind == .catalog_entry) {
            try std.testing.expectEqualStrings(svc_id, p.ref);
            found_catalog_pin = true;
        }
    }
    try std.testing.expect(found_catalog_pin);
}
