const std = @import("std");
const bench = @import("oidc_bench");

const FakeVerifier = struct {
    fn verify(_: *anyopaque, _: []const u8) !void {}
    fn clear(_: *anyopaque) void {}
    fn prime(_: *anyopaque) !void {}
};

test "OIDC-27 benchmark computes percentile stats and target pass" {
    var fake_ctx: u8 = 0;
    var verifier = bench.OidcVerifier{
        .ctx = &fake_ctx,
        .verifyFn = FakeVerifier.verify,
        .primeJwksCacheFn = FakeVerifier.prime,
        .clearJwksCacheForBenchmarkFn = FakeVerifier.clear,
    };

    const stats = try bench.runVerificationBenchmark(std.testing.allocator, &verifier, .{
        .realm_id = "bpm-default",
        .scenario = .warm_cache,
        .sample_count = 8,
        .concurrency = 1,
        .token_source = "a.b.c",
    });

    try std.testing.expectEqual(bench.VerificationBenchmarkScenario.warm_cache, stats.scenario);
    try std.testing.expect(stats.sample_count == 8);
    try std.testing.expect(stats.target_p95_us == 2_000);
}
