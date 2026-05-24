//! Unit tests for SCH-05 — Missed timer recovery (pure function tests).
//!
//! These tests cover the pure logic of the missed-timer recovery feature.
//! The `isFiredLate` and `buildTimerFiredPayload` functions are tested via
//! inline test blocks in `src/scheduler/scheduler.zig` (Zig idiom for private
//! function testing). This file tests the publicly accessible API surface.
const std = @import("std");
const testing = std.testing;
const bpm = @import("bpm");

const Scheduler = bpm.scheduler_poller.Scheduler;
const SchedulerConfig = bpm.scheduler_poller.SchedulerConfig;
const PollSummary = bpm.scheduler_poller.PollSummary;

test "TC-SCH-05-05a: is_startup_sweep is true on fresh Scheduler init" {
    // This test verifies the initial state without requiring a DB connection.
    // The actual transition after pollDueTimers requires integration tests.
    const scheduler = Scheduler.init(undefined, SchedulerConfig{ .poll_interval_ms = 5000 });
    try testing.expect(scheduler.is_startup_sweep);
}

test "TC-SCH-05-05b: SchedulerConfig default poll_interval_ms is 5000" {
    const config = SchedulerConfig{};
    try testing.expectEqual(@as(u64, 5000), config.poll_interval_ms);
}

test "TC-SCH-05-13: advisoryLockKey produces deterministic 64-bit key from UUID" {
    // advisoryLockKey is the sole public pure function in scheduler.zig
    const uuid: bpm.scheduler_poller.Uuid = .{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
    };
    const key = bpm.scheduler_poller.advisoryLockKey(uuid);
    // Key derived from first 8 bytes of UUID (deterministic).
    // Just verify it's non-zero for a non-zero UUID.
    try testing.expect(key != 0);
}

test "TC-SCH-05-13b: advisoryLockKey is deterministic (same UUID → same key)" {
    const uuid: bpm.scheduler_poller.Uuid = .{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    };
    const k1 = bpm.scheduler_poller.advisoryLockKey(uuid);
    const k2 = bpm.scheduler_poller.advisoryLockKey(uuid);
    try testing.expectEqual(k1, k2);
}

test "TC-SCH-05-13c: advisoryLockKey for zero UUID produces zero key" {
    const uuid: bpm.scheduler_poller.Uuid = .{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    const key = bpm.scheduler_poller.advisoryLockKey(uuid);
    try testing.expectEqual(@as(i64, 0), key);
}

test "TC-SCH-05-14: PollSummary default values are zero" {
    const summary = PollSummary{};
    try testing.expectEqual(@as(u32, 0), summary.fired);
    try testing.expectEqual(@as(u32, 0), summary.skipped_locked);
}
