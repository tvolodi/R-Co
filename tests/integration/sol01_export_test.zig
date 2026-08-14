//! Integration tests for SOL-01 — Solution pack export.
//!
//! Covers:
//!   TC-SOL01-01: Export minimal definition → doc shape correct, no deps
//!   TC-SOL01-02: Export definition with SERVICE_TASK → catalog entry included
//!   TC-SOL01-03: Export definition with two HUMAN_TASK ROLE nodes → sorted manifest
//!   TC-SOL01-04: Export unknown definition_id → DefinitionNotFound
//!
//! Per-test isolation: every test creates fixture rows with per-test UUIDs or
//! unique names; every test registers a defer cleanup block that runs on all
//! exit paths (pass and fail).  No error.SkipZigTest on MUST tests.
//!
//! BPM_TEST_DB_URL must be set; tests fail with a clear error when absent.
//!
//! Requirement traceability: SOL-01 AC1 + AC3 → TC-SOL01-01..04

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const helpers = @import("helpers.zig");
const pool_mod = bpm.pool;

const SolutionPackStore = bpm.solution_pack_store.SolutionPackStore;
const SolutionPackError = bpm.solution_pack_store.SolutionPackError;
const PACK_SCHEMA_VERSION = bpm.solution_pack_store.PACK_SCHEMA_VERSION;

// Actor UUID used as created_by for all fixture definitions.
const ACTOR_ID = "00000000-0000-0000-0000-000000000000";

// ---------------------------------------------------------------------------
// Test infrastructure
// ---------------------------------------------------------------------------

fn testDbUrl(alloc: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — SOL-01 integration tests FAILED (env var required)\n",
                .{},
            );
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(alloc: std.mem.Allocator, url: []const u8) !pool_mod.Pool {
    // Route all pool connections to tenant_default schema.
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return pool_mod.Pool.init(std.testing.io, alloc, pool_mod.PoolConfig{
        .url = url,
        .pool_size = 4,
    });
}

/// Insert a minimal process_definition row and return the assigned UUID string.
/// Caller owns the returned slice.
fn insertDefinition(
    pool: *pool_mod.Pool,
    alloc: std.mem.Allocator,
    name: []const u8,
    graph_json: []const u8,
) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    const row = try conn.queryRow(
        alloc,
        \\INSERT INTO process_definitions (name, version, description, status, graph, created_by)
        \\VALUES ($1, '1.0.0', 'sol01 test', 'DRAFT', $2::jsonb, $3::uuid)
        \\RETURNING id::text
    ,
        &[_][]const u8{ name, graph_json, ACTOR_ID },
    );
    const r = row orelse return error.InsertFailed;
    defer {
        for (r) |c| if (c) |v| alloc.free(v);
        alloc.free(r);
    }
    const id_str = r[0] orelse return error.InsertFailed;
    return alloc.dupe(u8, id_str);
}

/// Insert a public.service_catalog entry for use by export tests.
fn insertServiceCatalog(
    pool: *pool_mod.Pool,
    service_id: []const u8,
    endpoint_url: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.service_catalog
        \\    (service_id, endpoint_url, request_schema, response_schema,
        \\     required_auth, timeout_ms, retry_policy, scope)
        \\VALUES ($1, $2, '{}'::jsonb, '{}'::jsonb, 'NONE', 30000, 'null'::jsonb, 'global')
        \\ON CONFLICT (service_id) DO NOTHING
    ,
        &[_][]const u8{ service_id, endpoint_url },
    );
}

fn cleanupDefinitionByName(pool: *pool_mod.Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1",
        &[_][]const u8{name},
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

// ---------------------------------------------------------------------------
// TC-SOL01-01: Export minimal definition — correct doc shape, no deps.
// ---------------------------------------------------------------------------

test "TC-SOL01-01: exportPack with minimal definition returns well-formed SolutionPackDocument" {
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

    const def_name = try std.fmt.allocPrint(alloc, "sol01-tc01-{s}", .{uuid_str[0..8]});
    defer alloc.free(def_name);

    const simple_graph =
        \\{"nodes":[{"id":"S","node_type":"START","label":null,"attributes":null},{"id":"E","node_type":"END","label":null,"attributes":null}],"edges":[{"id":"e1","source":"S","target":"E","condition":null,"is_default":false}]}
    ;

    cleanupDefinitionByName(&pool, def_name);
    defer cleanupDefinitionByName(&pool, def_name);

    const def_id = try insertDefinition(&pool, alloc, def_name, simple_graph);
    defer alloc.free(def_id);

    var store = SolutionPackStore.init(&pool);
    const def_ids = [_][]const u8{def_id};
    const doc = store.exportPack(alloc, "1.0.0", &def_ids) catch |err| {
        std.debug.print("TC-SOL01-01: exportPack failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (doc.definitions) |d| {
            alloc.free(d.definition_id);
            alloc.free(d.process_key);
            alloc.free(d.name);
            alloc.free(d.version);
            alloc.free(d.graph);
            alloc.free(d.variable_schema);
        }
        alloc.free(doc.definitions);
        for (doc.service_catalog_entries) |e| {
            alloc.free(e.service_id);
            alloc.free(e.endpoint_url);
            alloc.free(e.request_schema);
            alloc.free(e.response_schema);
            alloc.free(e.required_auth);
            alloc.free(e.retry_policy);
        }
        alloc.free(doc.service_catalog_entries);
        for (doc.variable_schemas) |v| {
            alloc.free(v.definition_id);
            alloc.free(v.schema_name);
            alloc.free(v.schema_content);
        }
        alloc.free(doc.variable_schemas);
        for (doc.manifest.required_roles) |r| alloc.free(r);
        alloc.free(doc.manifest.required_roles);
        alloc.free(doc.pack_id);
        alloc.free(doc.version);
        alloc.free(doc.bpm_export_schema_version);
        alloc.free(doc.exported_at);
    }

    // pack_id is a 36-char UUID v4 hyphen string.
    try testing.expectEqual(@as(usize, 36), doc.pack_id.len);
    try testing.expectEqual(@as(u8, '-'), doc.pack_id[8]);
    try testing.expectEqual(@as(u8, '-'), doc.pack_id[13]);

    try testing.expectEqualStrings(PACK_SCHEMA_VERSION, doc.bpm_export_schema_version);
    try testing.expectEqualStrings("1.0.0", doc.version);
    try testing.expectEqual(@as(usize, 1), doc.definitions.len);
    try testing.expectEqualStrings(def_id, doc.definitions[0].definition_id);
    try testing.expectEqual(@as(usize, 0), doc.service_catalog_entries.len);
    try testing.expectEqual(@as(usize, 0), doc.manifest.required_roles.len);
}

// ---------------------------------------------------------------------------
// TC-SOL01-02: SERVICE_TASK graph → catalog entry included in export.
// ---------------------------------------------------------------------------

test "TC-SOL01-02: exportPack with SERVICE_TASK graph includes catalog entry" {
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

    const def_name = try std.fmt.allocPrint(alloc, "sol01-tc02-{s}", .{uuid_str[0..8]});
    defer alloc.free(def_name);

    // Unique service_id for this test run.
    const svc_id = try std.fmt.allocPrint(alloc, "sol01-svc-{s}", .{uuid_str[0..8]});
    defer alloc.free(svc_id);

    // Graph with a SERVICE_TASK node; attributes is a JSON-encoded string.
    const graph_prefix =
        \\{"nodes":[{"id":"S","node_type":"START","label":null,"attributes":null},{"id":"ST","node_type":"SERVICE_TASK","label":"t","attributes":"{\"service_id\":\"
    ;
    const graph_suffix =
        \\"}"},{"id":"E","node_type":"END","label":null,"attributes":null}],"edges":[]}
    ;
    const graph = try std.mem.concat(alloc, u8, &[_][]const u8{ graph_prefix, svc_id, graph_suffix });
    defer alloc.free(graph);

    cleanupDefinitionByName(&pool, def_name);
    defer cleanupDefinitionByName(&pool, def_name);
    cleanupServiceCatalog(&pool, svc_id);
    defer cleanupServiceCatalog(&pool, svc_id);

    try insertServiceCatalog(&pool, svc_id, "https://example.com/svc");
    const def_id = try insertDefinition(&pool, alloc, def_name, graph);
    defer alloc.free(def_id);

    var store = SolutionPackStore.init(&pool);
    const def_ids = [_][]const u8{def_id};
    const doc = store.exportPack(alloc, "1.0.0", &def_ids) catch |err| {
        std.debug.print("TC-SOL01-02: exportPack failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (doc.definitions) |d| {
            alloc.free(d.definition_id);
            alloc.free(d.process_key);
            alloc.free(d.name);
            alloc.free(d.version);
            alloc.free(d.graph);
            alloc.free(d.variable_schema);
        }
        alloc.free(doc.definitions);
        for (doc.service_catalog_entries) |e| {
            alloc.free(e.service_id);
            alloc.free(e.endpoint_url);
            alloc.free(e.request_schema);
            alloc.free(e.response_schema);
            alloc.free(e.required_auth);
            alloc.free(e.retry_policy);
        }
        alloc.free(doc.service_catalog_entries);
        for (doc.variable_schemas) |v| {
            alloc.free(v.definition_id);
            alloc.free(v.schema_name);
            alloc.free(v.schema_content);
        }
        alloc.free(doc.variable_schemas);
        for (doc.manifest.required_roles) |r| alloc.free(r);
        alloc.free(doc.manifest.required_roles);
        alloc.free(doc.pack_id);
        alloc.free(doc.version);
        alloc.free(doc.bpm_export_schema_version);
        alloc.free(doc.exported_at);
    }

    try testing.expectEqual(@as(usize, 1), doc.service_catalog_entries.len);
    try testing.expectEqualStrings(svc_id, doc.service_catalog_entries[0].service_id);
    try testing.expectEqualStrings("https://example.com/svc", doc.service_catalog_entries[0].endpoint_url);
    try testing.expectEqual(@as(usize, 1), doc.definitions.len);
}

// ---------------------------------------------------------------------------
// TC-SOL01-03: Two HUMAN_TASK ROLE nodes → sorted manifest roles.
// ---------------------------------------------------------------------------

test "TC-SOL01-03: exportPack with two HUMAN_TASK ROLE nodes returns alphabetically sorted manifest" {
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

    const def_name = try std.fmt.allocPrint(alloc, "sol01-tc03-{s}", .{uuid_str[0..8]});
    defer alloc.free(def_name);

    // Graph with two HUMAN_TASK nodes: "Zebra Role" and "Alpha Role".
    // attributes value is a JSON-encoded string: {"assignee_type":"ROLE","role_name":"<name>"}
    const graph =
        \\{"nodes":[{"id":"S","node_type":"START","label":null,"attributes":null},{"id":"HT1","node_type":"HUMAN_TASK","label":"z","attributes":"{\"assignee_type\":\"ROLE\",\"role_name\":\"Zebra Role\"}"},{"id":"HT2","node_type":"HUMAN_TASK","label":"a","attributes":"{\"assignee_type\":\"ROLE\",\"role_name\":\"Alpha Role\"}"},{"id":"E","node_type":"END","label":null,"attributes":null}],"edges":[]}
    ;

    cleanupDefinitionByName(&pool, def_name);
    defer cleanupDefinitionByName(&pool, def_name);

    const def_id = try insertDefinition(&pool, alloc, def_name, graph);
    defer alloc.free(def_id);

    var store = SolutionPackStore.init(&pool);
    const def_ids = [_][]const u8{def_id};
    const doc = store.exportPack(alloc, "1.0.0", &def_ids) catch |err| {
        std.debug.print("TC-SOL01-03: exportPack failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer {
        for (doc.definitions) |d| {
            alloc.free(d.definition_id);
            alloc.free(d.process_key);
            alloc.free(d.name);
            alloc.free(d.version);
            alloc.free(d.graph);
            alloc.free(d.variable_schema);
        }
        alloc.free(doc.definitions);
        for (doc.service_catalog_entries) |e| {
            alloc.free(e.service_id);
            alloc.free(e.endpoint_url);
            alloc.free(e.request_schema);
            alloc.free(e.response_schema);
            alloc.free(e.required_auth);
            alloc.free(e.retry_policy);
        }
        alloc.free(doc.service_catalog_entries);
        for (doc.variable_schemas) |v| {
            alloc.free(v.definition_id);
            alloc.free(v.schema_name);
            alloc.free(v.schema_content);
        }
        alloc.free(doc.variable_schemas);
        for (doc.manifest.required_roles) |r| alloc.free(r);
        alloc.free(doc.manifest.required_roles);
        alloc.free(doc.pack_id);
        alloc.free(doc.version);
        alloc.free(doc.bpm_export_schema_version);
        alloc.free(doc.exported_at);
    }

    // Manifest must list roles alphabetically.
    try testing.expectEqual(@as(usize, 2), doc.manifest.required_roles.len);
    try testing.expectEqualStrings("Alpha Role", doc.manifest.required_roles[0]);
    try testing.expectEqualStrings("Zebra Role", doc.manifest.required_roles[1]);

    // Roles must be a flat list (not embedded in graph node attributes).
    for (doc.manifest.required_roles) |role| {
        try testing.expect(std.mem.indexOf(u8, role, "{") == null);
    }
}

// ---------------------------------------------------------------------------
// TC-SOL01-04: Unknown definition_id → DefinitionNotFound.
// ---------------------------------------------------------------------------

test "TC-SOL01-04: exportPack with unknown definition_id returns DefinitionNotFound" {
    const alloc = testing.allocator;
    var lock_conn = try helpers.acquireIntegrationLock(alloc);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const uuid_bytes = helpers.randomUuidBytes();
    const nonexistent_id = try helpers.uuidBytesToString(alloc, uuid_bytes);
    defer alloc.free(nonexistent_id);

    var store = SolutionPackStore.init(&pool);
    const def_ids = [_][]const u8{nonexistent_id};
    const result = store.exportPack(alloc, "1.0.0", &def_ids);

    try testing.expectError(SolutionPackError.DefinitionNotFound, result);
}
