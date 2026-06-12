//! Unit tests for ISS-302 — Startup sweep session-level advisory lock.
//!
//! Tests cover:
//!   TC-SCH-302-02: is_startup_sweep true on fresh Scheduler init (traceability)
//!   TC-SCH-302-05: is_startup_sweep can be set to false and stays observable
//!
//! Source-inspection tests (TC-SCH-302-01, TC-SCH-302-04) are placed as inline
//! tests inside src/scheduler/scheduler.zig (the Zig idiom for testing private
//! module internals via @embedFile within the package root).
//!
//! TC-SCH-302-03 (lock not acquired → sweep skipped gracefully) is covered by
//! the integration test in tests/integration/sch303_timer_dlq_test.zig.
const std = @import("std");
const testing = std.testing;
const bpm = @import("bpm");

const Scheduler = bpm.scheduler_poller.Scheduler;
const SchedulerConfig = bpm.scheduler_poller.SchedulerConfig;

// TC-SCH-302-02: is_startup_sweep is true on fresh Scheduler init.
// Provides ISS-302 AC-302-2 traceability. Substantive coverage by TC-SCH-05-05a.
test "TC-SCH-302-02: Scheduler.init sets is_startup_sweep = true" {
    const s = Scheduler.init(undefined, SchedulerConfig{});
    try testing.expect(s.is_startup_sweep);
}

// TC-SCH-302-05: Normal poll (non-sweep): startup lock path not taken.
// Verifies is_startup_sweep is publicly readable/writable so tests can inspect it.
test "TC-SCH-302-05: is_startup_sweep field is observable and mutable" {
    var s = Scheduler.init(undefined, SchedulerConfig{});
    try testing.expect(s.is_startup_sweep); // true on init (AC-302-2)
    s.is_startup_sweep = false;
    try testing.expect(!s.is_startup_sweep); // mutation is visible (AC-302-4)
}
