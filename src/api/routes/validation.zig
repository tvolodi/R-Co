//! HTTP route handler for the VLD-01/02/03 semantic-validation endpoint.
//!
//! Requirement IDs: VLD-01, VLD-02, VLD-03
//! Design artefact:  src/design/vld-01-03-stage-16-validation.md §5.2, §11
//!
//! `POST /api/v1/definitions/:id/validate` — runs `validation.validateDefinition`
//! against the stored definition's graph and emits:
//!   - 200 OK with `{"status": "semantically_valid", ...}` when clean;
//!   - 422 Unprocessable Entity with the RFC 9457 Problem Details body when
//!     findings are produced (VLD-01/02/03 wire format).
//!
//! The env sources (variable_schema, service_results, module_outputs,
//! form_fields) are extracted from the in-memory `Definition` struct — no DB
//! reads are needed here because the orchestrator already passes the graph
//! in. When the platform's variable_schemas table is the source of truth
//! (the production deployment), VLD-04 will pre-fetch those rows and pass
//! them in here; this handler accepts the JSON body's `variable_schema`
//! override so VLD-04 can drop in without further rewiring.
//!
//! Auth: PROCESS_DESIGNER or PLATFORM_ADMIN — enforced by upstream middleware
//! (the router registers this handler in the same auth context as the
//! existing definition endpoints).
//!
//! Tenant scoping: `tenant_id` from the authenticated request is set on the
//! ambient tenant context (`api_tenant_context.set`) for the duration of the
//! DB read, then cleared. This is defence in depth on top of the
//! `process_definitions` RLS policy (see migrations/028_adp02_tenant_scope_
//! persistence.sql §process_definitions_tenant_policy) — even if RLS were
//! disabled or the connection were reused from a previous request with a
//! different tenant, the handler refuses to read another tenant's row.
//! Cross-tenant reads fall through as `DefinitionNotFound` (HTTP 404).

const std = @import("std");
const definition_store = @import("../../definition/store.zig");
const graph_mod = @import("graph");
// validation is exposed by build.zig as the `validation` named module —
// single-owner module rule (Zig 0.16) forbids a relative `@import` from
// src/api/routes/ into src/validation/ since validation/test_root.zig is
// its own module root.
const validation = @import("validation");
// VLD-04 (WF02-batch-7-20260816): the semantic gate wrapping the pure
// pipeline. Exposed by build.zig as the `validation_gate` named module.
const validation_gate = @import("validation_gate");
const api_tenant_context = @import("tenant_context");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Handler result (mirrors the convention of src/api/routes/definitions.zig).
pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

// ---------------------------------------------------------------------------
// handleValidate — POST /api/v1/definitions/:id/validate
// ---------------------------------------------------------------------------

/// Run VLD-04's semantic gate on the stored definition.
///
/// `tenant_id` is the 36-char UUID resolved by API-08 auth middleware for the
/// current request. The handler sets the ambient tenant context for the DB
/// read so the RLS policy on `process_definitions` cannot return a row owned
/// by another tenant; cross-tenant reads fall through as `DefinitionNotFound`
/// (HTTP 404).
///
/// Success: HTTP 200 + JSON `{"status":"semantically_valid", ...}`.
/// Findings present: HTTP 422 + JSON Problem Details body.
/// Budget expired: HTTP 422 + `validation timeout`.
/// Definition not found: HTTP 404 + JSON error body.
/// Invalid id: HTTP 422 + JSON error body.
/// Pool exhausted: HTTP 503.
/// Server error: HTTP 500.
pub fn handleValidate(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    tenant_id: [36]u8,
    id_str: []const u8,
) HandlerResult {
    // Validate the id format up front (422 on malformed) without touching the
    // store; the gate performs the actual tenant-scoped read.
    _ = parseUuid(id_str) catch {
        return errorResult(allocator, 422, "invalid id format");
    };

    // Defence in depth: pin the ambient tenant context for the duration of the
    // DB read. `process_definitions` is a PER_TENANT table reached via the
    // pool's SCHEMA-mode search_path routing (tenant_context.set() applied on
    // connection checkout); re-asserting here makes the handler
    // self-documenting and closes the gap if a future refactor caches/reuses
    // connections across tenant boundaries.
    api_tenant_context.set(tenant_id[0..]);
    defer api_tenant_context.clear();

    // VLD-04: run the semantic gate — it fetches the stored graph, runs the
    // VLD-01/02/03 pipeline under the 5 s budget, records the verdict on the
    // definition version (semantically_valid + COMPILER_VERSION) and appends
    // DEFINITION_VALIDATED / DEFINITION_VALIDATION_FAILED. check_stored_first
    // reuses a current + valid stored verdict without recompiling (AC3).
    const gate = validation_gate.runSemanticGate(
        allocator,
        store.pool,
        id_str,
        5_000,
        true,
    ) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service unavailable"),
        else => return errorResult(allocator, 500, "internal server error"),
    };

    switch (gate) {
        .valid => |verdict| {
            const body = validation.serialiseSuccess(
                allocator,
                verdict.validated_at orelse "",
                verdict.compiler_version orelse "",
            ) catch {
                validation_gate.freeValid(allocator, verdict);
                return errorResult(allocator, 500, "serialization failed");
            };
            validation_gate.freeValid(allocator, verdict);
            return .{ .status_code = 200, .body = body };
        },
        .invalid => |inv| {
            const failure = validation_gate.failureFromInvalid(inv);
            const body = validation.serialiseValidationFailure(allocator, failure) catch {
                validation_gate.freeInvalid(allocator, inv);
                return errorResult(allocator, 500, "serialization failed");
            };
            validation_gate.freeInvalid(allocator, inv);
            return .{ .status_code = 422, .body = body };
        },
        // VLD-04 AC4 — compilation exceeded the 5 s budget; caller maps to
        // HTTP 422 ValidationTimeout.
        .timeout => return errorResult(allocator, 422, "validation timeout"),
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn parseUuid(id_str: []const u8) !graph_mod.Uuid {
    var out: graph_mod.Uuid = undefined;
    if (id_str.len != 32) return error.InvalidFormat;
    for (0..32) |i| {
        const c = id_str[i];
        const v: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.InvalidFormat,
        };
        const byte_idx = i / 2;
        if (i % 2 == 0) {
            out[byte_idx] = v << 4;
        } else {
            out[byte_idx] |= v;
        }
    }
    return out;
}

fn errorResult(allocator: std.mem.Allocator, status: u16, message: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"{s}\",\"status\":{d}}}",
        .{ message, status },
    ) catch "{\"error\":\"internal\"}";
    return .{ .status_code = status, .body = body };
}
