//! HTTP route handlers for EXP-201 / EXP-202 entity APIs.
//!
//! The backend currently exposes the entity-definition entry points through
//! main.zig. This module provides the minimal route implementation required to
//! compile the server while the full event-sourced record path is completed.

const std = @import("std");
const db = @import("pool");
const entity_definition = @import("../../entities/definition.zig");
const entity_commands = @import("../../entities/commands.zig");

const Pool = db.Pool;

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

pub fn handleListDefinitions(
    allocator: std.mem.Allocator,
    pool: *Pool,
    user_id: []const u8,
    query_str: []const u8,
) HandlerResult {
    _ = query_str;

    const opts = entity_definition.ListDefinitionsOpts{
        .tenant_id = user_id,
        .page_size = 50,
    };

    const defs = entity_definition.listDefinitions(allocator, pool, opts) catch |err| switch (err) {
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer {
        for (defs) |*def| def.deinit(allocator);
        allocator.free(defs);
    }

    const body = std.fmt.allocPrint(allocator, "{{\"items\":{d}}}", .{defs.len}) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 200, .body = body };
}

pub fn handleCreateDefinition(
    allocator: std.mem.Allocator,
    pool: *Pool,
    body: []const u8,
    user_id: []const u8,
    actor_id: []const u8,
) HandlerResult {
    _ = actor_id;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch {
        return errorResult(allocator, 400, "malformed_json");
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return errorResult(allocator, 400, "malformed_json"),
    };

    const name = switch (obj.get("name") orelse return errorResult(allocator, 422, "invalid_name")) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "invalid_name"),
    };
    const display_name = switch (obj.get("display_name") orelse return errorResult(allocator, 422, "invalid_display_name")) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "invalid_display_name"),
    };
    const definition_json = switch (obj.get("definition_json") orelse return errorResult(allocator, 422, "invalid_definition_json")) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "invalid_definition_json"),
    };

    const description = blk: {
        const raw = obj.get("description") orelse break :blk null;
        switch (raw) {
            .string => |s| break :blk s,
            .null => break :blk null,
            else => return errorResult(allocator, 422, "invalid_description"),
        }
    };

    const params = entity_definition.CreateDefinitionParams{
        .name = name,
        .display_name = display_name,
        .description = description,
        .definition_json = definition_json,
        .created_by = user_id,
        .tenant_id = user_id,
    };

    var def = entity_definition.createDefinition(allocator, pool, params) catch |err| switch (err) {
        error.InvalidJson => return errorResult(allocator, 422, "invalid_definition_json"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        error.OutOfMemory => return errorResult(allocator, 500, "internal_error"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer def.deinit(allocator);

    const body_out = std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"name\":\"{s}\"}}", .{ def.id, def.name }) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 201, .body = body_out };
}

pub fn handleActivateDefinition(
    allocator: std.mem.Allocator,
    pool: *Pool,
    definition_id: []const u8,
) HandlerResult {
    var def = entity_definition.activateDefinition(allocator, pool, definition_id) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not_found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer def.deinit(allocator);

    const body_out = std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"status\":\"ACTIVE\"}}", .{def.id}) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 200, .body = body_out };
}

pub fn handleCreateRecord(
    allocator: std.mem.Allocator,
    pool: *Pool,
    ev_store: anytype,
    entity_type: []const u8,
    body: []const u8,
    actor_id: []const u8,
    tenant_id: []const u8,
) HandlerResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch {
        return errorResult(allocator, 400, "malformed_json");
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return errorResult(allocator, 400, "malformed_json"),
    };

    const field_values_val = obj.get("field_values") orelse return errorResult(allocator, 422, "missing_field_values");
    const field_values = std.json.Stringify.valueAlloc(allocator, field_values_val, .{}) catch return errorResult(allocator, 500, "serialization_failed");
    defer allocator.free(field_values);

    const idempotency_key = switch (obj.get("idempotency_key") orelse return errorResult(allocator, 422, "missing_idempotency_key")) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "invalid_idempotency_key"),
    };

    const params = entity_commands.CreateRecordParams{
        .entity_type = entity_type,
        .field_values = field_values,
        .idempotency_key = idempotency_key,
        .actor_id = actor_id,
        .tenant_id = tenant_id,
    };

    const res = entity_commands.createRecord(allocator, pool, ev_store, {}, params) catch |err| switch (err) {
        error.InvalidEntityType => return errorResult(allocator, 404, "entity_type_not_found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer {
        allocator.free(res.record_id);
        allocator.free(res.entity_type);
        allocator.free(res.field_values);
    }

    const body_out = std.fmt.allocPrint(allocator, "{{\"record_id\":\"{s}\",\"entity_type\":\"{s}\",\"version_seq\":{d}}}", .{ res.record_id, res.entity_type, res.version_seq }) catch
        return errorResult(allocator, 500, "serialization_failed");

    return .{ .status_code = if (res.is_duplicate) @as(u16, 200) else @as(u16, 201), .body = body_out };
}

pub fn handleUpdateRecord(
    allocator: std.mem.Allocator,
    pool: *Pool,
    ev_store: anytype,
    entity_type: []const u8,
    record_id: []const u8,
    body: []const u8,
    actor_id: []const u8,
    tenant_id: []const u8,
) HandlerResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch {
        return errorResult(allocator, 400, "malformed_json");
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return errorResult(allocator, 400, "malformed_json"),
    };

    const field_values_val = obj.get("field_values") orelse return errorResult(allocator, 422, "missing_field_values");
    const field_values = std.json.Stringify.valueAlloc(allocator, field_values_val, .{}) catch return errorResult(allocator, 500, "serialization_failed");
    defer allocator.free(field_values);

    const idempotency_key = switch (obj.get("idempotency_key") orelse return errorResult(allocator, 422, "missing_idempotency_key")) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "invalid_idempotency_key"),
    };

    const params = entity_commands.UpdateRecordParams{
        .entity_type = entity_type,
        .record_id = record_id,
        .field_values = field_values,
        .idempotency_key = idempotency_key,
        .actor_id = actor_id,
        .tenant_id = tenant_id,
    };

    const res = entity_commands.updateRecord(allocator, pool, ev_store, {}, params) catch |err| switch (err) {
        error.InvalidEntityType => return errorResult(allocator, 404, "entity_type_not_found"),
        error.InvalidRecord => return errorResult(allocator, 404, "record_not_found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer {
        allocator.free(res.record_id);
        allocator.free(res.entity_type);
        allocator.free(res.field_values);
    }

    const body_out = std.fmt.allocPrint(allocator, "{{\"record_id\":\"{s}\",\"entity_type\":\"{s}\",\"version_seq\":{d}}}", .{ res.record_id, res.entity_type, res.version_seq }) catch
        return errorResult(allocator, 500, "serialization_failed");

    return .{ .status_code = 200, .body = body_out };
}

pub fn handleListRecords(allocator: std.mem.Allocator, pool: *Pool, entity_type: []const u8, user_id: []const u8) HandlerResult {
    _ = user_id;
    var conn = pool.acquire() catch return errorResult(allocator, 503, "service_unavailable");
    defer pool.release(conn);

    var result = conn.query(allocator, "SELECT record_id, field_values, version_seq, updated_at FROM entity_record_latest WHERE entity_type = $1 ORDER BY updated_at DESC", &.{entity_type}) catch
        return errorResult(allocator, 500, "query_failed");
    defer result.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    buf.appendSlice(allocator, "[") catch return errorResult(allocator, 500, "out_of_memory");

    for (result.rows, 0..) |row, i| {
        if (i > 0) buf.appendSlice(allocator, ",") catch return errorResult(allocator, 500, "out_of_memory");

        const record_id = row[0] orelse "";
        const field_values = row[1] orelse "{}";
        const version_seq_str = row[2] orelse "0";
        const updated_at = row[3] orelse "";

        const item_json = std.fmt.allocPrint(allocator, "{{\"record_id\":\"{s}\",\"field_values\":{s},\"version_seq\":{s},\"updated_at\":\"{s}\"}}", .{ record_id, field_values, version_seq_str, updated_at }) catch
            return errorResult(allocator, 500, "serialization_failed");
        defer allocator.free(item_json);
        buf.appendSlice(allocator, item_json) catch return errorResult(allocator, 500, "out_of_memory");
    }

    buf.appendSlice(allocator, "]") catch return errorResult(allocator, 500, "out_of_memory");
    return .{ .status_code = 200, .body = buf.toOwnedSlice(allocator) catch "[]" };
}

pub fn handleGetRecord(allocator: std.mem.Allocator, pool: *Pool, entity_type: []const u8, record_id: []const u8, user_id: []const u8) HandlerResult {
    _ = user_id;
    var conn = pool.acquire() catch return errorResult(allocator, 503, "service_unavailable");
    defer pool.release(conn);

    var result = conn.query(allocator, "SELECT field_values, version_seq, updated_at FROM entity_record_latest WHERE entity_type = $1 AND record_id = $2", &.{ entity_type, record_id }) catch
        return errorResult(allocator, 500, "query_failed");
    defer result.deinit();

    if (result.rows.len == 0) return errorResult(allocator, 404, "record_not_found");
    const row = result.rows[0];

    const field_values = row[0] orelse "{}";
    const version_seq_str = row[1] orelse "0";
    const updated_at = row[2] orelse "";

    const body = std.fmt.allocPrint(allocator, "{{\"record_id\":\"{s}\",\"entity_type\":\"{s}\",\"field_values\":{s},\"version_seq\":{s},\"updated_at\":\"{s}\"}}", .{ record_id, entity_type, field_values, version_seq_str, updated_at }) catch
        return errorResult(allocator, 500, "serialization_failed");

    return .{ .status_code = 200, .body = body };
}

pub fn handleDeleteRecord(
    allocator: std.mem.Allocator,
    pool: *Pool,
    ev_store: anytype,
    entity_type: []const u8,
    record_id: []const u8,
    actor_id: []const u8,
    tenant_id: []const u8,
) HandlerResult {
    const idempotency_key = std.fmt.allocPrint(allocator, "delete-{s}", .{record_id}) catch record_id;
    defer if (!std.mem.eql(u8, idempotency_key, record_id)) allocator.free(idempotency_key);

    const params = entity_commands.DeleteRecordParams{
        .entity_type = entity_type,
        .record_id = record_id,
        .idempotency_key = idempotency_key,
        .actor_id = actor_id,
        .tenant_id = tenant_id,
    };

    const res = entity_commands.deleteRecord(allocator, pool, ev_store, {}, params) catch |err| switch (err) {
        error.InvalidEntityType => return errorResult(allocator, 404, "entity_type_not_found"),
        error.InvalidRecord => return errorResult(allocator, 404, "record_not_found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer {
        allocator.free(res.record_id);
        allocator.free(res.entity_type);
        allocator.free(res.field_values);
    }

    const body_out = std.fmt.allocPrint(allocator, "{{\"record_id\":\"{s}\",\"entity_type\":\"{s}\",\"version_seq\":{d}}}", .{ res.record_id, res.entity_type, res.version_seq }) catch
        return errorResult(allocator, 500, "serialization_failed");

    return .{ .status_code = 200, .body = body_out };
}

fn errorResult(allocator: std.mem.Allocator, status_code: u16, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{code}) catch "{\"error\":\"internal_error\"}";
    return .{ .status_code = status_code, .body = body };
}
