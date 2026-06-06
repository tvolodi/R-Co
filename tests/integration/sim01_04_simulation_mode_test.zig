//! Integration and unit-facing tests for SIM-01 through SIM-04.

const std = @import("std");
const testing = std.testing;
const bpm = @import("bpm");
const pool_mod = bpm.db_pool;
const tenant_context = bpm.api_tenant_context;
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;
const build_options = @import("build_options");

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const Store = bpm.store.Store;
const AppendParams = bpm.store.AppendParams;
const EventRecord = bpm.store.EventRecord;
const Registry = bpm.registry.Registry;
const RegisterParams = bpm.registry.RegisterParams;
const simulation = bpm.simulation;
const uuid_mod = bpm.uuid;
const provisioning = bpm.provisioning;

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for SIM integration tests\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 4,
    });
}

/// SPT-04: full provisioning (runs migrations) so the tenant schema gets
/// all tables including events, enabling search_path-based isolation.
fn provisionTenantSchema(allocator: std.mem.Allocator, pool: *pool_mod.Pool, tenant_id: []const u8) !void {
    try provisioning.provisionTenantSchema(
        allocator,
        pool,
        tenant_id,
        build_options.migrations_dir,
    );
}

fn dropTenantSchema(pool: *pool_mod.Pool, tenant_id: []const u8) void {
    var name_buf: [80]u8 = undefined;
    const schema_name = bpm.pool.schemaNameForTenant(tenant_id, &name_buf);
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    var drop_buf: [128]u8 = undefined;
    const drop_sql = std.fmt.bufPrint(
        &drop_buf,
        "DROP SCHEMA IF EXISTS {s} CASCADE",
        .{schema_name},
    ) catch return;
    conn.exec(drop_sql, &.{}) catch {};
    conn.exec("DELETE FROM public.tenant_schemas WHERE schema_name = $1", &.{schema_name}) catch {};
    conn.exec("DELETE FROM public.schema_migrations WHERE schema_name = $1", &.{schema_name}) catch {};
}

fn parseUuidString(s: []const u8) ![16]u8 {
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (i >= buf.len) return error.InvalidUuid;
        buf[i] = c;
        i += 1;
    }
    if (i != buf.len) return error.InvalidUuid;

    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, buf[0..]);
    return out;
}

// SPT-02 (migration 062): instance_projections no longer has a row-level scope column.
// The scope_id parameter is kept for API backward compatibility but not used in SQL.
fn insertProjection(
    pool: *Pool,
    instance_id: []const u8,
    definition_id: []const u8,
    scope_id: []const u8,
) !void {
    _ = scope_id;
    const conn = try pool.acquire();
    defer pool.release(conn);

    _ = try conn.exec(
        \\INSERT INTO instance_projections (
        \\  instance_id, definition_id, status, current_nodes,
        \\  variables, last_event_seq, definition_artifact_hash,
        \\  started_at, updated_at
        \\) VALUES ($1::uuid, $2::uuid, 'ACTIVE', $3::jsonb, $4::jsonb, $5, $6, NOW(), NOW())
        \\ON CONFLICT (instance_id) DO NOTHING
    ,
        &.{ instance_id, definition_id, "[]", "{}", "0", "sim-def-hash" },
    );
}

fn cleanupSim01IsolationFixtures(
    pool: *Pool,
    sim_instance_id: []const u8,
    real_instance_id: []const u8,
    sim_scope: []const u8,
    real_scope: []const u8,
    sim_idempotency_key: []const u8,
    real_idempotency_key: []const u8,
) void {
    _ = sim_scope;
    _ = real_scope;
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("DELETE FROM events WHERE idempotency_key IN ($1, $2)", &.{ sim_idempotency_key, real_idempotency_key }) catch {};
    conn.exec("DELETE FROM instance_sequence WHERE instance_id IN ($1::uuid, $2::uuid)", &.{ sim_instance_id, real_instance_id }) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id IN ($1::uuid, $2::uuid)", &.{ sim_instance_id, real_instance_id }) catch {};
}

fn cleanupEventTypeFixture(pool: *Pool, event_type: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("DELETE FROM event_type_registry WHERE name = $1", &.{event_type}) catch {};
}

// SPT-02 (migration 062): events and instance_projections no longer have row-level scope columns.
// This cleanup now uses idempotency_key and instance_id instead.
fn cleanupTenantFixtures(pool: *Pool, scope_id: []const u8) void {
    _ = scope_id;
    _ = pool;
    // Cleanup is now handled per-test via cleanupSim01IsolationFixtures using instance_id
}

fn freeEventRecords(allocator: std.mem.Allocator, records: []EventRecord) void {
    for (records) |rec| {
        allocator.free(rec.event_type);
        allocator.free(rec.payload);
        allocator.free(rec.idempotency_key);
        allocator.free(rec.metadata);
    }
    allocator.free(records);
}

test "TC-SIM-01-01: simulation events are isolated from real tenant queries" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const event_type_suffix = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(event_type_suffix);
    const event_type = try std.fmt.allocPrint(alloc, "SIM_EVENT_{s}", .{event_type_suffix});
    defer alloc.free(event_type);

    // Remove stale registry rows from interrupted runs before registration.
    cleanupEventTypeFixture(&pool, event_type);
    defer cleanupEventTypeFixture(&pool, event_type);

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    // SPT-04: event type registration happens below, per tenant schema,
    // after both tenant schemas are provisioned.

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const seed = simulation.SimulationSeed{ .uuid_seed = 12345, .time_epoch_ms = 1716892800000 };
    const ctx = try simulation.beginSimulationRun(alloc, seed, "SIM-01-scenario");

    const real_tenant_str = try uuid_mod.newUuidV4(alloc);
    const sim_tenant_str = simulation.tenant_store.tenantIdToString(ctx.simulation_tenant_id);

    try provisionTenantSchema(alloc, &pool, real_tenant_str);
    defer dropTenantSchema(&pool, real_tenant_str);
    try provisionTenantSchema(alloc, &pool, sim_tenant_str[0..]);
    defer dropTenantSchema(&pool, sim_tenant_str[0..]);

    // SPT-04: register the event type in each tenant schema where it will be used.
    // With schema-per-tenant and full provisioning, each schema has its own
    // event_type_registry; the entry must be present in both sim and real schemas.
    tenant_context.set(real_tenant_str);
    _ = try registry.registerType(alloc, RegisterParams{
        .name = event_type,
        .schema_version = 1,
        .json_schema = "{}",
        .description = "simulation event fixture",
    });
    tenant_context.set(sim_tenant_str[0..]);
    _ = try registry.registerType(alloc, RegisterParams{
        .name = event_type,
        .schema_version = 1,
        .json_schema = "{}",
        .description = "simulation event fixture",
    });

    const sim_instance_id = try uuid_mod.newUuidV4(alloc);
    const real_instance_id = try uuid_mod.newUuidV4(alloc);
    const definition_id = try uuid_mod.newUuidV4(alloc);
    const actor_id_str = try uuid_mod.newUuidV4(alloc);
    const sim_idem_suffix = try uuid_mod.newUuidV4(alloc);
    const real_idem_suffix = try uuid_mod.newUuidV4(alloc);
    const sim_idempotency_key = try std.fmt.allocPrint(alloc, "sim-01-idem-{s}", .{sim_idem_suffix});
    const real_idempotency_key = try std.fmt.allocPrint(alloc, "sim-01-idem-{s}", .{real_idem_suffix});
    defer {
        alloc.free(real_tenant_str);
        alloc.free(sim_instance_id);
        alloc.free(real_instance_id);
        alloc.free(definition_id);
        alloc.free(actor_id_str);
        alloc.free(sim_idem_suffix);
        alloc.free(real_idem_suffix);
        alloc.free(sim_idempotency_key);
        alloc.free(real_idempotency_key);
    }

    // Explicit cleanup for fixtures inserted through pooled connections.
    cleanupSim01IsolationFixtures(&pool, sim_instance_id, real_instance_id, sim_tenant_str[0..], real_tenant_str, sim_idempotency_key, real_idempotency_key);
    defer cleanupSim01IsolationFixtures(&pool, sim_instance_id, real_instance_id, sim_tenant_str[0..], real_tenant_str, sim_idempotency_key, real_idempotency_key);

    // SPT-04: set tenant context before insertProjection so rows go into
    // the correct tenant schema (not the public fallback).
    tenant_context.set(sim_tenant_str[0..]);
    try insertProjection(&pool, sim_instance_id, definition_id, sim_tenant_str[0..]);
    tenant_context.set(real_tenant_str);
    try insertProjection(&pool, real_instance_id, definition_id, real_tenant_str);

    const actor_id = try parseUuidString(actor_id_str);
    const sim_instance_uuid = try parseUuidString(sim_instance_id);
    const real_instance_uuid = try parseUuidString(real_instance_id);
    const real_tenant_id = try simulation.tenant_store.parseTenantId(real_tenant_str);

    tenant_context.set(sim_tenant_str[0..]);
    defer tenant_context.clear();
    _ = try simulation.appendSimulationEvent(alloc, &store, &ctx, .{
        .instance_id = sim_instance_uuid,
        .event_type = event_type,
        .payload = "{\"kind\":\"simulation\"}",
        .actor_id = actor_id,
        .idempotency_key = sim_idempotency_key,
        .metadata = null,
        .pipeline_run_id = null,
    });

    tenant_context.set(real_tenant_str);
    _ = try store.append(alloc, AppendParams{
        .tenant_id = real_tenant_str,
        .instance_id = real_instance_uuid,
        .event_type = event_type,
        .payload = "{\"kind\":\"real\"}",
        .actor_id = actor_id,
        .idempotency_key = real_idempotency_key,
        .metadata = null,
        .pipeline_run_id = null,
    });

    tenant_context.set(real_tenant_str);
    const real_events = try simulation.queryTenantEvents(alloc, &store, real_tenant_id, .{
        .after_global_seq = null,
        .limit = 50,
    });
    defer freeEventRecords(alloc, real_events);

    try testing.expectEqual(@as(usize, 1), real_events.len);
    const payload_json = try std.json.parseFromSlice(std.json.Value, alloc, real_events[0].payload, .{});
    defer payload_json.deinit();
    const kind_value = payload_json.value.object.get("kind") orelse .null;
    try testing.expect(kind_value == .string);
    try testing.expectEqualStrings("real", kind_value.string);
}

test "TC-SIM-01-02: simulation tenant query path is blocked" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const seed = simulation.SimulationSeed{ .uuid_seed = 314159, .time_epoch_ms = 1716892800000 };
    const ctx = try simulation.beginSimulationRun(alloc, seed, "SIM-01-visibility");

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const sim_tenant_str = simulation.tenant_store.tenantIdToString(ctx.simulation_tenant_id);
    // Explicit cleanup documents that simulation-tenant fixtures are never leaked.
    cleanupTenantFixtures(&pool, sim_tenant_str[0..]);
    defer cleanupTenantFixtures(&pool, sim_tenant_str[0..]);

    try testing.expectError(error.SimulationVisibilityViolation, simulation.queryTenantEvents(alloc, &store, ctx.simulation_tenant_id, .{}));
}

test "TC-SIM-02-01: service call resolves from scenario mock catalog" {
    const alloc = testing.allocator;
    const seed = simulation.SimulationSeed{ .uuid_seed = 2024, .time_epoch_ms = 1716892800000 };
    const ctx = try simulation.beginSimulationRun(alloc, seed, "SIM-02-mocks");

    var catalog = simulation.ServiceMockCatalog.init(alloc);
    defer catalog.deinit();

    const fingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try catalog.put("svc.billing", fingerprint, .{
        .status_code = 200,
        .headers_json = "{\"content-type\":\"application/json\"}",
        .body = "{\"approved\":true}",
    });

    const response = try simulation.executeMockedServiceCall(alloc, &ctx, &catalog, "svc.billing", .{
        .request_fingerprint = fingerprint,
        .method = "POST",
        .path = "/charge",
        .headers_json = null,
        .body = "{\"amount\":100}",
    });
    defer response.deinit(alloc);

    try testing.expectEqual(@as(u16, 200), response.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, response.body, 1, "approved"));
}

test "TC-SIM-02-02: missing mock returns deterministic miss without fallback" {
    const alloc = testing.allocator;
    const seed = simulation.SimulationSeed{ .uuid_seed = 2025, .time_epoch_ms = 1716892800000 };
    const ctx = try simulation.beginSimulationRun(alloc, seed, "SIM-02-missing-mock");

    var catalog = simulation.ServiceMockCatalog.init(alloc);
    defer catalog.deinit();

    const fingerprint = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

    try testing.expectError(error.MockResponseNotFound, simulation.executeMockedServiceCall(alloc, &ctx, &catalog, "svc.billing", .{
        .request_fingerprint = fingerprint,
        .method = "POST",
        .path = "/charge",
        .headers_json = null,
        .body = "{\"amount\":99}",
    }));
}

test "TC-SIM-03-01: scenario-controlled clock advances deterministically" {
    var clock = simulation.PlatformClock.init(1_716_892_800_000);

    try testing.expectEqual(@as(i64, 1_716_892_800_000), clock.nowMs());
    try clock.advanceMs(5000);
    try testing.expectEqual(@as(i64, 1_716_892_805_000), clock.nowMs());
}

test "TC-SIM-03-02: programmatic time set and advance are respected" {
    var clock = simulation.PlatformClock.init(0);

    try clock.setMs(10_000);
    try testing.expectEqual(@as(i64, 10_000), clock.nowMs());

    try clock.advanceMs(250);
    try testing.expectEqual(@as(i64, 10_250), clock.nowMs());

    try testing.expectError(error.InvalidSimulationTimeAdvance, clock.advanceMs(-1));
}

test "TC-SIM-04-01: same seed yields identical UUID sequence" {
    var left = try simulation.PlatformUuidSource.init(777);
    var right = try simulation.PlatformUuidSource.init(777);

    const left_first = try left.nextUuidV4();
    const right_first = try right.nextUuidV4();
    try testing.expectEqualSlices(u8, &left_first, &right_first);

    const left_second = try left.nextUuidV4();
    const right_second = try right.nextUuidV4();
    try testing.expectEqualSlices(u8, &left_second, &right_second);
}

test "TC-SIM-04-02: different seeds yield different UUID sequence" {
    var left = try simulation.PlatformUuidSource.init(1001);
    var right = try simulation.PlatformUuidSource.init(2002);

    const left_first = try left.nextUuidV4();
    const right_first = try right.nextUuidV4();

    try testing.expect(!std.mem.eql(u8, &left_first, &right_first));
}
