//! Integration tests for PD-09 — Definition import/export.
//!
//! Tests exercise ExportImportStore.exportDefinition() and importDefinition()
//! against a real PostgreSQL database.  All 7 test cases from
//! tests/specs/PD-09.md are implemented here.
//!
//! Requires: BPM_TEST_DB_URL environment variable.
//! Each test calls TestHarness.init() to run migrations, then creates its own
//! Pool for ExportImportStore and DefinitionStore operations.
//!
//! Isolation: each test cleans up its own rows explicitly by name prefix.
//! Definitions inserted by importDefinition() are also cleaned up using the
//! name written to the ExportDocument before import.
//!
//! Requirement traceability:
//!   PD-09 → TC-PD-09-01, TC-PD-09-02, TC-PD-09-03, TC-PD-09-04,
//!            TC-PD-09-05, TC-PD-09-06, TC-PD-09-07
const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const Definition = bpm.definition.Definition;

const ExportImportStore = bpm.export_import.ExportImportStore;
const ExportImportError = bpm.export_import.ExportImportError;
const ExportDocument = bpm.export_import.ExportDocument;
const EXPORT_SCHEMA_VERSION = bpm.export_import.EXPORT_SCHEMA_VERSION;

// ---------------------------------------------------------------------------
// Fixed test UUIDs (deterministic — no RNG dependency)
// ---------------------------------------------------------------------------

/// Fake "created_by" UUID; no FK constraint on process_definitions.created_by.
const creator_uuid_str = "00000000-0000-0000-0000-000000000099";

/// A definition_id guaranteed not to exist in any test run.
const unknown_def_str = "ffffffff-ffff-ffff-ffff-ffffffffffff";

// ---------------------------------------------------------------------------
// Minimal valid graph: START → HUMAN_TASK → END  (3 nodes, 2 edges)
// HUMAN_TASK requires role attribute per PD-05.
// ---------------------------------------------------------------------------

const g1_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};
const g1_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
};
const graph_g1 = DefinitionGraph{ .nodes = &g1_nodes, .edges = &g1_edges };

// ---------------------------------------------------------------------------
// Rich graph for TC-PD-09-07: includes EXCLUSIVE_GATEWAY, conditions,
// is_default flag.
// START → HUMAN_TASK → EXCLUSIVE_GATEWAY → END1 (condition "approved == true")
//                                        → END2 (is_default = true)
// ---------------------------------------------------------------------------

const g_rich_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"approver\"}" },
    .{ .id = "GW", .node_type = .EXCLUSIVE_GATEWAY, .label = null, .attributes = null },
    .{ .id = "E1", .node_type = .END, .label = null, .attributes = null },
    .{ .id = "E2", .node_type = .END, .label = "default_end", .attributes = null },
};
const g_rich_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "GW", .condition = null, .is_default = false },
    .{ .id = "e3", .source = "GW", .target = "E1", .condition = "approved == true", .is_default = false },
    .{ .id = "e4", .source = "GW", .target = "E2", .condition = null, .is_default = true },
};
const graph_g_rich = DefinitionGraph{ .nodes = &g_rich_nodes, .edges = &g_rich_edges };

// ---------------------------------------------------------------------------
// Invalid-CEL graph for TC-PD-09-05: passes structural + attribute validation
// but fails CEL condition validation on the non-default EXCLUSIVE_GATEWAY edge.
// ---------------------------------------------------------------------------

const g_invalid_cel_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "GW", .node_type = .EXCLUSIVE_GATEWAY, .label = null, .attributes = null },
    .{ .id = "E1", .node_type = .END, .label = null, .attributes = null },
    .{ .id = "E2", .node_type = .END, .label = null, .attributes = null },
};
const g_invalid_cel_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "GW", .condition = null, .is_default = false },
    // Syntactically invalid CEL — unmatched parenthesis.
    .{ .id = "e3", .source = "GW", .target = "E1", .condition = "((unclosed", .is_default = false },
    .{ .id = "e4", .source = "GW", .target = "E2", .condition = null, .is_default = true },
};
const graph_g_invalid_cel = DefinitionGraph{
    .nodes = &g_invalid_cel_nodes,
    .edges = &g_invalid_cel_edges,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

/// Parse a UUID hex string (36 chars with hyphens) into [16]u8.
fn parseUuid(_: std.mem.Allocator, s: []const u8) ![16]u8 {
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (i >= 32) return error.InvalidUuid;
        buf[i] = c;
        i += 1;
    }
    if (i != 32) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, buf[0..32]);
    return out;
}

/// Render [16]u8 UUID as lowercase hex with hyphens (36 chars).
fn uuidToHexStr(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

/// Free allocator-owned fields of a Definition returned by DefinitionStore.create()
/// or ExportImportStore.importDefinition().  Does NOT free def.graph (Store.create
/// does not allocate a separate graph copy in the returned Definition).
fn freeDefinition(allocator: std.mem.Allocator, d: Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |st| allocator.free(st);
}

/// Free all allocator-owned fields of an ExportDocument returned by
/// ExportImportStore.exportDefinition().
/// Note: bpm_export_schema_version is a static constant — NOT freed.
fn freeExportDocument(allocator: std.mem.Allocator, doc: ExportDocument) void {
    allocator.free(doc.name);
    allocator.free(doc.version);
    allocator.free(doc.description);
    allocator.free(doc.exported_at);
    for (doc.graph.nodes) |n| {
        allocator.free(n.id);
        if (n.label) |l| allocator.free(l);
        if (n.attributes) |a| allocator.free(a);
    }
    allocator.free(doc.graph.nodes);
    for (doc.graph.edges) |e| {
        allocator.free(e.id);
        allocator.free(e.source);
        allocator.free(e.target);
        if (e.condition) |c| allocator.free(c);
    }
    allocator.free(doc.graph.edges);
}

/// Delete definition rows matching an exact name.  Best-effort; ignores errors.
fn cleanupByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1",
        &.{name},
    ) catch {};
}

// ---------------------------------------------------------------------------
// TC-PD-09-01: Export happy path — any status
// ---------------------------------------------------------------------------

test "TC-PD-09-01: ExportImportStore.exportDefinition — happy path returns ExportDocument with matching fields" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-PD-09-01 Export Source";
    const def_ver = "1.0.0";
    const creator = try parseUuid(alloc, creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = def_ver,
        .description = "Export test definition",
        .graph = graph_g1,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def);
    defer cleanupByName(&pool, def_name);

    var ei_store = ExportImportStore{ .pool = &pool };

    const doc = try ei_store.exportDefinition(alloc, def.id);
    defer freeExportDocument(alloc, doc);

    // Verify schema version field.
    try std.testing.expectEqualStrings("bpm/definition/v1", doc.bpm_export_schema_version);
    // Verify metadata fields match source definition.
    try std.testing.expectEqualStrings(def_name, doc.name);
    try std.testing.expectEqualStrings(def_ver, doc.version);
    // Graph node count must match.
    try std.testing.expectEqual(graph_g1.nodes.len, doc.graph.nodes.len);
    // exported_at must be non-empty.
    try std.testing.expect(doc.exported_at.len > 0);
}

// ---------------------------------------------------------------------------
// TC-PD-09-02: Export unknown id returns DefinitionNotFound
// ---------------------------------------------------------------------------

test "TC-PD-09-02: ExportImportStore.exportDefinition — unknown id returns DefinitionNotFound" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const unknown_id = try parseUuid(alloc, unknown_def_str);

    var ei_store = ExportImportStore{ .pool = &pool };

    const result = ei_store.exportDefinition(alloc, unknown_id);
    try std.testing.expectError(ExportImportError.DefinitionNotFound, result);
}

// ---------------------------------------------------------------------------
// TC-PD-09-03: Import happy path — creates with DRAFT status
// ---------------------------------------------------------------------------

test "TC-PD-09-03: ExportImportStore.importDefinition — happy path creates definition with DRAFT status" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const import_name = "TC-PD-09-03 Import Process";
    defer cleanupByName(&pool, import_name);

    // Construct ExportDocument manually — no source definition needed in DB.
    const doc = ExportDocument{
        .bpm_export_schema_version = EXPORT_SCHEMA_VERSION,
        .id = std.mem.zeroes([16]u8),
        .name = import_name,
        .version = "1.0.0",
        .description = "",
        .graph = graph_g1,
        .exported_at = "2026-05-21T00:00:00Z",
    };

    var ei_store = ExportImportStore{ .pool = &pool };

    const def = try ei_store.importDefinition(alloc, doc);
    defer freeDefinition(alloc, def);

    // Status must be DRAFT.
    try std.testing.expectEqual(@import("bpm").definition.DefinitionStatus.DRAFT, def.status);
    // Name and version must match the document.
    try std.testing.expectEqualStrings(import_name, def.name);
    try std.testing.expectEqualStrings("1.0.0", def.version);
    // A real new UUID must have been assigned (not all-zeros).
    const zero_uuid = std.mem.zeroes([16]u8);
    try std.testing.expect(!std.mem.eql(u8, &def.id, &zero_uuid));
}

// ---------------------------------------------------------------------------
// TC-PD-09-04: Import with name+version conflict returns NameVersionConflict
// ---------------------------------------------------------------------------

test "TC-PD-09-04: ExportImportStore.importDefinition — name+version conflict returns NameVersionConflict" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-PD-09-04 Conflict Process";
    const def_ver = "1.0.0";
    const creator = try parseUuid(alloc, creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    // Create a definition that will conflict with the import.
    const existing = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = def_ver,
        .description = null,
        .graph = graph_g1,
        .created_by = creator,
    });
    defer freeDefinition(alloc, existing);
    defer cleanupByName(&pool, def_name);

    // Attempt to import with the same name+version.
    const doc = ExportDocument{
        .bpm_export_schema_version = EXPORT_SCHEMA_VERSION,
        .id = std.mem.zeroes([16]u8),
        .name = def_name,
        .version = def_ver,
        .description = "",
        .graph = graph_g1,
        .exported_at = "2026-05-21T00:00:00Z",
    };

    var ei_store = ExportImportStore{ .pool = &pool };

    const result = ei_store.importDefinition(alloc, doc);
    try std.testing.expectError(ExportImportError.NameVersionConflict, result);
}

// ---------------------------------------------------------------------------
// TC-PD-09-05: Import with invalid CEL condition returns InvalidGraph
// ---------------------------------------------------------------------------

test "TC-PD-09-05: ExportImportStore.importDefinition — invalid CEL condition returns InvalidGraph" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Name that would be used if import succeeded — used for best-effort cleanup.
    const import_name = "TC-PD-09-05 Invalid CEL";
    defer cleanupByName(&pool, import_name);

    // Construct ExportDocument with a graph containing an invalid CEL condition.
    const doc = ExportDocument{
        .bpm_export_schema_version = EXPORT_SCHEMA_VERSION,
        .id = std.mem.zeroes([16]u8),
        .name = import_name,
        .version = "1.0.0",
        .description = "",
        .graph = graph_g_invalid_cel,
        .exported_at = "2026-05-21T00:00:00Z",
    };

    var ei_store = ExportImportStore{ .pool = &pool };

    const result = ei_store.importDefinition(alloc, doc);
    try std.testing.expectError(ExportImportError.InvalidGraph, result);
}

// ---------------------------------------------------------------------------
// TC-PD-09-06: Import with unknown schema version returns UnknownSchemaVersion
// ---------------------------------------------------------------------------

test "TC-PD-09-06: ExportImportStore.importDefinition — unknown schema version returns UnknownSchemaVersion" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Schema version check is the first step — no DB access is needed.
    const doc = ExportDocument{
        .bpm_export_schema_version = "bpm/definition/v99",
        .id = std.mem.zeroes([16]u8),
        .name = "TC-PD-09-06 Unknown Schema",
        .version = "1.0.0",
        .description = "",
        .graph = graph_g1,
        .exported_at = "2026-05-21T00:00:00Z",
    };

    var ei_store = ExportImportStore{ .pool = &pool };

    const result = ei_store.importDefinition(alloc, doc);
    try std.testing.expectError(ExportImportError.UnknownSchemaVersion, result);
}

// ---------------------------------------------------------------------------
// TC-PD-09-07: Export-import round-trip preserves full graph
// ---------------------------------------------------------------------------

test "TC-PD-09-07: ExportImportStore export/import round-trip preserves full graph" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const source_name = "TC-PD-09-07 Source";
    const import_name = "TC-PD-09-07 Imported";
    const def_ver = "1.0.0";
    const creator = try parseUuid(alloc, creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    // Step 1: create source definition with the rich graph.
    const source_def = try def_store.create(alloc, CreateParams{
        .name = source_name,
        .version = def_ver,
        .description = null,
        .graph = graph_g_rich,
        .created_by = creator,
    });
    defer freeDefinition(alloc, source_def);
    defer cleanupByName(&pool, source_name);

    var ei_store = ExportImportStore{ .pool = &pool };

    // Step 2: export the source definition.
    const doc_original = try ei_store.exportDefinition(alloc, source_def.id);
    defer freeExportDocument(alloc, doc_original);

    // Step 3: import with a different name to avoid name+version conflict.
    // ExportDocument is a value type — copy and override the name field.
    const import_doc = ExportDocument{
        .bpm_export_schema_version = doc_original.bpm_export_schema_version,
        .id = doc_original.id,
        .name = import_name, // Different name — avoids conflict
        .version = doc_original.version,
        .description = doc_original.description,
        .graph = doc_original.graph, // Same graph memory — valid for duration of call
        .exported_at = doc_original.exported_at,
    };

    const imported_def = try ei_store.importDefinition(alloc, import_doc);
    defer freeDefinition(alloc, imported_def);
    defer cleanupByName(&pool, import_name);

    // Step 4: export the imported definition to retrieve its stored graph.
    const doc_imported = try ei_store.exportDefinition(alloc, imported_def.id);
    defer freeExportDocument(alloc, doc_imported);

    // Assertions: graphs must have identical structure.
    try std.testing.expectEqual(
        doc_original.graph.nodes.len,
        doc_imported.graph.nodes.len,
    );
    try std.testing.expectEqual(
        doc_original.graph.edges.len,
        doc_imported.graph.edges.len,
    );

    // Verify node types are preserved (same order — graph is stored/retrieved as ordered JSON).
    for (doc_original.graph.nodes, doc_imported.graph.nodes) |orig_n, imp_n| {
        try std.testing.expectEqual(orig_n.node_type, imp_n.node_type);
    }

    // Verify edge conditions and is_default flags are preserved.
    for (doc_original.graph.edges, doc_imported.graph.edges) |orig_e, imp_e| {
        try std.testing.expectEqual(orig_e.is_default, imp_e.is_default);
        if (orig_e.condition) |orig_cond| {
            const imp_cond = imp_e.condition orelse {
                std.debug.print("edge {s}: expected condition '{s}' but got null\n", .{ orig_e.id, orig_cond });
                return error.TestUnexpectedResult;
            };
            try std.testing.expectEqualStrings(orig_cond, imp_cond);
        } else {
            if (imp_e.condition != null) {
                std.debug.print("edge {s}: expected null condition but got '{s}'\n", .{ orig_e.id, imp_e.condition.? });
                return error.TestUnexpectedResult;
            }
        }
    }
}
