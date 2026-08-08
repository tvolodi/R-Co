//! ISS-0176 / GH #504 — LUA-07 second acceptance criterion: minimal, real
//! engine-side call path that invokes the Lua executor and persists the
//! resulting manifest_hash to a queryable audit record.
//!
//! See src/design/iss0176-lua07-audit-manifest-hash-minimal-wiring.md for the
//! full design, including the human-operator-confirmed scope decision (§0)
//! and the rejected EXT-03 plugin-registry alternative (§2.1).
const std = @import("std");
const db = @import("pool");
// Relative, not named-module: src/lua/mod.zig is deliberately NOT a named
// module anywhere in build.zig (see src/bpm.zig's comment on why) because
// src/lua/host_api/*.zig escapes src/lua/ into ../../simulation/*.zig, which
// in turn reaches ../event_store/store.zig. Any module that reaches this file
// by relative path must therefore be rooted at src/ (not src/engine/) so the
// whole chain stays inside the module root — the same constraint documented
// in src/lua_test_root.zig and src/transition_test_root.zig. This file is
// deliberately NOT re-exported by src/bpm.zig, so it never becomes part of
// bpm_src_mod (which is NOT linked against LuaJIT) — see build.zig's
// dedicated lua_script_audit module for the root that does contain it.
const lua_executor = @import("../lua/executor.zig");
const lua_manifest = @import("../lua/manifest.zig");
const lua_errors = @import("../lua/errors.zig");

/// `executeScriptForAudit` is a MINIMAL LUA-07-completion path. It is **not**
/// the SERVICE_TASK script-execution handler and must not be called from
/// `processServiceTaskRuntimeInTx` or any other normal process-execution flow.
/// It exists to give the engine one real, callable place that (a) invokes
/// `lua.executor.executeScriptWithManifest` and (b) persists the resulting
/// `manifest_hash` to `lua_script_execution_audit` — satisfying LUA-07's second acceptance
/// criterion end-to-end. The general SERVICE_TASK-with-script integration
/// described in `src/design/lua-integration.md` §25 remains unbuilt; when it
/// lands, that work supersedes this function rather than building on it.
pub fn executeScriptForAudit(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    context: *const lua_executor.ExecutionContext,
    script_source: []const u8,
    script_manifest: *const lua_manifest.ScriptManifest,
    registered_hash: [32]u8,
    actor_id_hex: ?[]const u8,
) LuaScriptAuditError!ScriptAuditOutcome {
    // Validate context.instance_id BEFORE calling the executor: a script may
    // still run correctly even if the audit write cannot be attributed, but
    // this function's whole purpose is producing an attributable audit row —
    // so an unparseable instance_id is rejected up front rather than letting
    // the script execute and then discovering the write cannot happen.
    if (!isCanonicalUuidFormat(context.instance_id)) {
        return LuaScriptAuditError.InvalidInstanceId;
    }

    // Step 1 (design §2.2): the real, existing function. No wrapping or
    // mocking of its internals.
    var script_result = try lua_executor.executeScriptWithManifest(
        context,
        script_source,
        script_manifest,
        registered_hash,
    );
    errdefer script_result.deinit(allocator);

    // Step 2/3: persist the audit row on the caller-supplied connection. No
    // BEGIN/COMMIT here — same convention as recordExecutionErrorEventInTx
    // (src/engine/instance.zig:3470): the caller controls the transaction
    // boundary.
    const hash = script_result.manifest_hash orelse registered_hash;
    const hex_hash = hexEncodeAlloc(allocator, &hash) catch return LuaScriptAuditError.OutOfMemory;
    defer allocator.free(hex_hash);

    const success_text: []const u8 = if (script_result.success) "true" else "false";
    // NULLIF($N, '')-on-empty-string convention: db.Conn's params are plain
    // []const u8 (no NULL sentinel in the wire-protocol helper — see
    // vendor/pg/pg.zig's exec/query), so an absent optional is normalised to
    // "" here and converted back to SQL NULL by NULLIF in the query text.
    // Matches src/obs/audit.zig's actor_id/trace_id/pipeline_run_id handling.
    const actor_param: []const u8 = actor_id_hex orelse "";
    const error_message_param: []const u8 = script_result.error_message orelse "";

    // DB query errors propagate unchanged (design §4.2) — no reinterpretation
    // into a new error variant; only the "no row came back" case below (which
    // has no natural db.PoolError counterpart) becomes PersistenceFailed.
    var row = try conn.queryRow(
        allocator,
        \\INSERT INTO lua_script_execution_audit (
        \\  instance_id, actor_id, script_success, manifest_hash, error_message
        \\) VALUES (
        \\  $1::uuid, NULLIF($2, '')::uuid, $3::boolean, decode($4, 'hex'), NULLIF($5, '')
        \\)
        \\RETURNING audit_id::text
    ,
        &.{
            context.instance_id,
            actor_param,
            success_text,
            hex_hash,
            error_message_param,
        },
    );
    defer if (row) |*r| {
        for (r.*) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(r.*);
    };

    const audit_id_row = row orelse return LuaScriptAuditError.PersistenceFailed;
    const audit_id_hex = audit_id_row[0] orelse return LuaScriptAuditError.PersistenceFailed;
    const audit_id = parseUuidBytes(audit_id_hex) catch return LuaScriptAuditError.PersistenceFailed;

    return ScriptAuditOutcome{
        .script_result = script_result,
        .audit_id = audit_id,
    };
}

pub const LuaScriptAuditError = error{
    OutOfMemory,
    InvalidInstanceId,
    /// The INSERT ... RETURNING produced no usable row or an unparseable
    /// audit_id. Distinct from db.PoolError (below), which propagates
    /// unchanged per design §4.2 — this is a new failure mode with no
    /// existing PoolError counterpart.
    PersistenceFailed,
} || lua_errors.LuaError || lua_manifest.ManifestError || db.PoolError;

pub const ScriptAuditOutcome = struct {
    script_result: lua_executor.ScriptResult,
    audit_id: [16]u8,

    // Caller must call script_result.deinit(allocator) — ownership matches
    // every existing executeScript* caller; this function adds no new
    // ownership rule on top of the one that already exists.
};

/// Canonical 36-char hyphenated UUID format check (8-4-4-4-12 hex groups).
/// Mirrors the format `bpm_audit_try_uuid` (migration 020) tolerates on the
/// SQL side, checked here so an unparseable `instance_id` returns the typed
/// `InvalidInstanceId` error rather than `catch unreachable` or a bare
/// Postgres cast failure.
fn isCanonicalUuidFormat(s: []const u8) bool {
    if (s.len != 36) return false;
    const dash_positions = [_]usize{ 8, 13, 18, 23 };
    for (dash_positions) |pos| {
        if (s[pos] != '-') return false;
    }
    for (s, 0..) |c, i| {
        var is_dash = false;
        for (dash_positions) |pos| {
            if (i == pos) is_dash = true;
        }
        if (is_dash) continue;
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!is_hex) return false;
    }
    return true;
}

/// Parse a canonical 36-char hyphenated UUID string into 16 raw bytes.
/// Used only on trusted values already produced by Postgres (RETURNING
/// audit_id), so a malformed value here indicates PersistenceFailed rather
/// than a caller-input error.
fn parseUuidBytes(hex: []const u8) error{InvalidUuid}![16]u8 {
    if (hex.len != 36) return error.InvalidUuid;
    var uuid: [16]u8 = undefined;
    var byte_idx: usize = 0;
    var i: usize = 0;
    while (i < hex.len) {
        if (hex[i] == '-') {
            i += 1;
            continue;
        }
        if (i + 1 >= hex.len) return error.InvalidUuid;
        const hi = hexNibble(hex[i]) catch return error.InvalidUuid;
        const lo = hexNibble(hex[i + 1]) catch return error.InvalidUuid;
        if (byte_idx >= 16) return error.InvalidUuid;
        uuid[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
        i += 2;
    }
    if (byte_idx != 16) return error.InvalidUuid;
    return uuid;
}

fn hexNibble(c: u8) error{InvalidUuid}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidUuid,
    };
}

fn hexEncodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    errdefer allocator.free(out);
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = alphabet[(b >> 4) & 0x0f];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}
