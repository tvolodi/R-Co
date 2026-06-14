//! XC-03: Platform Configuration Loader
//!
//! Loads platform configuration from repository artifacts per XC-03 specification.
//! Configuration includes capability defaults, tier selection rules, budget limits,
//! monitoring thresholds, and identity provider config.
//!
//! Configuration artifacts are immutable, versioned, and activated per-tenant
//! using the same artifact lifecycle as process definitions (REPO-*).

const std = @import("std");
const db = @import("pool");

/// Configuration categories stored as repository artifacts.
pub const ConfigKind = enum {
    capabilities,
    tier_rules,
    budget_limits,
    monitoring_config,
    oidc_config,
    quota_policy,
};

/// Per-node capability timeouts (milliseconds).
pub const CapabilityConfig = struct {
    tier1_node_timeout_ms: u32 = 30_000,    // 30 seconds
    tier2_node_timeout_ms: u32 = 120_000,   // 2 minutes
    tier3_node_timeout_ms: u32 = 300_000,   // 5 minutes
    user_task_timeout_ms: u32 = 86_400_000, // 24 hours
    service_task_timeout_ms: u32 = 60_000,  // 1 minute
};

/// Tier selection rules for LLM model selection.
pub const TierSelectionRules = struct {
    lr_model_selector: []const u8 = "size_based",
    rules: []const TierRule = &[_]TierRule{},
};

pub const TierRule = struct {
    name: []const u8,
    selector: []const u8,
};

/// Budget limits for LLM and service usage.
pub const BudgetLimits = struct {
    llm_tokens_per_day: u64 = 1_000_000,
    service_calls_per_minute: u32 = 1000,
    max_concurrent_instances: u32 = 10_000,
};

/// Monitoring and alerting thresholds.
pub const MonitoringConfig = struct {
    alert_on_latency_p99_ms: u32 = 500,
    alert_on_error_rate: f32 = 0.05,
    alert_on_queue_depth: u32 = 1000,
};

/// Complete platform configuration.
pub const PlatformConfig = struct {
    capabilities: CapabilityConfig,
    tier_rules: TierSelectionRules,
    budget_limits: BudgetLimits,
    monitoring: MonitoringConfig,

    pub fn deinit(self: PlatformConfig, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // No dynamic allocations in default config; subclasses may need cleanup
    }
};

pub const ConfigError = error{
    ConfigNotFound,
    ConfigParseError,
    ConfigValidationError,
    DatabaseError,
    OutOfMemory,
};

/// Load active configuration for a tenant.
///
/// Reads configuration artifacts from the repository that are currently activated
/// for the given tenant. Returns default safe values for missing configuration.
///
/// Configuration is NOT cached; reads from repository on every call.
/// Callers may wrap this in a TTL cache if high-frequency reads are needed.
pub fn loadActiveConfig(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    tenant_id: []const u8,
) ConfigError!PlatformConfig {
    var config = PlatformConfig{
        .capabilities = CapabilityConfig{},
        .tier_rules = TierSelectionRules{},
        .budget_limits = BudgetLimits{},
        .monitoring = MonitoringConfig{},
    };

    if (loadConfigArtifact(allocator, pool, tenant_id, .capabilities, "capabilities")) |maybe_json| {
        if (maybe_json) |json| {
            defer allocator.free(json);
            parseCapabilities(json, &config.capabilities) catch {};
        }
    } else |_| {}

    if (loadConfigArtifact(allocator, pool, tenant_id, .tier_rules, "tier_rules")) |maybe_json| {
        if (maybe_json) |json| {
            defer allocator.free(json);
        }
    } else |_| {}

    if (loadConfigArtifact(allocator, pool, tenant_id, .budget_limits, "budget_limits")) |maybe_json| {
        if (maybe_json) |json| {
            defer allocator.free(json);
            parseBudgetLimits(json, &config.budget_limits) catch {};
        }
    } else |_| {}

    if (loadConfigArtifact(allocator, pool, tenant_id, .monitoring_config, "monitoring_config")) |maybe_json| {
        if (maybe_json) |json| {
            defer allocator.free(json);
            parseMonitoringConfig(json, &config.monitoring) catch {};
        }
    } else |_| {}

    return config;
}

fn parseU32FromJson(key: []const u8, json: []const u8) ?u32 {
    var search: []const u8 = json;
    while (search.len > 0) {
        const key_start = std.mem.indexOf(u8, search, key) orelse return null;
        const remaining = search[key_start + key.len ..];
        if (remaining.len == 0) return null;
        if (remaining[0] != ':') {
            search = remaining;
            continue;
        }
        const val_start = remaining[1..];
        var i: usize = 0;
        while (i < val_start.len and val_start[i] == ' ') : (i += 1) {}
        if (i >= val_start.len) return null;
        const digits = val_start[i..];
        var end: usize = 0;
        while (end < digits.len and std.ascii.isDigit(digits[end])) : (end += 1) {}
        if (end == 0) return null;
        return std.fmt.parseUnsigned(u32, digits[0..end], 10) catch null;
    }
    return null;
}

fn parseF32FromJson(key: []const u8, json: []const u8) ?f32 {
    const key_pat = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(key_pat);
    const idx = std.mem.indexOf(u8, json, key_pat) orelse return null;
    const after = json[idx + key_pat.len ..];
    var i: usize = 0;
    while (i < after.len and after[i] == ' ') : (i += 1) {}
    if (i >= after.len) return null;
    const start = after[i..];
    var end: usize = 0;
    while (end < start.len and (std.ascii.isDigit(start[end]) or start[end] == '.' or start[end] == '-' or start[end] == 'e' or start[end] == 'E')) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseFloat(f32, start[0..end]) catch null;
}

fn parseCapabilities(json: []const u8, out: *CapabilityConfig) error{}!void {
    if (parseU32FromJson("tier1_node_timeout_ms", json)) |v| out.*.tier1_node_timeout_ms = v;
    if (parseU32FromJson("tier2_node_timeout_ms", json)) |v| out.*.tier2_node_timeout_ms = v;
    if (parseU32FromJson("tier3_node_timeout_ms", json)) |v| out.*.tier3_node_timeout_ms = v;
    if (parseU32FromJson("user_task_timeout_ms", json)) |v| out.*.user_task_timeout_ms = v;
    if (parseU32FromJson("service_task_timeout_ms", json)) |v| out.*.service_task_timeout_ms = v;
}

fn parseBudgetLimits(json: []const u8, out: *BudgetLimits) error{}!void {
    if (parseU32FromJson("service_calls_per_minute", json)) |v| out.*.service_calls_per_minute = v;
}

fn parseMonitoringConfig(json: []const u8, out: *MonitoringConfig) error{}!void {
    if (parseU32FromJson("alert_on_latency_p99_ms", json)) |v| out.*.alert_on_latency_p99_ms = v;
    if (parseF32FromJson("alert_on_error_rate", json)) |v| out.*.alert_on_error_rate = v;
    if (parseU32FromJson("alert_on_queue_depth", json)) |v| out.*.alert_on_queue_depth = v;
}

/// Load a specific configuration artifact by kind and name.
pub fn loadConfigArtifact(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    tenant_id: []const u8,
    kind: ConfigKind,
    artifact_name: []const u8,
) ConfigError!?[]const u8 {
    const kind_name: []const u8 = switch (kind) {
        .capabilities => "config",
        .tier_rules => "config",
        .budget_limits => "config",
        .monitoring_config => "config",
        .oidc_config => "config",
        .quota_policy => "config",
    };

    const conn = pool.acquire() catch return ConfigError.DatabaseError;
    defer pool.release(conn);

    var rows = conn.query(
        allocator,
        \\SELECT ra.content_json::text
        \\FROM tenant_artifact_activations taa
        \\JOIN repository_artifacts ra ON ra.version_id = taa.active_version_id
        \\WHERE taa.tenant_id = $1
        \\  AND taa.artifact_kind = $2
        \\  AND taa.artifact_name = $3
        \\LIMIT 1
    ,
        &.{ tenant_id, kind_name, artifact_name },
    ) catch return ConfigError.DatabaseError;
    defer rows.deinit();

    if (rows.rows.len == 0) return null;

    const content_json = rows.rows[0][0] orelse return null;
    return allocator.dupe(u8, content_json) catch ConfigError.OutOfMemory;
}

/// Load active EXP-601 quota policy JSON for a tenant.
pub fn loadActiveQuotaPolicy(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    tenant_id: []const u8,
) ConfigError!?[]const u8 {
    return loadConfigArtifact(allocator, pool, tenant_id, .quota_policy, "tier_quota_policy");
}

/// Validate a configuration artifact JSON against schema.
pub fn validateConfigArtifact(
    content_json: []const u8,
    config_kind: ConfigKind,
) ConfigError!void {
    if (content_json.len == 0) return ConfigError.ConfigValidationError;
    if (content_json[0] != '{') return ConfigError.ConfigValidationError;

    switch (config_kind) {
        .capabilities => {
            if (!std.mem.containsAtLeast(u8, content_json, 1, "tier1_node_timeout_ms"))
                return ConfigError.ConfigValidationError;
        },
        .tier_rules => {
            if (!std.mem.containsAtLeast(u8, content_json, 1, "lr_model_selector"))
                return ConfigError.ConfigValidationError;
        },
        .budget_limits => {
            if (!std.mem.containsAtLeast(u8, content_json, 1, "llm_tokens_per_day"))
                return ConfigError.ConfigValidationError;
        },
        .monitoring_config => {
            if (!std.mem.containsAtLeast(u8, content_json, 1, "alert_on_latency_p99_ms"))
                return ConfigError.ConfigValidationError;
        },
        .oidc_config => {
            if (!std.mem.containsAtLeast(u8, content_json, 1, "providers"))
                return ConfigError.ConfigValidationError;
        },
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ──────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "loadActiveConfig: returns default safe values" {
    const config = try loadActiveConfig(testing.allocator, undefined, "00000000-0000-0000-0000-000000000000");
    try testing.expectEqual(@as(u32, 30_000), config.capabilities.tier1_node_timeout_ms);
    try testing.expectEqual(@as(u32, 120_000), config.capabilities.tier2_node_timeout_ms);
}
