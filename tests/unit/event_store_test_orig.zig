//! Unit test stubs for ES-01 through ES-08.
//!
//! Each test block corresponds to one test case in tests/specs/ES-01-08.md.
//! All blocks return error.SkipZigTest until the TEST-RUNNER implements them.
//!
//! Requirement traceability:
//!   ES-01 → TC-ES-01-01 … TC-ES-01-06
//!   ES-02 → TC-ES-02-01 … TC-ES-02-02
//!   ES-03 → TC-ES-03-01 … TC-ES-03-03
//!   ES-04 → TC-ES-04-01 … TC-ES-04-02
//!   ES-05 → TC-ES-05-01 … TC-ES-05-04
//!   ES-06 → TC-ES-06-01 … TC-ES-06-02
//!   ES-07 → TC-ES-07-01 … TC-ES-07-02
//!   ES-08 → TC-ES-08-01 … TC-ES-08-04
const std = @import("std");

// Source modules (store.zig, registry.zig) are not imported here because Zig
// does not allow cross-module relative @import paths from a standalone root file.
// TEST-RUNNER must wire the module imports via build.zig when implementing logic.
comptime {
    _ = std;
}

// ---------------------------------------------------------------------------
// ES-01: Append event
// ---------------------------------------------------------------------------

test "TC-ES-01-01: valid append returns AppendResult with is_duplicate=false and persisted record" {
    return error.SkipZigTest;
}

test "TC-ES-01-02: append to non-existent instance returns InstanceNotFound" {
    return error.SkipZigTest;
}

test "TC-ES-01-03: append to COMPLETED instance returns InstanceTerminated" {
    return error.SkipZigTest;
}

test "TC-ES-01-04: append to CANCELLED instance returns InstanceTerminated" {
    return error.SkipZigTest;
}

test "TC-ES-01-05: append with nil actor_id returns ActorIdMissing" {
    return error.SkipZigTest;
}

test "TC-ES-01-06: append with JSON array payload returns PayloadInvalid" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// ES-02: Ordered read
// ---------------------------------------------------------------------------

test "TC-ES-02-01: two sequential appends to same instance receive sequence_numbers 1 and 2" {
    return error.SkipZigTest;
}

test "TC-ES-02-02: Store.read returns events sorted by ascending sequence_number" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// ES-03: Event idempotency
// ---------------------------------------------------------------------------

test "TC-ES-03-01: duplicate idempotency_key returns original event with is_duplicate=true" {
    return error.SkipZigTest;
}

test "TC-ES-03-02: empty idempotency_key returns IdempotencyKeyMissing" {
    return error.SkipZigTest;
}

test "TC-ES-03-03: idempotency_key of 256 characters returns IdempotencyKeyTooLong" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// ES-04: Global event stream
// ---------------------------------------------------------------------------

test "TC-ES-04-01: readGlobal returns events in ascending global_seq order" {
    return error.SkipZigTest;
}

test "TC-ES-04-02: readGlobal with after_global_seq cursor returns only events after that position" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// ES-05: Event type registry
// ---------------------------------------------------------------------------

test "TC-ES-05-01: append with unregistered event_type returns UnknownEventType" {
    return error.SkipZigTest;
}

test "TC-ES-05-02: append with payload failing registered schema returns PayloadSchemaInvalid" {
    return error.SkipZigTest;
}

test "TC-ES-05-03: registerType with invalid JSON Schema document returns InvalidJsonSchema" {
    return error.SkipZigTest;
}

test "TC-ES-05-04: registerType with duplicate name+version returns DuplicateEventTypeVersion" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// ES-06: Point-in-time query
// ---------------------------------------------------------------------------

test "TC-ES-06-01: pointInTime with before timestamp filters out later events" {
    return error.SkipZigTest;
}

test "TC-ES-06-02: read with up_to_sequence returns exactly events 1..K" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// ES-07: Retention policy
// ---------------------------------------------------------------------------

test "TC-ES-07-01: archive moves events past retention period to events_archive" {
    return error.SkipZigTest;
}

test "TC-ES-07-02: archive returns count of moved rows" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// ES-08: Event metadata
// ---------------------------------------------------------------------------

test "TC-ES-08-01: append with metadata key longer than 128 characters returns MetadataInvalid" {
    return error.SkipZigTest;
}

test "TC-ES-08-02: append with metadata value longer than 1024 characters returns MetadataInvalid" {
    return error.SkipZigTest;
}

test "TC-ES-08-03: append with more than 50 metadata entries returns MetadataInvalid" {
    return error.SkipZigTest;
}

test "TC-ES-08-04: absent metadata field defaults to empty object in returned record" {
    return error.SkipZigTest;
}
