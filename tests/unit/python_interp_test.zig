//! Unit tests for tests/integration/python_interp.zig — ISS-0147 (GitHub #374).
//!
//! These cover the interpreter resolver itself: that what it returns can
//! actually execute Python, that the liveness probe rejects a non-interpreter
//! (the Windows Store App Execution Alias stub is the motivating case), and
//! that the process-lifetime cache memoises without being owned by any single
//! test's allocator.
//!
//! No database is required. The resolver spawns short-lived `python -c`
//! subprocesses only.
//!
//! Design: src/design/python_interpreter_resolution.md

const std = @import("std");
const python_interp = @import("python_interp");

test "resolve returns an interpreter that can actually execute Python" {
    const alloc = std.testing.allocator;

    const exe = try python_interp.resolve(alloc, std.testing.io);
    defer alloc.free(exe);

    try std.testing.expect(exe.len > 0);

    // The property the whole module exists to guarantee: what comes back runs
    // Python. A Store alias stub would fail here with exit 49.
    const result = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ exe, "-c", "import sys; sys.stdout.write('hello')" },
        .stdout_limit = .limited(4 * 1024),
        .stderr_limit = .limited(4 * 1024),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "hello") != null);
}

test "probe rejects a path that cannot be spawned" {
    const alloc = std.testing.allocator;
    // A spawn failure must be a rejection, not a crash or an error.
    try std.testing.expect(
        !python_interp.probe(alloc, std.testing.io, "definitely-not-a-real-executable-bpm"),
    );
}

test "probe rejects a program that exits 0 without emitting the sentinel" {
    const alloc = std.testing.allocator;

    // The resolver must not accept just any runnable program. Checking the
    // sentinel on stdout — rather than only the exit code — is what makes the
    // probe robust to a stub that exits 0 while doing nothing useful.
    const py = try python_interp.resolve(alloc, std.testing.io);
    defer alloc.free(py);

    // `python` itself passes the probe; a shell command that ignores `-c
    // <probe source>` and prints nothing must not.
    const not_an_interpreter = if (@import("builtin").os.tag == .windows) "cmd.exe" else "true";
    try std.testing.expect(!python_interp.probe(alloc, std.testing.io, not_an_interpreter));
}

test "resolveCached memoises: repeat calls return the same backing memory" {
    const alloc = std.testing.allocator;
    defer python_interp.deinitCache();

    const a = try python_interp.resolveCached(alloc, std.testing.io);
    const b = try python_interp.resolveCached(alloc, std.testing.io);

    // Same backing memory — callers must not free it (design §5 ownership table).
    try std.testing.expectEqual(a.ptr, b.ptr);
    try std.testing.expectEqual(a.len, b.len);

    // This test's allocator is leak-checked at test end and the cache is
    // deliberately NOT allocated from it — that is the point of cache_allocator.
    // A cache owned by a test allocator would be an invalid free when a later
    // test released it, which is exactly what the first implementation hit.
}
