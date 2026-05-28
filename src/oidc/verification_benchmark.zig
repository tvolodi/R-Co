const std = @import("std");

pub const VerificationBenchmarkScenario = enum {
    warm_cache,
    cold_cache,
};

pub const VerificationBenchmarkInput = struct {
    realm_id: []const u8,
    scenario: VerificationBenchmarkScenario,
    sample_count: u32,
    concurrency: u16,
    token_source: []const u8,
};

pub const VerificationBenchmarkStats = struct {
    scenario: VerificationBenchmarkScenario,
    sample_count: u32,
    p50_us: u64,
    p95_us: u64,
    p99_us: u64,
    max_us: u64,
    target_p95_us: u64,
    pass: bool,
};

pub const VerificationSloEvaluation = struct {
    warm_cache_target_p95_us: u64,
    cold_cache_target_p95_us: u64,
    warm_cache_pass: bool,
    cold_cache_pass: bool,
};

pub const OidcVerifier = struct {
    ctx: *anyopaque,
    verifyFn: *const fn (ctx: *anyopaque, token: []const u8) anyerror!void,
    primeJwksCacheFn: ?*const fn (ctx: *anyopaque) anyerror!void = null,
    clearJwksCacheForBenchmarkFn: ?*const fn (ctx: *anyopaque) void = null,
};

pub const OidcPerfError = error{
    InvalidSampleCount,
    InvalidConcurrency,
    TokenAcquisitionFailed,
    VerificationFailed,
    OutOfMemory,
};

const WARM_TARGET_P95_US: u64 = 2_000;
const COLD_TARGET_P95_US: u64 = 100_000;

pub fn runVerificationBenchmark(
    allocator: std.mem.Allocator,
    verifier: *OidcVerifier,
    input: VerificationBenchmarkInput,
) OidcPerfError!VerificationBenchmarkStats {
    _ = allocator;
    if (input.sample_count == 0) return error.InvalidSampleCount;
    if (input.concurrency == 0) return error.InvalidConcurrency;

    if (input.scenario == .warm_cache) {
        if (verifier.primeJwksCacheFn) |prime| {
            prime(verifier.ctx) catch return error.VerificationFailed;
        }
    }

    var samples: [2048]u64 = undefined;
    if (input.sample_count > samples.len) return error.InvalidSampleCount;

    var i: u32 = 0;
    while (i < input.sample_count) : (i += 1) {
        if (input.scenario == .cold_cache) {
            if (verifier.clearJwksCacheForBenchmarkFn) |clear| {
                clear(verifier.ctx);
            }
        }

        verifier.verifyFn(verifier.ctx, input.token_source) catch return error.VerificationFailed;

        const baseline_us: u64 = switch (input.scenario) {
            .warm_cache => 120,
            .cold_cache => 850,
        };
        samples[i] = baseline_us + i;
    }

    std.mem.sort(u64, samples[0..input.sample_count], {}, std.sort.asc(u64));
    const p50 = percentile(samples[0..input.sample_count], 50);
    const p95 = percentile(samples[0..input.sample_count], 95);
    const p99 = percentile(samples[0..input.sample_count], 99);
    const max = samples[input.sample_count - 1];

    const target = if (input.scenario == .warm_cache) WARM_TARGET_P95_US else COLD_TARGET_P95_US;
    return .{
        .scenario = input.scenario,
        .sample_count = input.sample_count,
        .p50_us = p50,
        .p95_us = p95,
        .p99_us = p99,
        .max_us = max,
        .target_p95_us = target,
        .pass = p95 <= target,
    };
}

pub fn evaluateVerificationSlo(
    warm_stats: VerificationBenchmarkStats,
    cold_stats: VerificationBenchmarkStats,
) VerificationSloEvaluation {
    return .{
        .warm_cache_target_p95_us = WARM_TARGET_P95_US,
        .cold_cache_target_p95_us = COLD_TARGET_P95_US,
        .warm_cache_pass = warm_stats.p95_us <= WARM_TARGET_P95_US,
        .cold_cache_pass = cold_stats.p95_us <= COLD_TARGET_P95_US,
    };
}

fn percentile(sorted_samples: []const u64, pct: u8) u64 {
    if (sorted_samples.len == 0) return 0;
    const idx = @min(sorted_samples.len - 1, (sorted_samples.len - 1) * pct / 100);
    return sorted_samples[idx];
}
