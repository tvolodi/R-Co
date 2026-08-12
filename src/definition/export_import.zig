//! Export/import module for process definitions — PD-09
//!
//! Implements ExportImportStore with exportDefinition() and importDefinition().
//! Allows a process definition (graph + metadata) to be exported as a
//! self-contained document and re-imported on the same or another platform.
//!
//! Design artefact: src/design/definition.md §PD-09
const std = @import("std");
const db = @import("pool");
const Pool = db.Pool;
const PoolError = db.PoolError;
const graph_mod = @import("graph.zig");
const store_mod = @import("store.zig");

// Re-export shared types for callers.
pub const Uuid = graph_mod.Uuid;
pub const DefinitionGraph = graph_mod.DefinitionGraph;

// ---------------------------------------------------------------------------
// Schema version constant
// ---------------------------------------------------------------------------

/// Identifies the export document format.  Bump when the format changes.
pub const EXPORT_SCHEMA_VERSION: []const u8 = "bpm/definition/v1";

// ---------------------------------------------------------------------------
// ExportDocument struct
// ---------------------------------------------------------------------------

/// Self-contained export document produced by exportDefinition() and consumed
/// by importDefinition().
pub const ExportDocument = struct {
    /// Always "bpm/definition/v1" for this version of the platform.
    bpm_export_schema_version: []const u8,
    /// Primary key of the source definition (informational; NOT used on import).
    id: graph_mod.Uuid,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    graph: graph_mod.DefinitionGraph,
    /// UTC ISO8601 timestamp string, e.g. "2026-05-21T00:00:00Z".
    exported_at: []const u8,
};

// ---------------------------------------------------------------------------
// Error set
// ---------------------------------------------------------------------------

pub const ExportImportError = error{
    /// The requested definition_id does not exist in process_definitions.
    DefinitionNotFound,
    /// A definition with the same name+version already exists on this platform.
    NameVersionConflict,
    /// doc.bpm_export_schema_version does not match EXPORT_SCHEMA_VERSION.
    UnknownSchemaVersion,
    /// Graph failed structural, attribute, or CEL condition validation.
    InvalidGraph,
    /// db.Pool.acquire() returned ExhaustedPool.
    PoolExhausted,
    /// Any other database error.
    DatabaseError,
};

// ---------------------------------------------------------------------------
// ExportImportStore
// ---------------------------------------------------------------------------

pub const ExportImportStore = struct {
    pool: *Pool,

    // -----------------------------------------------------------------------
    // exportDefinition  (PD-09)
    // -----------------------------------------------------------------------

    /// Export the definition identified by `definition_id`.
    ///
    /// Works for definitions in ANY status (DRAFT, ACTIVE, DEPRECATED, ARCHIVED).
    /// Returns DefinitionNotFound if the id does not exist.
    ///
    /// The returned ExportDocument and all heap-allocated strings within it are
    /// owned by the caller via `allocator`.
    ///
    /// Security: definition_id is bound as $1::uuid — no SQL string interpolation.
    pub fn exportDefinition(
        self: *ExportImportStore,
        allocator: std.mem.Allocator,
        definition_id: graph_mod.Uuid,
    ) ExportImportError!ExportDocument {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const a = param_arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return ExportImportError.PoolExhausted,
            else => return ExportImportError.DatabaseError,
        };
        defer self.pool.release(conn);

        const id_hex = uuidToHex(a, definition_id) catch return ExportImportError.DatabaseError;

        // Security: definition_id bound as $1 — no SQL string interpolation.
        // Cast graph::text to ensure pg.zig returns a plain JSON string rather
        // than a binary-encoded JSONB value that std.json cannot parse.
        const rows = conn.query(
            allocator,
            \\SELECT id, name, version, description, graph::text
            \\FROM process_definitions
            \\WHERE id = $1::uuid
        ,
            &.{id_hex},
        ) catch return ExportImportError.DatabaseError;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return ExportImportError.DefinitionNotFound;

        const row = rows.rows[0];

        const id = parseUuid(colGet(row, 0)) catch std.mem.zeroes(graph_mod.Uuid);

        const name = allocator.dupe(u8, colGet(row, 1)) catch
            return ExportImportError.DatabaseError;
        errdefer allocator.free(name);

        const version = allocator.dupe(u8, colGet(row, 2)) catch
            return ExportImportError.DatabaseError;
        errdefer allocator.free(version);

        const description = allocator.dupe(u8, colGet(row, 3)) catch
            return ExportImportError.DatabaseError;
        errdefer allocator.free(description);

        // Parse graph column as JSON text. pg.zig returns JSONB as text format
        // (all columns use 0 format codes = text), so graph_json_str is a
        // plain JSON string that std.json can parse.
        const raw_graph = colGet(row, 4);
        // pg.zig may return a length-prefixed string; strip the first 4 bytes
        // if they look like a binary frame header (common in pg.zig v0.x).
        const graph_json_str = if (raw_graph.len > 4 and raw_graph[0] == 0 and raw_graph[1] == 0 and raw_graph[2] == 0 and raw_graph[3] == 0x01)
            raw_graph[4..]
        else
            raw_graph;
        const graph = parseGraphJson(allocator, graph_json_str) catch
            graph_mod.DefinitionGraph{ .nodes = &.{}, .edges = &.{} };

        const now_secs = std.Io.Clock.real.now(self.pool.io).toSeconds();
        const epoch_secs: u64 = @intCast(now_secs);
        const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
        const day = epoch.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = epoch.getDaySeconds();
        const exported_at = std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_secs.getHoursIntoDay(),
                day_secs.getMinutesIntoHour(),
                day_secs.getSecondsIntoMinute(),
            },
        ) catch return ExportImportError.DatabaseError;
        errdefer allocator.free(exported_at);

        return ExportDocument{
            .bpm_export_schema_version = EXPORT_SCHEMA_VERSION,
            .id = id,
            .name = name,
            .version = version,
            .description = description,
            .graph = graph,
            .exported_at = exported_at,
        };
    }

    // -----------------------------------------------------------------------
    // importDefinition  (PD-09)
    // -----------------------------------------------------------------------

    /// Import a definition from an ExportDocument, following the 4-step algorithm:
    ///   1. Schema version check.
    ///   2. Name+version uniqueness check (DB).
    ///   3. Graph re-validation (structural + node attributes + edge conditions).
    ///   4. Store.create() with status DRAFT.
    ///
    /// The doc.id field is informational — the platform assigns a new UUID.
    ///
    /// Security: All DB values are bound as $N parameters; no SQL string
    /// interpolation anywhere in this function.
    pub fn importDefinition(
        self: *ExportImportStore,
        allocator: std.mem.Allocator,
        doc: ExportDocument,
    ) ExportImportError!store_mod.Definition {
        // Step 1: validate schema version.
        if (!std.mem.eql(u8, doc.bpm_export_schema_version, EXPORT_SCHEMA_VERSION)) {
            return ExportImportError.UnknownSchemaVersion;
        }

        // Step 2: name+version uniqueness check.
        {
            const conn = self.pool.acquire() catch |err| switch (err) {
                PoolError.ExhaustedPool => return ExportImportError.PoolExhausted,
                else => return ExportImportError.DatabaseError,
            };
            defer self.pool.release(conn);

            // Security: name=$1, version=$2 — no SQL string interpolation.
            const count_rows = conn.query(
                allocator,
                \\SELECT COUNT(*)
                \\FROM process_definitions
                \\WHERE name = $1 AND version = $2
            ,
                &.{ doc.name, doc.version },
            ) catch return ExportImportError.DatabaseError;
            defer {
                var r = count_rows;
                r.deinit();
            }

            if (count_rows.rows.len > 0) {
                const count_str = colGet(count_rows.rows[0], 0);
                const count = std.fmt.parseInt(i64, count_str, 10) catch 0;
                if (count > 0) return ExportImportError.NameVersionConflict;
            }
        }

        // Step 3: re-validate graph (structural + node attributes + edge conditions + edge transforms).
        const vresult = graph_mod.validateGraph(allocator, doc.graph) catch
            return ExportImportError.InvalidGraph;
        if (vresult.violations.len > 0) {
            for (vresult.violations) |v| allocator.free(v.message);
            allocator.free(vresult.violations);
            return ExportImportError.InvalidGraph;
        }
        allocator.free(vresult.violations);

        const attr_result = graph_mod.validateNodeAttributes(allocator, doc.graph) catch
            return ExportImportError.InvalidGraph;
        if (attr_result.violations.len > 0) {
            for (attr_result.violations) |v| allocator.free(v.message);
            allocator.free(attr_result.violations);
            return ExportImportError.InvalidGraph;
        }
        allocator.free(attr_result.violations);

        const edge_result = graph_mod.validateEdgeConditions(allocator, doc.graph) catch
            return ExportImportError.InvalidGraph;
        if (edge_result.violations.len > 0) {
            for (edge_result.violations) |v| allocator.free(v.message);
            allocator.free(edge_result.violations);
            return ExportImportError.InvalidGraph;
        }
        allocator.free(edge_result.violations);

        const transform_result = graph_mod.validateEdgeTransforms(allocator, doc.graph) catch
            return ExportImportError.InvalidGraph;
        if (transform_result.violations.len > 0) {
            for (transform_result.violations) |v| allocator.free(v.message);
            allocator.free(transform_result.violations);
            return ExportImportError.InvalidGraph;
        }
        allocator.free(transform_result.violations);

        // Step 4: create the definition via Store.create() — status = DRAFT.
        // doc.id is NOT passed; the platform assigns a new UUID on INSERT.
        var s = store_mod.Store.init(allocator, self.pool);
        defer s.deinit();

        const def = s.create(allocator, store_mod.CreateParams{
            .name = doc.name,
            .version = doc.version,
            .description = if (doc.description.len > 0) doc.description else null,
            .graph = doc.graph,
            .created_by = std.mem.zeroes(graph_mod.Uuid),
        }) catch |err| switch (err) {
            error.PoolExhausted => return ExportImportError.PoolExhausted,
            error.DuplicateNameVersion => return ExportImportError.NameVersionConflict,
            error.NameInvalid,
            error.VersionEmpty,
            error.GraphStructureInvalid,
            error.GraphValidationFailed,
            => return ExportImportError.InvalidGraph,
            else => return ExportImportError.DatabaseError,
        };

        return def;
    }
};

// ---------------------------------------------------------------------------
// Private helpers — row access
// ---------------------------------------------------------------------------

inline fn colGet(row: []?[]u8, i: usize) []const u8 {
    if (i >= row.len) return "";
    return row[i] orelse "";
}

// ---------------------------------------------------------------------------
// Private helpers — UUID
// ---------------------------------------------------------------------------

fn uuidToHex(allocator: std.mem.Allocator, uuid: graph_mod.Uuid) error{OutOfMemory}![]u8 {
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

fn parseUuid(hex: []const u8) error{InvalidUuid}![16]u8 {
    if (hex.len != 36) return error.InvalidUuid;
    var uuid: [16]u8 = undefined;
    var byte_idx: usize = 0;
    var i: usize = 0;
    while (i < hex.len) {
        if (hex[i] == '-') {
            i += 1;
            continue;
        }
        if (i + 1 >= hex.len) return error.InvalidUuid;
        const hi = hexNibble(hex[i]) catch return error.InvalidUuid;
        const lo = hexNibble(hex[i + 1]) catch return error.InvalidUuid;
        if (byte_idx >= 16) return error.InvalidUuid;
        uuid[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
        i += 2;
    }
    if (byte_idx != 16) return error.InvalidUuid;
    return uuid;
}

fn hexNibble(c: u8) error{InvalidHex}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

// ---------------------------------------------------------------------------
// Private helpers — JSONB graph parsing
// ---------------------------------------------------------------------------

fn parseGraphJson(
    allocator: std.mem.Allocator,
    json_str: []const u8,
) error{ OutOfMemory, InvalidGraph }!graph_mod.DefinitionGraph {
    if (json_str.len == 0) return error.InvalidGraph;
    const parsed = std.json.parseFromSlice(
        graph_mod.DefinitionGraph,
        allocator,
        json_str,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return error.InvalidGraph;
    defer parsed.deinit();
    return duplicateGraph(allocator, parsed.value);
}

fn duplicateGraph(
    allocator: std.mem.Allocator,
    src: graph_mod.DefinitionGraph,
) error{OutOfMemory}!graph_mod.DefinitionGraph {
    const nodes = try allocator.alloc(graph_mod.GraphNode, src.nodes.len);
    errdefer allocator.free(nodes);

    for (src.nodes, 0..) |n, i| {
        nodes[i] = graph_mod.GraphNode{
            .id = try allocator.dupe(u8, n.id),
            .node_type = n.node_type,
            .label = if (n.label) |l| try allocator.dupe(u8, l) else null,
            .attributes = if (n.attributes) |attr| try allocator.dupe(u8, attr) else null,
        };
    }

    const edges = try allocator.alloc(graph_mod.GraphEdge, src.edges.len);
    errdefer allocator.free(edges);

    for (src.edges, 0..) |e, i| {
        edges[i] = graph_mod.GraphEdge{
            .id = try allocator.dupe(u8, e.id),
            .source = try allocator.dupe(u8, e.source),
            .target = try allocator.dupe(u8, e.target),
            .condition = if (e.condition) |c| try allocator.dupe(u8, c) else null,
            .transform = if (e.transform) |t| try allocator.dupe(u8, t) else null,
            .is_default = e.is_default,
        };
    }

    return graph_mod.DefinitionGraph{ .nodes = nodes, .edges = edges };
}
