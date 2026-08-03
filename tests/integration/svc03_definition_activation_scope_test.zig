// Integration tests for SVC-03: definition activation scope validation.
//
// Tests exercise ServiceScopeValidator.validateServiceTaskReferences()
// against a real PostgreSQL service_catalog table and an in-process
// PluginRegistry. Database access requires BPM_TEST_DB_URL.
//
// Tests (TC-SVC-03-01 through TC-SVC-03-07):
//   - Activation passes for global service reference
//   - Activation passes for own-tenant scoped service
//   - Activation rejected for cross-tenant scoped service
//   - Activation rejected for unregistered service reference
//   - Activation rejected for cross-tenant plugin_handler
//   - Activation passes for own-tenant plugin_handler
//   - First violation stops validation atomically (fail-fast)

const std = @import("std");
const bpm = @import("bpm");
const helpers = @import("helpers.zig");

// Root-level export required so pool connections apply tenant-schema search_path
// instead of falling back to search_path=public (see audit_iss103_test.zig).
pub const api_tenant_context = bpm.api_tenant_context;

// ---------------------------------------------------------------------------
// UUID helper
// ---------------------------------------------------------------------------

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

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const ServiceCatalog = bpm.service_catalog.ServiceCatalog;
const RegisterServiceParams = bpm.service_catalog.RegisterServiceParams;
const ServiceScopeValidator = bpm.service_scope_validator.ServiceScopeValidator;
const ServiceScopeError = bpm.service_scope_validator.ServiceScopeError;
const plugin_registry = bpm.plugin_registry;
const plugin_interface = bpm.plugin_interface;
const PluginRegistry = plugin_registry.PluginRegistry;
const PluginScope = plugin_registry.PluginScope;

const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

fn freeServiceRecord(alloc: std.mem.Allocator, rec: bpm.service_catalog.ServiceCatalogRecord) void {
    alloc.free(rec.service_id);
    alloc.free(rec.endpoint_url);
    alloc.free(rec.request_schema);
    alloc.free(rec.response_schema);
    alloc.free(rec.retry_policy);
}

fn testDbUrl(alloc: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping SVC-03 integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

/// Build a minimal DefinitionGraph with one SERVICE_TASK node whose attributes
/// contain the provided service_id and/or plugin_handler.
fn buildServiceTaskGraph(
    alloc: std.mem.Allocator,
    node_id: []const u8,
    service_id: ?[]const u8,
    plugin_handler: ?[]const u8,
) !DefinitionGraph {
    var attrs_buf: std.ArrayList(u8) = .empty;
    defer attrs_buf.deinit(alloc);

    try attrs_buf.appendSlice(alloc, "{");
    var first = true;
    if (service_id) |sid| {
        if (!first) try attrs_buf.appendSlice(alloc, ",");
        const s = try std.fmt.allocPrint(alloc, "\"service_id\":\"{s}\"", .{sid});
        defer alloc.free(s);
        try attrs_buf.appendSlice(alloc, s);
        first = false;
    }
    if (plugin_handler) |ph| {
        if (!first) try attrs_buf.appendSlice(alloc, ",");
        const s = try std.fmt.allocPrint(alloc, "\"plugin_handler\":\"{s}\"", .{ph});
        defer alloc.free(s);
        try attrs_buf.appendSlice(alloc, s);
    }
    try attrs_buf.appendSlice(alloc, "}");

    const attrs = try alloc.dupe(u8, attrs_buf.items);
    const node_id_owned = try alloc.dupe(u8, node_id);

    const nodes = try alloc.alloc(GraphNode, 1);
    nodes[0] = GraphNode{
        .id = node_id_owned,
        .node_type = .SERVICE_TASK,
        .label = null,
        .attributes = attrs,
    };

    const edges = try alloc.alloc(GraphEdge, 0);

    return DefinitionGraph{
        .nodes = nodes,
        .edges = edges,
    };
}

fn freeGraph(alloc: std.mem.Allocator, graph: DefinitionGraph) void {
    for (graph.nodes) |n| {
        alloc.free(n.id);
        if (n.label) |l| alloc.free(l);
        if (n.attributes) |a| alloc.free(a);
    }
    alloc.free(graph.nodes);
    alloc.free(graph.edges);
}

fn stubPluginHandler(ctx: plugin_interface.PluginExecutionContext) plugin_interface.PluginHandlerInvocationError!plugin_interface.PluginHandlerOutcome {
    _ = ctx;
    return .{ .COMPLETE = .{ .output_variables_json = null } };
}

const RUNTIME_API = plugin_interface.PluginApiVersion{ .major = 1, .minor = 0 };

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

// ---------------------------------------------------------------------------
// TC-SVC-03-01: activation passes for global service reference
// ---------------------------------------------------------------------------

test "svc03: activation passes for global service reference" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    var registry = PluginRegistry.init(alloc);
    defer registry.deinit();
    plugin_registry.freezePluginRegistry(&registry);

    var rand_bytes: [8]u8 = undefined;
    fillRandom(&rand_bytes);
    var svc_id_buf: [32]u8 = undefined;
    const svc_id = try std.fmt.bufPrint(&svc_id_buf, "svc-v3-glb-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});

    const rec = try catalog.registerService(alloc, RegisterServiceParams{
        .service_id = svc_id,
        .endpoint_url = "https://example.com/v3-glb",
        .request_schema = "{}",
        .response_schema = "{}",
        .required_auth = .NONE,
        .timeout_ms = 5000,
        .retry_policy = null,
        .scope = .global,
        .owner_tenant_id = null,
    });
    defer freeServiceRecord(alloc, rec);

    const any_tenant = try parseUuid36("10000000-0000-0000-0000-000000000001");
    var validator = ServiceScopeValidator.init(alloc, &catalog, &registry);

    const graph = try buildServiceTaskGraph(alloc, "N1", svc_id, null);
    defer freeGraph(alloc, graph);

    // Must not return an error.
    try validator.validateServiceTaskReferences(graph, any_tenant);
}

// ---------------------------------------------------------------------------
// TC-SVC-03-02: activation passes for own-tenant scoped service
// ---------------------------------------------------------------------------

test "svc03: activation passes for own-tenant scoped service" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    var registry = PluginRegistry.init(alloc);
    defer registry.deinit();
    plugin_registry.freezePluginRegistry(&registry);

    // Use pre-committed fixture tenant (visible to pool connections).
    const owner_hex = try randomUuidStr(alloc);
    defer alloc.free(owner_hex);
    const tid_owner = try parseUuid36(owner_hex);

    var rand_bytes: [8]u8 = undefined;
    fillRandom(&rand_bytes);
    var svc_id_buf: [32]u8 = undefined;
    const svc_id = try std.fmt.bufPrint(&svc_id_buf, "svc-v3-own-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});

    const rec = try catalog.registerService(alloc, RegisterServiceParams{
        .service_id = svc_id,
        .endpoint_url = "https://example.com/v3-own",
        .request_schema = "{}",
        .response_schema = "{}",
        .required_auth = .NONE,
        .timeout_ms = 5000,
        .retry_policy = null,
        .scope = .tenant,
        .owner_tenant_id = tid_owner,
    });
    defer freeServiceRecord(alloc, rec);

    var validator = ServiceScopeValidator.init(alloc, &catalog, &registry);

    const graph = try buildServiceTaskGraph(alloc, "N1", svc_id, null);
    defer freeGraph(alloc, graph);

    // Must pass — service belongs to the activating tenant.
    try validator.validateServiceTaskReferences(graph, tid_owner);
}

// ---------------------------------------------------------------------------
// TC-SVC-03-03: activation rejected for cross-tenant scoped service
// ---------------------------------------------------------------------------

test "svc03: activation rejected for cross-tenant service reference" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    var registry = PluginRegistry.init(alloc);
    defer registry.deinit();
    plugin_registry.freezePluginRegistry(&registry);

    // Use pre-committed fixture tenants (visible to pool connections).
    const owner_hex = try randomUuidStr(alloc);
    defer alloc.free(owner_hex);
    const caller_hex = try randomUuidStr(alloc);
    defer alloc.free(caller_hex);
    const tid_owner = try parseUuid36(owner_hex);
    const tid_caller = try parseUuid36(caller_hex);

    var rand_bytes: [8]u8 = undefined;
    fillRandom(&rand_bytes);
    var svc_id_buf: [32]u8 = undefined;
    const svc_id = try std.fmt.bufPrint(&svc_id_buf, "svc-v3-xt-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});

    const rec = try catalog.registerService(alloc, RegisterServiceParams{
        .service_id = svc_id,
        .endpoint_url = "https://example.com/v3-xt",
        .request_schema = "{}",
        .response_schema = "{}",
        .required_auth = .NONE,
        .timeout_ms = 5000,
        .retry_policy = null,
        .scope = .tenant,
        .owner_tenant_id = tid_owner,
    });
    defer freeServiceRecord(alloc, rec);

    var validator = ServiceScopeValidator.init(alloc, &catalog, &registry);

    const graph = try buildServiceTaskGraph(alloc, "N1", svc_id, null);
    defer freeGraph(alloc, graph);

    // Different tenant — must be rejected.
    try std.testing.expectError(
        ServiceScopeError.ServiceNotAvailableToTenant,
        validator.validateServiceTaskReferences(graph, tid_caller),
    );
}

// ---------------------------------------------------------------------------
// TC-SVC-03-04: activation rejected for unregistered service reference
// ---------------------------------------------------------------------------

test "svc03: activation rejected for unregistered service reference" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    var registry = PluginRegistry.init(alloc);
    defer registry.deinit();
    plugin_registry.freezePluginRegistry(&registry);

    const any_tenant = try parseUuid36("40000000-0000-0000-0000-000000000001");
    var validator = ServiceScopeValidator.init(alloc, &catalog, &registry);

    const graph = try buildServiceTaskGraph(alloc, "N1", "svc-does-not-exist-at-all", null);
    defer freeGraph(alloc, graph);

    try std.testing.expectError(
        ServiceScopeError.ServiceNotRegistered,
        validator.validateServiceTaskReferences(graph, any_tenant),
    );
}

// ---------------------------------------------------------------------------
// TC-SVC-03-05: activation rejected for cross-tenant plugin_handler
// ---------------------------------------------------------------------------

test "svc03: activation rejected for cross-tenant plugin_handler" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    const tenant_t: [16]u8 = [_]u8{ 0x50, 0x01 } ++ [_]u8{0x00} ** 14;
    const tenant_u: [16]u8 = [_]u8{ 0x50, 0x02 } ++ [_]u8{0x00} ** 14;

    var registry = PluginRegistry.init(alloc);
    defer registry.deinit();

    // Register a tenant-T-scoped plugin.
    // node_type must equal the plugin_handler attribute value used in the graph node.
    try plugin_registry.registerPluginHandler(alloc, &registry, plugin_registry.RegisterPluginHandlerInput{
        .node_type = "cross-tenant-plugin",
        .handler = &stubPluginHandler,
        .plugin_name = "cross-tenant-plugin",
        .plugin_version = "1.0.0",
        .target_api = RUNTIME_API,
        .scope = .tenant,
        .owner_tenant_id = tenant_t,
    });
    plugin_registry.freezePluginRegistry(&registry);

    var validator = ServiceScopeValidator.init(alloc, &catalog, &registry);

    // Graph references plugin_handler "cross-tenant-plugin" — but caller is tenant_u.
    const graph = try buildServiceTaskGraph(alloc, "N1", null, "cross-tenant-plugin");
    defer freeGraph(alloc, graph);

    try std.testing.expectError(
        ServiceScopeError.PluginNotAvailableToTenant,
        validator.validateServiceTaskReferences(graph, tenant_u),
    );
}

// ---------------------------------------------------------------------------
// TC-SVC-03-06: activation passes for own-tenant plugin_handler
// ---------------------------------------------------------------------------

test "svc03: activation passes for own-tenant plugin_handler" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    const tenant_t: [16]u8 = [_]u8{ 0x60, 0x01 } ++ [_]u8{0x00} ** 14;

    var registry = PluginRegistry.init(alloc);
    defer registry.deinit();

    // Register a tenant-T-scoped plugin for "my-own-plugin".
    // node_type must equal the plugin_handler attribute value used in the graph node.
    try plugin_registry.registerPluginHandler(alloc, &registry, plugin_registry.RegisterPluginHandlerInput{
        .node_type = "my-own-plugin",
        .handler = &stubPluginHandler,
        .plugin_name = "my-own-plugin",
        .plugin_version = "1.0.0",
        .target_api = RUNTIME_API,
        .scope = .tenant,
        .owner_tenant_id = tenant_t,
    });
    plugin_registry.freezePluginRegistry(&registry);

    var validator = ServiceScopeValidator.init(alloc, &catalog, &registry);

    const graph = try buildServiceTaskGraph(alloc, "N1", null, "my-own-plugin");
    defer freeGraph(alloc, graph);

    // Caller is tenant_t — the plugin owner. Must pass.
    try validator.validateServiceTaskReferences(graph, tenant_t);
}

// ---------------------------------------------------------------------------
// TC-SVC-03-07: first violation stops validation atomically (fail-fast)
// ---------------------------------------------------------------------------

test "svc03: first scope violation stops validation atomically" {
    const alloc = std.testing.allocator;

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
    defer pool.deinit();

    var catalog = ServiceCatalog.init(alloc, &pool);
    defer catalog.deinit();

    var registry = PluginRegistry.init(alloc);
    defer registry.deinit();
    plugin_registry.freezePluginRegistry(&registry);

    // Use pre-committed fixture tenants (visible to pool connections).
    const owner_hex = try randomUuidStr(alloc);
    defer alloc.free(owner_hex);
    const caller_hex = try randomUuidStr(alloc);
    defer alloc.free(caller_hex);
    const tid_owner = try parseUuid36(owner_hex);
    const tid_caller = try parseUuid36(caller_hex);

    var rand_bytes: [8]u8 = undefined;
    fillRandom(&rand_bytes);
    var bad_svc_id_buf: [32]u8 = undefined;
    const bad_svc_id = try std.fmt.bufPrint(&bad_svc_id_buf, "svc-atom-xt-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});
    fillRandom(&rand_bytes);
    var good_svc_id_buf: [32]u8 = undefined;
    const good_svc_id = try std.fmt.bufPrint(&good_svc_id_buf, "svc-atom-ok-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});

    // Register the cross-tenant service (owned by owner, not caller).
    const rec_bad = try catalog.registerService(alloc, RegisterServiceParams{
        .service_id = bad_svc_id,
        .endpoint_url = "https://example.com/atom-xt",
        .request_schema = "{}",
        .response_schema = "{}",
        .required_auth = .NONE,
        .timeout_ms = 5000,
        .retry_policy = null,
        .scope = .tenant,
        .owner_tenant_id = tid_owner,
    });
    defer freeServiceRecord(alloc, rec_bad);

    // Register global service (would pass for any tenant).
    const rec_good = try catalog.registerService(alloc, RegisterServiceParams{
        .service_id = good_svc_id,
        .endpoint_url = "https://example.com/atom-ok",
        .request_schema = "{}",
        .response_schema = "{}",
        .required_auth = .NONE,
        .timeout_ms = 5000,
        .retry_policy = null,
        .scope = .global,
        .owner_tenant_id = null,
    });
    defer freeServiceRecord(alloc, rec_good);

    // Build a graph with TWO nodes: first cross-tenant (fails), second global (passes).
    const bad_attrs = try std.fmt.allocPrint(alloc, "{{\"service_id\":\"{s}\"}}", .{bad_svc_id});
    defer alloc.free(bad_attrs);
    const good_attrs = try std.fmt.allocPrint(alloc, "{{\"service_id\":\"{s}\"}}", .{good_svc_id});
    defer alloc.free(good_attrs);

    const nodes = try alloc.alloc(GraphNode, 2);
    defer alloc.free(nodes);
    nodes[0] = GraphNode{ .id = "N-BAD", .node_type = .SERVICE_TASK, .label = null, .attributes = bad_attrs };
    nodes[1] = GraphNode{ .id = "N-GOOD", .node_type = .SERVICE_TASK, .label = null, .attributes = good_attrs };
    const edges = try alloc.alloc(GraphEdge, 0);
    defer alloc.free(edges);
    const graph = DefinitionGraph{ .nodes = nodes, .edges = edges };

    var validator = ServiceScopeValidator.init(alloc, &catalog, &registry);

    // Must fail on the first node (cross-tenant), not pass because the second is OK.
    const result = validator.validateServiceTaskReferences(graph, tid_caller);
    try std.testing.expectError(ServiceScopeError.ServiceNotAvailableToTenant, result);

    // lastViolation() must be non-null confirming the violation was recorded.
    const viol = validator.lastViolation();
    try std.testing.expect(viol != null);
    try std.testing.expectEqualStrings("N-BAD", viol.?.node_id);
}
