//! Thread-local storage for the current request's resolved tenant ID.
//!
//! Owned by authentication middleware; DB pool acquire reads this context and
//! applies it via search_path to scope every checked-out connection to the
//! correct tenant schema (SPT-03: bpm session variable removed, search_path only).

const std = @import("std");

pub const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

pub threadlocal var _current: [36]u8 = DEFAULT_TENANT_ID.*;
pub threadlocal var _has_value: bool = false;

pub fn get() []const u8 {
    if (!_has_value) return "";
    return _current[0..];
}

pub fn set(tenant_id: []const u8) void {
    if (tenant_id.len == 0) {
        clear();
        return;
    }
    if (tenant_id.len != 36) {
        clear();
        return;
    }
    @memcpy(_current[0..], tenant_id);
    _has_value = true;
}

pub fn clear() void {
    _has_value = false;
}

test "tenant_context: empty by default" {
    clear();
    try std.testing.expectEqualStrings("", get());
}

test "tenant_context: set/get round-trip" {
    const tenant = "11111111-1111-1111-1111-111111111111";
    set(tenant);
    defer clear();
    try std.testing.expectEqualStrings(tenant, get());
}

test "tenant_context: clear resets to empty" {
    set(DEFAULT_TENANT_ID);
    clear();
    try std.testing.expectEqualStrings("", get());
}
