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
/// ES-05 JSON Schema validator (ISS-0155 / GH #473). Named module rather than a
/// relative import because registry.zig sits under the `event_store` module
/// whose root is store.zig — `../tools/json_schema.zig` escapes the module path.
const json_schema = @import("json_schema");

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
        // ES-05 pre-write validation, shared with unit tests (ISS-0148).
        try validateRegisterParams(params);

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

        // Fetch the registered schema for event_type. UnknownEventType
        // propagates — ES-05 rejects appends of unregistered types.
        const record = try self.getType(allocator, event_type);
        defer freeTypeRecord(allocator, record);

        // ISS-0155 / GH #473: real JSON Schema validation against the registered
        // schema. Prior to this the fetched record was discarded (`_ = record;`)
        // and a bare is-JSON-object check was the entire extent of enforcement,
        // so any JSON object was accepted for any registered event type.
        var failures = try validatePayloadAgainstSchema(
            self.allocator,
            record.json_schema,
            payload,
        );
        if (failures.items.len == 0) {
            failures.deinit(self.allocator);
            return;
        }
        self.last_failures = failures.toOwnedSlice(self.allocator) catch {
            freeFailures(self.allocator, failures.items);
            failures.deinit(self.allocator);
            return RegistryError.PayloadValidationFailed;
        };
        return RegistryError.PayloadValidationFailed;
    }

    /// Retrieve the most recent schema version record for event_type.
    ///
    /// Returns UnknownEventType if the name is not registered.
    ///
    /// Every []const u8 / ?[]const u8 field of the returned record is owned by
    /// `allocator`; free with `freeTypeRecord(allocator, record)`.
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

        // ISS-0155 / GH #473: parse the row for real. This previously returned a
        // placeholder with json_schema hardcoded to "{}", which made ES-05's
        // schema enforcement validate against nothing even once validatePayload
        // started consulting it.
        const row = result.rows[0];
        if (row.len < 7) return RegistryError.TransactionFailed;

        var rec = EventTypeRecord{
            .id = parseUuidText(colText(row, 0) orelse ""),
            .name = undefined,
            .schema_version = parseU32(colText(row, 2) orelse "") orelse 1,
            .json_schema = undefined,
            .description = null,
            .created_at = parseI64(colText(row, 5) orelse "") orelse 0,
            .updated_at = parseI64(colText(row, 6) orelse "") orelse 0,
        };

        rec.name = allocator.dupe(u8, colText(row, 1) orelse event_type) catch
            return RegistryError.TransactionFailed;
        errdefer allocator.free(rec.name);

        // A SQL NULL json_schema is impossible (column is NOT NULL DEFAULT '{}'),
        // but degrade to the empty schema rather than failing the append if the
        // column is somehow absent.
        rec.json_schema = allocator.dupe(u8, colText(row, 3) orelse "{}") catch
            return RegistryError.TransactionFailed;
        errdefer allocator.free(rec.json_schema);

        if (colText(row, 4)) |desc| {
            rec.description = allocator.dupe(u8, desc) catch
                return RegistryError.TransactionFailed;
        }

        return rec;
    }

    /// Free the allocator-owned string fields of a record from `getType`.
    pub fn freeTypeRecord(allocator: std.mem.Allocator, record: EventTypeRecord) void {
        allocator.free(record.name);
        allocator.free(record.json_schema);
        if (record.description) |d| allocator.free(d);
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

    /// Free the previous failure set. ISS-0155: `field_path` and `actual` are
    /// now Registry-owned copies (they used to alias caller memory / literals),
    /// so both must be freed here or every rejected append leaks.
    /// `constraint` is always a static literal and is never freed.
    fn clearLastFailures(self: *Registry) void {
        if (self.last_failures.len > 0) {
            freeFailures(self.allocator, self.last_failures);
            self.allocator.free(self.last_failures);
            self.last_failures = &.{};
        }
    }
};

// ---------------------------------------------------------------------------
// Module-level helpers (not exported as public API)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Pre-write validation surface (ISS-0148)
//
// registerType() validates the event type name and the schema document before
// it acquires a connection.  Those checks are ES-05's rejection rules, but they
// were inlined in registerType(), reachable only with a live DB — which is why
// TC-ES-05-03 / TC-ES-05-04 were SkipZigTest stubs.  registerType() now calls
// this function, so a unit test against it runs the production bytes.
// ---------------------------------------------------------------------------

/// Validate RegisterParams name and schema constraints (ES-05), no DB access.
///
/// Note: DuplicateEventTypeVersion is deliberately NOT checked here — it is a
/// uniqueness property of persisted state, so it is only decidable against a
/// real database.  See TC-ES-05-04 in tests/integration/.
pub fn validateRegisterParams(params: RegisterParams) RegistryError!void {
    if (params.name.len == 0) return RegistryError.EventTypeNameEmpty;
    if (params.name.len > 128) return RegistryError.EventTypeNameTooLong;
    if (!isJsonObject(params.json_schema)) return RegistryError.InvalidJsonSchema;
}

/// Free the allocator-owned strings of a ValidationFailure slice.
/// `constraint` is always a static literal and is never freed.
pub fn freeFailures(allocator: std.mem.Allocator, failures: []const ValidationFailure) void {
    for (failures) |f| {
        allocator.free(f.field_path);
        allocator.free(f.actual);
    }
}

/// Validate `payload` against the JSON Schema document `schema_text` (ES-05).
///
/// This is the whole schema-vs-payload decision, and it needs no database —
/// `Registry.validatePayload` calls it after fetching the registered schema, so
/// a caller testing this function exercises exactly the production path
/// (ISS-0155; same shape as validateRegisterParams per ISS-0148).
///
/// Returns a list of every violation found — empty when the payload conforms.
/// The caller owns the list: free the strings with `freeFailures` and then
/// `deinit` the list. `InvalidJsonSchema` signals that the STORED schema is
/// corrupt (a registry-integrity fault); a bad payload is never an error here,
/// it is a non-empty result.
///
/// Validated subset (see src/tools/json_schema.zig for the full statement):
/// `type`, `required`, `properties`, `items`, `enum`, `minimum`, `maximum`,
/// `minLength`, `maxLength`, and `additionalProperties: false`. Keywords
/// outside that subset (`$ref`, `allOf`/`anyOf`/`oneOf`, `pattern`, `format`,
/// …) are ignored rather than treated as failures, so a schema using them stays
/// permissive instead of rejecting valid payloads.
pub fn validatePayloadAgainstSchema(
    allocator: std.mem.Allocator,
    schema_text: []const u8,
    payload: []const u8,
) RegistryError!std.ArrayList(ValidationFailure) {
    var out: std.ArrayList(ValidationFailure) = .empty;
    errdefer {
        freeFailures(allocator, out.items);
        out.deinit(allocator);
    }

    // Structural guard: the payload must at least look like a JSON object.
    if (!isJsonObject(payload)) {
        try appendFailure(allocator, &out, "/", "type", payload);
        return out;
    }

    // An empty / absent schema document imposes no constraints; skip the parse
    // so the very common `{}` case costs nothing. This is a fast path, not a
    // permissive fallback — any schema with content goes through the validator.
    if (isEmptySchema(schema_text)) return out;

    var parsed_schema = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        schema_text,
        .{},
    ) catch {
        // A stored schema that no longer parses is a registry-integrity fault,
        // not a caller error — never silently accept the payload instead.
        return RegistryError.InvalidJsonSchema;
    };
    defer parsed_schema.deinit();

    var parsed_payload = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        payload,
        .{},
    ) catch {
        // isJsonObject() only checks the leading brace; malformed JSON that
        // starts with '{' lands here and is a payload failure.
        try appendFailure(allocator, &out, "/", "type", payload);
        return out;
    };
    defer parsed_payload.deinit();

    const violations = json_schema.validateCollect(
        allocator,
        parsed_payload.value,
        parsed_schema.value,
    ) catch return RegistryError.PayloadValidationFailed;
    defer json_schema.deinitViolations(allocator, violations);

    // ES-05: report EVERY failure — field path, constraint, actual value.
    // Copy into caller-owned memory; `violations` dies with this frame.
    out.ensureTotalCapacity(allocator, violations.len) catch
        return RegistryError.PayloadValidationFailed;
    for (violations) |v| {
        // json_schema renders the document root as ""; ES-05's RFC 6901
        // pointer for the whole document is "/".
        try appendFailureRaw(
            allocator,
            &out,
            if (v.path.len == 0) "/" else v.path,
            v.constraint,
            v.actual,
        );
    }
    return out;
}

/// Append one failure whose `actual` is the raw payload/value bytes.
fn appendFailure(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(ValidationFailure),
    field_path: []const u8,
    constraint: []const u8,
    actual: []const u8,
) RegistryError!void {
    return appendFailureRaw(allocator, out, field_path, constraint, actual);
}

fn appendFailureRaw(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(ValidationFailure),
    field_path: []const u8,
    constraint: []const u8,
    actual: []const u8,
) RegistryError!void {
    const path = allocator.dupe(u8, field_path) catch
        return RegistryError.PayloadValidationFailed;
    errdefer allocator.free(path);
    const actual_dup = allocator.dupe(u8, actual) catch
        return RegistryError.PayloadValidationFailed;
    errdefer allocator.free(actual_dup);
    out.append(allocator, ValidationFailure{
        .field_path = path,
        // Static literal supplied by json_schema.zig — never freed.
        .constraint = constraint,
        .actual = actual_dup,
    }) catch return RegistryError.PayloadValidationFailed;
}

/// Return true if bytes is a non-empty JSON object (starts with '{').
/// This is a lightweight structural guard, not a full JSON Schema validator.
fn isJsonObject(bytes: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, bytes, &std.ascii.whitespace);
    return trimmed.len > 0 and trimmed[0] == '{';
}

/// Return true if `schema_text` is absent or the empty object `{}`.
///
/// An empty schema constrains nothing, so validation can be skipped without
/// changing the outcome. This is a fast path, not a permissive fallback: a
/// schema with any content at all goes through the real validator.
fn isEmptySchema(schema_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, schema_text, &std.ascii.whitespace);
    if (trimmed.len == 0) return true;
    if (trimmed.len < 2) return false;
    if (trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return false;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], &std.ascii.whitespace);
    return inner.len == 0;
}

/// Read column `idx` of a text-format result row, or null for SQL NULL.
fn colText(row: []const ?[]u8, idx: usize) ?[]const u8 {
    if (idx >= row.len) return null;
    return row[idx];
}

/// Parse a canonical UUID text form ("8-4-4-4-12") into 16 raw bytes.
/// Returns the nil UUID when the text is not a well-formed UUID — the id is
/// informational for callers here, never used as a lookup key.
fn parseUuidText(text: []const u8) Uuid {
    var hex: [32]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (c == '-') continue;
        if (n >= 32) return std.mem.zeroes(Uuid);
        hex[n] = c;
        n += 1;
    }
    if (n != 32) return std.mem.zeroes(Uuid);
    var out: Uuid = undefined;
    _ = std.fmt.hexToBytes(&out, hex[0..32]) catch return std.mem.zeroes(Uuid);
    return out;
}

/// Parse a decimal u32 from text; null when the text is not a valid u32.
fn parseU32(text: []const u8) ?u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, text, &std.ascii.whitespace), 10) catch null;
}

/// Parse a decimal i64 from text; null when the text is not a valid i64.
fn parseI64(text: []const u8) ?i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, &std.ascii.whitespace), 10) catch null;
}

/// Serialise an unsigned integer to a decimal string owned by allocator.
fn uintToStr(allocator: std.mem.Allocator, value: u32) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}
