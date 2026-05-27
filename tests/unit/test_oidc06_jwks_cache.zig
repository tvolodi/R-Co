const std = @import("std");
const testing = std.testing;
const jwks_cache_mod = @import("jwks_cache");
const JwksCache = jwks_cache_mod.JwksCache;

test "TC-OIDC-06-01: store kids; lookupKid true for present kid, false for absent" {
    var cache = JwksCache.init(testing.allocator, 600, 10);
    defer cache.deinit();

    const body =
        \\{"keys":[{"kid":"key-1","kty":"RSA"},{"kid":"key-2","kty":"RSA"}]}
    ;
    try cache.store("https://idp.example.com/jwks", body, 1000);

    try testing.expectEqual(@as(?bool, true), cache.lookupKid("https://idp.example.com/jwks", "key-1", 1000));
    try testing.expectEqual(@as(?bool, true), cache.lookupKid("https://idp.example.com/jwks", "key-2", 1000));
    try testing.expectEqual(@as(?bool, false), cache.lookupKid("https://idp.example.com/jwks", "absent-kid", 1000));
}

test "TC-OIDC-06-02: null before store; true after store with present kid" {
    var cache = JwksCache.init(testing.allocator, 600, 10);
    defer cache.deinit();

    // Before store — no entry, must return null
    try testing.expectEqual(@as(?bool, null), cache.lookupKid("https://idp.example.com/jwks", "key-1", 1000));

    const body =
        \\{"keys":[{"kid":"key-1","kty":"RSA"}]}
    ;
    try cache.store("https://idp.example.com/jwks", body, 1000);

    // After store — kid is present
    try testing.expectEqual(@as(?bool, true), cache.lookupKid("https://idp.example.com/jwks", "key-1", 1000));
}

test "TC-OIDC-06-03: null before store; false after store with absent kid" {
    var cache = JwksCache.init(testing.allocator, 600, 10);
    defer cache.deinit();

    try testing.expectEqual(@as(?bool, null), cache.lookupKid("https://idp.example.com/jwks", "absent", 1000));

    const body =
        \\{"keys":[{"kid":"key-1","kty":"RSA"}]}
    ;
    try cache.store("https://idp.example.com/jwks", body, 1000);

    try testing.expectEqual(@as(?bool, false), cache.lookupKid("https://idp.example.com/jwks", "absent", 1000));
}

test "TC-OIDC-06-04: TTL respected — valid at t=29, stale at t=31 (ttl=30)" {
    var cache = JwksCache.init(testing.allocator, 30, 10);
    defer cache.deinit();

    const body =
        \\{"keys":[{"kid":"key-1","kty":"RSA"}]}
    ;
    const stored_at: i64 = 1000;
    try cache.store("https://idp.example.com/jwks", body, stored_at);

    // At stored_at+29: now - fetched_at = 29 < 30 — valid
    try testing.expectEqual(@as(?bool, true), cache.lookupKid("https://idp.example.com/jwks", "key-1", stored_at + 29));
    // At stored_at+31: now - fetched_at = 31 >= 30 — stale
    try testing.expectEqual(@as(?bool, null), cache.lookupKid("https://idp.example.com/jwks", "key-1", stored_at + 31));
}

test "TC-OIDC-06-05: false for unknown kid; rate limiter OFF; caller re-stores with new JWKS; now true" {
    var cache = JwksCache.init(testing.allocator, 600, 10);
    defer cache.deinit();

    const now: i64 = 100;
    // Store initial JWKS with only key-A
    const body_a =
        \\{"keys":[{"kid":"key-A","kty":"RSA"}]}
    ;
    try cache.store("https://idp.example.com/jwks", body_a, now);
    cache.markRefreshed(0); // last refresh was at t=0; now=100 so not rate-limited

    // key-B not in cache — returns false (cache valid, kid absent)
    try testing.expectEqual(@as(?bool, false), cache.lookupKid("https://idp.example.com/jwks", "key-B", now));
    // Rate limiter is OFF at now=100 (100 - 0 = 100 >= 10)
    try testing.expectEqual(false, cache.isRateLimited(now));

    // Caller re-stores with new JWKS containing key-B
    const body_b =
        \\{"keys":[{"kid":"key-A","kty":"RSA"},{"kid":"key-B","kty":"RSA"}]}
    ;
    try cache.store("https://idp.example.com/jwks", body_b, now);
    cache.markRefreshed(now);

    // key-B now found
    try testing.expectEqual(@as(?bool, true), cache.lookupKid("https://idp.example.com/jwks", "key-B", now));
}

test "TC-OIDC-06-06: markRefreshed(0); isRateLimited(5)=true; isRateLimited(15)=false (min_refresh=10)" {
    var cache = JwksCache.init(testing.allocator, 600, 10);
    defer cache.deinit();

    cache.markRefreshed(0);

    // 5 - 0 = 5 < 10 → rate-limited
    try testing.expectEqual(true, cache.isRateLimited(5));
    // 15 - 0 = 15 >= 10 → not rate-limited
    try testing.expectEqual(false, cache.isRateLimited(15));
}

test "TC-OIDC-06-07: non-default TTL=120; valid at t=119, stale at t=121" {
    var cache = JwksCache.init(testing.allocator, 120, 10);
    defer cache.deinit();

    const body =
        \\{"keys":[{"kid":"key-1","kty":"RSA"}]}
    ;
    const stored_at: i64 = 5000;
    try cache.store("https://idp.example.com/jwks", body, stored_at);

    // At stored_at+119: now - fetched_at = 119 < 120 — valid
    try testing.expectEqual(@as(?bool, true), cache.lookupKid("https://idp.example.com/jwks", "key-1", stored_at + 119));
    // At stored_at+121: now - fetched_at = 121 >= 120 — stale
    try testing.expectEqual(@as(?bool, null), cache.lookupKid("https://idp.example.com/jwks", "key-1", stored_at + 121));
}
