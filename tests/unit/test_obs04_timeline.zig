//! Unit tests for OBS-04 timeline handler input-validation paths.
//!
//! These tests cover early validation exits that happen before any DB access.
//! They intentionally pass an undefined Store pointer because the handler
//! returns before touching the store on these branches.

const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const instances = bpm.instance_routes;
const EventStore = bpm.event_store.Store;

fn base64urlEncode(alloc: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out_len = encoder.calcSize(data.len);
    const buf = try alloc.alloc(u8, out_len);
    _ = encoder.encode(buf, data);
    return buf;
}

test "TC-OBS-04-01: handleTimeline invalid instance_id returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;

    const result = instances.handleTimeline(
        &dummy_store,
        alloc,
        "not-a-uuid",
        .{ .cursor = null, .page_size = 50 },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_INSTANCE_ID"));
}

test "TC-OBS-04-02: handleTimeline page_size out of range returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;

    const result = instances.handleTimeline(
        &dummy_store,
        alloc,
        "00000000-0000-0000-0000-000000000001",
        .{ .cursor = null, .page_size = 201 },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_PAGE_SIZE"));
}

test "TC-OBS-04-03: handleTimeline invalid base64 cursor returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;

    const result = instances.handleTimeline(
        &dummy_store,
        alloc,
        "00000000-0000-0000-0000-000000000001",
        .{ .cursor = "!!!not-base64!!!", .page_size = 50 },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_CURSOR"));
}

test "TC-OBS-04-04: handleTimeline wrong-endpoint cursor returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;

    const raw = "H:1716412800000000:77";
    const cursor = try base64urlEncode(alloc, raw);
    defer alloc.free(cursor);

    const result = instances.handleTimeline(
        &dummy_store,
        alloc,
        "00000000-0000-0000-0000-000000000001",
        .{ .cursor = cursor, .page_size = 50 },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INVALID_CURSOR"));
}

test "TC-OBS-04-05: handleTimeline expired cursor returns HTTP 410" {
    const alloc = testing.allocator;
    var dummy_store: EventStore = undefined;

    const raw = "TL:1:42";
    const cursor = try base64urlEncode(alloc, raw);
    defer alloc.free(cursor);

    const result = instances.handleTimeline(
        &dummy_store,
        alloc,
        "00000000-0000-0000-0000-000000000001",
        .{ .cursor = cursor, .page_size = 50 },
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 410), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "CURSOR_EXPIRED"));
}
