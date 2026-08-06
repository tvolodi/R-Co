//! Script manifest validation, hashing and capability binding (LUA-07).
//!
//! Each registered Lua script carries a manifest declaring the capabilities it
//! requires and its resource limits. This module parses that manifest, checks
//! it against the capabilities the deployment actually granted, and binds it to
//! the script artifact by hash.
//!
//! ## Trust direction (ISS-0169 design §6.2)
//!
//! The manifest is supplied by the CALLER (engine / script repository, REPO-05..07)
//! in its serialised JSON form — it is NOT scraped from the script text. A
//! manifest embedded in the artifact and read from the artifact is
//! self-asserted: a script could declare any capabilities it liked and the
//! "validation" would be a script grading its own homework. An embedded
//! `__manifest__` table, if any script carries one, is **advisory only** and is
//! never the source of a grant.
//!
//! ## Limits are validated, NOT enforced, in this tranche (design §6.5)
//!
//! `max_instructions`, `max_memory_bytes` and `timeout_seconds` are validated
//! against `Limits` and carried for LUA-08/09/10. **No limiter is installed by
//! this tranche** — ISS-0169 tranche 2 consumes these fields and installs the
//! real limiters. Validating a bound and enforcing it are different claims;
//! conflating them is how this subsystem reached RELEASED while executing
//! nothing. No comment, log line or test here may state or imply enforcement.

const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const ScriptManifest = struct {
    /// OWNED. `deinit` frees each string and then the slice.
    capabilities: []const []const u8,
    /// Validated against `Limits`; carried for LUA-08. NOT enforced in this
    /// tranche — see ISS-0169 tranche 2.
    max_instructions: u64,
    /// Validated against `Limits`; carried for LUA-09. NOT enforced in this
    /// tranche — see ISS-0169 tranche 2.
    max_memory_bytes: u64,
    /// Validated against `Limits`; carried for LUA-10. NOT enforced in this
    /// tranche — see ISS-0169 tranche 2.
    timeout_seconds: u32,
    manifest_hash: [32]u8,
    allocator: std.mem.Allocator,

    /// ISS-0169: previously freed only the outer slice, leaking every duped
    /// capability string `validateManifest` had allocated into it (design
    /// §6.1 defect 3). Ownership is stated on the struct: the manifest owns
    /// its capability strings; the caller owns the manifest and must deinit.
    pub fn deinit(self: *ScriptManifest) void {
        for (self.capabilities) |cap| {
            self.allocator.free(cap);
        }
        self.allocator.free(self.capabilities);
        self.capabilities = &.{};
    }
};

pub const ManifestError = error{
    UnauthorizedCapability,
    InstructionLimitTooLow,
    InstructionLimitTooHigh,
    MemoryLimitTooLow,
    MemoryLimitTooHigh,
    TimeoutTooLow,
    TimeoutTooHigh,
    ManifestHashMismatch,
    MalformedManifest,
};

/// Safe limit boundaries.
pub const Limits = struct {
    pub const MIN_INSTRUCTIONS = 1_000;
    pub const MAX_INSTRUCTIONS = 10_000_000;
    pub const MIN_MEMORY_BYTES = 1_048_576; // 1 MB
    pub const MAX_MEMORY_BYTES = 268_435_456; // 256 MB
    pub const MIN_TIMEOUT_SECONDS = 1;
    pub const MAX_TIMEOUT_SECONDS = 3600; // 1 hour
};

/// Canonical field separator for the manifest hash. A zero byte cannot occur
/// in a capability string or a decimal integer, so it is unambiguous.
const FIELD_SEP: u8 = 0x00;

// ---------------------------------------------------------------------------
// Hashing (design §6.3)
// ---------------------------------------------------------------------------

/// Compute the canonical manifest hash.
///
/// ISS-0169 fixed two defects in the previous scheme (design §6.1):
///
/// 1. **The hash did not cover the script.** It hashed only limits and
///    capability strings, so a manifest paired with a DIFFERENT script hashed
///    identically — making "a modified manifest without re-registration is
///    rejected" uncheckable. The SHA-256 digest of the script source is now
///    part of the canonical form; that is what binds manifest to artifact.
/// 2. **It was order-dependent and separator-free.** Capabilities were hashed
///    in declaration order with no delimiter, so `["ab","c"]` and `["a","bc"]`
///    collided and reordering changed the hash. TC-LUA-07-13 requires
///    logically identical manifests to hash identically.
///
/// Canonical serialisation:
///   1. capability strings sorted lexicographically ascending (byte order),
///      each followed by 0x00
///   2. 0x00 field separator
///   3. max_instructions, max_memory_bytes, timeout_seconds as decimal ASCII,
///      each followed by 0x00
///   4. 0x00 field separator
///   5. SHA-256 digest of the script source bytes
pub fn computeManifestHash(
    allocator: std.mem.Allocator,
    manifest_caps: []const []const u8,
    max_instructions: u64,
    max_memory_bytes: u64,
    timeout_seconds: u32,
    script_source: []const u8,
) (ManifestError || error{OutOfMemory})![32]u8 {
    // Sort a copy: the caller's slice must not be reordered as a side effect.
    const sorted = try allocator.alloc([]const u8, manifest_caps.len);
    defer allocator.free(sorted);
    @memcpy(sorted, manifest_caps);
    std.mem.sort([]const u8, sorted, {}, lessThanSlice);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (sorted) |cap| {
        hasher.update(cap);
        hasher.update(&[_]u8{FIELD_SEP});
    }
    hasher.update(&[_]u8{FIELD_SEP});

    var buf: [32]u8 = undefined;
    inline for (.{
        @as(u64, max_instructions),
        @as(u64, max_memory_bytes),
        @as(u64, timeout_seconds),
    }) |value| {
        const rendered = std.fmt.bufPrint(&buf, "{d}", .{value}) catch
            return ManifestError.MalformedManifest;
        hasher.update(rendered);
        hasher.update(&[_]u8{FIELD_SEP});
    }
    hasher.update(&[_]u8{FIELD_SEP});

    // The binding to the artifact.
    var script_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script_source, &script_digest, .{});
    hasher.update(&script_digest);

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Recompute the canonical hash over `script_manifest` + `script_source` and
/// compare it against the hash the repository recorded at registration.
///
/// The comparison is CONSTANT TIME. The hash is a tamper-detection value; a
/// timing-variable comparison on a tamper check is a defect even where
/// exploitation is impractical.
pub fn verifyManifestHash(
    allocator: std.mem.Allocator,
    script_manifest: *const ScriptManifest,
    script_source: []const u8,
    expected_hash: [32]u8,
) ManifestError!void {
    const recomputed = computeManifestHash(
        allocator,
        script_manifest.capabilities,
        script_manifest.max_instructions,
        script_manifest.max_memory_bytes,
        script_manifest.timeout_seconds,
        script_source,
    ) catch |err| switch (err) {
        error.OutOfMemory => return ManifestError.MalformedManifest,
        else => |e| return e,
    };

    if (!constantTimeEql(&recomputed, &expected_hash)) {
        return ManifestError.ManifestHashMismatch;
    }
}

/// Constant-time byte comparison. Accumulates differences rather than
/// short-circuiting, so the running time does not depend on where two digests
/// first differ.
fn constantTimeEql(a: *const [32]u8, b: *const [32]u8) bool {
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

// ---------------------------------------------------------------------------
// Parsing (design §6.2)
// ---------------------------------------------------------------------------

/// Parse the repository's serialised manifest form.
///
/// Expected shape:
/// ```json
/// {
///   "capabilities": ["variable:read", "audit:log"],
///   "max_instructions": 100000,
///   "max_memory_bytes": 8388608,
///   "timeout_seconds": 30
/// }
/// ```
///
/// Structurally invalid input, missing required fields, or wrong field types
/// all yield `MalformedManifest` (TC-LUA-07-16). No limit checking happens
/// here — that is `validateManifest`'s job — so a syntactically valid manifest
/// with an out-of-range limit parses and is then rejected with the specific
/// limit error rather than a generic malformed one.
///
/// The returned manifest's `manifest_hash` is zero: a hash is only meaningful
/// against a specific script artifact, which parsing does not have. Callers use
/// `computeManifestHash`/`verifyManifestHash` with the script source.
pub fn parseManifest(
    allocator: std.mem.Allocator,
    manifest_json: []const u8,
) (ManifestError || error{OutOfMemory})!ScriptManifest {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        manifest_json,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ManifestError.MalformedManifest,
    };
    defer parsed.deinit();

    if (parsed.value != .object) return ManifestError.MalformedManifest;
    const root = parsed.value.object;

    const caps_value = root.get("capabilities") orelse return ManifestError.MalformedManifest;
    if (caps_value != .array) return ManifestError.MalformedManifest;
    const caps_array = caps_value.array;

    const caps_copy = try allocator.alloc([]const u8, caps_array.items.len);
    // Unwind partial allocation if a later dupe fails, so a failed parse frees
    // everything it allocated.
    var filled: usize = 0;
    errdefer {
        for (caps_copy[0..filled]) |cap| allocator.free(cap);
        allocator.free(caps_copy);
    }

    for (caps_array.items) |item| {
        if (item != .string) return ManifestError.MalformedManifest;
        caps_copy[filled] = try allocator.dupe(u8, item.string);
        filled += 1;
    }

    const max_instructions = try readUnsigned(root, "max_instructions", u64);
    const max_memory_bytes = try readUnsigned(root, "max_memory_bytes", u64);
    const timeout_seconds = try readUnsigned(root, "timeout_seconds", u32);

    return ScriptManifest{
        .capabilities = caps_copy,
        .max_instructions = max_instructions,
        .max_memory_bytes = max_memory_bytes,
        .timeout_seconds = timeout_seconds,
        .manifest_hash = [_]u8{0} ** 32,
        .allocator = allocator,
    };
}

/// Read a required non-negative integer field. A missing field, a non-integer
/// field, a negative value, or a value that does not fit in `T` is
/// `MalformedManifest` — never a silent default, which would let a manifest
/// omit a limit and inherit whatever the code happened to pick.
fn readUnsigned(
    object: std.json.ObjectMap,
    key: []const u8,
    comptime T: type,
) ManifestError!T {
    const value = object.get(key) orelse return ManifestError.MalformedManifest;
    return switch (value) {
        .integer => |i| blk: {
            if (i < 0) return ManifestError.MalformedManifest;
            break :blk std.math.cast(T, i) orelse ManifestError.MalformedManifest;
        },
        else => ManifestError.MalformedManifest,
    };
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// Validate a manifest against granted capabilities and safe limits, and bind
/// it to the script artifact by hash.
///
/// ISS-0169: gained the `script_source` parameter so the stored hash covers the
/// artifact (design §6.3). Behaviour is otherwise unchanged.
pub fn validateManifest(
    manifest_caps: []const []const u8,
    granted_capabilities: *const capabilities.CapabilitySet,
    max_instructions: u64,
    max_memory_bytes: u64,
    timeout_seconds: u32,
    script_source: []const u8,
    allocator: std.mem.Allocator,
) (ManifestError || error{OutOfMemory})!ScriptManifest {
    // Every declared capability must actually have been granted. A manifest
    // that declares a superset of the grant is rejected outright rather than
    // silently intersected — the script author must see the discrepancy.
    for (manifest_caps) |cap| {
        if (!granted_capabilities.has(cap)) {
            return ManifestError.UnauthorizedCapability;
        }
    }

    if (max_instructions < Limits.MIN_INSTRUCTIONS) return ManifestError.InstructionLimitTooLow;
    if (max_instructions > Limits.MAX_INSTRUCTIONS) return ManifestError.InstructionLimitTooHigh;
    if (max_memory_bytes < Limits.MIN_MEMORY_BYTES) return ManifestError.MemoryLimitTooLow;
    if (max_memory_bytes > Limits.MAX_MEMORY_BYTES) return ManifestError.MemoryLimitTooHigh;
    if (timeout_seconds < Limits.MIN_TIMEOUT_SECONDS) return ManifestError.TimeoutTooLow;
    if (timeout_seconds > Limits.MAX_TIMEOUT_SECONDS) return ManifestError.TimeoutTooHigh;

    const manifest_hash = try computeManifestHash(
        allocator,
        manifest_caps,
        max_instructions,
        max_memory_bytes,
        timeout_seconds,
        script_source,
    );

    const caps_copy = try allocator.alloc([]const u8, manifest_caps.len);
    // ISS-0169: without this errdefer, a dupe failure partway through leaked
    // every string already duped plus the slice itself.
    var filled: usize = 0;
    errdefer {
        for (caps_copy[0..filled]) |cap| allocator.free(cap);
        allocator.free(caps_copy);
    }
    for (manifest_caps) |cap| {
        caps_copy[filled] = try allocator.dupe(u8, cap);
        filled += 1;
    }

    return ScriptManifest{
        .capabilities = caps_copy,
        .max_instructions = max_instructions,
        .max_memory_bytes = max_memory_bytes,
        .timeout_seconds = timeout_seconds,
        .manifest_hash = manifest_hash,
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// Tests — these genuinely CALL the functions above (ISS-0172 caveat).
// ---------------------------------------------------------------------------

test "ISS-0169: capability declaration order does not change the hash (TC-LUA-07-13)" {
    const a = [_][]const u8{ "variable:read", "audit:log", "event:emit" };
    const b = [_][]const u8{ "event:emit", "variable:read", "audit:log" };

    const ha = try computeManifestHash(std.testing.allocator, &a, 100_000, 8_388_608, 30, "return 1");
    const hb = try computeManifestHash(std.testing.allocator, &b, 100_000, 8_388_608, 30, "return 1");
    try std.testing.expectEqualSlices(u8, &ha, &hb);

    // The caller's slice must not have been reordered as a side effect.
    try std.testing.expectEqualStrings("variable:read", a[0]);
}

test "ISS-0169: the separator removes the concatenation ambiguity" {
    // Without a 0x00 separator, ["ab","c"] and ["a","bc"] hash identically.
    const a = [_][]const u8{ "ab", "c" };
    const b = [_][]const u8{ "a", "bc" };
    const ha = try computeManifestHash(std.testing.allocator, &a, 100_000, 8_388_608, 30, "x");
    const hb = try computeManifestHash(std.testing.allocator, &b, 100_000, 8_388_608, 30, "x");
    try std.testing.expect(!std.mem.eql(u8, &ha, &hb));
}

test "ISS-0169: the hash binds the manifest to the script artifact" {
    const caps = [_][]const u8{"variable:read"};
    const h1 = try computeManifestHash(std.testing.allocator, &caps, 100_000, 8_388_608, 30, "return 1");
    const h2 = try computeManifestHash(std.testing.allocator, &caps, 100_000, 8_388_608, 30, "return 2");
    // Same manifest, different script => different hash. Before ISS-0169 these
    // were equal, so a manifest could be paired with any script undetected.
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "ISS-0169: verifyManifestHash rejects a tampered manifest (TC-LUA-07-12)" {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    try caps.add("variable:read");

    const declared = [_][]const u8{"variable:read"};
    const script = "return platform.read_variable('k')";

    var m = try validateManifest(
        &declared,
        &caps,
        100_000,
        8_388_608,
        30,
        script,
        std.testing.allocator,
    );
    defer m.deinit();

    // The hash recorded at registration verifies.
    try verifyManifestHash(std.testing.allocator, &m, script, m.manifest_hash);

    // The same manifest against a DIFFERENT script does not.
    try std.testing.expectError(
        ManifestError.ManifestHashMismatch,
        verifyManifestHash(std.testing.allocator, &m, "return 999", m.manifest_hash),
    );

    // A tampered limit does not verify against the registered hash either.
    var tampered = m;
    tampered.max_instructions = 200_000;
    try std.testing.expectError(
        ManifestError.ManifestHashMismatch,
        verifyManifestHash(std.testing.allocator, &tampered, script, m.manifest_hash),
    );
}

test "ISS-0169: a manifest declaring an ungranted capability is rejected" {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    try caps.add("variable:read");

    const declared = [_][]const u8{ "variable:read", "variable:write" };
    try std.testing.expectError(
        ManifestError.UnauthorizedCapability,
        validateManifest(&declared, &caps, 100_000, 8_388_608, 30, "return 1", std.testing.allocator),
    );
}

test "ISS-0169: parseManifest accepts a well-formed manifest and rejects malformed ones" {
    var m = try parseManifest(std.testing.allocator,
        \\{"capabilities":["variable:read","audit:log"],
        \\ "max_instructions":100000,"max_memory_bytes":8388608,"timeout_seconds":30}
    );
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 2), m.capabilities.len);
    try std.testing.expectEqualStrings("variable:read", m.capabilities[0]);
    try std.testing.expectEqual(@as(u64, 100_000), m.max_instructions);
    try std.testing.expectEqual(@as(u32, 30), m.timeout_seconds);

    // TC-LUA-07-16: structurally invalid input.
    for ([_][]const u8{
        "not json at all",
        "[]",
        \\{"max_instructions":100000,"max_memory_bytes":8388608,"timeout_seconds":30}
        ,
        \\{"capabilities":"variable:read","max_instructions":1,"max_memory_bytes":1,"timeout_seconds":1}
        ,
        \\{"capabilities":[42],"max_instructions":1,"max_memory_bytes":1,"timeout_seconds":1}
        ,
        \\{"capabilities":[],"max_instructions":-5,"max_memory_bytes":1,"timeout_seconds":1}
        ,
        \\{"capabilities":[],"max_instructions":"lots","max_memory_bytes":1,"timeout_seconds":1}
        ,
    }) |bad| {
        try std.testing.expectError(
            ManifestError.MalformedManifest,
            parseManifest(std.testing.allocator, bad),
        );
    }
}

test "ISS-0169: limit bounds are validated (but not enforced in this tranche)" {
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    const none = [_][]const u8{};
    const a = std.testing.allocator;

    try std.testing.expectError(
        ManifestError.InstructionLimitTooLow,
        validateManifest(&none, &caps, 10, 8_388_608, 30, "s", a),
    );
    try std.testing.expectError(
        ManifestError.InstructionLimitTooHigh,
        validateManifest(&none, &caps, 99_000_000, 8_388_608, 30, "s", a),
    );
    try std.testing.expectError(
        ManifestError.MemoryLimitTooLow,
        validateManifest(&none, &caps, 100_000, 1024, 30, "s", a),
    );
    try std.testing.expectError(
        ManifestError.MemoryLimitTooHigh,
        validateManifest(&none, &caps, 100_000, 999_999_999, 30, "s", a),
    );
    try std.testing.expectError(
        ManifestError.TimeoutTooLow,
        validateManifest(&none, &caps, 100_000, 8_388_608, 0, "s", a),
    );
    try std.testing.expectError(
        ManifestError.TimeoutTooHigh,
        validateManifest(&none, &caps, 100_000, 8_388_608, 99_999, "s", a),
    );
}

test "ISS-0169: deinit frees every duped capability string, not just the slice" {
    // std.testing.allocator fails the test on leak, so this test IS the check:
    // before the fix it leaked one allocation per capability.
    var caps = capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    try caps.add("variable:read");
    try caps.add("audit:log");

    const declared = [_][]const u8{ "variable:read", "audit:log" };
    var m = try validateManifest(&declared, &caps, 100_000, 8_388_608, 30, "return 1", std.testing.allocator);
    m.deinit();
}
