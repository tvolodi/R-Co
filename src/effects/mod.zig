//! Effects subsystem — EXP-301/302/303 public types and executor interface
//!
//! This module defines the stable public API for the async effects subsystem.
//! All outbound I/O from the execution engine is decoupled via this interface:
//! the engine emits an EFFECT_EMITTED event (pure data); the effects worker
//! delivers it asynchronously; the result re-enters as EFFECT_COMPLETED or
//! EFFECT_FAILED, driving the catch-event node in the process graph.
//!
//! Inviolable invariants:
//!   1. src/engine/transition.zig has zero I/O — this module must never be
//!      imported from transition.zig.
//!   2. The event log is the source of truth; effects_outbox rows are projections
//!      rebuildable from events.
//!   3. All DB writes are atomic co-writes inside the same transaction that
//!      produced the EFFECT_EMITTED event.
const std = @import("std");

// ---------------------------------------------------------------------------
// Effect kind
// ---------------------------------------------------------------------------

pub const EffectKind = enum {
    http_call,
    email,

    pub fn toWire(self: EffectKind) []const u8 {
        return switch (self) {
            .http_call => "http_call",
            .email => "email",
        };
    }

    pub fn fromWire(s: []const u8) ?EffectKind {
        if (std.mem.eql(u8, s, "http_call")) return .http_call;
        if (std.mem.eql(u8, s, "email")) return .email;
        return null;
    }
};

// ---------------------------------------------------------------------------
// Effect specification (embedded in EFFECT_EMITTED event payload)
// ---------------------------------------------------------------------------

/// Stable specification for one outbound effect. Embedded in the
/// EFFECT_EMITTED event payload and in effects_outbox.spec_json.
pub const EffectSpec = struct {
    /// Stable idempotency key sent to the remote as `Idempotency-Key` header.
    /// Set to the UUID of the EFFECT_EMITTED event by the event-store writer.
    effect_event_id: []const u8,

    /// Back-reference to the instance/node that produced this effect.
    instance_id: []const u8,
    node_id: []const u8,
    token_id: []const u8,

    /// Correlation key used to link the result re-entry back to the waiting token.
    /// Format: "<node_id>:<token_id_or_branch_id>" within the instance.
    correlation_key: []const u8,

    kind: EffectKind,

    /// Kind-specific JSON payload (HttpEffectSpec or EmailEffectSpec serialised).
    spec_json: []const u8,
};

/// HTTP outbound effect specification.
pub const HttpEffectSpec = struct {
    url: []const u8,
    method: []const u8, // "POST" | "GET" | "PUT" | "PATCH" | "DELETE"
    headers_json: ?[]const u8, // JSON object; Idempotency-Key injected by worker
    body_json: ?[]const u8,
    timeout_ms: u32,
    retry_limit: u8,
    /// Secret reference resolved via EXP-501 at delivery time.
    /// If non-null and EXP-501 is not yet implemented, delivery returns
    /// EffectDeliveryError.SecretResolutionFailed.
    // TODO(EXP-501): resolve secret_ref via secrets module when available.
    secret_ref: ?[]const u8,
};

/// Email outbound effect specification (placeholder — EXP-501 dependency).
pub const EmailEffectSpec = struct {
    to: []const u8,
    subject: []const u8,
    body: []const u8,
    // TODO(EXP-501): resolve SMTP credential reference.
    secret_ref: ?[]const u8,
};

// ---------------------------------------------------------------------------
// Delivery result and error types
// ---------------------------------------------------------------------------

pub const EffectDeliveryResult = struct {
    status_code: u16,
    response_body: ?[]u8, // caller owns memory
    idempotency_key_sent: []const u8,
};

pub const EffectDeliveryError = error{
    /// TCP/TLS-level transport failure — retry.
    TransportError,
    /// Per-call deadline exceeded — retry.
    Timeout,
    /// EXP-501 secret reference not resolvable — retry (infrastructure concern).
    // TODO(EXP-501): remove once secrets module lands.
    SecretResolutionFailed,
    OutOfMemory,
    /// spec_json failed to deserialise — DLQ immediately, no retry.
    InvalidSpec,
};

// ---------------------------------------------------------------------------
// Executor vtable interface
// ---------------------------------------------------------------------------

/// Vtable for effect executors. Implementations: http.zig adapter, stub.zig.
pub const EffectExecutorVTable = struct {
    /// Attempt one delivery. Returns the HTTP status code (for HTTP kind) or a
    /// synthetic status code (200 = success, 0 = undeliverable) for other kinds.
    /// Non-blocking with respect to the effects worker main loop.
    execute: *const fn (
        allocator: std.mem.Allocator,
        spec: EffectSpec,
        attempt: u8,
    ) EffectDeliveryError!EffectDeliveryResult,
};

// ---------------------------------------------------------------------------
// Error sets for queue and re-entry
// ---------------------------------------------------------------------------

pub const EffectQueueError = error{
    PersistenceFailed,
    OutOfMemory,
};

pub const EffectReentryError = error{
    /// Instance was deleted before re-entry could fire.
    InstanceNotFound,
    /// Catch-event node was not waiting (idempotent skip — already fired).
    CorrelationKeyNotFound,
    /// Engine transition returned an error state.
    TransitionFailed,
    PersistenceFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Backoff schedule (reuses ISS-205 constants)
// ---------------------------------------------------------------------------

/// Backoff delays in milliseconds, indexed by attempt number (0-based).
/// attempt 0 → 5_000 ms (first retry after initial failure)
/// attempt 4 → 1_800_000 ms (30 min, final slot before DLQ)
pub const EFFECT_BACKOFF_MS = [_]u32{
    5_000,
    30_000,
    120_000,
    600_000,
    1_800_000,
};

pub const EFFECT_MAX_ATTEMPTS: u8 = 5;

/// Compute the back-off delay in milliseconds for a given attempt number.
/// attempt_count is the current value from effects_outbox (0-based after first try).
/// Returns the capped delay for the next attempt.
pub fn computeEffectBackoffMs(attempt_count: u8) u32 {
    if (attempt_count >= EFFECT_BACKOFF_MS.len) {
        return EFFECT_BACKOFF_MS[EFFECT_BACKOFF_MS.len - 1];
    }
    return EFFECT_BACKOFF_MS[attempt_count];
}

// ---------------------------------------------------------------------------
// HTTP outcome classification
// ---------------------------------------------------------------------------

pub const HttpOutcome = enum {
    success,
    retry,
    permanent,
};

/// Classify an HTTP status code into the retry / DLQ / success decision.
/// HTTP 4xx (except 429) → permanent failure → DLQ.
/// HTTP 3xx → permanent failure (no auto-follow) → DLQ.
/// HTTP 429, 5xx → retry.
/// HTTP 2xx → success.
pub fn classifyHttpOutcome(status_code: u16) HttpOutcome {
    if (status_code >= 200 and status_code <= 299) return .success;
    if (status_code >= 300 and status_code <= 399) return .permanent; // no redirect follow
    if (status_code == 429) return .retry;
    if (status_code >= 400 and status_code <= 499) return .permanent;
    if (status_code >= 500) return .retry;
    return .permanent; // unknown
}

// ---------------------------------------------------------------------------
// Correlation key helpers
// ---------------------------------------------------------------------------

/// Build the correlation key for a service task token.
/// Format: "<node_id>:<token_id_or_branch_id>".
/// This key is embedded in both the EFFECT_EMITTED event and the
/// effects_outbox row. The effects worker passes it to reenterEffectResult().
pub fn buildCorrelationKey(
    allocator: std.mem.Allocator,
    node_id: []const u8,
    token_id: []const u8,
) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ node_id, token_id });
}
