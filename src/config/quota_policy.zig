//! EXP-601: Tier-to-quota policy resolution and evaluation.
//!
//! This module provides a single configuration surface for tenant quotas.
//! Policy is loaded from the active `tier_quota_policy` config artifact.

const std = @import("std");
const loader = @import("loader.zig");
const pool_mod = @import("pool");

pub const TierName = enum {
    free,
    standard,
    enterprise,
    internal,
};

pub const QuotaDimension = enum {
    script_cpu,
    script_memory,
    entity_records,
    entity_storage,
    file_bytes,
    file_count,
    concurrent_sandboxes,
    agent_retry_per_job,
    agent_retry_per_day,
};

pub const EffectiveQuotaProfile = struct {
    tenant_id: []const u8,
    tier: TierName,
    script_cpu_millis_per_request: u32,
    script_memory_bytes_per_request: u64,
    max_entity_records_total: u64,
    max_entity_storage_bytes: u64,
    max_file_bytes_total: u64,
    max_file_count_total: u64,
    max_concurrent_sandboxes: u32,
    max_agent_retries_per_job: u16,
    max_agent_retries_per_day: u32,
};

pub const QuotaUsageSnapshot = struct {
    tenant_id: []const u8,
    dimension: QuotaDimension,
    used: u64,
    limit: u64,
    remaining: u64,
};

pub const QuotaViolation = struct {
    dimension: QuotaDimension,
    tenant_id: []const u8,
    tier: TierName,
    used: u64,
    requested_delta: u64,
    limit: u64,
    retry_after_seconds: ?u32,
};

pub const QuotaDecision = union(enum) {
    allowed,
    rejected: QuotaViolation,
};

pub const QuotaPolicyError = error{
    QuotaPolicyNotConfigured,
    QuotaPolicyInvalid,
    DatabaseError,
    OutOfMemory,
};

const TierQuotaProfile = struct {
    script_cpu_millis_per_request: u32,
    script_memory_bytes_per_request: u64,
    max_entity_records_total: u64,
    max_entity_storage_bytes: u64,
    max_file_bytes_total: u64,
    max_file_count_total: u64,
    max_concurrent_sandboxes: u32,
    max_agent_retries_per_job: u16,
    max_agent_retries_per_day: u32,
};

pub fn loadEffectiveQuotaProfile(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
) QuotaPolicyError!EffectiveQuotaProfile {
    var selected_tier: TierName = .standard;

    if (resolveTierHintFromTenant(allocator, pool, tenant_id)) |maybe_hint| {
        if (maybe_hint) |hint| {
            selected_tier = hint;
        }
    } else |_| {}

    var profile = defaultProfileForTier(selected_tier);

    const maybe_json = loader.loadActiveQuotaPolicy(allocator, pool, tenant_id) catch |err| switch (err) {
        loader.ConfigError.ConfigNotFound => null,
        loader.ConfigError.DatabaseError => return error.DatabaseError,
        loader.ConfigError.OutOfMemory => return error.OutOfMemory,
        else => return error.QuotaPolicyInvalid,
    };

    if (maybe_json) |json| {
        defer allocator.free(json);
        applyPolicyJson(allocator, json, tenant_id, &selected_tier, &profile) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.QuotaPolicyInvalid,
        };
    }

    return .{
        .tenant_id = tenant_id,
        .tier = selected_tier,
        .script_cpu_millis_per_request = profile.script_cpu_millis_per_request,
        .script_memory_bytes_per_request = profile.script_memory_bytes_per_request,
        .max_entity_records_total = profile.max_entity_records_total,
        .max_entity_storage_bytes = profile.max_entity_storage_bytes,
        .max_file_bytes_total = profile.max_file_bytes_total,
        .max_file_count_total = profile.max_file_count_total,
        .max_concurrent_sandboxes = profile.max_concurrent_sandboxes,
        .max_agent_retries_per_job = profile.max_agent_retries_per_job,
        .max_agent_retries_per_day = profile.max_agent_retries_per_day,
    };
}

pub fn evaluateQuota(
    profile: EffectiveQuotaProfile,
    usage_snapshot: QuotaUsageSnapshot,
    requested_delta: u64,
) QuotaDecision {
    const limit = switch (usage_snapshot.dimension) {
        .script_cpu => profile.script_cpu_millis_per_request,
        .script_memory => profile.script_memory_bytes_per_request,
        .entity_records => profile.max_entity_records_total,
        .entity_storage => profile.max_entity_storage_bytes,
        .file_bytes => profile.max_file_bytes_total,
        .file_count => profile.max_file_count_total,
        .concurrent_sandboxes => profile.max_concurrent_sandboxes,
        .agent_retry_per_job => profile.max_agent_retries_per_job,
        .agent_retry_per_day => profile.max_agent_retries_per_day,
    };

    const next_used = usage_snapshot.used + requested_delta;
    if (next_used > limit) {
        return .{ .rejected = .{
            .dimension = usage_snapshot.dimension,
            .tenant_id = usage_snapshot.tenant_id,
            .tier = profile.tier,
            .used = usage_snapshot.used,
            .requested_delta = requested_delta,
            .limit = limit,
            .retry_after_seconds = null,
        } };
    }

    return .allowed;
}

pub fn mapQuotaDecisionToProblem(
    allocator: std.mem.Allocator,
    violation: QuotaViolation,
) QuotaPolicyError![]const u8 {
    const remaining: u64 = if (violation.used >= violation.limit) 0 else violation.limit - violation.used;
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"https://bpm.local/problems/quota-exceeded\",\"title\":\"Tenant Quota Exceeded\",\"status\":429,\"detail\":\"Quota exceeded for {s}\",\"extensions\":{{\"tenant_id\":\"{s}\",\"tier\":\"{s}\",\"dimension\":\"{s}\",\"used\":{d},\"requested_delta\":{d},\"limit\":{d},\"remaining\":{d}}}}}",
        .{
            dimensionToString(violation.dimension),
            violation.tenant_id,
            tierToString(violation.tier),
            dimensionToString(violation.dimension),
            violation.used,
            violation.requested_delta,
            violation.limit,
            remaining,
        },
    ) catch return error.OutOfMemory;
}

fn resolveTierHintFromTenant(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
) QuotaPolicyError!?TierName {
    const conn = pool.acquire() catch return error.DatabaseError;
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        "SELECT tenant_type FROM tenant WHERE id = $1::uuid LIMIT 1",
        &[_][]const u8{tenant_id},
    ) catch return error.DatabaseError;

    if (row == null) return null;
    defer {
        for (row.?) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(row.?);
    }

    const tenant_type = row.?[0] orelse return null;
    if (std.mem.eql(u8, tenant_type, "test")) return .internal;
    return null;
}

fn applyPolicyJson(
    allocator: std.mem.Allocator,
    json: []const u8,
    tenant_id: []const u8,
    selected_tier: *TierName,
    profile: *TierQuotaProfile,
) (error{ OutOfMemory, InvalidPolicy } || std.json.ParseError(std.json.Scanner))!void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidPolicy;

    if (parsed.value.object.get("default_tier")) |default_tier_val| {
        if (default_tier_val != .string) return error.InvalidPolicy;
        selected_tier.* = tierFromString(default_tier_val.string) orelse return error.InvalidPolicy;
        profile.* = defaultProfileForTier(selected_tier.*);
    }

    const tiers_obj = parsed.value.object.get("tiers") orelse return;
    if (tiers_obj != .object) return error.InvalidPolicy;

    if (tiers_obj.object.get(tierToString(selected_tier.*))) |tier_cfg| {
        profile.* = try parseTierProfileStrict(tier_cfg);
    }

    if (parsed.value.object.get("tenant_overrides")) |overrides_val| {
        if (overrides_val != .object) return error.InvalidPolicy;
        if (overrides_val.object.get(tenant_id)) |tenant_override| {
            if (tenant_override != .object) return error.InvalidPolicy;

            if (tenant_override.object.get("tier")) |tenant_tier_val| {
                if (tenant_tier_val != .string) return error.InvalidPolicy;
                const tier_override = tierFromString(tenant_tier_val.string) orelse return error.InvalidPolicy;
                selected_tier.* = tier_override;
                profile.* = defaultProfileForTier(selected_tier.*);
                if (tiers_obj.object.get(tierToString(selected_tier.*))) |tier_cfg2| {
                    profile.* = try parseTierProfileStrict(tier_cfg2);
                }
            }

            if (tenant_override.object.get("overrides")) |partial| {
                if (partial != .object) return error.InvalidPolicy;
                applyTierProfilePartial(partial, profile) catch return error.InvalidPolicy;
            }
        }
    }
}

fn parseTierProfileStrict(value: std.json.Value) error{ InvalidPolicy }!TierQuotaProfile {
    if (value != .object) return error.InvalidPolicy;
    return .{
        .script_cpu_millis_per_request = try getU32(value.object, "script_cpu_millis_per_request"),
        .script_memory_bytes_per_request = try getU64(value.object, "script_memory_bytes_per_request"),
        .max_entity_records_total = try getU64(value.object, "max_entity_records_total"),
        .max_entity_storage_bytes = try getU64(value.object, "max_entity_storage_bytes"),
        .max_file_bytes_total = try getU64(value.object, "max_file_bytes_total"),
        .max_file_count_total = try getU64(value.object, "max_file_count_total"),
        .max_concurrent_sandboxes = try getU32(value.object, "max_concurrent_sandboxes"),
        .max_agent_retries_per_job = try getU16(value.object, "max_agent_retries_per_job"),
        .max_agent_retries_per_day = try getU32(value.object, "max_agent_retries_per_day"),
    };
}

fn applyTierProfilePartial(value: std.json.Value, profile: *TierQuotaProfile) error{ InvalidPolicy }!void {
    if (value != .object) return error.InvalidPolicy;

    if (value.object.get("script_cpu_millis_per_request")) |_| profile.script_cpu_millis_per_request = try getU32(value.object, "script_cpu_millis_per_request");
    if (value.object.get("script_memory_bytes_per_request")) |_| profile.script_memory_bytes_per_request = try getU64(value.object, "script_memory_bytes_per_request");
    if (value.object.get("max_entity_records_total")) |_| profile.max_entity_records_total = try getU64(value.object, "max_entity_records_total");
    if (value.object.get("max_entity_storage_bytes")) |_| profile.max_entity_storage_bytes = try getU64(value.object, "max_entity_storage_bytes");
    if (value.object.get("max_file_bytes_total")) |_| profile.max_file_bytes_total = try getU64(value.object, "max_file_bytes_total");
    if (value.object.get("max_file_count_total")) |_| profile.max_file_count_total = try getU64(value.object, "max_file_count_total");
    if (value.object.get("max_concurrent_sandboxes")) |_| profile.max_concurrent_sandboxes = try getU32(value.object, "max_concurrent_sandboxes");
    if (value.object.get("max_agent_retries_per_job")) |_| profile.max_agent_retries_per_job = try getU16(value.object, "max_agent_retries_per_job");
    if (value.object.get("max_agent_retries_per_day")) |_| profile.max_agent_retries_per_day = try getU32(value.object, "max_agent_retries_per_day");
}

fn getU64(obj: std.json.ObjectMap, key: []const u8) error{ InvalidPolicy }!u64 {
    const val = obj.get(key) orelse return error.InvalidPolicy;
    return parsePositiveU64(val) orelse error.InvalidPolicy;
}

fn getU32(obj: std.json.ObjectMap, key: []const u8) error{ InvalidPolicy }!u32 {
    const n = try getU64(obj, key);
    return std.math.cast(u32, n) orelse error.InvalidPolicy;
}

fn getU16(obj: std.json.ObjectMap, key: []const u8) error{ InvalidPolicy }!u16 {
    const n = try getU64(obj, key);
    return std.math.cast(u16, n) orelse error.InvalidPolicy;
}

fn parsePositiveU64(val: std.json.Value) ?u64 {
    return switch (val) {
        .integer => |i| if (i < 0) null else std.math.cast(u64, i),
        .float => |f| if (f < 0) null else std.math.lossyCast(u64, f),
        .number_string => |s| std.fmt.parseUnsigned(u64, s, 10) catch null,
        else => null,
    };
}

fn defaultProfileForTier(tier: TierName) TierQuotaProfile {
    return switch (tier) {
        .free => .{
            .script_cpu_millis_per_request = 1_500,
            .script_memory_bytes_per_request = 16 * 1024 * 1024,
            .max_entity_records_total = 10_000,
            .max_entity_storage_bytes = 256 * 1024 * 1024,
            .max_file_bytes_total = 128 * 1024 * 1024,
            .max_file_count_total = 1_000,
            .max_concurrent_sandboxes = 2,
            .max_agent_retries_per_job = 3,
            .max_agent_retries_per_day = 200,
        },
        .standard => .{
            .script_cpu_millis_per_request = 5_000,
            .script_memory_bytes_per_request = 64 * 1024 * 1024,
            .max_entity_records_total = 200_000,
            .max_entity_storage_bytes = 4 * 1024 * 1024 * 1024,
            .max_file_bytes_total = 2 * 1024 * 1024 * 1024,
            .max_file_count_total = 100_000,
            .max_concurrent_sandboxes = 10,
            .max_agent_retries_per_job = 8,
            .max_agent_retries_per_day = 5_000,
        },
        .enterprise => .{
            .script_cpu_millis_per_request = 15_000,
            .script_memory_bytes_per_request = 256 * 1024 * 1024,
            .max_entity_records_total = 5_000_000,
            .max_entity_storage_bytes = 64 * 1024 * 1024 * 1024,
            .max_file_bytes_total = 32 * 1024 * 1024 * 1024,
            .max_file_count_total = 2_000_000,
            .max_concurrent_sandboxes = 100,
            .max_agent_retries_per_job = 20,
            .max_agent_retries_per_day = 100_000,
        },
        .internal => .{
            .script_cpu_millis_per_request = 30_000,
            .script_memory_bytes_per_request = 512 * 1024 * 1024,
            .max_entity_records_total = 10_000_000,
            .max_entity_storage_bytes = 128 * 1024 * 1024 * 1024,
            .max_file_bytes_total = 64 * 1024 * 1024 * 1024,
            .max_file_count_total = 4_000_000,
            .max_concurrent_sandboxes = 200,
            .max_agent_retries_per_job = 50,
            .max_agent_retries_per_day = 500_000,
        },
    };
}

pub fn tierFromString(s: []const u8) ?TierName {
    if (std.mem.eql(u8, s, "free")) return .free;
    if (std.mem.eql(u8, s, "standard")) return .standard;
    if (std.mem.eql(u8, s, "enterprise")) return .enterprise;
    if (std.mem.eql(u8, s, "internal")) return .internal;
    return null;
}

pub fn tierToString(t: TierName) []const u8 {
    return switch (t) {
        .free => "free",
        .standard => "standard",
        .enterprise => "enterprise",
        .internal => "internal",
    };
}

pub fn dimensionToString(d: QuotaDimension) []const u8 {
    return switch (d) {
        .script_cpu => "script_cpu",
        .script_memory => "script_memory",
        .entity_records => "entity_records",
        .entity_storage => "entity_storage",
        .file_bytes => "file_bytes",
        .file_count => "file_count",
        .concurrent_sandboxes => "concurrent_sandboxes",
        .agent_retry_per_job => "agent_retry_per_job",
        .agent_retry_per_day => "agent_retry_per_day",
    };
}

test "evaluateQuota rejects when used plus delta exceeds limit" {
    const profile = EffectiveQuotaProfile{
        .tenant_id = "00000000-0000-0000-0000-000000000000",
        .tier = .standard,
        .script_cpu_millis_per_request = 100,
        .script_memory_bytes_per_request = 100,
        .max_entity_records_total = 100,
        .max_entity_storage_bytes = 100,
        .max_file_bytes_total = 100,
        .max_file_count_total = 100,
        .max_concurrent_sandboxes = 100,
        .max_agent_retries_per_job = 100,
        .max_agent_retries_per_day = 100,
    };

    const decision = evaluateQuota(profile, .{
        .tenant_id = profile.tenant_id,
        .dimension = .entity_records,
        .used = 99,
        .limit = 100,
        .remaining = 1,
    }, 2);

    switch (decision) {
        .allowed => return error.TestUnexpectedResult,
        .rejected => |v| {
            try std.testing.expectEqual(QuotaDimension.entity_records, v.dimension);
            try std.testing.expectEqual(@as(u64, 99), v.used);
            try std.testing.expectEqual(@as(u64, 100), v.limit);
        },
    }
}
