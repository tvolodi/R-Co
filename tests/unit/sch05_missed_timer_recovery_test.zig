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

test "TC-SCH-05-13: SchedulerConfig.max_timer_fire_retries default is 3 (ISS-303)" {
    // ISS-303: Verify the default retry limit used before a timer is moved to FAILED.
    const config = SchedulerConfig{};
    try testing.expectEqual(@as(u32, 3), config.max_timer_fire_retries);
}

test "TC-SCH-05-13b: SchedulerConfig.max_timer_fire_retries can be overridden (ISS-303)" {
    // Callers can configure a custom retry limit.
    const config = SchedulerConfig{ .max_timer_fire_retries = 5 };
    try testing.expectEqual(@as(u32, 5), config.max_timer_fire_retries);
}

test "TC-SCH-05-13c: SchedulerConfig zero max_timer_fire_retries is allowed (ISS-303)" {
    // A zero value means every fire failure immediately routes to FAILED + DLQ.
    const config = SchedulerConfig{ .max_timer_fire_retries = 0 };
    try testing.expectEqual(@as(u32, 0), config.max_timer_fire_retries);
}

test "TC-SCH-05-14: PollSummary default values are zero" {
    const summary = PollSummary{};
    try testing.expectEqual(@as(u32, 0), summary.fired);
    try testing.expectEqual(@as(u32, 0), summary.skipped_locked);
}
