//! OIDC token validation cache and JTI denylist — ISS-402.
//!
//! Provides a two-layer in-memory cache for OIDC token validation results:
//! 1. TokenValidationCache — caches validation outcomes keyed by (realm, jti).
//! 2. JtiDenylist — tracks revoked JTIs per realm.
//!
//! All public wrapper functions acquire/release the module-level mutex internally.
//! Callers do not need to manage synchronisation.

const std = @import("std");

// ── Constants ─────────────────────────────────────────────────────────────────

/// Maximum cache entry lifetime in seconds (5 minutes).
pub const MAX_CACHE_TTL_SECONDS: i64 = 300;

/// TTL for caching a validation failure (60 seconds).
const FAILURE_CACHE_TTL_SECONDS: i64 = 60;

// ── Key types ─────────────────────────────────────────────────────────────────

pub const TokenCacheKey = struct {
    realm: []const u8,
    jti: []const u8,
};

pub const TokenCacheKeyContext = struct {
    pub fn hash(_: TokenCacheKeyContext, key: TokenCacheKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.realm);
        h.update(":");
        h.update(key.jti);
        return h.final();
    }

    pub fn eql(_: TokenCacheKeyContext, a: TokenCacheKey, b: TokenCacheKey) bool {
        return std.mem.eql(u8, a.realm, b.realm) and std.mem.eql(u8, a.jti, b.jti);
    }
};

pub const CachedValidation = struct {
    valid: bool,
    /// Serialised VerifiedPrincipal fields as JSON (only meaningful if valid).
    principal_json: []const u8,
    /// Unix timestamp when this entry expires.
    expires_at: i64,

    pub fn deinit(self: *CachedValidation, allocator: std.mem.Allocator) void {
        allocator.free(self.principal_json);
    }
};

// ── Denylist entry ────────────────────────────────────────────────────────────

const DenylistEntry = struct {
    realm: []const u8,
    jti: []const u8,
    expires_at: i64,
};

// ── TokenValidationCache ──────────────────────────────────────────────────────

pub const TokenValidationCache = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    map: std.HashMap(TokenCacheKey, CachedValidation, TokenCacheKeyContext, std.hash_map.default_max_load_percentage),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .map = std.HashMap(TokenCacheKey, CachedValidation, TokenCacheKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.realm);
            self.allocator.free(entry.key_ptr.jti);
            self.allocator.free(entry.value_ptr.principal_json);
        }
        self.map.deinit();
    }

    /// Look up a cached validation result. Returns null on miss or expiry.
    pub fn get(self: *Self, realm: []const u8, jti: []const u8, now: i64) ?CachedValidation {
        self.evictExpired(now);

        const key = TokenCacheKey{ .realm = realm, .jti = jti };
        const entry = self.map.get(key) orelse return null;

        if (now >= entry.expires_at) {
            return null;
        }

        // Return a deep copy — caller owns it.
        const principal_copy = self.allocator.dupe(u8, entry.principal_json) catch return null;
        return CachedValidation{
            .valid = entry.valid,
            .principal_json = principal_copy,
            .expires_at = entry.expires_at,
        };
    }

    /// Store a validation result. TTL = min(exp - now, MAX_CACHE_TTL_SECONDS), clamped >= 1.
    /// For failures (valid=false), TTL is capped at FAILURE_CACHE_TTL_SECONDS.
    pub fn put(
        self: *Self,
        realm: []const u8,
        jti: []const u8,
        valid: bool,
        principal_json: []const u8,
        exp: i64,
        now: i64,
    ) error{OutOfMemory}!void {
        self.evictExpired(now);

        const max_ttl: i64 = if (valid) MAX_CACHE_TTL_SECONDS else FAILURE_CACHE_TTL_SECONDS;
        const ttl = @max(@min(exp - now, max_ttl), 1);
        const expires_at = now + ttl;

        const gop = try self.map.getOrPut(.{ .realm = realm, .jti = jti });
        if (gop.found_existing) {
            // Replace existing entry: free old owned data, store new.
            self.allocator.free(gop.key_ptr.realm);
            self.allocator.free(gop.key_ptr.jti);
            self.allocator.free(gop.value_ptr.principal_json);
        }

        gop.key_ptr.realm = try self.allocator.dupe(u8, realm);
        gop.key_ptr.jti = try self.allocator.dupe(u8, jti);
        gop.value_ptr.principal_json = try self.allocator.dupe(u8, principal_json);
        gop.value_ptr.valid = valid;
        gop.value_ptr.expires_at = expires_at;
    }

    /// Remove all entries with now >= expires_at.
    pub fn evictExpired(self: *Self, now: i64) void {
        var to_remove = std.ArrayList(TokenCacheKey).init(self.allocator);
        defer to_remove.deinit();

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (now >= entry.value_ptr.expires_at) {
                to_remove.append(.{
                    .realm = entry.key_ptr.realm,
                    .jti = entry.key_ptr.jti,
                }) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.map.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key.realm);
                self.allocator.free(kv.key.jti);
                self.allocator.free(kv.value.principal_json);
            }
        }
    }

    /// Remove all cache entries for a given realm. Used during realm logout.
    pub fn evictRealm(self: *Self, realm: []const u8) void {
        var to_remove = std.ArrayList(TokenCacheKey).init(self.allocator);
        defer to_remove.deinit();

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.realm, realm)) {
                to_remove.append(.{
                    .realm = entry.key_ptr.realm,
                    .jti = entry.key_ptr.jti,
                }) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.map.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key.realm);
                self.allocator.free(kv.key.jti);
                self.allocator.free(kv.value.principal_json);
            }
        }
    }

    /// Collect all active cache keys for a given realm.
    fn collectRealmEntries(self: *Self, realm: []const u8, list: *std.ArrayList(TokenCacheKey)) !void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.realm, realm)) {
                try list.append(.{
                    .realm = entry.key_ptr.realm,
                    .jti = entry.key_ptr.jti,
                });
            }
        }
    }

    /// Iterate all entries in the cache (for bulk operations).
    fn iterate(self: *Self) MapIterator {
        return .{ .inner = self.map.iterator() };
    }

    const MapIterator = struct {
        inner: std.HashMap(TokenCacheKey, CachedValidation, TokenCacheKeyContext, std.hash_map.default_max_load_percentage).Iterator,

        pub fn next(self: *MapIterator) ?*const CacheEntry {
            if (self.inner.next()) |kv| {
                return &CacheEntry{
                    .realm = kv.key_ptr.realm,
                    .jti = kv.key_ptr.jti,
                    .valid = kv.value_ptr.valid,
                    .expires_at = kv.value_ptr.expires_at,
                };
            }
            return null;
        }
    };

    const CacheEntry = struct {
        realm: []const u8,
        jti: []const u8,
        valid: bool,
        expires_at: i64,
    };
};

// ── JtiDenylist ───────────────────────────────────────────────────────────────

pub const JtiDenylist = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    entries: std.ArrayList(DenylistEntry),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(DenylistEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |*e| {
            self.allocator.free(e.realm);
            self.allocator.free(e.jti);
        }
        self.entries.deinit();
    }

    /// Add a (realm, jti) to the denylist with an expiry time.
    pub fn add(
        self: *Self,
        alloc: std.mem.Allocator,
        realm: []const u8,
        jti: []const u8,
        expires_at: i64,
    ) error{OutOfMemory}!void {
        // Check if already present; skip duplicate.
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.realm, realm) and std.mem.eql(u8, e.jti, jti)) {
                return;
            }
        }
        try self.entries.append(.{
            .realm = try alloc.dupe(u8, realm),
            .jti = try alloc.dupe(u8, jti),
            .expires_at = expires_at,
        });
    }

    /// Check if a (realm, jti) is actively revoked.
    pub fn isRevoked(self: *const Self, realm: []const u8, jti: []const u8, now: i64) bool {
        for (self.entries.items) |e| {
            if (now >= e.expires_at) continue;
            if (std.mem.eql(u8, e.realm, realm) and std.mem.eql(u8, e.jti, jti)) {
                return true;
            }
        }
        return false;
    }

    /// Bulk-revoke all active tokens for a realm. Reads from the cache to find
    /// active JTIs, then adds them to the denylist.
    pub fn revokeRealm(
        self: *Self,
        alloc: std.mem.Allocator,
        cache: *TokenValidationCache,
        realm: []const u8,
        now: i64,
    ) error{OutOfMemory}!void {
        cache.evictExpired(now);
        var it = cache.iterate();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.realm, realm) and entry.valid) {
                try self.add(alloc, realm, entry.jti, entry.expires_at);
            }
        }
        // Invalidate cache entries for the realm.
        cache.evictRealm(realm);
    }

    /// Remove expired entries from the denylist.
    pub fn evictExpired(self: *Self, now: i64) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (now >= self.entries.items[i].expires_at) {
                self.allocator.free(self.entries.items[i].realm);
                self.allocator.free(self.entries.items[i].jti);
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

// ── Module-level state ────────────────────────────────────────────────────────

var oidc_cache: ?TokenValidationCache = null;
var oidc_denylist: ?JtiDenylist = null;
var cache_mutex: std.Thread.Mutex = .{};
var cache_initialized: bool = false;

// ── Public wrapper functions (thread-safe) ────────────────────────────────────

/// Initialise the OIDC cache and denylist. Must be called once at startup.
pub fn initCache(allocator: std.mem.Allocator) error{OutOfMemory}!void {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (cache_initialized) return;
    oidc_cache = TokenValidationCache.init(allocator);
    oidc_denylist = JtiDenylist.init(allocator);
    cache_initialized = true;
}

/// Free all cache and denylist state.
pub fn deinitCache() void {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (!cache_initialized) return;
    if (oidc_cache) |*c| c.deinit();
    if (oidc_denylist) |*d| d.deinit();
    oidc_cache = null;
    oidc_denylist = null;
    cache_initialized = false;
}

/// Check if a (realm, jti) has a cached validation result.
/// Returns a deep copy — caller owns the returned CachedValidation.
pub fn checkCache(realm: []const u8, jti: []const u8, now: i64) ?CachedValidation {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (!cache_initialized) return null;
    return oidc_cache.?.get(realm, jti, now);
}

/// Store a validation result in the cache.
pub fn putCache(
    realm: []const u8,
    jti: []const u8,
    valid: bool,
    principal_json: []const u8,
    exp: i64,
    now: i64,
) error{OutOfMemory}!void {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (!cache_initialized) return;
    try oidc_cache.?.put(realm, jti, valid, principal_json, exp, now);
}

/// Check if a (realm, jti) is on the revocation denylist.
pub fn isRevoked(realm: []const u8, jti: []const u8, now: i64) bool {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (!cache_initialized) return false;
    return oidc_denylist.?.isRevoked(realm, jti, now);
}

/// Add a (realm, jti) to the revocation denylist.
pub fn revokeToken(realm: []const u8, jti: []const u8, expires_at: i64) error{OutOfMemory}!void {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (!cache_initialized) return;
    // Use the module-level allocator from the cache.
    // The cache and denylist share the same allocator.
    if (oidc_cache) |*c| {
        try oidc_denylist.?.add(c.allocator, realm, jti, expires_at);
    }
}

/// Bulk-revoke all tokens for a realm.
pub fn revokeRealmTokens(realm: []const u8, now: i64) error{OutOfMemory}!void {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (!cache_initialized) return;
    if (oidc_cache) |*c| {
        try oidc_denylist.?.revokeRealm(c.allocator, c, realm, now);
    }
}

/// Evict expired entries from both cache and denylist.
pub fn evictExpired(now: i64) void {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (!cache_initialized) return;
    oidc_cache.?.evictExpired(now);
    oidc_denylist.?.evictExpired(now);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "TokenValidationCache: put and get" {
    var cache = TokenValidationCache.init(std.testing.allocator);
    defer cache.deinit();

    const now: i64 = 1000;
    const exp: i64 = 2000;

    try cache.put("test-realm", "jti-001", true, "{\"sub\":\"user1\"}", exp, now);

    const result = cache.get("test-realm", "jti-001", now);
    try std.testing.expect(result != null);
    defer {
        if (result) |r| {
            std.testing.allocator.free(r.principal_json);
        }
    }
    try std.testing.expect(result.?.valid);
    try std.testing.expectEqualStrings("{\"sub\":\"user1\"}", result.?.principal_json);
}

test "TokenValidationCache: miss for unknown key" {
    var cache = TokenValidationCache.init(std.testing.allocator);
    defer cache.deinit();

    const result = cache.get("unknown-realm", "unknown-jti", 1000);
    try std.testing.expect(result == null);
}

test "TokenValidationCache: entry expires" {
    var cache = TokenValidationCache.init(std.testing.allocator);
    defer cache.deinit();

    const now: i64 = 1000;
    const exp: i64 = 1010;
    try cache.put("realm", "jti-exp", true, "{}", exp, now);

    // Before expiry — found.
    const r1 = cache.get("realm", "jti-exp", now + 5);
    try std.testing.expect(r1 != null);
    if (r1) |r| std.testing.allocator.free(r.principal_json);

    // After expiry — not found.
    const r2 = cache.get("realm", "jti-exp", now + 20);
    try std.testing.expect(r2 == null);
}

test "TokenValidationCache: TTL capped at MAX_CACHE_TTL_SECONDS" {
    var cache = TokenValidationCache.init(std.testing.allocator);
    defer cache.deinit();

    const now: i64 = 1000;
    const far_future: i64 = 100000;
    try cache.put("realm", "jti-long", true, "{}", far_future, now);

    // Should be found at now + 200 (within 5 min TTL).
    const r1 = cache.get("realm", "jti-long", now + 200);
    try std.testing.expect(r1 != null);
    if (r1) |r| std.testing.allocator.free(r.principal_json);

    // Should expire after MAX_CACHE_TTL_SECONDS.
    const r2 = cache.get("realm", "jti-long", now + MAX_CACHE_TTL_SECONDS + 10);
    try std.testing.expect(r2 == null);
}

test "JtiDenylist: add and isRevoked" {
    var dl = JtiDenylist.init(std.testing.allocator);
    defer dl.deinit();

    try dl.add(std.testing.allocator, "realm-a", "jti-x", 2000);
    const now: i64 = 1500;

    try std.testing.expect(dl.isRevoked("realm-a", "jti-x", now));
    try std.testing.expect(!dl.isRevoked("realm-a", "jti-y", now));
    try std.testing.expect(!dl.isRevoked("realm-b", "jti-x", now));
}

test "JtiDenylist: expired entries not considered revoked" {
    var dl = JtiDenylist.init(std.testing.allocator);
    defer dl.deinit();

    try dl.add(std.testing.allocator, "realm", "jti-old", 1000);
    // now is past expires_at.
    try std.testing.expect(!dl.isRevoked("realm", "jti-old", 1500));
}

test "JtiDenylist: evictExpired removes stale entries" {
    var dl = JtiDenylist.init(std.testing.allocator);
    defer dl.deinit();

    try dl.add(std.testing.allocator, "r1", "j1", 1000);
    try dl.add(std.testing.allocator, "r2", "j2", 3000);

    dl.evictExpired(1500);
    try std.testing.expectEqual(@as(usize, 1), dl.entries.items.len);
    try std.testing.expectEqualStrings("r2", dl.entries.items[0].realm);
}

test "JtiDenylist: duplicate add is idempotent" {
    var dl = JtiDenylist.init(std.testing.allocator);
    defer dl.deinit();

    try dl.add(std.testing.allocator, "realm", "jti", 2000);
    try dl.add(std.testing.allocator, "realm", "jti", 2000);
    try std.testing.expectEqual(@as(usize, 1), dl.entries.items.len);
}

test "initCache and deinitCache: no error" {
    try initCache(std.testing.allocator);
    defer deinitCache();

    try std.testing.expect(cache_initialized);
}

test "checkCache and putCache: end-to-end" {
    try initCache(std.testing.allocator);
    defer deinitCache();

    const now: i64 = 1000;
    const exp: i64 = 2000;
    try putCache("realm", "jti-abc", true, "{\"sub\":\"x\"}", exp, now);

    const result = checkCache("realm", "jti-abc", now);
    try std.testing.expect(result != null);
    if (result) |r| {
        defer std.testing.allocator.free(r.principal_json);
        try std.testing.expect(r.valid);
    }
}

test "isRevoked and revokeToken: end-to-end" {
    try initCache(std.testing.allocator);
    defer deinitCache();

    const now: i64 = 1000;
    const exp: i64 = 2000;
    try putCache("realm", "jti-rev", true, "{\"sub\":\"y\"}", exp, now);
    try revokeToken("realm", "jti-rev", exp);

    try std.testing.expect(isRevoked("realm", "jti-rev", now));
    try std.testing.expect(!isRevoked("realm", "jti-other", now));
}

test "revokeRealmTokens: bulk-revoke all tokens for a realm" {
    try initCache(std.testing.allocator);
    defer deinitCache();

    const now: i64 = 1000;
    const exp: i64 = 2000;
    try putCache("realm-a", "jti-1", true, "{}", exp, now);
    try putCache("realm-a", "jti-2", true, "{}", exp, now);
    try putCache("realm-b", "jti-3", true, "{}", exp, now);

    try revokeRealmTokens("realm-a", now);

    try std.testing.expect(isRevoked("realm-a", "jti-1", now));
    try std.testing.expect(isRevoked("realm-a", "jti-2", now));
    // realm-b tokens should NOT be revoked.
    try std.testing.expect(!isRevoked("realm-b", "jti-3", now));
}

test "evictExpired: global cleanup" {
    try initCache(std.testing.allocator);
    defer deinitCache();

    const now: i64 = 1000;
    const exp: i64 = 1010;
    try putCache("realm", "jti-stale", true, "{}", exp, now);
    try revokeToken("realm", "jti-stale", exp);

    evictExpired(now + 20);

    // Both cache and denylist should be clean.
    const c = checkCache("realm", "jti-stale", now + 20);
    try std.testing.expect(c == null);
    try std.testing.expect(!isRevoked("realm", "jti-stale", now + 20));
}
