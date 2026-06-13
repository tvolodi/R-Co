//! Unit tests for EXP-301/302/303 — Effects subsystem
//!
//! All tests are pure (no DB, no network, no clock reads).
//! Tests cover:
//!   1. Backoff schedule — computeEffectBackoffMs across all attempt indices
//!   2. Idempotency key format — verify Idempotency-Key sent matches effect_event_id
//!   3. Stub executor — execute() increments counters, records spec, reset() clears
//!   4. EffectSpec serialisation — round-trip JSON field preservation
//!   5. Failure classification — classifyHttpOutcome for key status codes
//!   6. Correlation key helpers — buildCorrelationKey and extractNodeId
const std = @import("std");
const bpm = @import("bpm");
const effects_mod = bpm.effects_mod;
const stub_mod = bpm.effects_stub;

// ---------------------------------------------------------------------------
// 1. Backoff schedule
// ---------------------------------------------------------------------------

test "computeEffectBackoffMs returns expected schedule" {
    const expected = effects_mod.EFFECT_BACKOFF_MS;

    // Each index returns the table entry.
    for (expected, 0..) |ms, i| {
        const got = effects_mod.computeEffectBackoffMs(@intCast(i));
        try std.testing.expectEqual(ms, got);
    }

    // Beyond max_attempts returns the last slot (30 min).
    const capped = effects_mod.computeEffectBackoffMs(99);
    try std.testing.expectEqual(expected[expected.len - 1], capped);
}

test "EFFECT_MAX_ATTEMPTS equals 5" {
    try std.testing.expectEqual(@as(u8, 5), effects_mod.EFFECT_MAX_ATTEMPTS);
}

test "backoff schedule matches design table" {
    // Documented: 5s, 30s, 2min, 10min, 30min
    try std.testing.expectEqual(@as(u32, 5_000), effects_mod.computeEffectBackoffMs(0));
    try std.testing.expectEqual(@as(u32, 30_000), effects_mod.computeEffectBackoffMs(1));
    try std.testing.expectEqual(@as(u32, 120_000), effects_mod.computeEffectBackoffMs(2));
    try std.testing.expectEqual(@as(u32, 600_000), effects_mod.computeEffectBackoffMs(3));
    try std.testing.expectEqual(@as(u32, 1_800_000), effects_mod.computeEffectBackoffMs(4));
}

// ---------------------------------------------------------------------------
// 2. Idempotency key derivation
// ---------------------------------------------------------------------------

test "effect_event_id is used as Idempotency-Key in stub response" {
    const allocator = std.testing.allocator;

    var stub = stub_mod.StubEffectsExecutor.init(allocator);
    defer stub.deinit();

    const spec = effects_mod.EffectSpec{
        .effect_event_id = "550e8400-e29b-41d4-a716-446655440000",
        .instance_id = "inst-001",
        .node_id = "node-svc-01",
        .token_id = "tok-001",
        .correlation_key = "node-svc-01:tok-001",
        .kind = .http_call,
        .spec_json = "{}",
    };

    const result = try stub.execute(allocator, spec, 0);
    defer if (result.response_body) |b| allocator.free(b);

    // The stub must echo back effect_event_id as the idempotency key sent.
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", result.idempotency_key_sent);
}

// ---------------------------------------------------------------------------
// 3. Stub executor
// ---------------------------------------------------------------------------

test "StubEffectsExecutor.execute increments http_call_count" {
    const allocator = std.testing.allocator;

    var stub = stub_mod.StubEffectsExecutor.init(allocator);
    defer stub.deinit();

    const spec = makeHttpSpec();

    const r1 = try stub.execute(allocator, spec, 0);
    defer if (r1.response_body) |b| allocator.free(b);
    try std.testing.expectEqual(@as(u32, 1), stub.http_call_count);

    const r2 = try stub.execute(allocator, spec, 1);
    defer if (r2.response_body) |b| allocator.free(b);
    try std.testing.expectEqual(@as(u32, 2), stub.http_call_count);
}

test "StubEffectsExecutor.execute increments email_count" {
    const allocator = std.testing.allocator;

    var stub = stub_mod.StubEffectsExecutor.init(allocator);
    defer stub.deinit();

    const spec = effects_mod.EffectSpec{
        .effect_event_id = "email-event-id",
        .instance_id = "inst-002",
        .node_id = "node-email",
        .token_id = "tok-002",
        .correlation_key = "node-email:tok-002",
        .kind = .email,
        .spec_json = "{}",
    };

    const r = try stub.execute(allocator, spec, 0);
    defer if (r.response_body) |b| allocator.free(b);
    try std.testing.expectEqual(@as(u32, 1), stub.email_count);
    try std.testing.expectEqual(@as(u32, 0), stub.http_call_count);
}

test "StubEffectsExecutor.execute records spec_json under correlation_key" {
    const allocator = std.testing.allocator;

    var stub = stub_mod.StubEffectsExecutor.init(allocator);
    defer stub.deinit();

    const corr = "node-svc-01:tok-001";
    const spec = effects_mod.EffectSpec{
        .effect_event_id = "evt-001",
        .instance_id = "inst-001",
        .node_id = "node-svc-01",
        .token_id = "tok-001",
        .correlation_key = corr,
        .kind = .http_call,
        .spec_json = "{\"url\":\"https://example.com\"}",
    };

    const r = try stub.execute(allocator, spec, 0);
    defer if (r.response_body) |b| allocator.free(b);

    const recorded = stub.getRecorded(corr) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("{\"url\":\"https://example.com\"}", recorded);
}

test "StubEffectsExecutor.reset zeroes counters and clears recorded map" {
    const allocator = std.testing.allocator;

    var stub = stub_mod.StubEffectsExecutor.init(allocator);
    defer stub.deinit();

    const spec = makeHttpSpec();
    const r = try stub.execute(allocator, spec, 0);
    defer if (r.response_body) |b| allocator.free(b);

    try std.testing.expectEqual(@as(u32, 1), stub.http_call_count);
    try std.testing.expect(stub.recorded.count() > 0);

    stub.reset();

    try std.testing.expectEqual(@as(u32, 0), stub.http_call_count);
    try std.testing.expectEqual(@as(u32, 0), stub.email_count);
    try std.testing.expectEqual(@as(usize, 0), stub.recorded.count());
}

test "StubEffectsExecutor returns default 200 / {} response" {
    const allocator = std.testing.allocator;

    var stub = stub_mod.StubEffectsExecutor.init(allocator);
    defer stub.deinit();

    const spec = makeHttpSpec();
    const r = try stub.execute(allocator, spec, 0);
    defer if (r.response_body) |b| allocator.free(b);

    try std.testing.expectEqual(@as(u16, 200), r.status_code);
    if (r.response_body) |body| {
        try std.testing.expectEqualStrings("{}", body);
    }
}

// ---------------------------------------------------------------------------
// 4. EffectSpec round-trip serialisation
// ---------------------------------------------------------------------------

test "EffectKind.toWire and fromWire round-trip" {
    try std.testing.expectEqualStrings("http_call", effects_mod.EffectKind.http_call.toWire());
    try std.testing.expectEqualStrings("email", effects_mod.EffectKind.email.toWire());

    try std.testing.expectEqual(effects_mod.EffectKind.http_call, effects_mod.EffectKind.fromWire("http_call").?);
    try std.testing.expectEqual(effects_mod.EffectKind.email, effects_mod.EffectKind.fromWire("email").?);
    try std.testing.expect(effects_mod.EffectKind.fromWire("unknown") == null);
}

test "buildCorrelationKey produces correct format" {
    const allocator = std.testing.allocator;

    const key = try effects_mod.buildCorrelationKey(allocator, "node-svc-01", "tok-abc123");
    defer allocator.free(key);

    try std.testing.expectEqualStrings("node-svc-01:tok-abc123", key);
}

// ---------------------------------------------------------------------------
// 5. Failure classification
// ---------------------------------------------------------------------------

test "classifyHttpOutcome: 2xx → success" {
    try std.testing.expectEqual(effects_mod.HttpOutcome.success, effects_mod.classifyHttpOutcome(200));
    try std.testing.expectEqual(effects_mod.HttpOutcome.success, effects_mod.classifyHttpOutcome(201));
    try std.testing.expectEqual(effects_mod.HttpOutcome.success, effects_mod.classifyHttpOutcome(204));
}

test "classifyHttpOutcome: 3xx → permanent" {
    try std.testing.expectEqual(effects_mod.HttpOutcome.permanent, effects_mod.classifyHttpOutcome(301));
    try std.testing.expectEqual(effects_mod.HttpOutcome.permanent, effects_mod.classifyHttpOutcome(302));
}

test "classifyHttpOutcome: 4xx → permanent (except 429)" {
    try std.testing.expectEqual(effects_mod.HttpOutcome.permanent, effects_mod.classifyHttpOutcome(400));
    try std.testing.expectEqual(effects_mod.HttpOutcome.permanent, effects_mod.classifyHttpOutcome(404));
    try std.testing.expectEqual(effects_mod.HttpOutcome.permanent, effects_mod.classifyHttpOutcome(422));
}

test "classifyHttpOutcome: 429 → retry" {
    try std.testing.expectEqual(effects_mod.HttpOutcome.retry, effects_mod.classifyHttpOutcome(429));
}

test "classifyHttpOutcome: 5xx → retry" {
    try std.testing.expectEqual(effects_mod.HttpOutcome.retry, effects_mod.classifyHttpOutcome(500));
    try std.testing.expectEqual(effects_mod.HttpOutcome.retry, effects_mod.classifyHttpOutcome(503));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn makeHttpSpec() effects_mod.EffectSpec {
    return effects_mod.EffectSpec{
        .effect_event_id = "evt-001",
        .instance_id = "inst-001",
        .node_id = "node-svc-01",
        .token_id = "tok-001",
        .correlation_key = "node-svc-01:tok-001",
        .kind = .http_call,
        .spec_json = "{}",
    };
}
