//! Unit tests for ES-01 through ES-08 — event store pre-write validation.
//!
//! ISS-0148 / GH #464: this file previously consisted of 25 `error.SkipZigTest`
//! blocks. They reported green while executing zero assertions, so ES-01..ES-08
//! had no real unit coverage at all. Every block below now either asserts
//! against the real implementation in src/event_store/, or has been replaced by
//! a NAMED integration test that already covers it (see the
//! "Integration-level coverage map" at the bottom of this file).
//!
//! Scope boundary. `Store.append` splits into two phases: a block of purely
//! in-process validation (ES-01 actor/payload, ES-03 idempotency key shape,
//! ES-08 metadata limits) and a DB transaction (instance status, sequence
//! assignment, idempotency dedup, global ordering, archival). Only the first
//! phase is decidable without a database, and it is exactly what this file
//! tests — through `store.validateAppendParams`, which `append()` itself calls,
//! so these assertions run the same bytes production runs. No mocks, no fakes,
//! no in-memory Pool substitute (DIRECTIVE T-1).
//!
//! Everything requiring persisted state lives in
//! tests/integration/event_store_integration_test.zig against real PostgreSQL
//! via BPM_TEST_DB_URL.
const std = @import("std");
const store = @import("event_store");
const registry = store.registry_module;

const StoreError = store.StoreError;
const AppendParams = store.AppendParams;
const RegistryError = registry.RegistryError;
const RegisterParams = registry.RegisterParams;

const talloc = std.testing.allocator;

/// A UUID with at least one non-zero byte — passes the ES-01 non-nil actor check.
const VALID_ACTOR: store.Uuid = .{ 0xac, 0xac, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
const VALID_INSTANCE: store.Uuid = .{ 0xe5, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

/// AppendParams that pass every pre-write check; individual tests override one
/// field so each assertion isolates exactly one rule.
fn validParams() AppendParams {
    return AppendParams{
        .instance_id = VALID_INSTANCE,
        .event_type = "ES01_TYPE",
        .payload = "{\"x\":1}",
        .actor_id = VALID_ACTOR,
        .idempotency_key = "es01-idem-01",
        .metadata = null,
    };
}

// ---------------------------------------------------------------------------
// ES-01: Append event — pre-write validation
// ---------------------------------------------------------------------------

// TC-ES-01-01 (unit half): a fully valid request clears every in-process check.
// The persisted-record half is DB-bound; see integration TC-ES-01-01.
test "TC-ES-01-01: valid params clear all pre-write validation and default metadata" {
    const metadata = try store.validateAppendParams(talloc, validParams());
    try std.testing.expectEqualStrings("{}", metadata);
}

// TC-ES-01-05: ES-01 requires a non-nil actor_id.
test "TC-ES-01-05: append with nil actor_id returns ActorIdMissing" {
    var p = validParams();
    p.actor_id = std.mem.zeroes(store.Uuid);
    try std.testing.expectError(
        StoreError.ActorIdMissing,
        store.validateAppendParams(talloc, p),
    );
}

// TC-ES-01-06: ES-01 requires payload to be a JSON object — not an array,
// not a scalar, not null.
test "TC-ES-01-06: append with non-object payload returns PayloadInvalid" {
    const bad_payloads = [_][]const u8{
        "[1,2,3]", // JSON array
        "42", // JSON number scalar
        "\"str\"", // JSON string scalar
        "null", // JSON null
        "", // empty
    };
    for (bad_payloads) |payload| {
        var p = validParams();
        p.payload = payload;
        try std.testing.expectError(
            StoreError.PayloadInvalid,
            store.validateAppendParams(talloc, p),
        );
    }
}

// ES-01 explicitly permits an empty object as payload.
test "TC-ES-01-06b: empty JSON object payload is accepted (ES-01 permits {})" {
    var p = validParams();
    p.payload = "{}";
    _ = try store.validateAppendParams(talloc, p);
}

// Leading whitespace must not defeat the JSON-object check.
test "TC-ES-01-06c: payload with leading whitespace is still recognised as an object" {
    var p = validParams();
    p.payload = "   \n\t{\"x\":1}";
    _ = try store.validateAppendParams(talloc, p);
}

// ADP-01: tenant context is required at the storage boundary.
test "TC-ES-01-07: empty tenant_id returns MissingTenantContext" {
    var p = validParams();
    p.tenant_id = "";
    try std.testing.expectError(
        StoreError.MissingTenantContext,
        store.validateAppendParams(talloc, p),
    );
}

// ---------------------------------------------------------------------------
// ES-03: Event idempotency — key shape validation
// ---------------------------------------------------------------------------

// TC-ES-03-02: ES-03 rejects a missing/empty idempotency key.
test "TC-ES-03-02: empty idempotency_key returns IdempotencyKeyMissing" {
    var p = validParams();
    p.idempotency_key = "";
    try std.testing.expectError(
        StoreError.IdempotencyKeyMissing,
        store.validateAppendParams(talloc, p),
    );
}

// TC-ES-03-03: ES-03 accepts keys up to 255 chars, rejects 256+.
// Asserting the boundary on both sides is what makes this a real test: an
// off-by-one in either direction fails here.
test "TC-ES-03-03: idempotency_key boundary - 255 accepted, 256 rejected" {
    const key_255 = "k" ** 255;
    try std.testing.expectEqual(@as(usize, 255), key_255.len);
    var ok = validParams();
    ok.idempotency_key = key_255;
    _ = try store.validateAppendParams(talloc, ok);

    const key_256 = "k" ** 256;
    var bad = validParams();
    bad.idempotency_key = key_256;
    try std.testing.expectError(
        StoreError.IdempotencyKeyTooLong,
        store.validateAppendParams(talloc, bad),
    );
}

// ---------------------------------------------------------------------------
// ES-05: Event type registry — name and schema document validation
// ---------------------------------------------------------------------------

fn validRegisterParams() RegisterParams {
    return RegisterParams{
        .name = "ES05_TYPE",
        .schema_version = 1,
        .json_schema = "{\"type\":\"object\"}",
        .description = null,
    };
}

// TC-ES-05-03: ES-05 requires the stored schema to be a JSON Schema document.
// A non-object document must be rejected before anything is persisted.
test "TC-ES-05-03: registerType with non-object JSON Schema returns InvalidJsonSchema" {
    const bad_schemas = [_][]const u8{ "[]", "\"not-a-schema\"", "7", "", "null" };
    for (bad_schemas) |schema| {
        var p = validRegisterParams();
        p.json_schema = schema;
        try std.testing.expectError(
            RegistryError.InvalidJsonSchema,
            registry.validateRegisterParams(p),
        );
    }
}

// ES-05: name must be a non-empty string of <= 128 characters.
test "TC-ES-05-05: event type name boundary - empty rejected, 128 accepted, 129 rejected" {
    var empty = validRegisterParams();
    empty.name = "";
    try std.testing.expectError(
        RegistryError.EventTypeNameEmpty,
        registry.validateRegisterParams(empty),
    );

    const name_128 = "n" ** 128;
    var ok = validRegisterParams();
    ok.name = name_128;
    try registry.validateRegisterParams(ok);

    const name_129 = "n" ** 129;
    var too_long = validRegisterParams();
    too_long.name = name_129;
    try std.testing.expectError(
        RegistryError.EventTypeNameTooLong,
        registry.validateRegisterParams(too_long),
    );
}

// A well-formed schema document passes.
test "TC-ES-05-06: valid object schema document is accepted" {
    try registry.validateRegisterParams(validRegisterParams());
}

// ---------------------------------------------------------------------------
// TC-PAR-03-01: PAR-03 AC1's app-level guard — RegistryError.RetentionClassForbidden
//
// PAR-03 AC1: "GIVEN an event type in the set {INSTANCE_*, TASK_*, GATEWAY_*,
// EXECUTION_*}, WHEN retention class `delete` is configured for it, THEN
// configuration is rejected with `RetentionClassForbidden` and the type never
// routes to `events_ephemeral`."
//
// registry.validateRegisterParams() (registry.zig) implements this check as a
// pure, DB-free function — registerType() calls it before acquiring any
// connection, the same ES-05 pattern TC-ES-05-03/05/06 above already exercise
// for this exact function. Before this test, RegistryError.RetentionClassForbidden
// was never asserted anywhere in the suite: the only integration coverage of
// this guard (event_store_integration_test.zig's TC-ADP-11-02) only exercises
// the PERMITTED path (a non-protected name), and
// par03_retention_class_test.zig's DB-CHECK-constraint test bypasses
// Registry.registerType() entirely via a raw SQL UPDATE — so the app-level
// guard itself (the first line of defense named explicitly by AC1) was a
// silent, untested gap. This closes it directly against the production bytes.
test "TC-PAR-03-01: registerType rejects retention_class=delete for a protected-family name" {
    const protected_names = [_][]const u8{
        "INSTANCE_STARTED",
        "TASK_COMPLETED",
        "GATEWAY_EVALUATED",
        "EXECUTION_PARTITION_CREATED",
    };
    for (protected_names) |name| {
        var p = validRegisterParams();
        p.name = name;
        p.retention_class = "delete";
        try std.testing.expectError(
            RegistryError.RetentionClassForbidden,
            registry.validateRegisterParams(p),
        );
    }
}

// The converse of TC-PAR-03-01: a non-protected name with retention_class =
// 'delete' is the permitted path TC-ADP-11-02 exercises end-to-end against a
// real DB — this asserts the pure guard itself does not over-reject it.
test "TC-PAR-03-02: registerType permits retention_class=delete for a non-protected name" {
    var p = validRegisterParams();
    p.name = "WIDGET_CREATED";
    p.retention_class = "delete";
    try registry.validateRegisterParams(p);
}

// Protected-family names with a non-'delete' retention_class (the two allowed
// modes per ADP-11/PAR-03: retain_forever, archive_queryable) must NOT be
// rejected — the guard is specifically retention_class=='delete' AND
// protected-family, not protected-family alone.
test "TC-PAR-03-03: registerType permits protected-family names with non-delete retention_class" {
    const allowed_classes = [_][]const u8{ "retain_forever", "archive_queryable" };
    for (allowed_classes) |class| {
        var p = validRegisterParams();
        p.name = "INSTANCE_STARTED";
        p.retention_class = class;
        try registry.validateRegisterParams(p);
    }
}

// ---------------------------------------------------------------------------
// TC-ES-05-02: payload validation against the REGISTERED schema (ISS-0155)
//
// ES-05: "WHEN a caller appends a payload that fails the registered schema,
// THEN the platform returns HTTP 422 with an RFC 9457 body listing every
// validation failure (field path, constraint violated, actual value)."
//
// Until ISS-0155 / GH #473 this was unreachable: Registry.validatePayload
// fetched the schema then discarded it (`_ = record;`) and Registry.getType
// returned a placeholder with json_schema hardcoded to "{}", so every JSON
// object was accepted for every registered event type.
//
// The schema-vs-payload decision itself is pure and DB-free — it is
// `registry.validatePayloadAgainstSchema`, which `Registry.validatePayload`
// itself calls after fetching the row, so these assertions execute the same
// bytes production executes (no mock Registry, no fake Pool; DIRECTIVE T-1).
// The DB half — that getType returns the STORED schema rather than "{}" — is
// covered by integration TC-ES-05-02 against real PostgreSQL.
// ---------------------------------------------------------------------------

/// Free a failure list returned by validatePayloadAgainstSchema. The caller
/// owns both the per-failure strings and the list itself.
fn freeFailureList(list: *std.ArrayList(registry.ValidationFailure)) void {
    registry.freeFailures(talloc, list.items);
    list.deinit(talloc);
}

/// Collect failures for (schema, payload) and assert the call was accepted.
fn expectPayloadAccepted(schema: []const u8, payload: []const u8) !void {
    var failures = try registry.validatePayloadAgainstSchema(talloc, schema, payload);
    defer freeFailureList(&failures);
    if (failures.items.len != 0) {
        std.debug.print("expected accept, got {d} failure(s); first: {s} {s}\n", .{
            failures.items.len,
            failures.items[0].field_path,
            failures.items[0].constraint,
        });
        return error.TestUnexpectedResult;
    }
}

// The positive direction: a payload conforming to the registered schema is
// accepted. Without this, "reject everything" would pass the negative test.
test "TC-ES-05-02a: payload conforming to the registered schema is accepted" {
    const schema =
        \\{"type":"object","required":["order_id","amount"],"properties":{"order_id":{"type":"string","maxLength":36},"amount":{"type":"integer","minimum":0}}}
    ;
    try expectPayloadAccepted(schema,
        \\{"order_id":"ord-1","amount":250}
    );
    // Optional members may be omitted, and undeclared members are allowed
    // because the schema does not set additionalProperties:false.
    try expectPayloadAccepted(schema,
        \\{"order_id":"ord-2","amount":0,"note":"extra"}
    );
    // An empty schema constrains nothing (ES-05 edge case: payload {} with a
    // schema that has no required fields is valid).
    try expectPayloadAccepted("{}", "{}");
    try expectPayloadAccepted("{\"type\":\"object\"}", "{}");
}

// The negative direction: a payload violating the registered schema is
// rejected, and EVERY violation is reported with its field path, the failing
// constraint, and the actual value (ES-05's RFC 9457 requirement).
test "TC-ES-05-02b: payload failing the registered schema is rejected with per-field detail" {
    const schema =
        \\{"type":"object","required":["order_id","amount"],"properties":{"order_id":{"type":"string","maxLength":5},"amount":{"type":"integer","minimum":0}}}
    ;

    // Wrong type on a declared property.
    {
        var f = try registry.validatePayloadAgainstSchema(talloc,
            schema,
            \\{"order_id":"ord-1","amount":"not-a-number"}
        );
        defer freeFailureList(&f);
        try std.testing.expectEqual(@as(usize, 1), f.items.len);
        try std.testing.expectEqualStrings("/amount", f.items[0].field_path);
        try std.testing.expectEqualStrings("type", f.items[0].constraint);
        try std.testing.expectEqualStrings("\"not-a-number\"", f.items[0].actual);
    }

    // ES-05 edge case: payload {} against a schema WITH required fields must
    // list ALL missing required fields — not stop at the first.
    {
        var f = try registry.validatePayloadAgainstSchema(talloc, schema, "{}");
        defer freeFailureList(&f);
        try std.testing.expectEqual(@as(usize, 2), f.items.len);
        try std.testing.expectEqualStrings("/order_id", f.items[0].field_path);
        try std.testing.expectEqualStrings("required", f.items[0].constraint);
        try std.testing.expectEqualStrings("null", f.items[0].actual);
        try std.testing.expectEqualStrings("/amount", f.items[1].field_path);
        try std.testing.expectEqualStrings("required", f.items[1].constraint);
    }

    // Multiple simultaneous constraint violations are all reported.
    {
        var f = try registry.validatePayloadAgainstSchema(talloc,
            schema,
            \\{"order_id":"far-too-long","amount":-5}
        );
        defer freeFailureList(&f);
        try std.testing.expectEqual(@as(usize, 2), f.items.len);
        try std.testing.expectEqualStrings("/order_id", f.items[0].field_path);
        try std.testing.expectEqualStrings("maxLength", f.items[0].constraint);
        try std.testing.expectEqualStrings("/amount", f.items[1].field_path);
        try std.testing.expectEqualStrings("minimum", f.items[1].constraint);
        try std.testing.expectEqualStrings("-5", f.items[1].actual);
    }
}

// Regression guard for the exact ISS-0155 defect: before the fix, validation
// ran against a hardcoded "{}" schema, so a payload that plainly contradicts
// its registered schema was accepted. If the schema argument is ever ignored
// again, this test fails.
test "TC-ES-05-02c: the registered schema is actually consulted (ISS-0155 regression)" {
    const strict =
        \\{"type":"object","required":["must_have"]}
    ;
    var f = try registry.validatePayloadAgainstSchema(talloc, strict,
        \\{"something_else":1}
    );
    defer freeFailureList(&f);
    // An empty-schema no-op would return zero failures here.
    try std.testing.expect(f.items.len > 0);
    try std.testing.expectEqualStrings("/must_have", f.items[0].field_path);
    try std.testing.expectEqualStrings("required", f.items[0].constraint);
}

// The real seeded schemas from migrations/094_entity_subsystem.sql, exercised
// against the payloads src/entities/events.zig actually builds. This pins the
// two together: if either drifts, real appends would start being rejected in
// production, and this test catches it first.
test "TC-ES-05-02d: real ENTITY_RECORD_CREATED schema accepts the payload production builds" {
    const schema =
        \\{"type":"object","required":["entity_type","entity_def_version","record_id","field_values"],"properties":{"entity_type":{"type":"string","minLength":1,"maxLength":128},"entity_def_version":{"type":"integer","minimum":1},"record_id":{"type":"string","format":"uuid"},"field_values":{"type":"object"}}}
    ;
    try expectPayloadAccepted(schema,
        \\{"entity_type":"customer","entity_def_version":1,"record_id":"550e8400-e29b-41d4-a716-446655440000","field_values":{"email":"a@b.c"}}
    );

    // A payload missing a required member is rejected against that same schema.
    var f = try registry.validatePayloadAgainstSchema(talloc, schema,
        \\{"entity_type":"customer","entity_def_version":1,"record_id":"550e8400-e29b-41d4-a716-446655440000"}
    );
    defer freeFailureList(&f);
    try std.testing.expectEqual(@as(usize, 1), f.items.len);
    try std.testing.expectEqualStrings("/field_values", f.items[0].field_path);
    try std.testing.expectEqualStrings("required", f.items[0].constraint);
}

// A payload that is not a JSON object at all fails the structural check with a
// root-pointer "type" failure, regardless of what the schema says.
test "TC-ES-05-02e: non-object payload fails at the document root" {
    for ([_][]const u8{ "[1,2]", "42", "\"str\"", "null", "" }) |payload| {
        var f = try registry.validatePayloadAgainstSchema(talloc, "{\"type\":\"object\"}", payload);
        defer freeFailureList(&f);
        try std.testing.expectEqual(@as(usize, 1), f.items.len);
        try std.testing.expectEqualStrings("/", f.items[0].field_path);
        try std.testing.expectEqualStrings("type", f.items[0].constraint);
    }
}

// Malformed JSON that happens to start with '{' passes the cheap structural
// guard but must still be rejected by the parse step.
test "TC-ES-05-02f: malformed JSON payload starting with a brace is rejected" {
    var f = try registry.validatePayloadAgainstSchema(talloc, "{\"type\":\"object\"}", "{not valid json");
    defer freeFailureList(&f);
    try std.testing.expectEqual(@as(usize, 1), f.items.len);
    try std.testing.expectEqualStrings("/", f.items[0].field_path);
    try std.testing.expectEqualStrings("type", f.items[0].constraint);
}

// A stored schema that no longer parses is a registry-integrity fault: it must
// surface as InvalidJsonSchema, never as "payload accepted".
test "TC-ES-05-02g: unparseable stored schema returns InvalidJsonSchema, not silent acceptance" {
    try std.testing.expectError(
        RegistryError.InvalidJsonSchema,
        registry.validatePayloadAgainstSchema(talloc, "{broken schema", "{\"a\":1}"),
    );
}

// ---------------------------------------------------------------------------
// ES-07: Retention policy — mode/value consistency (ADP-11 protected families)
// ---------------------------------------------------------------------------

// ES-07: each policy mode requires exactly its own value field and no other.
test "TC-ES-07-03: retention policy mode/value consistency is enforced" {
    // keep_forever takes neither keep_days nor keep_count.
    try store.validateRetentionPolicyParams(talloc, .{
        .event_type = "REPORT_GENERATED",
        .policy = .keep_forever,
    });
    try std.testing.expectError(StoreError.InvalidRetentionPolicyValue, store.validateRetentionPolicyParams(talloc, .{
        .event_type = "REPORT_GENERATED",
        .policy = .keep_forever,
        .keep_days = 30,
    }));

    // keep_days requires keep_days and forbids keep_count.
    try store.validateRetentionPolicyParams(talloc, .{
        .event_type = "REPORT_GENERATED",
        .policy = .keep_days,
        .keep_days = 30,
    });
    try std.testing.expectError(StoreError.InvalidRetentionPolicyValue, store.validateRetentionPolicyParams(talloc, .{
        .event_type = "REPORT_GENERATED",
        .policy = .keep_days,
    }));
    try std.testing.expectError(StoreError.InvalidRetentionPolicyValue, store.validateRetentionPolicyParams(talloc, .{
        .event_type = "REPORT_GENERATED",
        .policy = .keep_days,
        .keep_days = 30,
        .keep_count = 5,
    }));

    // keep_count requires keep_count and forbids keep_days.
    try store.validateRetentionPolicyParams(talloc, .{
        .event_type = "REPORT_GENERATED",
        .policy = .keep_count,
        .keep_count = 5,
    });
    try std.testing.expectError(StoreError.InvalidRetentionPolicyValue, store.validateRetentionPolicyParams(talloc, .{
        .event_type = "REPORT_GENERATED",
        .policy = .keep_count,
    }));
}

// ES-07 / ADP-11: hard-delete is forbidden for replay-critical event families,
// and the family match must be case- and whitespace-insensitive because
// upsertRetentionPolicy normalises the event_type before checking.
test "TC-ES-07-04: hard-delete on protected families is rejected after normalisation" {
    const protected = [_][]const u8{
        "INSTANCE_CREATED",
        "task_completed", // lowercase — normalisation must still catch it
        "  gateway_evaluated  ", // padded — trimmed before the family check
        "EXECUTION_STARTED",
    };
    for (protected) |event_type| {
        try std.testing.expectError(StoreError.ProtectedFamilyHardDeleteForbidden, store.validateRetentionPolicyParams(talloc, .{
            .event_type = event_type,
            .policy = .hard_delete_days,
            .keep_days = 7,
        }));
        try std.testing.expectError(StoreError.ProtectedFamilyHardDeleteForbidden, store.validateRetentionPolicyParams(talloc, .{
            .event_type = event_type,
            .policy = .hard_delete_count,
            .keep_count = 7,
        }));
    }

    // Non-protected families remain hard-delete configurable.
    try store.validateRetentionPolicyParams(talloc, .{
        .event_type = "REPORT_GENERATED",
        .policy = .hard_delete_days,
        .keep_days = 7,
    });

    // Protected families still accept non-destructive modes.
    try store.validateRetentionPolicyParams(talloc, .{
        .event_type = "INSTANCE_CREATED",
        .policy = .keep_days,
        .keep_days = 90,
    });
}

// An empty event_type is not a valid retention policy target.
test "TC-ES-07-05: empty event_type returns InvalidRetentionPolicyValue" {
    try std.testing.expectError(StoreError.InvalidRetentionPolicyValue, store.validateRetentionPolicyParams(talloc, .{
        .event_type = "",
        .policy = .keep_forever,
    }));
}

// ES-07 error surface: the RFC 9457 problem code exposed for each rejection.
test "TC-ES-07-06: retention policy errors map to stable problem codes" {
    try std.testing.expectEqualStrings(
        "RETENTION_POLICY_PROTECTED_FAMILY_HARD_DELETE_FORBIDDEN",
        store.retentionPolicyErrorCode(StoreError.ProtectedFamilyHardDeleteForbidden).?,
    );
    try std.testing.expectEqualStrings(
        "RETENTION_POLICY_INPUT_INVALID",
        store.retentionPolicyErrorCode(StoreError.InvalidRetentionPolicyValue).?,
    );
    // Unrelated errors carry no retention problem code.
    try std.testing.expect(store.retentionPolicyErrorCode(StoreError.InstanceNotFound) == null);
}

// The violation detail returned to the caller must name the family and the
// allowed alternatives, and must be absent when there is no violation.
test "TC-ES-07-07: protected-family violation detail names family and allowed modes" {
    const v = store.retentionPolicyViolation("TASK_COMPLETED", .hard_delete_days).?;
    try std.testing.expectEqualStrings("TASK_*", v.event_family);
    try std.testing.expectEqualStrings("hard_delete_days", v.requested_mode);
    try std.testing.expectEqualStrings("TASK_COMPLETED", v.event_type);
    try std.testing.expectEqualStrings(
        "RETENTION_POLICY_PROTECTED_FAMILY_HARD_DELETE_FORBIDDEN",
        v.code,
    );
    try std.testing.expectEqualStrings("keep_forever", v.allowed_modes[0]);
    try std.testing.expectEqualStrings("keep_days", v.allowed_modes[1]);
    try std.testing.expectEqualStrings("keep_count", v.allowed_modes[2]);

    // No violation for a non-protected family, or for a non-destructive mode.
    try std.testing.expect(store.retentionPolicyViolation("REPORT_GENERATED", .hard_delete_days) == null);
    try std.testing.expect(store.retentionPolicyViolation("TASK_COMPLETED", .keep_days) == null);
}

// ---------------------------------------------------------------------------
// ES-08: Event metadata — limits and defaulting
// ---------------------------------------------------------------------------

/// Build a metadata object {"k0":"v",...} with exactly n string entries.
fn buildMetadataJson(allocator: std.mem.Allocator, n: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');
    for (0..n) |i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.print(allocator, "\"k{d}\":\"v\"", .{i});
    }
    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

// TC-ES-08-01: ES-08 caps metadata keys at 128 characters.
test "TC-ES-08-01: metadata key boundary - 128 accepted, 129 returns MetadataInvalid" {
    const key_128 = "k" ** 128;
    const ok_json = try std.fmt.allocPrint(talloc, "{{\"{s}\":\"v\"}}", .{key_128});
    defer talloc.free(ok_json);
    var ok = validParams();
    ok.metadata = ok_json;
    _ = try store.validateAppendParams(talloc, ok);

    const key_129 = "k" ** 129;
    const bad_json = try std.fmt.allocPrint(talloc, "{{\"{s}\":\"v\"}}", .{key_129});
    defer talloc.free(bad_json);
    var bad = validParams();
    bad.metadata = bad_json;
    try std.testing.expectError(
        StoreError.MetadataInvalid,
        store.validateAppendParams(talloc, bad),
    );
}

// TC-ES-08-02: ES-08 caps metadata values at 1024 characters.
test "TC-ES-08-02: metadata value boundary - 1024 accepted, 1025 returns MetadataInvalid" {
    const val_1024 = "v" ** 1024;
    const ok_json = try std.fmt.allocPrint(talloc, "{{\"k\":\"{s}\"}}", .{val_1024});
    defer talloc.free(ok_json);
    var ok = validParams();
    ok.metadata = ok_json;
    _ = try store.validateAppendParams(talloc, ok);

    const val_1025 = "v" ** 1025;
    const bad_json = try std.fmt.allocPrint(talloc, "{{\"k\":\"{s}\"}}", .{val_1025});
    defer talloc.free(bad_json);
    var bad = validParams();
    bad.metadata = bad_json;
    try std.testing.expectError(
        StoreError.MetadataInvalid,
        store.validateAppendParams(talloc, bad),
    );
}

// TC-ES-08-03: ES-08 caps metadata at 50 entries.
test "TC-ES-08-03: metadata entry-count boundary - 50 accepted, 51 returns MetadataInvalid" {
    const ok_json = try buildMetadataJson(talloc, 50);
    defer talloc.free(ok_json);
    var ok = validParams();
    ok.metadata = ok_json;
    _ = try store.validateAppendParams(talloc, ok);

    const bad_json = try buildMetadataJson(talloc, 51);
    defer talloc.free(bad_json);
    var bad = validParams();
    bad.metadata = bad_json;
    try std.testing.expectError(
        StoreError.MetadataInvalid,
        store.validateAppendParams(talloc, bad),
    );
}

// ES-08: metadata values must be strings — number/object/array/bool rejected.
test "TC-ES-08-05: non-string metadata values return MetadataInvalid" {
    const bad_metadata = [_][]const u8{
        "{\"k\":1}", // number
        "{\"k\":{\"nested\":\"x\"}}", // object
        "{\"k\":[\"a\"]}", // array
        "{\"k\":true}", // boolean
        "{\"k\":null}", // null
    };
    for (bad_metadata) |metadata| {
        var p = validParams();
        p.metadata = metadata;
        try std.testing.expectError(
            StoreError.MetadataInvalid,
            store.validateAppendParams(talloc, p),
        );
    }
}

// ES-08: metadata that is not a JSON object at all is rejected.
test "TC-ES-08-06: non-object metadata document returns MetadataInvalid" {
    const bad_metadata = [_][]const u8{ "[]", "\"str\"", "5", "", "not json" };
    for (bad_metadata) |metadata| {
        var p = validParams();
        p.metadata = metadata;
        try std.testing.expectError(
            StoreError.MetadataInvalid,
            store.validateAppendParams(talloc, p),
        );
    }
}

// TC-ES-08-04 (unit half): an absent metadata field defaults to "{}".
// The "returned in the persisted record" half is DB-bound; see integration
// TC-ES-08-04.
test "TC-ES-08-04: absent metadata defaults to empty object" {
    var p = validParams();
    p.metadata = null;
    try std.testing.expectEqualStrings("{}", try store.validateAppendParams(talloc, p));

    // An explicit empty object is preserved as-is.
    p.metadata = "{}";
    try std.testing.expectEqualStrings("{}", try store.validateAppendParams(talloc, p));
}

// ---------------------------------------------------------------------------
// Validation ORDER (ES-01/ES-03/ES-08 interaction)
//
// Order matters to callers: the HTTP layer maps each StoreError to a distinct
// RFC 9457 problem, so a request violating two rules must report a stable,
// documented one. This pins append()'s documented order rather than letting it
// drift silently.
// ---------------------------------------------------------------------------

test "pre-write validation order is actor then key then payload then metadata" {
    // nil actor + empty key + bad payload + bad metadata -> ActorIdMissing wins.
    var p = AppendParams{
        .instance_id = VALID_INSTANCE,
        .event_type = "T",
        .payload = "[]",
        .actor_id = std.mem.zeroes(store.Uuid),
        .idempotency_key = "",
        .metadata = "[]",
    };
    try std.testing.expectError(StoreError.ActorIdMissing, store.validateAppendParams(talloc, p));

    // Fix actor -> empty key wins over bad payload/metadata.
    p.actor_id = VALID_ACTOR;
    try std.testing.expectError(StoreError.IdempotencyKeyMissing, store.validateAppendParams(talloc, p));

    // Fix key -> bad payload wins over bad metadata.
    p.idempotency_key = "k";
    try std.testing.expectError(StoreError.PayloadInvalid, store.validateAppendParams(talloc, p));

    // Fix payload -> metadata is the last check to fire.
    p.payload = "{}";
    try std.testing.expectError(StoreError.MetadataInvalid, store.validateAppendParams(talloc, p));

    // Fix metadata -> everything passes.
    p.metadata = "{}";
    _ = try store.validateAppendParams(talloc, p);
}

// ---------------------------------------------------------------------------
// Integration-level coverage map (ISS-0148)
//
// The following cases are NOT unit-testable: each asserts a property of
// persisted state (instance status, sequence assignment, cross-instance global
// ordering, idempotency dedup, archival movement) and therefore requires a real
// PostgreSQL database. They are covered by the NAMED tests below in
// tests/integration/event_store_integration_test.zig, run by
// `zig build test-integration` with BPM_TEST_DB_URL set.
//
//   TC-ES-01-01  "TC-ES-01-01: valid append returns AppendResult with
//                 is_duplicate=false and persisted record"
//   TC-ES-01-05  "TC-ES-01-05: append with nil actor_id returns ActorIdMissing"
//   TC-ES-01-06  "TC-ES-01-06: append with array payload returns PayloadInvalid"
//   TC-ES-02-01  "TC-ES-02-01: two sequential appends receive sequence_numbers 1 and 2"
//   TC-ES-02-02  "TC-ES-02-02: Store.read returns events sorted by ascending
//                 sequence_number"
//   TC-ES-03-01  "TC-ES-03-01: duplicate idempotency_key returns original event
//                 with is_duplicate=true"
//   TC-ES-03-02  "TC-ES-03-02: append with empty idempotency_key returns
//                 IdempotencyKeyMissing"
//   TC-ES-03-03  "TC-ES-03-03: append with 256-char idempotency_key returns
//                 IdempotencyKeyTooLong"
//   TC-ES-04-01  "TC-ES-04-01: readGlobal returns events in ascending global_seq order"
//   TC-ES-04-02  "TC-ES-04-02: readGlobal with after_global_seq cursor returns
//                 only later events"
//   TC-ES-05-01  "TC-ES-05-01: append with unregistered event_type returns
//                 UnknownEventType"
//   TC-ES-06-01  "TC-ES-06-01: pointInTime filters out events created after the
//                 timestamp"
//   TC-ES-06-02  "TC-ES-06-02: read with up_to_sequence returns exactly events 1..K"
//   TC-ES-07-01  "TC-ES-07-01: archive moves expired events to events_archive"
//   TC-ES-08-04  "TC-ES-08-04: absent metadata field defaults to empty object in
//                 returned record"
//
// Cases with NO coverage at either level. These were SkipZigTest stubs whose
// requirement is real but untested; they are filed as their own issues rather
// than silently dropped (CLAUDE.md: "Never Satisfy a Gate by Editing What It
// Measures"):
//
//   TC-ES-01-02 (append to non-existent instance -> InstanceNotFound)
//   TC-ES-01-03 (append to COMPLETED instance -> InstanceTerminated)
//   TC-ES-01-04 (append to CANCELLED instance -> InstanceTerminated)
//   TC-ES-05-04 (duplicate name+version -> DuplicateEventTypeVersion)
//   TC-ES-07-02 (archive returns count of moved rows)
//                                                        -> see ISS-0154 / GH #472
//
//   TC-ES-05-02 (payload failing registered schema -> PayloadSchemaInvalid) was
//   previously listed here as "not implementable at any level": Registry
//   .validatePayload carried a TODO and performed only a structural
//   is-JSON-object check, so no payload could fail a registered schema. That
//   production gap was ISS-0155 / GH #473 and is now FIXED. Coverage:
//     - unit (this file): TC-ES-05-02a..g against
//       registry.validatePayloadAgainstSchema, the pure schema-vs-payload
//       decision Registry.validatePayload itself calls.
//     - integration: "TC-ES-05-02: append with payload failing registered
//       schema returns PayloadSchemaInvalid" in
//       tests/integration/event_store_integration_test.zig, which additionally
//       proves Registry.getType returns the STORED schema rather than the old
//       hardcoded "{}" placeholder.
// ---------------------------------------------------------------------------
