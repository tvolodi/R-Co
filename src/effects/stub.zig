//! Effects stub executor — EXP-303
//!
//! The StubEffectsExecutor is used when instance.is_sandbox = true or when
//! the effects worker is started with executor = .stub. It records every
//! execute() call and returns a configurable stub response without making
//! any network calls, file I/O, or clock reads.
//!
//! Intended for deterministic sandbox/simulation contexts and unit tests.
//! Test assertions access http_call_count, email_count, and recorded directly.
const std = @import("std");
const mod = @import("mod.zig");

pub const EffectSpec = mod.EffectSpec;
pub const EffectKind = mod.EffectKind;
pub const EffectDeliveryResult = mod.EffectDeliveryResult;
pub const EffectDeliveryError = mod.EffectDeliveryError;

pub const DEFAULT_STUB_STATUS: u16 = 200;
pub const DEFAULT_STUB_BODY: []const u8 = "{}";

pub const StubEffectsExecutor = struct {
    /// Per-kind counters: incremented on each execute() call.
    http_call_count: u32,
    email_count: u32,

    /// Per-correlation_key recorded calls.
    /// Key: correlation_key. Value: most recent EffectSpec.spec_json.
    recorded: std.StringHashMap([]const u8),

    /// Injected stub response. Defaults to HTTP 200 / body "{}".
    stub_status_code: u16,
    stub_body: []const u8,

    /// Allocator used for recorded map storage. Must outlive the executor.
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StubEffectsExecutor {
        return .{
            .http_call_count = 0,
            .email_count = 0,
            .recorded = std.StringHashMap([]const u8).init(allocator),
            .stub_status_code = DEFAULT_STUB_STATUS,
            .stub_body = DEFAULT_STUB_BODY,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StubEffectsExecutor) void {
        var it = self.recorded.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.recorded.deinit();
    }

    /// Execute one effect delivery — records call, returns stub response.
    /// Performs no I/O.
    pub fn execute(
        self: *StubEffectsExecutor,
        allocator: std.mem.Allocator,
        spec: EffectSpec,
        _: u8, // attempt — ignored by stub
    ) EffectDeliveryError!EffectDeliveryResult {
        // Increment kind-specific counter.
        switch (spec.kind) {
            .http_call => self.http_call_count += 1,
            .email => self.email_count += 1,
        }

        // Record the spec_json under this correlation_key.
        const key_dup = allocator.dupe(u8, spec.correlation_key) catch return error.OutOfMemory;
        const val_dup = allocator.dupe(u8, spec.spec_json) catch {
            allocator.free(key_dup);
            return error.OutOfMemory;
        };
        // If a previous entry exists, free it before overwriting.
        if (self.recorded.fetchRemove(spec.correlation_key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        self.recorded.put(key_dup, val_dup) catch {
            allocator.free(key_dup);
            allocator.free(val_dup);
            return error.OutOfMemory;
        };

        // Build stub response body — duplicated so caller owns memory.
        const body_dup = allocator.dupe(u8, self.stub_body) catch return error.OutOfMemory;

        return EffectDeliveryResult{
            .status_code = self.stub_status_code,
            .response_body = body_dup,
            .idempotency_key_sent = spec.effect_event_id,
        };
    }

    /// Reset all counters and clear the recorded map.
    pub fn reset(self: *StubEffectsExecutor) void {
        var it = self.recorded.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.recorded.clearRetainingCapacity();
        self.http_call_count = 0;
        self.email_count = 0;
    }

    /// Look up the most recently recorded spec_json for a correlation_key.
    /// Returns null if not found.
    pub fn getRecorded(self: *const StubEffectsExecutor, correlation_key: []const u8) ?[]const u8 {
        return self.recorded.get(correlation_key);
    }

    /// Build the vtable function pointer for use with EffectExecutorVTable.
    /// NOTE: This function is a free function adapter; context (self) is passed
    /// separately. For vtable use, pair with a pointer-to-executor approach.
    pub fn executeVia(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        spec: EffectSpec,
        attempt: u8,
    ) EffectDeliveryError!EffectDeliveryResult {
        const self: *StubEffectsExecutor = @ptrCast(@alignCast(ctx));
        return self.execute(allocator, spec, attempt);
    }
};
