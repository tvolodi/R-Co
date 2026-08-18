//! SBX-01/SBX-02 — POST /api/v1/agent/task-specs handler.

const std = @import("std");
const db = @import("pool");
const auth_mod = @import("../../api/middleware/auth.zig");
const agent_auth = @import("../../api/middleware/agent_auth.zig");
const audit_mod = @import("../../obs/audit.zig");
const canonical_json = @import("../../crypto/canonical_json.zig");
const trace_context = @import("../../api/trace_context.zig");

pub const HandlerResult = auth_mod.HandlerResult;

fn forbidden403(allocator: std.mem.Allocator, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"detail\":\"{s}\",\"status\":403}}",
        .{code},
    ) catch "{\"detail\":\"forbidden\",\"status\":403}";
    return .{ .status_code = 403, .body = body };
}

fn badRequest400(allocator: std.mem.Allocator, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"detail\":\"{s}\",\"status\":400}}",
        .{code},
    ) catch "{\"detail\":\"bad_request\",\"status\":400}";
    return .{ .status_code = 400, .body = body };
}

fn conflict409(allocator: std.mem.Allocator, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"detail\":\"{s}\",\"status\":409}}",
        .{code},
    ) catch "{\"detail\":\"conflict\",\"status\":409}";
    return .{ .status_code = 409, .body = body };
}

fn appendJsonValue(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: std.json.Value) !void {
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
            for (s) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    '\n' => try buf.appendSlice(allocator, "\\n"),
                    '\r' => try buf.appendSlice(allocator, "\\r"),
                    '\t' => try buf.appendSlice(allocator, "\\t"),
                    else => try buf.append(allocator, c),
                }
            }
            try buf.append(allocator, '"');
        },
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, idx| {
                if (idx > 0) try buf.append(allocator, ',');
                try appendJsonValue(allocator, buf, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var obj_it = obj.iterator();
            var first = true;
            while (obj_it.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, entry.key_ptr.*);
                try buf.appendSlice(allocator, "\":");
                try appendJsonValue(allocator, buf, entry.value_ptr.*);
            }
            try buf.append(allocator, '}');
        },
    }
}

fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) error{OutOfMemory}![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = try allocator.alloc(u8, 64);
    const chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = chars[byte >> 4];
        hex[i * 2 + 1] = chars[byte & 0x0f];
    }
    return hex;
}

/// POST /api/v1/agent/task-specs
pub fn handleSubmitTaskSpec(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    auth: auth_mod.AuthContext,
    body_json: []const u8,
) HandlerResult {
    // SBX-01: orchestrator gate
    switch (agent_auth.requireOrchestratorSubmit(allocator, auth)) {
        .forbidden => |hr| {
            const tenant_id_slice: []const u8 = auth.tenant_id[0..];
            const trace_id = trace_context.get();
            const conn = pool.acquire() catch return hr;
            defer pool.release(conn);
            const after = std.fmt.allocPrint(
                allocator,
                "{{\"principal\":\"{s}\",\"tenant_id\":\"{s}\",\"missing_credential\":\"both\"}}",
                .{ auth.user_id, tenant_id_slice },
            ) catch null;
            if (after) |a| {
                const audit_id = audit_mod.writeAuditInTx(
                    allocator,
                    conn,
                    tenant_id_slice,
                    auth.user_id,
                    "task_spec.submission_rejected",
                    "task_spec",
                    auth.user_id,
                    null,
                    a,
                    trace_id,
                    null,
                ) catch null;
                if (audit_id) |id| allocator.free(id);
                allocator.free(a);
            }
            return hr;
        },
        .pass => {},
    }

    // SBX-02: build merged doc with server-authoritative orchestrator_principal
    // Parse the body into a mutable JSON value to manipulate it.
    const parsed_body = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body_json,
        .{ .allocate = .alloc_always },
    ) catch return badRequest400(allocator, "malformed_json");
    defer parsed_body.deinit();

    const body_obj = switch (parsed_body.value) {
        .object => |o| o,
        else => return badRequest400(allocator, "malformed_json"),
    };

    // Extract rng_seed (AGT-05: must not be 0 or absent).
    // Large u64 values (> i64::MAX) are represented as .number_string by the JSON parser.
    const rng_seed: i64 = blk: {
        const rv = body_obj.get("rng_seed") orelse return badRequest400(allocator, "rng_seed_zero");
        switch (rv) {
            .integer => |n| {
                if (n == 0) return badRequest400(allocator, "rng_seed_zero");
                break :blk n;
            },
            .number_string => |s| {
                const u = std.fmt.parseInt(u64, s, 10) catch return badRequest400(allocator, "rng_seed_zero");
                if (u == 0) return badRequest400(allocator, "rng_seed_zero");
                break :blk @bitCast(u);
            },
            else => return badRequest400(allocator, "rng_seed_zero"),
        }
    };

    // Build merged object: copy all keys except orchestrator_principal, then set server value.
    var merged_buf: std.ArrayList(u8) = .empty;
    defer merged_buf.deinit(allocator);
    merged_buf.append(allocator, '{') catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"out_of_memory\",\"status\":503}",
    };
    var first_key = true;
    var it2 = body_obj.iterator();
    while (it2.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "orchestrator_principal")) continue;
        if (!first_key) merged_buf.append(allocator, ',') catch return .{
            .status_code = 503,
            .body = "{\"detail\":\"out_of_memory\",\"status\":503}",
        };
        first_key = false;
        // key
        merged_buf.append(allocator, '"') catch return .{ .status_code = 503, .body = "{\"detail\":\"out_of_memory\",\"status\":503}" };
        merged_buf.appendSlice(allocator, entry.key_ptr.*) catch return .{ .status_code = 503, .body = "{\"detail\":\"out_of_memory\",\"status\":503}" };
        merged_buf.appendSlice(allocator, "\":") catch return .{ .status_code = 503, .body = "{\"detail\":\"out_of_memory\",\"status\":503}" };
        // value
        appendJsonValue(allocator, &merged_buf, entry.value_ptr.*) catch return .{ .status_code = 503, .body = "{\"detail\":\"out_of_memory\",\"status\":503}" };
    }
    // Append server-authoritative orchestrator_principal
    if (!first_key) merged_buf.append(allocator, ',') catch return .{ .status_code = 503, .body = "{\"detail\":\"out_of_memory\",\"status\":503}" };
    merged_buf.appendSlice(allocator, "\"orchestrator_principal\":\"") catch return .{ .status_code = 503, .body = "{\"detail\":\"out_of_memory\",\"status\":503}" };
    merged_buf.appendSlice(allocator, auth.user_id) catch return .{ .status_code = 503, .body = "{\"detail\":\"out_of_memory\",\"status\":503}" };
    merged_buf.appendSlice(allocator, "\"}") catch return .{ .status_code = 503, .body = "{\"detail\":\"out_of_memory\",\"status\":503}" };

    const merged_json = merged_buf.items;

    // RFC 8785 canonical JSON — parse merged_json then canonicalise
    const merged_parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        merged_json,
        .{ .allocate = .alloc_always },
    ) catch return .{ .status_code = 503, .body = "{\"detail\":\"out_of_memory\",\"status\":503}" };
    defer merged_parsed.deinit();

    const canonical_bytes = canonical_json.canonicalise(allocator, merged_parsed.value) catch |err| switch (err) {
        error.OutOfMemory => return .{ .status_code = 503, .body = "{\"detail\":\"out_of_memory\",\"status\":503}" },
        error.UnsupportedType => return badRequest400(allocator, "malformed_json"),
    };
    defer allocator.free(canonical_bytes);

    // SHA-256 hex
    const spec_hash = sha256Hex(allocator, canonical_bytes) catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"out_of_memory\",\"status\":503}",
    };
    defer allocator.free(spec_hash);

    // Use merged_json directly as spec body (already a JSON string)
    const spec_body_str = merged_json;

    const rng_seed_str = std.fmt.allocPrint(allocator, "{d}", .{rng_seed}) catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"out_of_memory\",\"status\":503}",
    };
    defer allocator.free(rng_seed_str);

    const tenant_id_slice: []const u8 = auth.tenant_id[0..];

    const conn = pool.acquire() catch return .{
        .status_code = 503,
        .body = "{\"detail\":\"pool_exhausted\",\"status\":503}",
    };
    defer pool.release(conn);

    // INSERT … ON CONFLICT (spec_hash) DO NOTHING RETURNING task_spec_id
    const row = conn.queryRow(
        allocator,
        \\INSERT INTO task_specs
        \\    (spec_hash, spec_body, orchestrator_principal, rng_seed)
        \\VALUES ($1, $2::jsonb, $3, $4::bigint)
        \\ON CONFLICT (spec_hash) DO NOTHING
        \\RETURNING task_spec_id::text
    ,
        &.{ spec_hash, spec_body_str, auth.user_id, rng_seed_str },
    ) catch return .{ .status_code = 503, .body = "{\"detail\":\"db_error\",\"status\":503}" };

    if (row == null) {
        // spec_hash collision — task_spec_immutable
        return conflict409(allocator, "task_spec_immutable");
    }
    const task_spec_id = blk: {
        const r = row.?;
        defer {
            for (r) |col| if (col) |c| allocator.free(c);
            allocator.free(r);
        }
        break :blk allocator.dupe(u8, r[0] orelse "") catch return .{
            .status_code = 503,
            .body = "{\"detail\":\"out_of_memory\",\"status\":503}",
        };
    };
    defer allocator.free(task_spec_id);

    // Audit: TaskSpecSubmitted
    const trace_id = trace_context.get();
    const after_state = std.fmt.allocPrint(
        allocator,
        "{{\"task_spec_id\":\"{s}\",\"spec_hash\":\"{s}\",\"orchestrator_principal\":\"{s}\",\"tenant_id\":\"{s}\"}}",
        .{ task_spec_id, spec_hash, auth.user_id, tenant_id_slice },
    ) catch null;
    if (after_state) |a| {
        const audit_id = audit_mod.writeAuditInTx(
            allocator,
            conn,
            tenant_id_slice,
            auth.user_id,
            "task_spec.submitted",
            "task_spec",
            task_spec_id,
            null,
            a,
            trace_id,
            null,
        ) catch null;
        if (audit_id) |id| allocator.free(id);
        allocator.free(a);
    }

    const response_body = std.fmt.allocPrint(
        allocator,
        "{{\"task_spec_id\":\"{s}\",\"spec_hash\":\"{s}\"}}",
        .{ task_spec_id, spec_hash },
    ) catch return .{ .status_code = 503, .body = "{\"detail\":\"out_of_memory\",\"status\":503}" };

    return .{ .status_code = 201, .body = response_body };
}
