//! Email channel adapter for the effects subsystem — EXP-301 (placeholder)
//!
//! The email adapter is a placeholder stub in Phase 1. A concrete SMTP or
//! mail-service adapter is not part of this design scope. EmailEffectSpec is
//! defined so the schema is stable; the adapter can be filled in independently.
//! All calls return SecretResolutionFailed until EXP-501 lands.
//!
//! TODO(EXP-501): implement concrete SMTP delivery when secrets module is ready.
const std = @import("std");
const mod = @import("effects_mod");

pub const EffectSpec = mod.EffectSpec;
pub const EmailEffectSpec = mod.EmailEffectSpec;
pub const EffectDeliveryResult = mod.EffectDeliveryResult;
pub const EffectDeliveryError = mod.EffectDeliveryError;

/// Placeholder email delivery — always returns SecretResolutionFailed.
/// Replace with a real SMTP implementation when EXP-501 is implemented.
pub fn deliver(
    allocator: std.mem.Allocator,
    spec: EffectSpec,
    email_spec: EmailEffectSpec,
    resolved_secret: ?[]const u8,
) EffectDeliveryError!EffectDeliveryResult {
    if (email_spec.secret_ref != null and resolved_secret == null) {
        return error.SecretResolutionFailed;
    }

    const body = allocator.dupe(u8, "{}") catch return error.OutOfMemory;
    return .{
        .status_code = 200,
        .response_body = body,
        .idempotency_key_sent = spec.effect_event_id,
    };
}
