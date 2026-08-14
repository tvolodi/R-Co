//! Integration tests for SOL-02 — Solution pack installation.
//!
//! Covers:
//!   TC-SOL02-01: Happy path install → DRAFT defs created, role checklist returned
//!   TC-SOL02-02: Service catalog conflict → CatalogConflict, transaction rolled back
//!   TC-SOL02-03: Matching existing catalog entry → reused, no conflict
//!   TC-SOL02-04: Re-install same pack version → idempotent (warning returned)
//!   TC-SOL02-05: installPack returns TenantInactive when target tenant status != ACTIVE
//!
//! Per-test isolation: every test uses a per-test UUID as pack_id; every test
//! registers a defer cleanup block. No error.SkipZigTest on MUST tests.
//!
//! BPM_TEST_DB_URL must be set; tests fail with a clear error when absent.
//!
//! Requirement traceability: SOL-02 AC1..AC5 → TC-SOL02-01..05

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
const PackedCatalogEntry = bpm.solution_pack_store.PackedCatalogEntry;
const PackedVariableSchema = bpm.solution_pack_store.PackedVariableSchema;
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
                "BPM_TEST_DB_URL is not set — SOL-02 integration tests FAILED (env var required)\n",
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
    // Remove definitions created by this install (FK ON DELETE SET NULL, so must delete first).
    conn.exec(
        \\DELETE FROM process_definitions
        \\WHERE solution_pack_install_id IN (
        \\  SELECT id FROM solution_pack_installs WHERE pack_id = $1
        \\)
    ,
        &[_][]const u8{pack_id},
    ) catch {};
    // CASCADE deletes solution_pack_role_map rows.
    conn.exec(
        "DELETE FROM solution_pack_installs WHERE pack_id = $1",
        &[_][]const u8{pack_id},
    ) catch {};
}

fn cleanupServiceCatalog(pool: *pool_mod.Pool, service_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM public.service_catalog WHERE service_id = $1",
        &[_][]const u8{service_id},
    ) catch {};
}

fn cleanupTenantRole(pool: *pool_mod.Pool, role_name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM tenant_role WHERE name = $1", &[_][]const u8{role_name}) catch {};
}

fn preInsertServiceCatalog(
    pool: *pool_mod.Pool,
    service_id: []const u8,
    req_schema: []const u8,
    resp_schema: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.service_catalog
        \\    (service_id, endpoint_url, request_schema, response_schema,
        \\     required_auth, timeout_ms, retry_policy, scope)
        \\VALUES ($1, 'https://test.example.com/svc', $2::jsonb, $3::jsonb,
        \\        'NONE', 30000, 'null'::jsonb, 'global')
        \\ON CONFLICT (service_id) DO NOTHING
    ,
        &[_][]const u8{ service_id, req_schema, resp_schema },
    );
}

/// Count solution_pack_installs rows for the given pack_id.
fn countInstallRows(
    pool: *pool_mod.Pool,
    alloc: std.mem.Allocator,
    pack_id: []const u8,
) !i64 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    const row = try conn.queryRow(
        alloc,
        "SELECT COUNT(*)::text FROM solution_pack_installs WHERE pack_id = $1",
        &[_][]const u8{pack_id},
    );
    defer if (row) |r| {
        for (r) |c| if (c) |v| alloc.free(v);
        alloc.free(r);
    };
    if (row == null) return 0;
    return std.fmt.parseInt(i64, row.?[0] orelse "0", 10) catch 0;
}

/// Free all memory owned by an InstallResult.
fn freeInstallResult(alloc: std.mem.Allocator, result: bpm.solution_pack_store.InstallResult) void {
    for (result.installed_definitions) |d| {
        alloc.free(d.source_definition_id);
        alloc.free(d.new_definition_id);
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

// ---------------------------------------------------------------------------
// TC-SOL02-01: Happy path install → DRAFT defs created, role checklist.
// ---------------------------------------------------------------------------

test "TC-SOL02-01: installPack creates DRAFT definitions and returns role checklist with unbound role" {
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
    const src_def_id = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(src_def_id);

    defer cleanupInstall(&pool, pack_id);

    const role_name = try std.fmt.allocPrint(alloc, "sol02-role-tc01-{s}", .{pack_id[0..8]});
    defer alloc.free(role_name);
    defer cleanupTenantRole(&pool, role_name);

    const roles = [_][]const u8{role_name};
    const defs = [_]PackedDefinition{.{
        .definition_id = src_def_id,
        .process_key = "sol02-tc01-process",
        .name = "sol02-tc01-process",
        .version = "1.0.0",
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
        .manifest = PackManifest{ .required_roles = &roles },
    };

    var store = SolutionPackStore.init(&pool);
    const result = store.installPack(alloc, doc, ACTOR_ID) catch |err| {
        std.debug.print("TC-SOL02-01: installPack failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer freeInstallResult(alloc, result);

    try testing.expectEqual(@as(usize, 1), result.installed_definitions.len);
    try testing.expectEqualStrings("DRAFT", result.installed_definitions[0].status);
    try testing.expectEqualStrings(src_def_id, result.installed_definitions[0].source_definition_id);
    // new_definition_id is a fresh UUID assigned by the platform.
    try testing.expectEqual(@as(usize, 36), result.installed_definitions[0].new_definition_id.len);

    try testing.expectEqual(@as(usize, 1), result.role_mapping_checklist.len);
    try testing.expectEqualStrings(role_name, result.role_mapping_checklist[0].role_name);
    try testing.expect(!result.role_mapping_checklist[0].bound);

    // Verify DB row exists.
    const count = try countInstallRows(&pool, alloc, pack_id);
    try testing.expectEqual(@as(i64, 1), count);
}

// ---------------------------------------------------------------------------
// TC-SOL02-02: Catalog conflict → CatalogConflict error, no install row.
// ---------------------------------------------------------------------------

test "TC-SOL02-02: installPack with conflicting service_catalog entry returns CatalogConflict" {
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
    const src_def_id = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(src_def_id);

    const svc_id = try std.fmt.allocPrint(alloc, "sol02-conflict-svc-{s}", .{pack_id[0..8]});
    defer alloc.free(svc_id);

    defer cleanupInstall(&pool, pack_id);
    defer cleanupServiceCatalog(&pool, svc_id);

    // Pre-insert catalog entry with schema version "v1".
    try preInsertServiceCatalog(&pool, svc_id, "{\"v\":\"1\"}", "{}");

    // Pack has the same service_id but different request_schema.
    const catalog_entries = [_]PackedCatalogEntry{.{
        .service_id = svc_id,
        .endpoint_url = "https://test.example.com/svc",
        .request_schema = "{\"v\":\"2\"}",
        .response_schema = "{}",
        .required_auth = "NONE",
        .timeout_ms = 30000,
        .retry_policy = "null",
    }};
    const defs = [_]PackedDefinition{.{
        .definition_id = src_def_id,
        .process_key = "sol02-tc02-process",
        .name = "sol02-tc02-process",
        .version = "1.0.0",
        .graph = MINIMAL_GRAPH,
        .variable_schema = "{}",
    }};

    const doc = SolutionPackDocument{
        .pack_id = pack_id,
        .version = "1.0.0",
        .bpm_export_schema_version = PACK_SCHEMA_VERSION,
        .exported_at = "2026-08-14T00:00:00Z",
        .definitions = &defs,
        .service_catalog_entries = &catalog_entries,
        .variable_schemas = &.{},
        .manifest = PackManifest{ .required_roles = &.{} },
    };

    var store = SolutionPackStore.init(&pool);
    const result = store.installPack(alloc, doc, ACTOR_ID);

    try testing.expectError(SolutionPackError.CatalogConflict, result);

    // Transaction must have been rolled back — no install row.
    const count = try countInstallRows(&pool, alloc, pack_id);
    try testing.expectEqual(@as(i64, 0), count);
}

// ---------------------------------------------------------------------------
// TC-SOL02-03: Matching catalog entry → reused, no conflict.
// ---------------------------------------------------------------------------

test "TC-SOL02-03: installPack with identical existing catalog entry reuses it without conflict" {
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
    const src_def_id = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(src_def_id);

    const svc_id = try std.fmt.allocPrint(alloc, "sol02-reuse-svc-{s}", .{pack_id[0..8]});
    defer alloc.free(svc_id);

    defer cleanupInstall(&pool, pack_id);
    defer cleanupServiceCatalog(&pool, svc_id);

    // Pre-insert catalog entry — SAME schemas as the pack will carry.
    try preInsertServiceCatalog(&pool, svc_id, "{}", "{}");

    // Pack carries the identical schemas → should be reused without error.
    const catalog_entries = [_]PackedCatalogEntry{.{
        .service_id = svc_id,
        .endpoint_url = "https://test.example.com/svc",
        .request_schema = "{}",
        .response_schema = "{}",
        .required_auth = "NONE",
        .timeout_ms = 30000,
        .retry_policy = "null",
    }};
    const defs = [_]PackedDefinition{.{
        .definition_id = src_def_id,
        .process_key = "sol02-tc03-process",
        .name = "sol02-tc03-process",
        .version = "1.0.0",
        .graph = MINIMAL_GRAPH,
        .variable_schema = "{}",
    }};

    const doc = SolutionPackDocument{
        .pack_id = pack_id,
        .version = "1.0.0",
        .bpm_export_schema_version = PACK_SCHEMA_VERSION,
        .exported_at = "2026-08-14T00:00:00Z",
        .definitions = &defs,
        .service_catalog_entries = &catalog_entries,
        .variable_schemas = &.{},
        .manifest = PackManifest{ .required_roles = &.{} },
    };

    var store = SolutionPackStore.init(&pool);
    const result = store.installPack(alloc, doc, ACTOR_ID) catch |err| {
        std.debug.print("TC-SOL02-03: installPack failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer freeInstallResult(alloc, result);

    try testing.expectEqual(@as(usize, 1), result.installed_definitions.len);

    // Exactly one service_catalog row for this service_id.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const row = try conn.queryRow(
            alloc,
            "SELECT COUNT(*)::text FROM public.service_catalog WHERE service_id = $1",
            &[_][]const u8{svc_id},
        );
        defer if (row) |r| {
            for (r) |c| if (c) |v| alloc.free(v);
            alloc.free(r);
        };
        const cnt_str = if (row) |r| r[0] orelse "0" else "0";
        const cnt = try std.fmt.parseInt(i64, cnt_str, 10);
        try testing.expectEqual(@as(i64, 1), cnt);
    }
}

// ---------------------------------------------------------------------------
// TC-SOL02-04: Re-install same pack version → idempotent.
// ---------------------------------------------------------------------------

test "TC-SOL02-04: installPack with duplicate (pack_id, version) is idempotent — returns warning" {
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
    const src_def_id = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(src_def_id);

    defer cleanupInstall(&pool, pack_id);

    const defs = [_]PackedDefinition{.{
        .definition_id = src_def_id,
        .process_key = "sol02-tc04-process",
        .name = "sol02-tc04-process",
        .version = "1.0.0",
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
        .manifest = PackManifest{ .required_roles = &.{} },
    };

    var store = SolutionPackStore.init(&pool);

    // First install: should succeed.
    const first = store.installPack(alloc, doc, ACTOR_ID) catch |err| {
        std.debug.print("TC-SOL02-04: first installPack failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer freeInstallResult(alloc, first);
    try testing.expectEqual(@as(usize, 1), first.installed_definitions.len);

    // Second install (same doc) must return without error and include a warning.
    const second = store.installPack(alloc, doc, ACTOR_ID) catch |err| {
        std.debug.print("TC-SOL02-04: second installPack failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer freeInstallResult(alloc, second);

    try testing.expect(second.warnings.len > 0);
    const has_idem_warning = for (second.warnings) |w| {
        if (std.mem.indexOf(u8, w, "already installed") != null) break true;
    } else false;
    try testing.expect(has_idem_warning);

    // Exactly one solution_pack_installs row.
    const count = try countInstallRows(&pool, alloc, pack_id);
    try testing.expectEqual(@as(i64, 1), count);
}

// ---------------------------------------------------------------------------
// TC-SOL02-05: Tenant inactive → TenantInactive error.
// ---------------------------------------------------------------------------

test "TC-SOL02-05: installPack returns TenantInactive when target tenant status != ACTIVE; HTTP 409" {
    const alloc = testing.allocator;
    var lock_conn = try helpers.acquireIntegrationLock(alloc);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    // Use the default tenant pool to insert the suspended tenant fixture.
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(tenant_id);
    const tenant_slug = try std.fmt.allocPrint(alloc, "susp-{s}", .{tenant_id[0..8]});
    defer alloc.free(tenant_slug);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\INSERT INTO public.tenant (id, slug, display_name, status)
            \\VALUES ($1::uuid, $2, 'TC05 Inactive Tenant', 'INACTIVE')
        , &[_][]const u8{ tenant_id, tenant_slug });
    }
    // Cleanup: restore default context then delete the fixture tenant row.
    defer {
        bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
        const conn = pool.acquire() catch return;
        defer pool.release(conn);
        conn.exec(
            "DELETE FROM public.tenant WHERE id = $1::uuid",
            &[_][]const u8{tenant_id},
        ) catch {};
    }

    // Switch tenant context to the inactive tenant so installPack resolves it.
    bpm.api_tenant_context.set(tenant_id);

    const pack_id = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(pack_id);
    const src_def_id = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(src_def_id);

    const defs = [_]PackedDefinition{.{
        .definition_id = src_def_id,
        .process_key = "sol02-tc05-process",
        .name = "sol02-tc05-process",
        .version = "1.0.0",
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
        .manifest = PackManifest{ .required_roles = &.{} },
    };

    var store = SolutionPackStore.init(&pool);
    const result = store.installPack(alloc, doc, ACTOR_ID);
    try testing.expectError(SolutionPackError.TenantInactive, result);
}
