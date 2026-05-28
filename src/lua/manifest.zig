//! Script manifest validation and capability checking (LUA-07).
//!
//! Each Lua script carries a manifest declaring required capabilities and resource limits.
//! This module validates the manifest against registered capabilities and enforces safe limits.

const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const ScriptManifest = struct {
    capabilities: []const []const u8,
    max_instructions: u64,
    max_memory_bytes: u64,
    timeout_seconds: u32,
    manifest_hash: [32]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ScriptManifest) void {
        self.allocator.free(self.capabilities);
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

/// Safe limit boundaries
pub const Limits = struct {
    pub const MIN_INSTRUCTIONS = 1_000;
    pub const MAX_INSTRUCTIONS = 10_000_000;
    pub const MIN_MEMORY_BYTES = 1_048_576; // 1 MB
    pub const MAX_MEMORY_BYTES = 268_435_456; // 256 MB
    pub const MIN_TIMEOUT_SECONDS = 1;
    pub const MAX_TIMEOUT_SECONDS = 3600; // 1 hour
};

/// Validate a manifest against granted capabilities and safe limits.
pub fn validateManifest(
    manifest_caps: []const []const u8,
    granted_capabilities: *const capabilities.CapabilitySet,
    max_instructions: u64,
    max_memory_bytes: u64,
    timeout_seconds: u32,
    allocator: std.mem.Allocator,
) !ScriptManifest {
    // Verify all declared capabilities are granted
    for (manifest_caps) |cap| {
        if (!granted_capabilities.has(cap)) {
            return ManifestError.UnauthorizedCapability;
        }
    }

    // Validate instruction limits
    if (max_instructions < Limits.MIN_INSTRUCTIONS) {
        return ManifestError.InstructionLimitTooLow;
    }
    if (max_instructions > Limits.MAX_INSTRUCTIONS) {
        return ManifestError.InstructionLimitTooHigh;
    }

    // Validate memory limits
    if (max_memory_bytes < Limits.MIN_MEMORY_BYTES) {
        return ManifestError.MemoryLimitTooLow;
    }
    if (max_memory_bytes > Limits.MAX_MEMORY_BYTES) {
        return ManifestError.MemoryLimitTooHigh;
    }

    // Validate timeout limits
    if (timeout_seconds < Limits.MIN_TIMEOUT_SECONDS) {
        return ManifestError.TimeoutTooLow;
    }
    if (timeout_seconds > Limits.MAX_TIMEOUT_SECONDS) {
        return ManifestError.TimeoutTooHigh;
    }

    // Compute manifest hash (simplified: use a deterministic hash of the limits)
    var manifest_hash: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    var buf: [32]u8 = undefined;
    var written: usize = 0;

    // Hash instruction limit
    written = std.fmt.bufPrint(&buf, "{d}", .{max_instructions}) catch return ManifestError.MalformedManifest;
    hasher.update(buf[0..written]);

    // Hash memory limit
    written = std.fmt.bufPrint(&buf, "{d}", .{max_memory_bytes}) catch return ManifestError.MalformedManifest;
    hasher.update(buf[0..written]);

    // Hash timeout
    written = std.fmt.bufPrint(&buf, "{d}", .{timeout_seconds}) catch return ManifestError.MalformedManifest;
    hasher.update(buf[0..written]);

    // Hash capabilities
    for (manifest_caps) |cap| {
        hasher.update(cap);
    }

    hasher.final(&manifest_hash);

    // Create manifest with allocated capability list copy
    const caps_copy = try allocator.alloc([]const u8, manifest_caps.len);
    for (manifest_caps, caps_copy) |cap, *cap_slot| {
        cap_slot.* = try allocator.dupe(u8, cap);
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
