//! ISS-0173 / GH-501 regression test: the orphan `src/oidc/jwks.zig` re-export
//! is gone from `src/main.zig` and the file itself is deleted.
//!
//! Background: per the diagnosis at docs/issue-reports/ISS-0173-gh501-diagnosis.yaml,
//! src/oidc/jwks.zig was orphaned on three independent axes — no `addTest` root
//! reached it, build.zig did not register it as a named module, and the only
//! caller of its re-export was the re-export itself (`src/main.zig:78`). The
//! decision (State A — DELETE) is documented in the design at
//! src/design/iss0173-gh501-jwks-zig016-fix.md.
//!
//! This test prevents the blind spot from returning:
//!   1. The re-export line `pub const oidc_jwks = @import("oidc/jwks.zig");`
//!      MUST NOT appear in src/main.zig.
//!   2. The file src/oidc/jwks.zig MUST NOT exist on the filesystem.
//!   3. The file src/oidc/jwks.zig MUST NOT exist in git's tracked file index.
//!   4. The literal identifier `oidc_jwks` MUST NOT appear in src/main.zig.
//!
//! Per-test UUIDs are used to give each test a unique identity so the test
//! isolation linter can confirm no shared state across cases.
//!
//! Run with: `zig build test-iss0173-orphan` (also reached by `zig build test`).

const std = @import("std");
const testing = std.testing;

// Tiny inline UUID v4 generator. Per-test UUIDs are constructed by each test
// and used only for that test's allocator bookkeeping (none here, but the
// lint_test_isolation.py check expects per-test labels). The UUID is derived
// from the test's source location via @src() to make it deterministic but
// unique per test invocation.
fn newTestUuid(buf: *[36]u8, src: std.builtin.SourceLocation) void {
    const alphabet = "0123456789abcdef";
    // Mix the source location's line and column into a deterministic seed.
    var seed: u64 = (@as(u64, @intCast(src.line)) *% 0x9E3779B97F4A7C15) ^
        (@as(u64, @intCast(src.column)) *% 0xBF58476D1CE4E5B9);
    for (buf, 0..) |*c, i| {
        switch (i) {
            8, 13, 18, 23 => c.* = '-',
            else => {
                if (i == 14) {
                    c.* = '4';
                } else if (i == 19) {
                    c.* = "89ab"[@as(usize, @intCast(seed & 0x3))];
                    seed >>= 2;
                } else {
                    seed = seed *% 6364136223846793005 +% 1442695040888963407;
                    c.* = alphabet[@as(usize, @intCast((seed >> 32) & 0xF))];
                }
            },
        }
    }
}

// Read entire file into an owned buffer. Returns the file content as a slice
// owned by the caller. Fails with FileNotFound if the file is absent.
fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.Io.Dir.cwd();
    const content = try dir.readFileAlloc(std.testing.io, path, allocator, std.Io.Limit.limited(1024 * 1024));
    return content;
}

// ---------------------------------------------------------------------------
// TC-ISS-0173-01: src/main.zig does NOT contain the orphan re-export line.
// ---------------------------------------------------------------------------
test "TC-ISS-0173-01: src/main.zig does not declare oidc_jwks re-export" {
    var uuid: [36]u8 = undefined;
    newTestUuid(&uuid, @src());
    std.debug.print("iss0173-orphan TC-01 uuid={s}\n", .{uuid});

    const allocator = testing.allocator;
    const main_path = "src/main.zig";

    const content = readFileAlloc(allocator, main_path) catch |err| {
        std.debug.print("FAIL: could not read {s}: {s}\n", .{ main_path, @errorName(err) });
        return err;
    };
    defer allocator.free(content);

    // The re-export line MUST NOT appear. We search for the exact bare-token
    // form to avoid matching accidental substrings inside a comment.
    const needle = "pub const oidc_jwks = @import";
    if (std.mem.indexOf(u8, content, needle) != null) {
        std.debug.print(
            "FAIL: src/main.zig still contains the orphan re-export: {s}\n",
            .{needle},
        );
        return error.ReExportStillPresent;
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-0173-02: src/oidc/jwks.zig does NOT exist on the filesystem.
// ---------------------------------------------------------------------------
test "TC-ISS-0173-02: src/oidc/jwks.zig is deleted from the filesystem" {
    var uuid: [36]u8 = undefined;
    newTestUuid(&uuid, @src());
    std.debug.print("iss0173-orphan TC-02 uuid={s}\n", .{uuid});

    const orphan_path = "src/oidc/jwks.zig";
    const dir = std.Io.Dir.cwd();

    // statFile returns error.FileNotFound if the file is gone.
    if (dir.statFile(std.testing.io, orphan_path, .{})) |_| {
        std.debug.print(
            "FAIL: {s} still exists on the filesystem\n",
            .{orphan_path},
        );
        return error.OrphanFileStillPresent;
    } else |err| switch (err) {
        error.FileNotFound => return, // expected — the file is gone
        else => return err,
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-0173-03: src/oidc/jwks.zig is NOT tracked by git.
// ---------------------------------------------------------------------------
test "TC-ISS-0173-03: src/oidc/jwks.zig is not tracked by git" {
    var uuid: [36]u8 = undefined;
    newTestUuid(&uuid, @src());
    std.debug.print("iss0173-orphan TC-03 uuid={s}\n", .{uuid});

    const allocator = testing.allocator;

    // Spawn `git ls-files -- src/oidc/jwks.zig` and require it to print
    // nothing for the file. If the file is staged or committed, the command
    // returns the path; if it is absent, the command returns empty.
    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "git", "ls-files", "--", "src/oidc/jwks.zig" },
    }) catch |err| {
        std.debug.print("FAIL: could not invoke git ls-files: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print(
            "FAIL: git ls-files exited non-zero: {s}\n",
            .{result.stderr},
        );
        return error.GitLsFilesFailed;
    }

    if (result.stdout.len > 0) {
        std.debug.print(
            "FAIL: git ls-files still returns {s} for src/oidc/jwks.zig\n",
            .{result.stdout},
        );
        return error.OrphanFileTrackedByGit;
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-0173-04: the literal identifier `oidc_jwks` is absent from src/main.zig.
// ---------------------------------------------------------------------------
test "TC-ISS-0173-04: src/main.zig does not contain the literal 'oidc_jwks' identifier" {
    var uuid: [36]u8 = undefined;
    newTestUuid(&uuid, @src());
    std.debug.print("iss0173-orphan TC-04 uuid={s}\n", .{uuid});

    const allocator = testing.allocator;
    const main_path = "src/main.zig";

    const content = readFileAlloc(allocator, main_path) catch |err| {
        return err;
    };
    defer allocator.free(content);

    var line_no: usize = 1;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| : (line_no += 1) {
        if (std.mem.indexOf(u8, line, "oidc_jwks") != null) {
            std.debug.print(
                "FAIL: src/main.zig:{d} contains 'oidc_jwks': {s}\n",
                .{ line_no, line },
            );
            return error.OrphanIdentifierStillPresent;
        }
    }
}
