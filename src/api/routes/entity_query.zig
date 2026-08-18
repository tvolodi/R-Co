//! QRY-01..QRY-04 — Entity query HTTP handler.
//!
//! POST /api/v1/entities/{entity_key}/query
//!
//! QRY-04: emptyEnvelope() is byte-identical for deny and unknown-entity paths.
//! No HTTP 403 or 404 is ever returned.

const std = @import("std");
const builtin = @import("builtin");
const db = @import("pool");
const auth_mod = @import("../../api/middleware/auth.zig");
const errors_mod = @import("../../api/errors.zig");
const response_mod = @import("../../api/response.zig");
const audit_mod = @import("../../obs/audit.zig");
const trace_context = @import("../../api/trace_context.zig");
const query_types = @import("../../entities/query/types.zig");
const query_allowlist = @import("../../entities/query/allowlist.zig");
const query_compiler = @import("../../entities/query/compiler.zig");
const query_cursor = @import("../../entities/query/cursor.zig");

pub const HandlerResult = response_mod.HandlerResult;

const EMPTY_ENVELOPE: []const u8 = "{\"items\":[],\"next_cursor\":null,\"page_size\":50}";

fn emptyEnvelope() HandlerResult {
    return .{ .status_code = 200, .body = EMPTY_ENVELOPE };
}

fn validateEntityKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 128) return false;
    if (key[0] < 'a' or key[0] > 'z') return false;
    for (key[1..]) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) return false;
    }
    return true;
}

pub fn handleEntityQuery(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    auth: auth_mod.AuthContext,
    entity_key: []const u8,
    body_json: []const u8,
) HandlerResult {
    if (!validateEntityKey(entity_key)) {
        const pd = errors_mod.problemBadRequest("invalid_entity_key");
        return response_mod.problemResponse(allocator, pd);
    }

    const conn = pool.acquire() catch {
        const pd = errors_mod.problemServiceUnavailable("pool_exhausted");
        return response_mod.problemResponse(allocator, pd);
    };
    defer pool.release(conn);

    const tenant_id_slice: []const u8 = auth.tenant_id[0..];

    const is_registered = checkEntityRegistered(allocator, conn, tenant_id_slice, entity_key) catch {
        return emptyEnvelope();
    };
    if (!is_registered) {
        appendDenyAudit(allocator, conn, auth.user_id, tenant_id_slice, entity_key, "not_registered");
        return emptyEnvelope();
    }

    const req = parseRequest(allocator, body_json) catch |err| {
        const detail: []const u8 = switch (err) {
            error.UnknownOp => "operator_not_recognised",
            else => "malformed_json",
        };
        const pd = errors_mod.problemBadRequest(detail);
        return response_mod.problemResponse(allocator, pd);
    };
    defer freeRequest(allocator, req);

    var al = query_allowlist.loadAllowlist(allocator, conn, tenant_id_slice, entity_key) catch {
        const pd = errors_mod.problemServiceUnavailable("allowlist_load_failed");
        return response_mod.problemResponse(allocator, pd);
    };
    defer query_allowlist.deinitAllowlist(allocator, &al);

    const table_name = std.fmt.allocPrint(allocator, "ent_{s}", .{entity_key}) catch {
        const pd = errors_mod.problemServiceUnavailable("out_of_memory");
        return response_mod.problemResponse(allocator, pd);
    };
    defer allocator.free(table_name);

    const compiled = query_compiler.compile(allocator, table_name, al, req, tenant_id_slice) catch |err| {
        const detail: []const u8 = switch (err) {
            error.OperatorNotRecognised => "operator_not_recognised",
            error.FilterFieldNotAllowlisted => "filter_field_not_allowlisted",
            error.OperatorNotValidForType => "operator_not_valid_for_type",
            error.SortFieldNotAllowlisted => "sort_field_not_allowlisted",
            error.TooManySortFields => "too_many_sort_fields",
            error.PageSizeExceedsMax => "page_size_exceeds_max",
            error.CursorMalformed => "cursor_malformed",
            error.CursorSortMismatch => "cursor_sort_mismatch",
            error.OutOfMemory => "out_of_memory",
        };
        const pd = errors_mod.problemBadRequest(detail);
        return response_mod.problemResponse(allocator, pd);
    };
    defer {
        var cq = compiled;
        query_compiler.deinitCompiledQuery(allocator, &cq);
    }

    var rows = conn.query(allocator, compiled.sql, compiled.params) catch {
        const pd = errors_mod.problemServiceUnavailable("query_failed");
        return response_mod.problemResponse(allocator, pd);
    };
    defer rows.deinit();

    const effective_page_size = compiled.effective_page_size;
    const has_next = rows.rows.len > effective_page_size;
    const result_count: usize = if (has_next) effective_page_size else rows.rows.len;

    var next_cursor_str: ?[]u8 = null;
    defer if (next_cursor_str) |c| allocator.free(c);

    if (has_next and result_count > 0) {
        next_cursor_str = buildNextCursor(
            allocator,
            rows.rows[result_count - 1],
            compiled.order_by_terms,
        ) catch null;
    }

    const items_json = serialiseRows(allocator, rows.rows[0..result_count]) catch {
        const pd = errors_mod.problemServiceUnavailable("serialization_failed");
        return response_mod.problemResponse(allocator, pd);
    };
    defer allocator.free(items_json);

    appendQueryAudit(allocator, conn, auth.user_id, tenant_id_slice, entity_key, req, @intCast(result_count), effective_page_size, req.cursor != null);

    const cursor_json: []const u8 = if (next_cursor_str) |c|
        std.fmt.allocPrint(allocator, "\"{s}\"", .{c}) catch "null"
    else
        "null";
    defer if (next_cursor_str != null and !std.mem.eql(u8, cursor_json, "null")) allocator.free(cursor_json);

    const body = std.fmt.allocPrint(
        allocator,
        "{{\"items\":{s},\"next_cursor\":{s},\"page_size\":{d}}}",
        .{ items_json, cursor_json, effective_page_size },
    ) catch {
        const pd = errors_mod.problemServiceUnavailable("serialization_failed");
        return response_mod.problemResponse(allocator, pd);
    };

    return .{ .status_code = 200, .body = body };
}

fn checkEntityRegistered(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    tenant_id: []const u8,
    entity_key: []const u8,
) !bool {
    const row = try conn.queryRow(
        allocator,
        "SELECT 1 FROM entity_definitions WHERE tenant_id = $1::uuid AND name = $2 AND status = 'ACTIVE' LIMIT 1",
        &.{ tenant_id, entity_key },
    );
    if (row) |r| {
        defer {
            for (r) |col| if (col) |c| allocator.free(c);
            allocator.free(r);
        }
        return true;
    }
    return false;
}

const ParseRequestError = error{ BadJson, UnknownOp, OutOfMemory };

fn parseRequest(allocator: std.mem.Allocator, body_json: []const u8) ParseRequestError!query_types.EntityQueryRequest {
    if (body_json.len == 0) {
        return query_types.EntityQueryRequest{
            .filters = try allocator.alloc(query_types.FilterNode, 0),
            .sort = try allocator.alloc(query_types.SortNode, 0),
            .page_size = null,
            .cursor = null,
        };
    }

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body_json,
        .{ .allocate = .alloc_always },
    ) catch return ParseRequestError.BadJson;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        .null => {
            return query_types.EntityQueryRequest{
                .filters = try allocator.alloc(query_types.FilterNode, 0),
                .sort = try allocator.alloc(query_types.SortNode, 0),
                .page_size = null,
                .cursor = null,
            };
        },
        else => return ParseRequestError.BadJson,
    };

    var page_size: ?u16 = null;
    if (obj.get("page_size")) |ps_val| {
        switch (ps_val) {
            .integer => |n| {
                if (n < 0 or n > 65535) return ParseRequestError.BadJson;
                page_size = @intCast(n);
            },
            .null => {},
            else => return ParseRequestError.BadJson,
        }
    }

    var cursor_opt: ?[]const u8 = null;
    if (obj.get("cursor")) |c_val| {
        switch (c_val) {
            .string => |s| {
                cursor_opt = allocator.dupe(u8, s) catch return ParseRequestError.OutOfMemory;
            },
            .null => {},
            else => return ParseRequestError.BadJson,
        }
    }

    var filters: std.ArrayList(query_types.FilterNode) = .empty;
    errdefer {
        for (filters.items) |f| {
            allocator.free(f.field);
            allocator.free(f.value);
        }
        filters.deinit(allocator);
    }

    if (obj.get("filters")) |f_val| {
        switch (f_val) {
            .array => |f_arr| {
                for (f_arr.items) |item| {
                    const fobj = switch (item) {
                        .object => |o| o,
                        else => return ParseRequestError.BadJson,
                    };
                    const field_str = switch (fobj.get("field") orelse return ParseRequestError.BadJson) {
                        .string => |s| s,
                        else => return ParseRequestError.BadJson,
                    };
                    const op_str = switch (fobj.get("op") orelse return ParseRequestError.BadJson) {
                        .string => |s| s,
                        else => return ParseRequestError.BadJson,
                    };
                    const value_raw = fobj.get("value") orelse return ParseRequestError.BadJson;
                    const value_str: []const u8 = switch (value_raw) {
                        .string => |s| s,
                        .integer => |n| blk: {
                            break :blk std.fmt.allocPrint(allocator, "{d}", .{n}) catch return ParseRequestError.OutOfMemory;
                        },
                        .float => |n| blk: {
                            break :blk std.fmt.allocPrint(allocator, "{d}", .{n}) catch return ParseRequestError.OutOfMemory;
                        },
                        else => return ParseRequestError.BadJson,
                    };

                    const op = query_types.filterOpFromString(op_str) orelse return ParseRequestError.UnknownOp;
                    const field_copy = allocator.dupe(u8, field_str) catch return ParseRequestError.OutOfMemory;
                    const value_copy = allocator.dupe(u8, value_str) catch {
                        allocator.free(field_copy);
                        return ParseRequestError.OutOfMemory;
                    };
                    filters.append(allocator, .{ .field = field_copy, .op = op, .value = value_copy }) catch {
                        allocator.free(field_copy);
                        allocator.free(value_copy);
                        return ParseRequestError.OutOfMemory;
                    };
                }
            },
            .null => {},
            else => return ParseRequestError.BadJson,
        }
    }

    var sort_nodes: std.ArrayList(query_types.SortNode) = .empty;
    errdefer {
        for (sort_nodes.items) |s| allocator.free(s.field);
        sort_nodes.deinit(allocator);
    }

    if (obj.get("sort")) |s_val| {
        switch (s_val) {
            .array => |s_arr| {
                for (s_arr.items) |item| {
                    const sobj = switch (item) {
                        .object => |o| o,
                        else => return ParseRequestError.BadJson,
                    };
                    const field_str = switch (sobj.get("field") orelse return ParseRequestError.BadJson) {
                        .string => |s| s,
                        else => return ParseRequestError.BadJson,
                    };
                    const dir_str = switch (sobj.get("dir") orelse return ParseRequestError.BadJson) {
                        .string => |s| s,
                        else => return ParseRequestError.BadJson,
                    };
                    const dir = query_types.sortDirFromString(dir_str) orelse return ParseRequestError.BadJson;
                    const field_copy = allocator.dupe(u8, field_str) catch return ParseRequestError.OutOfMemory;
                    sort_nodes.append(allocator, .{ .field = field_copy, .dir = dir }) catch {
                        allocator.free(field_copy);
                        return ParseRequestError.OutOfMemory;
                    };
                }
            },
            .null => {},
            else => return ParseRequestError.BadJson,
        }
    }

    return query_types.EntityQueryRequest{
        .filters = try filters.toOwnedSlice(allocator),
        .sort = try sort_nodes.toOwnedSlice(allocator),
        .page_size = page_size,
        .cursor = cursor_opt,
    };
}

fn freeRequest(allocator: std.mem.Allocator, req: query_types.EntityQueryRequest) void {
    for (req.filters) |f| {
        allocator.free(f.field);
        allocator.free(f.value);
    }
    allocator.free(req.filters);
    for (req.sort) |s| allocator.free(s.field);
    allocator.free(req.sort);
    if (req.cursor) |c| allocator.free(c);
}

fn buildNextCursor(
    allocator: std.mem.Allocator,
    row: []?[]u8,
    order_terms: []const query_compiler.OrderByTerm,
) ![]u8 {
    if (row.len == 0) return error.OutOfMemory;
    const json_str = row[0] orelse return error.OutOfMemory;

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_str,
        .{ .allocate = .alloc_always },
    ) catch return error.OutOfMemory;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.OutOfMemory,
    };

    var tuple: std.ArrayList([]const u8) = .empty;
    defer {
        for (tuple.items) |v| allocator.free(v);
        tuple.deinit(allocator);
    }

    for (order_terms) |ot| {
        const val_opt = obj.get(ot.name);
        const val_str: []const u8 = if (val_opt) |v| switch (v) {
            .string => |s| s,
            .integer => |n| std.fmt.allocPrint(allocator, "{d}", .{n}) catch return error.OutOfMemory,
            .float => |n| std.fmt.allocPrint(allocator, "{d}", .{n}) catch return error.OutOfMemory,
            else => "",
        } else "";
        const val_copy = allocator.dupe(u8, val_str) catch return error.OutOfMemory;
        tuple.append(allocator, val_copy) catch {
            allocator.free(val_copy);
            return error.OutOfMemory;
        };
    }

    var fp_terms: std.ArrayList(query_cursor.SortTerm) = .empty;
    defer fp_terms.deinit(allocator);
    for (order_terms) |ot| {
        fp_terms.append(allocator, .{ .name = ot.name, .dir = ot.dir }) catch return error.OutOfMemory;
    }
    const fp = query_cursor.buildFingerprint(allocator, fp_terms.items) catch return error.OutOfMemory;
    defer allocator.free(fp.value);

    const now_us = currentMicrosecondTimestamp();
    return query_cursor.encodeCursor(allocator, fp, tuple.items, now_us);
}

fn serialiseRows(allocator: std.mem.Allocator, rows: [][]?[]u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    out.append(allocator, '[') catch return error.OutOfMemory;
    for (rows, 0..) |row, i| {
        if (i > 0) out.append(allocator, ',') catch return error.OutOfMemory;
        if (row.len > 0) {
            if (row[0]) |json_col| {
                out.appendSlice(allocator, json_col) catch return error.OutOfMemory;
            } else {
                out.appendSlice(allocator, "null") catch return error.OutOfMemory;
            }
        } else {
            out.appendSlice(allocator, "null") catch return error.OutOfMemory;
        }
    }
    out.append(allocator, ']') catch return error.OutOfMemory;
    return out.toOwnedSlice(allocator);
}

fn appendDenyAudit(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    actor_id: []const u8,
    tenant_id: []const u8,
    entity_key: []const u8,
    deny_reason: []const u8,
) void {
    const after_state = std.fmt.allocPrint(
        allocator,
        "{{\"entity_key\":\"{s}\",\"deny_reason\":\"{s}\"}}",
        .{ entity_key, deny_reason },
    ) catch return;
    defer allocator.free(after_state);
    const trace_id = trace_context.get();
    const audit_id = audit_mod.writeAuditInTx(allocator, conn, tenant_id, actor_id, "entity.query", "entity_key", entity_key, null, after_state, trace_id, null) catch |err| {
        std.log.warn("appendDenyAudit: {}", .{err});
        return;
    };
    allocator.free(audit_id);
}

fn appendQueryAudit(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    actor_id: []const u8,
    tenant_id: []const u8,
    entity_key: []const u8,
    req: query_types.EntityQueryRequest,
    row_count: u32,
    page_size: u16,
    has_cursor: bool,
) void {
    var names_buf: std.ArrayList(u8) = .empty;
    defer names_buf.deinit(allocator);
    names_buf.append(allocator, '[') catch return;
    for (req.filters, 0..) |f, i| {
        if (i > 0) names_buf.append(allocator, ',') catch return;
        const quoted = std.fmt.allocPrint(allocator, "\"{s}\"", .{f.field}) catch return;
        defer allocator.free(quoted);
        names_buf.appendSlice(allocator, quoted) catch return;
    }
    names_buf.append(allocator, ']') catch return;

    const after_state = std.fmt.allocPrint(
        allocator,
        "{{\"entity_key\":\"{s}\",\"filter_field_names\":{s},\"row_count\":{d},\"page_size\":{d},\"has_cursor\":{s}}}",
        .{ entity_key, names_buf.items, row_count, page_size, if (has_cursor) "true" else "false" },
    ) catch return;
    defer allocator.free(after_state);
    const trace_id = trace_context.get();
    const audit_id = audit_mod.writeAuditInTx(allocator, conn, tenant_id, actor_id, "entity.query", "entity_key", entity_key, null, after_state, trace_id, null) catch |err| {
        std.log.warn("appendQueryAudit: {}", .{err});
        return;
    };
    allocator.free(audit_id);
}

fn currentMicrosecondTimestamp() i64 {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10);
    } else {
        const posix = std.posix;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.REALTIME, &ts);
        return ts.sec * 1_000_000 + @divTrunc(ts.nsec, 1000);
    }
}
