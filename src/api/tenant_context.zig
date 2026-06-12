//! Thread-local storage for the current request's resolved tenant ID
//! and storage mode.
//!
//! Owned by authentication middleware; DB pool acquire reads this context and
//! applies it to PostgreSQL session config for every checked-out connection.
//!
//! ISS-501: Added StorageMode enum and threadlocal storage so the connection
//! routing layer can branch on LEGACY_RLS vs SCHEMA without re-querying the
//! tenant table on every connection acquisition.

const std = @import("std");

pub const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

/// ISS-501: Tenant storage mode — resolved once per request from
/// public.tenants.storage_mode.  Determines search_path and session
/// variable configuration for every connection acquired during the request.
pub const StorageMode = enum {
    LEGACY_RLS,
    SCHEMA,
};

pub threadlocal var _current: [36]u8 = DEFAULT_TENANT_ID.*;
pub threadlocal var _has_value: bool = false;
pub threadlocal var _storage_mode: StorageMode = .LEGACY_RLS;
pub threadlocal var _storage_mode_resolved: bool = false;

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
    _storage_mode_resolved = false;
    _storage_mode = .LEGACY_RLS;
}

/// ISS-501: Return the storage mode resolved for the current request.
/// Returns LEGACY_RLS when no mode has been resolved (safe default).
pub fn getStorageMode() StorageMode {
    return _storage_mode;
}

/// ISS-501: Set the storage mode for the current request.
/// Called once by pool.acquire() after reading storage_mode from the DB.
pub fn setStorageMode(mode: StorageMode) void {
    _storage_mode = mode;
    _storage_mode_resolved = true;
}

/// ISS-501: True if storage mode has been resolved for this request.
pub fn hasStorageMode() bool {
    return _storage_mode_resolved;
}

test "tenant_context: empty by default" {
    clear();
    try std.testing.expectEqualStrings("", get());
    try std.testing.expectEqual(StorageMode.LEGACY_RLS, getStorageMode());
    try std.testing.expect(!hasStorageMode());
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

test "tenant_context: storage mode set/get round-trip" {
    clear();
    try std.testing.expectEqual(StorageMode.LEGACY_RLS, getStorageMode());
    setStorageMode(.SCHEMA);
    try std.testing.expectEqual(StorageMode.SCHEMA, getStorageMode());
    try std.testing.expect(hasStorageMode());
    clear();
    try std.testing.expect(!hasStorageMode());
}
