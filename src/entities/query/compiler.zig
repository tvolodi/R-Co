//! QRY-01/QRY-02/QRY-03 — Parameterised SQL query compiler.
//!
//! All filter values are bound as positional $N parameters (Layer 3).
//! Column expressions come from the allowlist only (Layer 2).
//! Operators come from a closed enum (Layer 1).

const std = @import("std");
const types = @import("types.zig");
const allowlist = @import("allowlist.zig");
const cursor_mod = @import("cursor.zig");

pub const OrderByTerm = struct {
    name: []const u8,
    dir: []const u8,
};

pub const CompiledQuery = struct {
    sql: []const u8,
    params: [][]const u8,
    param_count: usize,
    order_by_terms: []OrderByTerm,
    effective_page_size: u16,
};

pub const CompileError = error{
    OperatorNotRecognised,
    FilterFieldNotAllowlisted,
    OperatorNotValidForType,
    SortFieldNotAllowlisted,
    TooManySortFields,
    PageSizeExceedsMax,
    CursorMalformed,
    CursorSortMismatch,
    OutOfMemory,
};

const DEFAULT_PAGE_SIZE: u16 = 50;
const MAX_PAGE_SIZE: u16 = 200;
const MAX_SORT_FIELDS: usize = 2;

fn sortDirToSql(dir: types.SortDir) []const u8 {
    return switch (dir) {
        .asc => "ASC",
        .desc => "DESC",
    };
}

fn sortDirStr(dir: types.SortDir) []const u8 {
    return switch (dir) {
        .asc => "asc",
        .desc => "desc",
    };
}

fn columnExpr(
    allocator: std.mem.Allocator,
    field: allowlist.AllowlistedField,
    params: *std.ArrayList([]const u8),
    pidx: *usize,
) error{OutOfMemory}![]u8 {
    return switch (field.kind) {
        .typed_column => std.fmt.allocPrint(allocator, "\"{s}\"", .{field.name}),
        .jsonb_key => blk: {
            try params.append(allocator, field.name);
            const idx = pidx.*;
            pidx.* += 1;
            break :blk std.fmt.allocPrint(allocator, "payload ->> ${d}", .{idx});
        },
    };
}

pub fn compile(
    allocator: std.mem.Allocator,
    table: []const u8,
    al: allowlist.EntityAllowlist,
    request: types.EntityQueryRequest,
    tenant_id: []const u8,
    rejected_filter_field: *?[]const u8,
) CompileError!CompiledQuery {
    rejected_filter_field.* = null;
    const page_size: u16 = blk: {
        const requested = request.page_size orelse DEFAULT_PAGE_SIZE;
        if (requested > MAX_PAGE_SIZE) return CompileError.PageSizeExceedsMax;
        if (requested == 0) break :blk DEFAULT_PAGE_SIZE;
        break :blk requested;
    };

    if (request.sort.len > MAX_SORT_FIELDS) return CompileError.TooManySortFields;

    var params: std.ArrayList([]const u8) = .empty;
    errdefer params.deinit(allocator);
    params.append(allocator, tenant_id) catch return CompileError.OutOfMemory;
    var pidx: usize = 2;

    var where_parts: std.ArrayList([]u8) = .empty;
    defer {
        for (where_parts.items) |p| allocator.free(p);
        where_parts.deinit(allocator);
    }

    {
        const w = allocator.dupe(u8, "\"tenant_id\" = $1::uuid") catch return CompileError.OutOfMemory;
        where_parts.append(allocator, w) catch {
            allocator.free(w);
            return CompileError.OutOfMemory;
        };
    }

    for (request.filters) |f| {
        const af = al.find(f.field) orelse {
            rejected_filter_field.* = allocator.dupe(u8, f.field) catch null;
            return CompileError.FilterFieldNotAllowlisted;
        };

        if (f.op == .contains and af.storage_type != .text) return CompileError.OperatorNotValidForType;
        if ((f.op == .lt or f.op == .lte or f.op == .gt or f.op == .gte) and
            af.storage_type == .boolean) return CompileError.OperatorNotValidForType;

        const col_expr = columnExpr(allocator, af, &params, &pidx) catch return CompileError.OutOfMemory;
        defer allocator.free(col_expr);

        const clause: []u8 = switch (f.op) {
            .eq => std.fmt.allocPrint(allocator, "{s} = ${d}", .{ col_expr, pidx }),
            .neq => std.fmt.allocPrint(allocator, "{s} <> ${d}", .{ col_expr, pidx }),
            .lt => std.fmt.allocPrint(allocator, "{s} < ${d}", .{ col_expr, pidx }),
            .lte => std.fmt.allocPrint(allocator, "{s} <= ${d}", .{ col_expr, pidx }),
            .gt => std.fmt.allocPrint(allocator, "{s} > ${d}", .{ col_expr, pidx }),
            .gte => std.fmt.allocPrint(allocator, "{s} >= ${d}", .{ col_expr, pidx }),
            .in => std.fmt.allocPrint(allocator, "{s} = ANY(${d}::text[])", .{ col_expr, pidx }),
            .contains => std.fmt.allocPrint(allocator, "{s} ILIKE '%' || ${d} || '%'", .{ col_expr, pidx }),
        } catch return CompileError.OutOfMemory;

        params.append(allocator, f.value) catch {
            allocator.free(clause);
            return CompileError.OutOfMemory;
        };
        where_parts.append(allocator, clause) catch {
            allocator.free(clause);
            return CompileError.OutOfMemory;
        };
        pidx += 1;
    }

    var order_terms: std.ArrayList(OrderByTerm) = .empty;
    errdefer {
        for (order_terms.items) |ot| allocator.free(ot.name);
        order_terms.deinit(allocator);
    }

    var order_sql_parts: std.ArrayList([]u8) = .empty;
    defer {
        for (order_sql_parts.items) |p| allocator.free(p);
        order_sql_parts.deinit(allocator);
    }

    for (request.sort) |s| {
        const af = al.find(s.field) orelse return CompileError.SortFieldNotAllowlisted;
        if (!af.is_sortable) return CompileError.SortFieldNotAllowlisted;

        const col_expr = columnExpr(allocator, af, &params, &pidx) catch return CompileError.OutOfMemory;
        defer allocator.free(col_expr);

        const part = std.fmt.allocPrint(allocator, "{s} {s}", .{ col_expr, sortDirToSql(s.dir) }) catch
            return CompileError.OutOfMemory;
        order_sql_parts.append(allocator, part) catch {
            allocator.free(part);
            return CompileError.OutOfMemory;
        };

        const name_copy = allocator.dupe(u8, s.field) catch return CompileError.OutOfMemory;
        order_terms.append(allocator, .{ .name = name_copy, .dir = sortDirStr(s.dir) }) catch {
            allocator.free(name_copy);
            return CompileError.OutOfMemory;
        };
    }

    const tiebreak_dir = if (request.sort.len > 0) request.sort[0].dir else types.SortDir.asc;
    {
        const part = std.fmt.allocPrint(allocator, "\"record_id\" {s}", .{sortDirToSql(tiebreak_dir)}) catch
            return CompileError.OutOfMemory;
        order_sql_parts.append(allocator, part) catch {
            allocator.free(part);
            return CompileError.OutOfMemory;
        };
    }
    {
        const name_copy = allocator.dupe(u8, "record_id") catch return CompileError.OutOfMemory;
        order_terms.append(allocator, .{ .name = name_copy, .dir = sortDirStr(tiebreak_dir) }) catch {
            allocator.free(name_copy);
            return CompileError.OutOfMemory;
        };
    }

    if (request.cursor) |cursor_str| {
        var fp_input: std.ArrayList(cursor_mod.SortTerm) = .empty;
        defer fp_input.deinit(allocator);
        for (order_terms.items) |ot| {
            fp_input.append(allocator, .{ .name = ot.name, .dir = ot.dir }) catch return CompileError.OutOfMemory;
        }
        const fp = cursor_mod.buildFingerprint(allocator, fp_input.items) catch return CompileError.OutOfMemory;
        defer allocator.free(fp.value);

        const decoded = cursor_mod.decodeCursor(allocator, cursor_str, fp, order_terms.items.len) catch |err| switch (err) {
            error.CursorSortMismatch => return CompileError.CursorSortMismatch,
            error.OutOfMemory => return CompileError.OutOfMemory,
            else => return CompileError.CursorMalformed,
        };
        defer decoded.deinit();

        const keyset = buildKeysetPredicate(allocator, order_terms.items, decoded.tuple, &pidx, &params) catch
            return CompileError.OutOfMemory;
        where_parts.append(allocator, keyset) catch {
            allocator.free(keyset);
            return CompileError.OutOfMemory;
        };
    }

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);

    sql.appendSlice(allocator, "SELECT row_to_json(t) AS r FROM (SELECT * FROM ") catch return CompileError.OutOfMemory;
    sql.appendSlice(allocator, table) catch return CompileError.OutOfMemory;
    sql.appendSlice(allocator, " WHERE ") catch return CompileError.OutOfMemory;
    for (where_parts.items, 0..) |wp, i| {
        if (i > 0) sql.appendSlice(allocator, " AND ") catch return CompileError.OutOfMemory;
        sql.appendSlice(allocator, wp) catch return CompileError.OutOfMemory;
    }
    sql.appendSlice(allocator, " ORDER BY ") catch return CompileError.OutOfMemory;
    for (order_sql_parts.items, 0..) |op_part, i| {
        if (i > 0) sql.appendSlice(allocator, ", ") catch return CompileError.OutOfMemory;
        sql.appendSlice(allocator, op_part) catch return CompileError.OutOfMemory;
    }
    const limit_str = std.fmt.allocPrint(allocator, " LIMIT {d}) t", .{@as(u32, page_size) + 1}) catch
        return CompileError.OutOfMemory;
    defer allocator.free(limit_str);
    sql.appendSlice(allocator, limit_str) catch return CompileError.OutOfMemory;

    return CompiledQuery{
        .sql = try sql.toOwnedSlice(allocator),
        .params = try params.toOwnedSlice(allocator),
        .param_count = pidx - 1,
        .order_by_terms = try order_terms.toOwnedSlice(allocator),
        .effective_page_size = page_size,
    };
}

pub fn deinitCompiledQuery(allocator: std.mem.Allocator, cq: *CompiledQuery) void {
    allocator.free(cq.sql);
    allocator.free(cq.params);
    for (cq.order_by_terms) |ot| allocator.free(ot.name);
    allocator.free(cq.order_by_terms);
}

fn buildKeysetPredicate(
    allocator: std.mem.Allocator,
    order_terms: []const OrderByTerm,
    tuple: []const []const u8,
    pidx: *usize,
    params: *std.ArrayList([]const u8),
) error{OutOfMemory}![]u8 {
    if (order_terms.len == 0) return allocator.dupe(u8, "TRUE");

    const base_idx = pidx.*;
    for (tuple) |val| {
        params.append(allocator, val) catch return error.OutOfMemory;
        pidx.* += 1;
    }

    var pred: std.ArrayList(u8) = .empty;
    defer pred.deinit(allocator);

    pred.append(allocator, '(') catch return error.OutOfMemory;

    for (0..order_terms.len) |branch_len| {
        if (branch_len > 0) {
            pred.appendSlice(allocator, " OR (") catch return error.OutOfMemory;
        } else {
            pred.append(allocator, '(') catch return error.OutOfMemory;
        }

        for (0..branch_len) |eq_idx| {
            const part = std.fmt.allocPrint(
                allocator,
                "\"{s}\" = ${d} AND ",
                .{ order_terms[eq_idx].name, base_idx + eq_idx },
            ) catch return error.OutOfMemory;
            defer allocator.free(part);
            pred.appendSlice(allocator, part) catch return error.OutOfMemory;
        }

        const is_asc = std.mem.eql(u8, order_terms[branch_len].dir, "asc");
        const strict_op: []const u8 = if (is_asc) ">" else "<";
        const strict_part = std.fmt.allocPrint(
            allocator,
            "\"{s}\" {s} ${d}",
            .{ order_terms[branch_len].name, strict_op, base_idx + branch_len },
        ) catch return error.OutOfMemory;
        defer allocator.free(strict_part);
        pred.appendSlice(allocator, strict_part) catch return error.OutOfMemory;
        pred.append(allocator, ')') catch return error.OutOfMemory;
    }

    pred.append(allocator, ')') catch return error.OutOfMemory;
    return pred.toOwnedSlice(allocator);
}
