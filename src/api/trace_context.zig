//! Thread-local storage for the current request's trace ID.
//!
//! Owned by the trace middleware; reads are safe from any module
//! that imports trace_context.zig.
//!
//! The slice points into a per-request heap allocation managed by
//! the trace middleware.  Accessing get() outside an active request
//! returns an empty slice.
//!
//! Invariant: _current always points to a valid (possibly zero-length)
//! UTF-8 string.  It is never a dangling pointer.  The trace middleware
//! must clear() before freeing the backing allocation.

/// Thread-local backing variable.
/// Do NOT access directly — use get(), set(), clear().
pub threadlocal var _current: []const u8 = "";

/// Return the active trace ID for the current thread.
/// Returns "" if no request is in progress on this thread.
pub fn get() []const u8 {
    return _current;
}

/// Set the active trace ID.  Called only by trace.zig at request start.
pub fn set(id: []const u8) void {
    _current = id;
}

/// Clear the active trace ID.  Called only by trace.zig after response is sent.
pub fn clear() void {
    _current = "";
}

// ── Embedded unit tests ───────────────────────────────────────────────────────

const std = @import("std");
const testing = std.testing;

test "trace_context: get returns empty string by default" {
    clear();
    try testing.expectEqualStrings("", get());
}

test "trace_context: set and get round-trip" {
    const id = "abc-123";
    set(id);
    defer clear();
    try testing.expectEqualStrings("abc-123", get());
}

test "trace_context: clear resets to empty string" {
    set("some-trace-id");
    clear();
    try testing.expectEqualStrings("", get());
}
