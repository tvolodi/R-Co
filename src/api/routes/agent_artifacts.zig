//! AGT-01..04 — Agent artifact submission handlers.
//!
//! POST /api/v1/agent/artifacts         — submit a typed artifact envelope
//! GET  /api/v1/agent/artifacts/schemas — list versioned payload schemas

const std = @import("std");
const db = @import("pool");
const auth_mod = @import("../../api/middleware/auth.zig");
const audit_mod = @import("../../obs/audit.zig");
const trace_context = @import("../../api/trace_context.zig");
const json_schema = @import("json_schema");

pub const HandlerResult = auth_mod.HandlerResult;

// ── Per-kind payload schemas (version 1.0.0, additionalProperties: false) ────

const SCHEMA_TEST_REPORT: []const u8 =
    \\{"type":"object","required":["suite_id","run_id","passed","failed","skipped","duration_ms","assertions"],"additionalProperties":false,"properties":{"suite_id":{"type":"string"},"run_id":{"type":"string"},"passed":{"type":"integer","minimum":0},"failed":{"type":"integer","minimum":0},"skipped":{"type":"integer","minimum":0},"duration_ms":{"type":"integer","minimum":0},"assertions":{"type":"array","items":{"type":"object","required":["name","passed"],"additionalProperties":false,"properties":{"name":{"type":"string"},"passed":{"type":"boolean"},"message":{"type":"string"},"duration_ms":{"type":"integer"}}}},"coverage_pct":{"type":"number"},"error_summary":{"type":"string"}}}
;

const SCHEMA_DESIGN_ARTIFACT: []const u8 =
    \\{"type":"object","required":["artifact_path","format","content_hash","schema_version"],"additionalProperties":false,"properties":{"artifact_path":{"type":"string"},"format":{"type":"string","enum":["markdown","yaml","json"]},"content_hash":{"type":"string"},"schema_version":{"type":"string"},"description":{"type":"string"},"open_issues":{"type":"array","items":{"type":"string"}}}}
;

const SCHEMA_PATCH_SET: []const u8 =
    \\{"type":"object","required":["base_commit","patches","total_files","total_lines_added","total_lines_removed"],"additionalProperties":false,"properties":{"base_commit":{"type":"string"},"patches":{"type":"array","items":{"type":"object","required":["file_path","diff_hash"],"additionalProperties":false,"properties":{"file_path":{"type":"string"},"diff_hash":{"type":"string"},"lines_added":{"type":"integer"},"lines_removed":{"type":"integer"}}}},"total_files":{"type":"integer","minimum":1},"total_lines_added":{"type":"integer","minimum":0},"total_lines_removed":{"type":"integer","minimum":0}}}
;

const SCHEMA_SCENARIO_RUN: []const u8 =
    \\{"type":"object","required":["scenario_id","seed","passed","step_results"],"additionalProperties":false,"properties":{"scenario_id":{"type":"string"},"seed":{"type":"integer"},"passed":{"type":"boolean"},"step_results":{"type":"array","items":{"type":"object","required":["step_id","passed"],"additionalProperties":false,"properties":{"step_id":{"type":"string"},"passed":{"type":"boolean"},"message":{"type":"string"},"elapsed_ms":{"type":"integer"}}}},"elapsed_ms":{"type":"integer","minimum":0},"assertion_count":{"type":"integer","minimum":0}}}
;

// ── Helpers ───────────────────────────────────────────────────────────────────

fn getKindSchemaJson(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "test_report")) return SCHEMA_TEST_REPORT;
    if (std.mem.eql(u8, kind, "design_artifact")) return SCHEMA_DESIGN_ARTIFACT;
    if (std.mem.eql(u8, kind, "patch_set")) return SCHEMA_PATCH_SET;
    return SCHEMA_SCENARIO_RUN; // "scenario_run" — guarded by isKnownKind before called
}

fn svc503() HandlerResult {
    return .{ .status_code = 503, .body = "{\"error\":\"service_unavailable\",\"status\":503}" };
}

fn unknownKind400(allocator: std.mem.Allocator, received: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"unknown_artifact_kind\",\"received\":\"{s}\",\"accepted\":[\"test_report\",\"design_artifact\",\"patch_set\",\"scenario_run\"],\"status\":400}}",
        .{received},
    ) catch "{\"error\":\"unknown_artifact_kind\",\"status\":400}";
    return .{ .status_code = 400, .body = body };
}

fn payloadInvalid422(allocator: std.mem.Allocator, pointer: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"artifact_payload_invalid\",\"pointer\":\"{s}\",\"status\":422}}",
        .{pointer},
    ) catch "{\"error\":\"artifact_payload_invalid\",\"status\":422}";
    return .{ .status_code = 422, .body = body };
}

fn wrongEnv403() HandlerResult {
    return .{ .status_code = 403, .body = "{\"error\":\"wrong_environment\",\"status\":403}" };
}

fn taskSpecNotFound404(allocator: std.mem.Allocator, spec_hash: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"task_spec_not_found\",\"spec_hash\":\"{s}\",\"status\":404}}",
        .{spec_hash},
    ) catch "{\"error\":\"task_spec_not_found\",\"status\":404}";
    return .{ .status_code = 404, .body = body };
}

fn specHashMismatch409(allocator: std.mem.Allocator, stored: []const u8, submitted: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"spec_hash_mismatch\",\"stored_spec_hash\":\"{s}\",\"submitted_spec_hash\":\"{s}\",\"status\":409}}",
        .{ stored, submitted },
    ) catch "{\"error\":\"spec_hash_mismatch\",\"status\":409}";
    return .{ .status_code = 409, .body = body };
}

fn attemptRegressed409(allocator: std.mem.Allocator, submitted: i64, max_stored: i64) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"attempt_count_regressed\",\"submitted_attempt\":{d},\"max_stored_attempt\":{d},\"status\":409}}",
        .{ submitted, max_stored },
    ) catch "{\"error\":\"attempt_count_regressed\",\"status\":409}";
    return .{ .status_code = 409, .body = body };
}

/// Serialise a `std.json.Value` to a heap-allocated JSON byte string.
fn serialiseJsonValue(allocator: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendJsonVal(allocator, &buf, value);
    return buf.toOwnedSlice(allocator);
}

fn appendJsonVal(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: std.json.Value) error{OutOfMemory}!void {
    switch (value) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .number_string => |s| try buf.appendSlice(allocator, s),
        .string => |s| {
            try buf.append(allocator, '"');
            for (s) |c| switch (c) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                else => try buf.append(allocator, c),
            };
            try buf.append(allocator, '"');
        },
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, idx| {
                if (idx > 0) try buf.append(allocator, ',');
                try appendJsonVal(allocator, buf, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, entry.key_ptr.*);
                try buf.appendSlice(allocator, "\":");
                try appendJsonVal(allocator, buf, entry.value_ptr.*);
            }
            try buf.append(allocator, '}');
        },
    }
}

// ── GET /api/v1/agent/artifacts/schemas ───────────────────────────────────────

/// Return the versioned schema catalog for all four artifact kinds.
pub fn handleSchemaCatalog(allocator: std.mem.Allocator) HandlerResult {
    _ = allocator;
    const body =
        "{\"schemas\":[" ++
        "{\"kind\":\"test_report\",\"version\":\"1.0.0\",\"schema\":" ++ SCHEMA_TEST_REPORT ++ "}," ++
        "{\"kind\":\"design_artifact\",\"version\":\"1.0.0\",\"schema\":" ++ SCHEMA_DESIGN_ARTIFACT ++ "}," ++
        "{\"kind\":\"patch_set\",\"version\":\"1.0.0\",\"schema\":" ++ SCHEMA_PATCH_SET ++ "}," ++
        "{\"kind\":\"scenario_run\",\"version\":\"1.0.0\",\"schema\":" ++ SCHEMA_SCENARIO_RUN ++ "}" ++
        "]}";
    return .{ .status_code = 200, .body = body };
}

// ── POST /api/v1/agent/artifacts ──────────────────────────────────────────────

/// Submit an artifact envelope.
/// production_mode is derived from the deployment config at startup — never from the request.
pub fn handleArtifactSubmit(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    auth: auth_mod.AuthContext,
    body: []const u8,
    production_mode: bool,
) HandlerResult {
    const tenant_id: []const u8 = auth.tenant_id[0..];
    const trace_id = trace_context.get();

    // [1] AGT-02: environment gate — fires BEFORE any JSON parsing.
    if (production_mode) {
        const conn = pool.acquire() catch return wrongEnv403();
        defer pool.release(conn);
        const after_state = std.fmt.allocPrint(
            allocator,
            "{{\"event_type\":\"ArtifactSubmissionRejected\",\"environment_class\":\"production\",\"principal\":\"{s}\"}}",
            .{auth.user_id},
        ) catch null;
        if (after_state) |a| {
            const audit_id = audit_mod.writeAuditInTx(
                allocator,
                conn,
                tenant_id,
                auth.user_id,
                "artifact.submission_rejected",
                "agent_artifact",
                "none",
                null,
                a,
                trace_id,
                null,
            ) catch null;
            if (audit_id) |id| allocator.free(id);
        }
        return wrongEnv403();
    }

    // [2] Parse envelope body.
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return .{ .status_code = 400, .body = "{\"error\":\"malformed_json\",\"status\":400}" };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return .{ .status_code = 400, .body = "{\"error\":\"malformed_json\",\"status\":400}" },
    };

    // [3] AGT-01: extract and validate `kind`.
    const kind: []const u8 = switch (root_obj.get("kind") orelse .null) {
        .string => |s| s,
        else => return .{ .status_code = 400, .body = "{\"error\":\"missing_field_kind\",\"status\":400}" },
    };
    var kind_known = false;
    for ([_][]const u8{ "test_report", "design_artifact", "patch_set", "scenario_run" }) |k| {
        if (std.mem.eql(u8, kind, k)) {
            kind_known = true;
            break;
        }
    }
    if (!kind_known) return unknownKind400(allocator, kind);

    // [4] Extract remaining envelope fields.
    const task_spec_id_str: []const u8 = switch (root_obj.get("task_spec_id") orelse .null) {
        .string => |s| s,
        else => return .{ .status_code = 400, .body = "{\"error\":\"missing_field_task_spec_id\",\"status\":400}" },
    };
    const attempt_count_val: i64 = switch (root_obj.get("attempt_count") orelse .null) {
        .integer => |n| n,
        else => return .{ .status_code = 400, .body = "{\"error\":\"missing_field_attempt_count\",\"status\":400}" },
    };
    const spec_hash_str: []const u8 = switch (root_obj.get("spec_hash") orelse .null) {
        .string => |s| s,
        else => return .{ .status_code = 400, .body = "{\"error\":\"missing_field_spec_hash\",\"status\":400}" },
    };
    const payload_val: std.json.Value = root_obj.get("payload") orelse
        return .{ .status_code = 400, .body = "{\"error\":\"missing_field_payload\",\"status\":400}" };

    // [5] AGT-01: validate payload against the kind-selected closed schema.
    const schema_json = getKindSchemaJson(kind);
    const parsed_schema = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        schema_json,
        .{ .allocate = .alloc_always },
    ) catch return svc503();
    defer parsed_schema.deinit();

    const violations = json_schema.validateCollect(allocator, payload_val, parsed_schema.value) catch return svc503();
    defer json_schema.deinitViolations(allocator, violations);

    if (violations.len > 0) {
        const first_ptr = violations[0].path;
        const pointer = if (first_ptr.len == 0) "/" else first_ptr;
        return payloadInvalid422(allocator, pointer);
    }

    // Serialise payload to JSON string for the DB INSERT.
    const payload_json = serialiseJsonValue(allocator, payload_val) catch return svc503();
    defer allocator.free(payload_json);

    // Extract optional non_deterministic_fields.
    const ndf_json: ?[]u8 = blk: {
        const ndf_val = root_obj.get("non_deterministic_fields") orelse break :blk null;
        if (ndf_val == .null) break :blk null;
        break :blk serialiseJsonValue(allocator, ndf_val) catch null;
    };
    defer if (ndf_json) |n| allocator.free(n);

    const conn = pool.acquire() catch return svc503();
    defer pool.release(conn);

    // [6] AGT-04: verify spec_hash exists in task_specs.
    const spec_row = conn.queryRow(
        allocator,
        \\SELECT task_spec_id::text FROM task_specs WHERE spec_hash = $1
    ,
        &.{spec_hash_str},
    ) catch return svc503();

    if (spec_row == null) return taskSpecNotFound404(allocator, spec_hash_str);

    const db_task_spec_id: []u8 = blk: {
        const r = spec_row.?;
        defer {
            for (r) |col| if (col) |c| allocator.free(c);
            allocator.free(r);
        }
        break :blk allocator.dupe(u8, r[0] orelse task_spec_id_str) catch return svc503();
    };
    defer allocator.free(db_task_spec_id);

    // [7] AGT-03: attempt-count regression guard.
    const max_row = conn.queryRow(
        allocator,
        \\SELECT MAX(attempt_count)::text FROM staging.agent_artifacts
        \\WHERE tenant_id = $1::uuid AND task_spec_id = $2::uuid
    ,
        &.{ tenant_id, db_task_spec_id },
    ) catch return svc503();
    if (max_row) |r| {
        defer {
            for (r) |col| if (col) |c| allocator.free(c);
            allocator.free(r);
        }
        if (r[0]) |max_str| {
            const max_attempt = std.fmt.parseInt(i64, max_str, 10) catch 0;
            if (attempt_count_val < max_attempt) {
                return attemptRegressed409(allocator, attempt_count_val, max_attempt);
            }
        }
    }

    // [8] AGT-03: idempotency INSERT … ON CONFLICT … DO UPDATE … RETURNING xmax.
    const attempt_str = std.fmt.allocPrint(allocator, "{d}", .{attempt_count_val}) catch return svc503();
    defer allocator.free(attempt_str);

    const raw_row = if (ndf_json) |ndf|
        conn.queryRow(
            allocator,
            \\INSERT INTO staging.agent_artifacts
            \\    (tenant_id, task_spec_id, attempt_count, kind, spec_hash, payload, non_deterministic_fields)
            \\VALUES ($1::uuid, $2::uuid, $3::integer, $4, $5, $6::jsonb, $7::jsonb)
            \\ON CONFLICT (tenant_id, task_spec_id, attempt_count)
            \\    DO UPDATE SET touched_at = now()
            \\RETURNING artifact_id::text, RTRIM(spec_hash),
            \\    to_char(touched_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            \\    to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            \\    (xmax = 0)::text
        ,
            &.{ tenant_id, db_task_spec_id, attempt_str, kind, spec_hash_str, payload_json, ndf },
        )
    else
        conn.queryRow(
            allocator,
            \\INSERT INTO staging.agent_artifacts
            \\    (tenant_id, task_spec_id, attempt_count, kind, spec_hash, payload)
            \\VALUES ($1::uuid, $2::uuid, $3::integer, $4, $5, $6::jsonb)
            \\ON CONFLICT (tenant_id, task_spec_id, attempt_count)
            \\    DO UPDATE SET touched_at = now()
            \\RETURNING artifact_id::text, RTRIM(spec_hash),
            \\    to_char(touched_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            \\    to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            \\    (xmax = 0)::text
        ,
            &.{ tenant_id, db_task_spec_id, attempt_str, kind, spec_hash_str, payload_json },
        );

    const insert_row = raw_row catch return svc503();
    if (insert_row == null) return svc503();

    // Extract RETURNING columns; dupe before freeing row.
    var r_art_id: []u8 = &.{};
    var r_stored_hash: []u8 = &.{};
    var r_touched_at: []u8 = &.{};
    var r_created_at: []u8 = &.{};
    var r_inserted: bool = false;
    {
        const r = insert_row.?;
        r_art_id = allocator.dupe(u8, r[0] orelse "") catch &.{};
        r_stored_hash = allocator.dupe(u8, r[1] orelse "") catch &.{};
        r_touched_at = allocator.dupe(u8, r[2] orelse "") catch &.{};
        r_created_at = allocator.dupe(u8, r[3] orelse "") catch &.{};
        r_inserted = std.mem.eql(u8, r[4] orelse "false", "true");
        for (r) |col| if (col) |c| allocator.free(c);
        allocator.free(r);
    }
    defer allocator.free(r_art_id);
    defer allocator.free(r_stored_hash);
    defer allocator.free(r_touched_at);
    defer allocator.free(r_created_at);

    if (!r_inserted) {
        // Re-hit: compare spec_hash to detect payload mutation.
        if (!std.mem.eql(u8, r_stored_hash, spec_hash_str)) {
            return specHashMismatch409(allocator, r_stored_hash, spec_hash_str);
        }
        // HTTP 200 — idempotent re-hit with matching spec_hash.
        const resp = std.fmt.allocPrint(
            allocator,
            "{{\"artifact_id\":\"{s}\",\"kind\":\"{s}\",\"task_spec_id\":\"{s}\",\"attempt_count\":{d},\"spec_hash\":\"{s}\",\"created_at\":\"{s}\",\"touched_at\":\"{s}\"}}",
            .{ r_art_id, kind, db_task_spec_id, attempt_count_val, spec_hash_str, r_created_at, r_touched_at },
        ) catch return svc503();
        return .{ .status_code = 200, .body = resp };
    }

    // HTTP 201 — fresh insert.
    const resp = std.fmt.allocPrint(
        allocator,
        "{{\"artifact_id\":\"{s}\",\"kind\":\"{s}\",\"task_spec_id\":\"{s}\",\"attempt_count\":{d},\"spec_hash\":\"{s}\",\"created_at\":\"{s}\",\"touched_at\":\"{s}\"}}",
        .{ r_art_id, kind, db_task_spec_id, attempt_count_val, spec_hash_str, r_created_at, r_touched_at },
    ) catch return svc503();
    return .{ .status_code = 201, .body = resp };
}
