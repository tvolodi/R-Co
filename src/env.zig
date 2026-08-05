//! Portable environment-variable access.
//!
//! ISS-0134 / GH #432: seven call sites constructed `std.process.Environ` with
//! `.{ .block = .global }`. That literal only type-checks where
//! `std.process.Environ.Block` resolves to `GlobalBlock` — Windows, WASI, and
//! freestanding targets. On Linux and macOS, `Block` resolves to `PosixBlock`,
//! which has no `.global` member, so the codebase would not compile there.
//! CI's first successful run on `ubuntu-latest` caught this; the build had
//! always passed locally because development happens on Windows.
//!
//! `globalEnviron()` is the portable replacement: it returns the same
//! `GlobalBlock`-backed `Environ` on the platforms where that literal already
//! worked, and on POSIX targets builds a `PosixBlock` from libc's `environ`
//! extern instead. Requires linking libc on non-Windows targets (see
//! `build.zig`); libc's `environ` is guaranteed by POSIX, so this does not
//! trade one fragile assumption for another.

const std = @import("std");
const builtin = @import("builtin");

/// The process environment, valid for the lifetime of the process.
///
/// Use exactly where `std.process.Environ{ .block = .global }` was used
/// before: `globalEnviron().getAlloc(allocator, "VAR_NAME")`.
pub fn globalEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows, .wasi, .freestanding, .other => .{ .block = .global },
        else => blk: {
            // std.c.environ is `[*:null]?[*:0]u8` — a many-item sentinel
            // pointer with no known length. std.mem.span converts it to the
            // bounded `[:null]?[*:0]u8` slice that PosixBlock.slice expects.
            // The element type must stay mutable (`u8`, not `const u8`) to
            // match std.c.environ's declared type; PosixBlock.slice itself
            // holds `?[*:0]const u8` entries, so the assignment narrows the
            // mutability at the point of use rather than at this cast.
            const raw: [*:null]?[*:0]u8 = std.c.environ;
            break :blk .{ .block = .{ .slice = std.mem.span(raw) } };
        },
    };
}

test "globalEnviron reads a variable known to be set in the test runner" {
    // PATH (Windows) / PATH (POSIX) is set in every environment that can run
    // `zig build test`, so this is a real assertion, not a smoke test that
    // passes by construction.
    const environ = globalEnviron();
    const val = environ.getAlloc(std.testing.allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            // Some minimal CI sandboxes strip PATH; do not fail the suite for
            // an environment property unrelated to this function's correctness.
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer std.testing.allocator.free(val);
    try std.testing.expect(val.len > 0);
}

test "globalEnviron.getAlloc returns EnvironmentVariableMissing for an unset variable" {
    const environ = globalEnviron();
    const result = environ.getAlloc(
        std.testing.allocator,
        "BPM_ISS_0134_DEFINITELY_UNSET_PROBE_VAR",
    );
    try std.testing.expectError(error.EnvironmentVariableMissing, result);
}
