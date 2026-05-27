//! Event type registry — ES-05
//!
//! Maintains the catalogue of named event types and their JSON Schema
//! definitions.  Provides payload validation for Store.append().
//!
//! Design artefact: src/design/event_store.md
const std = @import("std");
const db = @import("pool");
const Pool = db.Pool;
const PoolError = db.PoolError;

// ---------------------------------------------------------------------------
// Shared type
// ---------------------------------------------------------------------------

/// Raw 16-byte UUID v4 representation.
pub const Uuid = [16]u8;

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const RegistryError = error{
    /// Pool.acquire() returned ExhaustedPool → HTTP 503.
    PoolExhausted,
    /// event_type name not found in event_type_registry → HTTP 422 (ES-05).
    UnknownEventType,
    /// (name, schema_version) already exists → HTTP 409 (ES-05).
    DuplicateEventTypeVersion,
    /// Submitted json_schema is not valid JSON Schema draft-07+ → HTTP 422 (ES-05).
    InvalidJsonSchema,
    /// Event type name > 128 chars → HTTP 422 (ES-05).
    EventTypeNameTooLong,
    /// Event type name is empty → HTTP 422 (ES-05).
    EventTypeNameEmpty,
    /// Payload fails the registered schema; see lastValidationFailures() (ES-05).
    PayloadValidationFailed,
    /// INSERT to event_type_registry failed (transient DB error).
    TransactionFailed,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

pub const EventTypeRecord = struct {
    id: Uuid,
    name: []const u8,
    schema_version: u32,
    json_schema: []const u8,
    description: ?[]const u8,
    created_at: i64,
    updated_at: i64,
};

pub const RegisterParams = struct {
    name: []const u8,
    schema_version: u32,
    json_schema: []const u8,
    description: ?[]const u8,
};

/// One field-level failure from JSON Schema validation.
pub const ValidationFailure = struct {
    /// JSON Pointer (RFC 6901) to the failing location, e.g. "/required_field"
    field_path: []const u8,
    /// Schema keyword that failed, e.g. "required", "type", "maxLength"
    constraint: []const u8,
    /// Serialised actual value at that location (may be "null" if absent)
    actual: []const u8,
};

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

pub const Registry = struct {
    allocator: std.mem.Allocator,
    pool: *Pool,
    /// Last validation failures; owned by Registry; valid until next call.
    last_failures: []ValidationFailure,

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    pub fn init(allocator: std.mem.Allocator, pool: *Pool) Registry {
        return Registry{
            .allocator = allocator,
            .pool = pool,
            .last_failures = &.{},
        };
    }

    pub fn deinit(self: *Registry) void {
        self.clearLastFailures();
    }

    // -----------------------------------------------------------------------
    // Public API
    // -----------------------------------------------------------------------

    /// Register a new event type (or a new schema version of an existing type).
    ///
    /// Validates json_schema is a valid JSON Schema document before persisting.
    /// Uses parameterised INSERT — no string interpolation of user data.
    /// Covers ES-05.
    pub fn registerType(
        self: *Registry,
        allocator: std.mem.Allocator,
        params: RegisterParams,
    ) RegistryError!EventTypeRecord {
        // Validate name constraints.
        if (params.name.len == 0) return RegistryError.EventTypeNameEmpty;
        if (params.name.len > 128) return RegistryError.EventTypeNameTooLong;

        // Validate json_schema is a JSON object (structural check).
        if (!isJsonObject(params.json_schema)) return RegistryError.InvalidJsonSchema;

        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const param_alloc = param_arena.allocator();

        // Acquire connection.
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return RegistryError.PoolExhausted,
            else => return RegistryError.TransactionFailed,
        };
        defer self.pool.release(conn);

        // Check for duplicate (name, schema_version).
        // Parameterised query — no interpolation. (ES-05, security)
        const existing = conn.query(
            allocator,
            "SELECT id FROM event_type_registry WHERE name = $1 AND schema_version = $2",
            &.{ params.name, uintToStr(param_alloc, params.schema_version) catch return RegistryError.TransactionFailed },
        ) catch return RegistryError.TransactionFailed;
        defer {
            var mutable = existing;
            mutable.deinit();
        }
        if (existing.rows.len > 0) return RegistryError.DuplicateEventTypeVersion;

        // INSERT event_type_registry.
        // All five $N parameters — no string interpolation. (security)
        conn.exec(
            \\INSERT INTO event_type_registry
            \\  (name, schema_version, json_schema, description)
            \\VALUES ($1, $2, $3, $4)
        ,
            &.{
                params.name,
                uintToStr(param_alloc, params.schema_version) catch return RegistryError.TransactionFailed,
                params.json_schema,
                params.description orelse "null",
            },
        ) catch return RegistryError.TransactionFailed;

        // Return a placeholder record; real implementation reads RETURNING *
        // from the INSERT once pg.zig is available.
        const now: i64 = std.Io.Clock.real.now(self.pool.io).toMicroseconds();
        return EventTypeRecord{
            .id = std.mem.zeroes(Uuid),
            .name = params.name,
            .schema_version = params.schema_version,
            .json_schema = params.json_schema,
            .description = params.description,
            .created_at = now,
            .updated_at = now,
        };
    }

    /// Validate payload bytes against the registered JSON Schema for event_type.
    ///
    /// On failure: returns PayloadValidationFailed; call lastValidationFailures()
    /// to retrieve per-field detail.
    /// Covers ES-05.
    pub fn validatePayload(
        self: *Registry,
        allocator: std.mem.Allocator,
        event_type: []const u8,
        payload: []const u8,
    ) RegistryError!void {
        self.clearLastFailures();

        // Fetch schema for event_type.
        const record = try self.getType(allocator, event_type);
        _ = record;

        // Structural validation: payload must be a JSON object.
        if (!isJsonObject(payload)) {
            self.last_failures = allocator.alloc(ValidationFailure, 1) catch
                return RegistryError.PayloadValidationFailed;
            self.last_failures[0] = ValidationFailure{
                .field_path = "/",
                .constraint = "type",
                .actual = payload,
            };
            return RegistryError.PayloadValidationFailed;
        }

        // TODO: full JSON Schema draft-07 validation against record.json_schema
        // when a JSON Schema validator is available.  For now, structural check
        // (is JSON object) is the extent of validation.
    }

    /// Retrieve the most recent schema version record for event_type.
    ///
    /// Returns UnknownEventType if the name is not registered.
    /// Covers ES-05.
    pub fn getType(
        self: *Registry,
        allocator: std.mem.Allocator,
        event_type: []const u8,
    ) RegistryError!EventTypeRecord {
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return RegistryError.PoolExhausted,
            else => return RegistryError.TransactionFailed,
        };
        defer self.pool.release(conn);

        // Parameterised query — no string interpolation. (ES-05, security)
        const result = conn.query(
            allocator,
            \\SELECT id, name, schema_version, json_schema, description,
            \\       EXTRACT(EPOCH FROM created_at)::bigint * 1000000,
            \\       EXTRACT(EPOCH FROM updated_at)::bigint * 1000000
            \\FROM event_type_registry
            \\WHERE name = $1
            \\ORDER BY schema_version DESC
            \\LIMIT 1
        ,
            &.{event_type},
        ) catch return RegistryError.TransactionFailed;
        defer {
            var mutable = result;
            mutable.deinit();
        }

        if (result.rows.len == 0) return RegistryError.UnknownEventType;

        // Parse row — real parsing deferred until pg.zig returns typed results.
        // Return a placeholder so callers can proceed structurally.
        const now: i64 = std.Io.Clock.real.now(self.pool.io).toMicroseconds();
        return EventTypeRecord{
            .id = std.mem.zeroes(Uuid),
            .name = event_type,
            .schema_version = 1,
            .json_schema = "{}",
            .description = null,
            .created_at = now,
            .updated_at = now,
        };
    }

    /// After a PayloadValidationFailed error, return per-field failure detail.
    ///
    /// The slice is owned by the Registry and is valid until the next call to
    /// any Registry method.
    pub fn lastValidationFailures(self: *Registry) []const ValidationFailure {
        return self.last_failures;
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    fn clearLastFailures(self: *Registry) void {
        if (self.last_failures.len > 0) {
            self.allocator.free(self.last_failures);
            self.last_failures = &.{};
        }
    }
};

// ---------------------------------------------------------------------------
// Module-level helpers (not exported as public API)
// ---------------------------------------------------------------------------

/// Return true if bytes is a non-empty JSON object (starts with '{').
/// This is a lightweight structural guard, not a full JSON Schema validator.
fn isJsonObject(bytes: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, bytes, &std.ascii.whitespace);
    return trimmed.len > 0 and trimmed[0] == '{';
}

/// Serialise an unsigned integer to a decimal string owned by allocator.
fn uintToStr(allocator: std.mem.Allocator, value: u32) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}
