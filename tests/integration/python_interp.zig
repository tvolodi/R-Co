//! Deterministic Python interpreter resolution for test subprocesses.
//!
//! ISS-0147 (GitHub #374). Tests that assert on a Python tool's exit code must
//! actually run a Python interpreter. Selecting one by bare name ("python")
//! does not guarantee that: on Windows, `python` resolves to the Microsoft
//! Store App Execution Alias stub on many machines, which prints
//!
//!     Python was not found; run without arguments to install from the
//!     Microsoft Store, ...
//!
//! and exits 49. A test comparing that against a linter's real exit code (1 or
//! 0) fails for a reason that has nothing to do with the linter. Which of the
//! several `python` entries on PATH wins is not stable between an interactive
//! shell and a zig-build-spawned test binary, so name-based selection cannot be
//! made deterministic by reordering names alone — that was ISS-0138's (GH #440)
//! fix for the sibling `python3` case, and it does not cover this one.
//!
//! This module replaces name-based selection with an ordered candidate list in
//! which every candidate must pass an execution probe before it is accepted.
//!
//! Design: src/design/python_interpreter_resolution.md

const std = @import("std");
const builtin = @import("builtin");
const portable_env = @import("env");

/// Sentinel the probe requires on stdout. Checking for this, rather than only
/// for exit 0, keeps the probe robust against a stub that exits 0 while doing
/// nothing useful.
const probe_sentinel = "BPM_PY_OK";
const probe_source = "import sys; sys.stdout.write('" ++ probe_sentinel ++ "')";

pub const PythonInterpError = error{
    /// No candidate passed the liveness probe.
    NoPythonInterpreter,
    /// $BPM_PYTHON was set and non-empty but failed the liveness probe.
    /// Resolution never falls through to autodetection in this case — an
    /// override that silently resolved to a different interpreter than the one
    /// named would reintroduce exactly the non-determinism this module exists
    /// to remove. See design §3.
    BpmPythonOverrideUnusable,
} || std.mem.Allocator.Error;

/// The candidates tried, in order, when $BPM_PYTHON is not set. Reported in the
/// failure message so a developer can see what was attempted.
pub const path_candidates = [_][]const u8{ "python3", "python" };

// ---------------------------------------------------------------------------
// Liveness probe
// ---------------------------------------------------------------------------

/// Run `<exe> -c "<probe>"` and report whether it behaved like a real
/// interpreter: terminated normally, exit 0, and wrote the sentinel to stdout.
///
/// Any spawn failure (candidate absent, not executable) is a rejection, not an
/// error — resolution moves on to the next candidate.
fn probe(allocator: std.mem.Allocator, io: std.Io, exe: []const u8) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ exe, "-c", probe_source },
        .stdout_limit = .limited(4 * 1024),
        .stderr_limit = .limited(4 * 1024),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    return std.mem.indexOf(u8, result.stdout, probe_sentinel) != null;
}

// ---------------------------------------------------------------------------
// Candidate construction
// ---------------------------------------------------------------------------

/// Interpreter path inside a virtualenv rooted at `root`:
/// `<root>/Scripts/python.exe` on Windows, `<root>/bin/python` elsewhere.
fn venvInterpreter(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const rel = if (builtin.os.tag == .windows) "Scripts/python.exe" else "bin/python";
    return std.fs.path.join(allocator, &.{ root, rel });
}

fn envVar(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const environ = portable_env.globalEnviron();
    return environ.getAlloc(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => null,
    };
}

// ---------------------------------------------------------------------------
// Resolution
// ---------------------------------------------------------------------------

/// Resolve a Python interpreter that is verified executable.
///
/// Order: $BPM_PYTHON (authoritative), repo `.venv`, $VIRTUAL_ENV, `python3`,
/// `python`. Each candidate is accepted only after passing the liveness probe.
///
/// OWNERSHIP: caller owns the returned slice and must free it with `allocator`.
/// (`resolveCached` has the opposite contract — see its doc comment.)
pub fn resolve(allocator: std.mem.Allocator, io: std.Io) PythonInterpError![]const u8 {
    // 1. $BPM_PYTHON — authoritative when set and non-empty. A value that fails
    //    the probe is a hard failure, never a fallback.
    if (try envVar(allocator, "BPM_PYTHON")) |override| {
        errdefer allocator.free(override);
        const trimmed = std.mem.trim(u8, override, " \t\r\n");
        if (trimmed.len > 0) {
            if (probe(allocator, io, trimmed)) {
                if (trimmed.len == override.len) return override;
                // Trimming changed the slice — return an exactly-sized copy so
                // the caller's free() matches the allocation.
                const exact = try allocator.dupe(u8, trimmed);
                allocator.free(override);
                return exact;
            }
            std.debug.print(
                "python_interp: $BPM_PYTHON is set to '{s}' but it is not a working " ++
                    "Python interpreter (probe failed). Refusing to fall back to PATH — " ++
                    "unset BPM_PYTHON to use autodetection, or point it at a real interpreter.\n",
                .{trimmed},
            );
            allocator.free(override);
            return error.BpmPythonOverrideUnusable;
        }
        // Empty/whitespace is treated as unset, so a blank CI variable does not
        // become a hard failure.
        allocator.free(override);
    }

    // 2. Repository .venv, relative to the repo root. Integration tests run
    //    with cwd = repo root (build.zig setCwd(b.path("."))).
    {
        const candidate = try venvInterpreter(allocator, ".venv");
        if (probe(allocator, io, candidate)) return candidate;
        allocator.free(candidate);
    }

    // 3. Active virtualenv, if this process inherited one.
    if (try envVar(allocator, "VIRTUAL_ENV")) |venv_root| {
        defer allocator.free(venv_root);
        if (venv_root.len > 0) {
            const candidate = try venvInterpreter(allocator, venv_root);
            if (probe(allocator, io, candidate)) return candidate;
            allocator.free(candidate);
        }
    }

    // 4/5. PATH names last — the non-deterministic input. The probe is what
    //      rejects the WindowsApps alias stub here.
    for (path_candidates) |name| {
        if (probe(allocator, io, name)) return try allocator.dupe(u8, name);
    }

    std.debug.print(
        "python_interp: no working Python interpreter found. Tried: $BPM_PYTHON (unset or " ++
            "empty), .venv, $VIRTUAL_ENV, python3, python. Set BPM_PYTHON to a real " ++
            "interpreter, or create the repository .venv.\n",
        .{},
    );
    return error.NoPythonInterpreter;
}

// ---------------------------------------------------------------------------
// Process-lifetime cache
// ---------------------------------------------------------------------------

var cached: ?[]const u8 = null;

/// The cache is deliberately backed by `page_allocator`, NOT by the allocator
/// the caller passes in.
///
/// Zig's test runner hands each `test` block its own `std.testing.allocator`
/// instance and leak-checks it at that test's end. A cache allocated under one
/// test's allocator and freed under a later test's is an invalid free, and a
/// cache that outlives the test that filled it is reported as that test's leak.
/// Since the cache is process-lifetime by definition, it must not be owned by
/// any single test's allocator. The caller's allocator is still used for the
/// probe subprocesses inside `resolve`, which are freed before it returns.
const cache_allocator = std.heap.page_allocator;

/// `resolve` with a process-lifetime cache, so repeated calls within one test
/// binary probe at most once.
///
/// OWNERSHIP: the returned slice is owned by this module, NOT by the caller.
/// Callers must NOT free it; it stays valid until `deinitCache` is called.
/// This differs from `resolve` deliberately — freeing it per call would be a
/// double-free on the second call site.
///
/// Failures are not cached: only a successful resolution is memoised, so a
/// transient probe failure does not poison the rest of the run.
pub fn resolveCached(allocator: std.mem.Allocator, io: std.Io) PythonInterpError![]const u8 {
    if (cached) |c| return c;
    // Resolve using the caller's allocator (probe scratch is freed inside),
    // then re-home the result in the process-lifetime allocator.
    const resolved = try resolve(allocator, io);
    defer allocator.free(resolved);

    const owned = try cache_allocator.dupe(u8, resolved);
    cached = owned;
    return owned;
}

/// Release the cached interpreter path.
///
/// Optional: the cache is not owned by any test's allocator, so leaving it
/// allocated does not fail a leak check. Provided for callers that want to
/// force a re-probe. Takes no allocator — the cache has its own.
pub fn deinitCache() void {
    if (cached) |c| {
        cache_allocator.free(@constCast(c));
        cached = null;
    }
}

// ---------------------------------------------------------------------------
// Unit tests — no database required.
// ---------------------------------------------------------------------------

test "resolve returns an interpreter that can execute code" {
    const alloc = std.testing.allocator;
    const exe = try resolve(alloc, std.testing.io);
    defer alloc.free(exe);

    try std.testing.expect(exe.len > 0);

    // The resolved interpreter must actually run Python — this is the property
    // the whole module exists to guarantee.
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

test "probe rejects a non-interpreter" {
    const alloc = std.testing.allocator;
    // A path that cannot spawn must be rejected, not crash.
    try std.testing.expect(!probe(alloc, std.testing.io, "definitely-not-a-real-executable-bpm"));
}

test "resolveCached memoises: repeat calls return the same backing memory" {
    const alloc = std.testing.allocator;
    defer deinitCache();

    const a = try resolveCached(alloc, std.testing.io);
    const b = try resolveCached(alloc, std.testing.io);
    // Same backing memory — callers must not free it (design §5 ownership table).
    // Note this test's allocator is leak-checked at test end and the cache is
    // NOT allocated from it, which is the point of `cache_allocator`.
    try std.testing.expectEqual(a.ptr, b.ptr);
    try std.testing.expectEqual(a.len, b.len);
}
