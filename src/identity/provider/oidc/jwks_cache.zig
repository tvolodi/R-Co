const std = @import("std");

/// A single cached JWKS entry for one JWKS URI.
/// `kids` is heap-owned (each slice duped at store time).
/// `fetched_at` is unix seconds at time of the last successful fetch.
pub const JwksCacheEntry = struct {
    kids: [][]u8, // heap-owned slice of heap-owned kid strings
    fetched_at: i64, // unix epoch seconds
};

/// In-memory cache of JWKS key IDs, keyed by JWKS URI string.
/// Thread-safety: NOT thread-safe; callers must hold an external mutex
/// if the Adapter is accessed concurrently.
pub const JwksCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(JwksCacheEntry), // key = duped URI string
    ttl_seconds: i64,
    min_refresh_seconds: i64,
    last_refresh_at: i64, // unix seconds of last fetch across all URIs

    /// Initialise a cache with given TTL and rate-limit window.
    pub fn init(
        allocator: std.mem.Allocator,
        ttl_seconds: i64,
        min_refresh_seconds: i64,
    ) JwksCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(JwksCacheEntry).init(allocator),
            .ttl_seconds = ttl_seconds,
            .min_refresh_seconds = min_refresh_seconds,
            .last_refresh_at = 0,
        };
    }

    /// Free all heap-owned kid strings, URI keys, and the hash map itself.
    pub fn deinit(self: *JwksCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.kids) |kid| {
                self.allocator.free(kid);
            }
            self.allocator.free(entry.value_ptr.kids);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    /// Look up whether `kid` is present for the given `uri` as of `now` (unix seconds).
    ///
    /// Returns:
    ///   true  — entry is present and valid; kid IS in the set.
    ///   false — entry is present and valid; kid is NOT in the set.
    ///   null  — entry absent OR stale (caller must fetch and call store()).
    pub fn lookupKid(
        self: *JwksCache,
        uri: []const u8,
        kid: []const u8,
        now: i64,
    ) ?bool {
        const entry = self.entries.get(uri) orelse return null;
        // Stale check: >= ttl means stale
        if (now - entry.fetched_at >= self.ttl_seconds) return null;
        // Valid cache — search for kid
        for (entry.kids) |k| {
            if (std.mem.eql(u8, k, kid)) return true;
        }
        return false;
    }

    /// Parse `kid` strings from a raw JWKS JSON body and store them under `uri`.
    /// Replaces any existing entry for `uri` (freeing old kids but not the URI key).
    /// Returns error.UpstreamProtocolError if the JSON is malformed or
    /// the "keys" array is absent/wrong type.
    /// Returns error.OutOfMemory on allocation failure.
    pub fn store(
        self: *JwksCache,
        uri: []const u8,
        jwks_body: []const u8,
        now: i64,
    ) (error{ UpstreamProtocolError, OutOfMemory })!void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, jwks_body, .{ .allocate = .alloc_always }) catch return error.UpstreamProtocolError;
        defer parsed.deinit();

        if (parsed.value != .object) return error.UpstreamProtocolError;
        const root = parsed.value.object;
        const keys_value = root.get("keys") orelse return error.UpstreamProtocolError;
        if (keys_value != .array) return error.UpstreamProtocolError;

        // Build kids array; defer handles cleanup if an error occurs before toOwnedSlice
        var kids: std.ArrayList([]u8) = .empty;
        defer {
            for (kids.items) |k| self.allocator.free(k);
            kids.deinit(self.allocator);
        }
        for (keys_value.array.items) |item| {
            if (item != .object) continue;
            const kid_value = item.object.get("kid") orelse continue;
            if (kid_value != .string) continue;
            const duped_kid = try self.allocator.dupe(u8, kid_value.string);
            errdefer self.allocator.free(duped_kid);
            try kids.append(self.allocator, duped_kid);
        }
        // After toOwnedSlice, kids.items is empty — the defer above is a no-op from here
        const kids_slice = try kids.toOwnedSlice(self.allocator);

        const new_entry = JwksCacheEntry{
            .kids = kids_slice,
            .fetched_at = now,
        };

        // Replace existing entry: free old kids but NOT the URI key (map owns it)
        if (self.entries.getPtr(uri)) |existing| {
            for (existing.kids) |k| self.allocator.free(k);
            self.allocator.free(existing.kids);
            existing.* = new_entry;
            return;
        }

        // New entry: dup the URI key and insert
        errdefer {
            for (kids_slice) |k| self.allocator.free(k);
            self.allocator.free(kids_slice);
        }
        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);
        try self.entries.put(owned_uri, new_entry);
    }

    /// Returns true if a refresh would be blocked by the rate limiter.
    /// Refresh is rate-limited when `now - last_refresh_at < min_refresh_seconds`.
    pub fn isRateLimited(self: *const JwksCache, now: i64) bool {
        return now - self.last_refresh_at < self.min_refresh_seconds;
    }

    /// Record that a JWKS fetch was just performed.
    pub fn markRefreshed(self: *JwksCache, now: i64) void {
        self.last_refresh_at = now;
    }
};
