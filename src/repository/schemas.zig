//! Form schema indexing and discovery (REPO-05)
//!
//! Index form schemas by field name, type, and label to enable
//! agent-driven discovery queries.
//!
//! Design artefact: src/design/repository.md (REPO-05)

const std = @import("std");
const db = @import("pool");

const Pool = db.Pool;
const Uuid = [16]u8;

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const SchemasError = error{
    PoolExhausted,
    FieldNameTooLong,
    FieldNameEmpty,
    FieldTypeTooLong,
    FieldTypeMissing,
    FieldLabelTooLong,
    FormNotFound,
    InvalidIndexing,
    TransactionFailed,
    OutOfMemory,
    InvalidJson,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

pub const FormSchemaField = struct {
    field_name: []const u8,
    field_type: []const u8,
    field_label: []const u8,
    required: bool,
    pattern: ?[]const u8,
};

pub const FormSchemaIndexParams = struct {
    version_id: Uuid,
    artifact_name: []const u8,
    fields: []FormSchemaField,
};

pub const FormSchemaSearchOpts = struct {
    field_type: ?[]const u8,
    field_name: ?[]const u8,
    field_label: ?[]const u8,
    after_field: ?[]const u8,
    limit: u32,
};

pub const Schemas = struct {
    allocator: std.mem.Allocator,
    pool: *Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *Pool) Schemas {
        return Schemas{
            .allocator = allocator,
            .pool = pool,
        };
    }

    pub fn deinit(_: *Schemas) void {
        // No resources to clean up
    }

    /// Index a form schema by parsing and extracting all fields.
    /// Called when a form artifact is activated.
    pub fn indexSchema(
        self: *Schemas,
        allocator: std.mem.Allocator,
        params: FormSchemaIndexParams,
    ) SchemasError!void {
        _ = self;
        _ = allocator;
        _ = params;

        // TODO: Implement schema indexing
        //   1. Validate field parameters
        //   2. Insert rows into form_schema_registry
    }

    /// Search form schemas by field type, name, or label. Returns deduplicated list of artifact versions.
    pub fn searchSchemas(
        self: *Schemas,
        allocator: std.mem.Allocator,
        opts: FormSchemaSearchOpts,
    ) SchemasError![]FormSchemaField {
        _ = self;
        _ = allocator;
        _ = opts;

        return &[_]FormSchemaField{};
    }

    /// Clear all index entries for a given version_id (e.g., when deactivating).
    pub fn clearIndex(
        self: *Schemas,
        allocator: std.mem.Allocator,
        version_id: Uuid,
    ) SchemasError!void {
        _ = self;
        _ = allocator;
        _ = version_id;

        // TODO: Implement index clearing
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Schemas initialization" {
    const allocator = std.testing.allocator;
    var schemas = Schemas.init(allocator, undefined);
    defer schemas.deinit();
    _ = schemas;
}
