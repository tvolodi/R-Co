//! Platform-event conventions for non-instance-scoped scheduler events.
//! XC-04: no LLM, HTTP, or external service dependencies in this file.

/// Sentinel instance_id for all platform-level EXECUTION_* events.
/// Never inserted into instance_projections.
pub const PLATFORM_INSTANCE_ID: []const u8 = "00000000-0000-0000-0000-0000000000ff";

/// Sentinel actor_id for scheduler-driven events (no human actor).
pub const PLATFORM_ACTOR_ID: []const u8 = "00000000-0000-0000-0000-000000000000";

/// Sentinel tenant_id written into platform events (same as DEFAULT_TENANT_ID).
pub const PLATFORM_TENANT_ID: []const u8 = "00000000-0000-0000-0000-000000000000";
