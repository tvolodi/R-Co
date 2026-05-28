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
    _ = allocator;
    _ = pool;
    _ = tenant_id;

    // TODO: Implement repository artifact loading per REPO-08, REPO-09
    // For now, return safe defaults.
    return PlatformConfig{
        .capabilities = CapabilityConfig{},
        .tier_rules = TierSelectionRules{},
        .budget_limits = BudgetLimits{},
        .monitoring = MonitoringConfig{},
    };
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

/// Validate a configuration artifact JSON against schema.
pub fn validateConfigArtifact(
    content_json: []const u8,
    config_kind: ConfigKind,
) ConfigError!void {
    _ = content_json;
    _ = config_kind;

    // TODO: Implement schema validation for each config kind
    // - capabilities: must have tier1_node_timeout_ms, etc.
    // - tier_rules: must have lr_model_selector and rules array
    // - budget_limits: must have llm_tokens_per_day, etc.
    // - monitoring_config: must have alert_on_latency_p99_ms, etc.
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
