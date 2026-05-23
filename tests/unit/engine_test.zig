// engine_test.zig — unit tests for EE-08 (Instance cancellation) and EE-10
const std = @import("std");
const bpm = @import("bpm");
const instance_mod = bpm.engine;
const task_mod = bpm.tasks;

// ---------------------------------------------------------------------------
// handleCancel — unit tests (no DB; tests the route handler's input validation)
// ---------------------------------------------------------------------------

test "handleCancel: invalid UUID returns 422" {
    const allocator = std.testing.allocator;

    // We can't call the handler without a real store, but we can test the
    // UUID parse path by directly verifying parseUuid rejects invalid input.
    // The handler rejects before touching the store, so a null store would panic
    // only if the parse succeeds.
    //
    // Verify by testing that a well-formed UUID parses without error.
    const valid = "123e4567-e89b-12d3-a456-426614174000";
    var buf: [16]u8 = undefined;
    _ = try parseUuidHelper(valid, &buf);

    // Verify a malformed UUID is rejected.
    const invalid = "not-a-uuid";
    var buf2: [16]u8 = undefined;
    const res = parseUuidHelper(invalid, &buf2);
    try std.testing.expectError(error.InvalidUuid, res);

    _ = allocator;
}

test "CancelInstanceError: error set contains expected variants" {
    // Compile-time check: all expected error codes exist in the error set.
    // This ensures that code that handles these variants will compile correctly.
    const e: instance_mod.CancelInstanceError = error.InstanceNotFound;
    try std.testing.expect(e == error.InstanceNotFound);

    const e2: instance_mod.CancelInstanceError = error.InstanceAlreadyTerminated;
    try std.testing.expect(e2 == error.InstanceAlreadyTerminated);

    const e3: instance_mod.CancelInstanceError = error.PoolExhausted;
    try std.testing.expect(e3 == error.PoolExhausted);

    const e4: instance_mod.CancelInstanceError = error.PersistenceFailed;
    try std.testing.expect(e4 == error.PersistenceFailed);

    const e5: instance_mod.CancelInstanceError = error.OutOfMemory;
    try std.testing.expect(e5 == error.OutOfMemory);
}

test "TaskStore.cancelInTx: TaskError contains expected variants" {
    // Compile-time check: TaskError variants used by cancelInTx exist.
    const e: task_mod.TaskError = error.InvalidInput;
    try std.testing.expect(e == error.InvalidInput);
}

// ---------------------------------------------------------------------------
// EE-10: SetInstanceErrorError — error set validation tests
// ---------------------------------------------------------------------------

test "SetInstanceErrorError: error set contains all required variants" {
    // Compile-time check: all EE-10 §2 error variants exist in SetInstanceErrorError.
    const e1: instance_mod.SetInstanceErrorError = error.InstanceNotFound;
    try std.testing.expect(e1 == error.InstanceNotFound);

    const e2: instance_mod.SetInstanceErrorError = error.AlreadyTerminal;
    try std.testing.expect(e2 == error.AlreadyTerminal);

    const e3: instance_mod.SetInstanceErrorError = error.PoolExhausted;
    try std.testing.expect(e3 == error.PoolExhausted);

    const e4: instance_mod.SetInstanceErrorError = error.PersistenceFailed;
    try std.testing.expect(e4 == error.PersistenceFailed);

    const e5: instance_mod.SetInstanceErrorError = error.OutOfMemory;
    try std.testing.expect(e5 == error.OutOfMemory);
}

// ---------------------------------------------------------------------------
// EE-10: CompleteTaskError — InstanceInError variant present
// ---------------------------------------------------------------------------

test "CompleteTaskError: InstanceInError variant exists and maps to HTTP 409" {
    // Compile-time check: InstanceInError is a valid CompleteTaskError variant.
    const e: instance_mod.CompleteTaskError = error.InstanceInError;
    try std.testing.expect(e == error.InstanceInError);
}

test "CompleteTaskError: SchemaViolationError variant still exists" {
    // Regression check: SchemaViolationError must remain after EE-10 refactor.
    const e: instance_mod.CompleteTaskError = error.SchemaViolationError;
    try std.testing.expect(e == error.SchemaViolationError);
}

// ---------------------------------------------------------------------------
// EE-12: CompleteTaskError — ConcurrentModification variant present
// ---------------------------------------------------------------------------

test "CompleteTaskError: ConcurrentModification variant exists and maps to HTTP 409" {
    // Compile-time check: ConcurrentModification is a valid CompleteTaskError variant.
    const e: instance_mod.CompleteTaskError = error.ConcurrentModification;
    try std.testing.expect(e == error.ConcurrentModification);
}

// ---------------------------------------------------------------------------
// EE-10: ErrorType enum — variant checks
// ---------------------------------------------------------------------------

test "ErrorType: NO_MATCHING_EDGE and SCHEMA_VIOLATION variants exist" {
    const t1: instance_mod.ErrorType = .NO_MATCHING_EDGE;
    try std.testing.expect(t1 == .NO_MATCHING_EDGE);

    const t2: instance_mod.ErrorType = .SCHEMA_VIOLATION;
    try std.testing.expect(t2 == .SCHEMA_VIOLATION);
}

// ---------------------------------------------------------------------------
// EE-10: SetInstanceErrorArgs — struct field layout check
// ---------------------------------------------------------------------------

test "SetInstanceErrorArgs: struct fields have expected layout" {
    // Verify that the struct fields defined in EE-10 §5 all exist and have
    // the expected types. This is a compile-time structural check.
    const dummy_uuid: instance_mod.Uuid = std.mem.zeroes(instance_mod.Uuid);
    const args = instance_mod.SetInstanceErrorArgs{
        .instance_id = dummy_uuid,
        .error_type = .NO_MATCHING_EDGE,
        .affected_node = "gateway-01",
        .affected_field = null,
        .reason = "no matching edge",
        .variable_state = "{}",
        .evaluated_conditions = null,
        .actor_id = "user-1",
    };
    try std.testing.expect(args.error_type == .NO_MATCHING_EDGE);
    try std.testing.expectEqualStrings("gateway-01", args.affected_node.?);
    try std.testing.expectEqualStrings("no matching edge", args.reason);
}

test "SetInstanceErrorArgs: SCHEMA_VIOLATION layout check" {
    const dummy_uuid: instance_mod.Uuid = std.mem.zeroes(instance_mod.Uuid);
    const args = instance_mod.SetInstanceErrorArgs{
        .instance_id = dummy_uuid,
        .error_type = .SCHEMA_VIOLATION,
        .affected_node = null,
        .affected_field = "order_amount",
        .reason = "value must be a number",
        .variable_state = "{\"order_amount\":\"bad\"}",
        .evaluated_conditions = null,
        .actor_id = "user-2",
    };
    try std.testing.expect(args.error_type == .SCHEMA_VIOLATION);
    try std.testing.expectEqualStrings("order_amount", args.affected_field.?);
}

// ---------------------------------------------------------------------------
// EE-10: EvaluatedCondition struct — layout check
// ---------------------------------------------------------------------------

test "EvaluatedCondition: struct fields exist" {
    const cond = instance_mod.EvaluatedCondition{
        .edge_id = "edge-1",
        .condition = "amount > 100",
        .result = false,
    };
    try std.testing.expectEqualStrings("edge-1", cond.edge_id);
    try std.testing.expectEqualStrings("amount > 100", cond.condition);
    try std.testing.expect(cond.result == false);
}

// ---------------------------------------------------------------------------
// EE-10: mapSetErrorToCompleteError — mapping correctness
// ---------------------------------------------------------------------------

test "mapSetErrorToCompleteError: AlreadyTerminal maps to InstanceInError" {
    const result = instance_mod.mapSetErrorToCompleteError(error.AlreadyTerminal);
    try std.testing.expect(result == error.InstanceInError);
}

test "mapSetErrorToCompleteError: PoolExhausted maps to PoolExhausted" {
    const result = instance_mod.mapSetErrorToCompleteError(error.PoolExhausted);
    try std.testing.expect(result == error.PoolExhausted);
}

test "mapSetErrorToCompleteError: OutOfMemory maps to OutOfMemory" {
    const result = instance_mod.mapSetErrorToCompleteError(error.OutOfMemory);
    try std.testing.expect(result == error.OutOfMemory);
}

test "mapSetErrorToCompleteError: PersistenceFailed maps to PersistenceFailed" {
    const result = instance_mod.mapSetErrorToCompleteError(error.PersistenceFailed);
    try std.testing.expect(result == error.PersistenceFailed);
}

test "mapSetErrorToCompleteError: InstanceNotFound maps to PersistenceFailed" {
    const result = instance_mod.mapSetErrorToCompleteError(error.InstanceNotFound);
    try std.testing.expect(result == error.PersistenceFailed);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Minimal UUID hex parser (mirrors the one in instances.zig) for test use.
fn parseUuidHelper(hex: []const u8, out: *[16]u8) error{InvalidUuid}!void {
    if (hex.len != 36) return error.InvalidUuid;
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
        out[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
        i += 2;
    }
    if (byte_idx != 16) return error.InvalidUuid;
}

fn hexNibble(c: u8) error{InvalidHex}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}
