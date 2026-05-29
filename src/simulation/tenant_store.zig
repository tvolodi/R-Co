const std = @import("std");
const event_store = @import("../event_store/store.zig");
const ctx_mod = @import("context.zig");
const types = @import("types.zig");

pub fn appendSimulationEvent(
    allocator: std.mem.Allocator,
    store: *event_store.Store,
    ctx: *const types.SimulationContext,
    event: types.EventAppendInput,
) types.SimulationError!event_store.EventRecord {
    const tenant_id = tenantIdToString(ctx.simulation_tenant_id);

    const result = store.append(allocator, .{
        .tenant_id = tenant_id[0..],
        .instance_id = event.instance_id,
        .event_type = event.event_type,
        .payload = event.payload,
        .actor_id = event.actor_id,
        .idempotency_key = event.idempotency_key,
        .metadata = event.metadata,
        .pipeline_run_id = event.pipeline_run_id,
    }) catch |err| {
        return mapStoreError(err);
    };

    return result.record;
}

pub fn queryTenantEvents(
    allocator: std.mem.Allocator,
    store: *event_store.Store,
    tenant_id: types.TenantId,
    filter: types.EventQueryFilter,
) types.SimulationError![]event_store.EventRecord {
    if (ctx_mod.isSimulationTenant(tenant_id)) return error.SimulationVisibilityViolation;

    const tenant_text = tenantIdToString(tenant_id);
    const after_global_seq = filter.after_global_seq;

    return store.readGlobal(allocator, .{
        .tenant_id = tenant_text[0..],
        .after_global_seq = after_global_seq,
        .limit = filter.limit,
    }) catch |err| {
        return mapStoreError(err);
    };
}

pub fn tenantIdToString(tenant_id: types.TenantId) [36]u8 {
    var out: [36]u8 = undefined;
    var di: usize = 0;
    var si: usize = 0;
    while (si < tenant_id.len) : (si += 1) {
        if (di == 8 or di == 13 or di == 18 or di == 23) {
            out[di] = '-';
            di += 1;
        }
        writeHexByte(out[di .. di + 2], tenant_id[si]);
        di += 2;
    }
    return out;
}

pub fn parseTenantId(tenant_text: []const u8) types.SimulationError!types.TenantId {
    if (tenant_text.len != 36) return error.InvalidSimulationContext;

    var out: [16]u8 = undefined;
    var si: usize = 0;
    var di: usize = 0;
    while (si < tenant_text.len and di < out.len) {
        if (tenant_text[si] == '-') {
            si += 1;
            continue;
        }
        if (si + 1 >= tenant_text.len) return error.InvalidSimulationContext;
        out[di] = (try hexNibble(tenant_text[si]) << 4) | try hexNibble(tenant_text[si + 1]);
        si += 2;
        di += 1;
    }
    if (di != out.len) return error.InvalidSimulationContext;
    return out;
}

fn writeHexByte(dst: []u8, b: u8) void {
    const alphabet = "0123456789abcdef";
    dst[0] = alphabet[(b >> 4) & 0x0f];
    dst[1] = alphabet[b & 0x0f];
}

fn hexNibble(c: u8) types.SimulationError!u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return 10 + (c - 'a');
    if (c >= 'A' and c <= 'F') return 10 + (c - 'A');
    return error.InvalidSimulationContext;
}

fn mapStoreError(err: anyerror) types.SimulationError {
    return switch (err) {
        error.PoolExhausted,
        error.TransactionFailed,
        error.PayloadSchemaInvalid,
        error.UnknownEventType,
        error.MetadataInvalid,
        error.IdempotencyKeyMissing,
        error.IdempotencyKeyTooLong,
        error.PayloadInvalid,
        error.ActorIdMissing,
        error.InstanceNotFound,
        error.InstanceTerminated,
        error.PipelineRunIdMetadataConflict,
        error.MissingTenantContext,
        => error.PersistenceFailure,
        else => error.PersistenceFailure,
    };
}

test "tenant id round-trip" {
    const original: types.TenantId = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const text = tenantIdToString(original);
    const parsed = try parseTenantId(text[0..]);
    try std.testing.expectEqualSlices(u8, &original, &parsed);
}
