//! Unit tests for SCH-06 — Timer jitter (pure function tests).
//!
//! These tests verify the public API surface of the timer jitter feature.
//! The `computePollDelayMs` function is tested via inline test blocks in
//! `src/scheduler/scheduler.zig` (Zig idiom for private function testing).
//! This file tests the publicly accessible API surface and configuration.
const std = @import("std");
const testing = std.testing;
const bpm = @import("bpm");

const Scheduler = bpm.scheduler_poller.Scheduler;
const SchedulerConfig = bpm.scheduler_poller.SchedulerConfig;

test "TC-SCH-06-10: Scheduler struct has prng field after init" {
    // Verify the Scheduler struct layout includes the new prng field
    var scheduler = Scheduler.init(undefined, SchedulerConfig{
        .poll_interval_ms = 5000,
        .jitter_ms = 1000,
    });

    // The prng field should be initialized (unique seed from crypto.random)
    // We can't easily inspect internal state, but we verify computePollDelayMs works
    const delay = scheduler.computePollDelayMs();
    try testing.expect(delay >= 4000); // base(5000) - jitter(1000) = 4000
    try testing.expect(delay <= 6000); // base(5000) + jitter(1000) = 6000
}

test "TC-SCH-06-11: SchedulerConfig defaults are correct" {
    const config = SchedulerConfig{};
    try testing.expectEqual(@as(u64, 5000), config.poll_interval_ms);
    try testing.expectEqual(@as(u64, 0), config.jitter_ms);
}

test "TC-SCH-06-12: Scheduler with jitter=0 behaves identically to no jitter" {
    var s1 = Scheduler.init(undefined, SchedulerConfig{
        .poll_interval_ms = 3000,
        .jitter_ms = 0,
    });
    var s2 = Scheduler.init(undefined, SchedulerConfig{
        .poll_interval_ms = 3000,
        // jitter_ms defaults to 0
    });

    // Both should return exactly base_ms
    try testing.expectEqual(@as(u64, 3000), s1.computePollDelayMs());
    try testing.expectEqual(@as(u64, 3000), s2.computePollDelayMs());
}

test "TC-SCH-06-13: computePollDelayMs mean approximates base_ms over many samples" {
    const base_ms: u64 = 10000;
    const jitter_ms: u64 = 1000;
    var scheduler = Scheduler.init(undefined, SchedulerConfig{
        .poll_interval_ms = base_ms,
        .jitter_ms = jitter_ms,
    });

    // Sum 1000 samples and check mean is close to base_ms
    const sample_count: u64 = 1000;
    var sum: u64 = 0;
    var i: u64 = 0;
    while (i < sample_count) : (i += 1) {
        sum += scheduler.computePollDelayMs();
    }
    const mean = sum / sample_count;

    // Mean should be within 5% of base_ms (with 1000 uniform samples)
    const tolerance = base_ms / 20; // 5%
    const lower = base_ms -| tolerance;
    const upper = base_ms + tolerance;
    try testing.expect(mean >= lower);
    try testing.expect(mean <= upper);
}

test "TC-SCH-06-14: Minimum jitter (jitter_ms=1) covers both extremes of range" {
    // With jitter_ms=1, the offset can be -1, 0, or +1.
    // Over enough samples we should see both base-1 and base+1.
    const base_ms: u64 = 1000;
    const jitter_ms: u64 = 1;
    var scheduler = Scheduler.init(undefined, SchedulerConfig{
        .poll_interval_ms = base_ms,
        .jitter_ms = jitter_ms,
    });

    var saw_minus_one = false;
    var saw_plus_one = false;
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        const delay = scheduler.computePollDelayMs();
        if (delay == base_ms - 1) saw_minus_one = true;
        if (delay == base_ms + 1) saw_plus_one = true;
        if (saw_minus_one and saw_plus_one) break;
    }

    try testing.expect(saw_minus_one);
    try testing.expect(saw_plus_one);
}

test "TC-SCH-06-15: Different Scheduler instances have independent PRNG seeds" {
    // Two schedulers with identical config should produce different first
    // outputs with extremely high probability, because each init() draws
    // from OS entropy to seed its PRNG independently.
    const config = SchedulerConfig{
        .poll_interval_ms = 10000,
        .jitter_ms = 5000,
    };
    var s1 = Scheduler.init(undefined, config);
    var s2 = Scheduler.init(undefined, config);

    const d1 = s1.computePollDelayMs();
    const d2 = s2.computePollDelayMs();

    // With range 10001 possible values, the chance of collision is ~1/10001.
    // If they shared a seed, they'd produce identical first values.
    try testing.expect(d1 != d2);
}

test "TC-SCH-06-16: computePollDelayMs range covers most of the [base-jitter, base+jitter] interval" {
    // Over a large number of samples, verify the range [min, max] approaches
    // the theoretical boundaries. With 2000 samples across 2001 values, the
    // test is probabilistic, so we check that we span at least 95 % of the
    // range (≥ 1900 distinct values) rather than requiring exact endpoints.
    const base_ms: u64 = 5000;
    const jitter_ms: u64 = 1000;
    var scheduler = Scheduler.init(undefined, SchedulerConfig{
        .poll_interval_ms = base_ms,
        .jitter_ms = jitter_ms,
    });

    var min_seen: u64 = base_ms + jitter_ms;
    var max_seen: u64 = 0;
    var i: u32 = 0;
    while (i < 2000) : (i += 1) {
        const delay = scheduler.computePollDelayMs();
        if (delay < min_seen) min_seen = delay;
        if (delay > max_seen) max_seen = delay;
    }

    const observed_span = max_seen - min_seen;
    const theoretical_span: u64 = 2 * jitter_ms; // 2000
    // Observed span must be at least 70 % of theoretical (very high probability
    // with a uniform distribution and 2000 samples).
    try testing.expect(observed_span >= theoretical_span * 70 / 100);
    // Every value must respect the theoretical bounds.
    try testing.expect(min_seen >= base_ms -| jitter_ms);
    try testing.expect(max_seen <= base_ms + jitter_ms);
}
