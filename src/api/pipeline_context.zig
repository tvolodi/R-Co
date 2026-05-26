//! Thread-local storage for the current request's resolved pipeline run ID.
//!
//! The value is populated by trusted auth/request context resolution and then
//! applied to PostgreSQL session config (`bpm.pipeline_run_id`) on connection
//! checkout. Empty means no pipeline correlation for the request.

const std = @import("std");

pub threadlocal var _current: [36]u8 = std.mem.zeroes([36]u8);
pub threadlocal var _has_value: bool = false;

pub fn get() []const u8 {
    if (!_has_value) return "";
    return _current[0..];
}

pub fn set(pipeline_run_id: []const u8) void {
    if (pipeline_run_id.len != 36) {
        clear();
        return;
    }
    @memcpy(_current[0..], pipeline_run_id);
    _has_value = true;
}

pub fn clear() void {
    _has_value = false;
}

test "pipeline_context: empty by default" {
    clear();
    try std.testing.expectEqualStrings("", get());
}

test "pipeline_context: set/get round-trip" {
    const run_id = "11111111-2222-3333-4444-555555555555";
    set(run_id);
    defer clear();
    try std.testing.expectEqualStrings(run_id, get());
}

test "pipeline_context: clear resets to empty" {
    set("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    clear();
    try std.testing.expectEqualStrings("", get());
}