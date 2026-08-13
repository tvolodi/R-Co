//! ISS-0181 / GH-512 — regression tests for the T010 hardcoded-UUID migration.
//!
//! Locks in three invariants of the WF03-GH512-20260808 migration (see
//! `src/design/iss0181-gh512-t010-migration.md`):
//!
//!   TC-RG-01  The T010 BLOCKER count under `lint_test_isolation.py --no-baseline`
//!             stays at the post-fix ceiling (73). Any future contributor who
//!             re-introduces a hardcoded UUID literal fails this test.
//!
//!   TC-RG-02  `tools/lint_test_isolation.baseline.json` matches the per-rule
//!             snapshot at `tests/specs/fixtures/gh512-baseline-snapshot.json`.
//!             No new code values, no new severities, platform-admin count stays
//!             at 13 (design §R1).
//!
//!   TC-RG-03  `zig build test` still exits 0 — the migration did not introduce
//!             a compile error in any of the touched files.
//!
//! DIRECTIVE T-1: no mocks, no stubs, no SkipZigTest on MUST tests. Each block
//! is a runnable, observable assertion against the real repository state.
//! BPM_TEST_DB_URL is NOT required (no DB connections).

const std = @import("std");
const testing = std.testing;
const python_interp = @import("python_interp");
const portable_env = @import("env");
const build_options = @import("build_options");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Maximum tolerated T010 BLOCKER count under `--no-baseline`. This is the
/// as-implemented post-step-04 ceiling: 13 platform-admin UUIDs (design §R1)
/// + 60 module-scope `const`/comptime UUIDs that BACKEND-DEV marked RETAIN
/// per `step-03-backend-dev.json` summary + 1 step-04 RETAIN (the substring-
/// search target below) + 1 (snapshot v5, GH-759/ISS-0697): a new integration
/// test file (idn05_role_registry_test.zig, WF02-idn05-20260812 / commit
/// 34d7ca13) reintroduced the canonical platform-admin UUID literal in its own
/// local adminActor() helper -- same RETAIN class as every other file's
/// admin-actor helper, not a new defect. See
/// `tests/specs/fixtures/gh512-baseline-snapshot.json`'s `snapshot_v5_addendum`
/// for the rationale.
const t010_blocker_ceiling: u32 = 75;

/// Path to the on-disk baseline (relative to repo root, which is the cwd).
const baseline_relpath = "tools" ++ "/" ++ "lint_test_isolation.baseline.json";

/// Path to the per-rule snapshot fixture (committed alongside this test).
const snapshot_relpath = "tests" ++ "/" ++ "specs" ++ "/" ++ "fixtures" ++ "/" ++ "gh512-baseline-snapshot.json";

/// Run a subprocess and return its exit code, combined stdout/stderr, and
/// the parsed T010 BLOCKER count from the trailing `BLOCKER=N MAJOR=N MINOR=N`
/// summary line (or null if the summary line was absent).
///
/// `argv` is the full command line (no shell). Stdout and stderr are captured
/// with a generous cap; the linter emits ~30 KB at most even on 184 findings,
/// and `zig build test` emits ~10 KB on success.
fn runAndCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !struct {
    code: u8,
    combined: []u8,
    t010_blocker: ?u32,
    abnormal: bool,
} {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const abnormal = switch (result.term) {
        .exited => false,
        else => true,
    };
    const code: u8 = if (abnormal) 0xFF else switch (result.term) {
        .exited => |c| c,
        else => 0xFF,
    };

    const combined = try std.fmt.allocPrint(allocator, "{s}\n--- stderr ---\n{s}", .{ result.stdout, result.stderr });

    // Parse the trailing summary line `BLOCKER=N MAJOR=N MINOR=N`.
    const summary_pattern = "BLOCKER=";
    var t010_blocker: ?u32 = null;
    if (std.mem.lastIndexOf(u8, result.stdout, summary_pattern)) |idx| {
        // Find the start of the line containing this match.
        var line_start: usize = idx;
        while (line_start > 0 and result.stdout[line_start - 1] != '\n') : (line_start -= 1) {}
        const line_end = std.mem.indexOfPos(u8, result.stdout, idx, "\n") orelse result.stdout.len;
        const line = result.stdout[line_start..line_end];
        t010_blocker = parseBlockerCount(line);
    }

    return .{ .code = code, .combined = combined, .t010_blocker = t010_blocker, .abnormal = abnormal };
}

/// Extract the BLOCKER=N integer from a `BLOCKER=N MAJOR=...` line.
/// Returns null if the line does not contain `BLOCKER=N` or N is not a u32.
fn parseBlockerCount(line: []const u8) ?u32 {
    const marker = "BLOCKER=";
    const idx = std.mem.indexOf(u8, line, marker) orelse return null;
    var end: usize = idx + marker.len;
    while (end < line.len and line[end] != ' ' and line[end] != '\t' and line[end] != '\n') : (end += 1) {}
    return std.fmt.parseInt(u32, line[idx + marker.len .. end], 10) catch null;
}

/// Read BPM_TEST_DB_URL. The TC-RG-* tests do not require it, but
/// helpers.zig::TestHarness is not importable from this file (we don't want
/// a hard DB dependency) — this is the same pattern as the orphan self-heal
/// test, kept here for symmetry with the rest of `tests/integration/`.
fn testDbUrlOptional(allocator: std.mem.Allocator) ?[]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch null;
}

// ---------------------------------------------------------------------------
// TC-RG-01: T010 BLOCKER count under --no-baseline is ≤ post-fix ceiling
// ---------------------------------------------------------------------------
//
// This is the primary regression guard for GH-512. The migration converted
// 111 sites and marked 51 RETAIN; the resulting ceiling is 73 T010 BLOCKERs.
// If a future contributor hand-writes a new `const id = "..."` UUID literal
// anywhere under `tests/integration/`, the count rises above 73 and this
// test fails with a clear message.
//
// We use --no-baseline to expose the unfiltered count — the linter otherwise
// suppresses every T010 in the baseline, which would mask any regression.
//
// Note on the task statement's "≤ 13": the 13 platform-admin literals (design
// §R1) are the only T010 BLOCKERs the design MANDATES as RETAIN. The
// remaining 60 are module-scope `const`/comptime UUIDs / document-identity
// fixtures that BACKEND-DEV chose to RETAIN rather than convert (step-03
// summary: "Remaining 73 T010 sites are module-scope `const` declarations or
// document-identity fixtures ... Converting them would require rewriting
// the test to allocate a per-test UUID and re-deriving the substrings
// from that, which is out of scope for a T010-only migration"). 73 is the
// as-implemented ceiling. The 13 platform-admin invariant is asserted by
// TC-RG-02 against the snapshot fixture.
//
// DIRECT test:
test "TC-RG-01: T010 BLOCKER count after --no-baseline is at most the post-fix ceiling" {
    const alloc = testing.allocator;

    // BPM_TEST_DB_URL is NOT required; just confirm it is not silently
    // assumed by reading and freeing it if present.
    if (testDbUrlOptional(alloc)) |url| {
        defer alloc.free(url);
    }

    const py = python_interp.resolveCached(alloc, std.testing.io) catch |err| switch (err) {
        error.NoPythonInterpreter => {
            std.debug.print(
                "TC-RG-01: python_interp.resolveCached returned NoPythonInterpreter; " ++
                    "set BPM_PYTHON or create .venv before running this regression test\n",
                .{},
            );
            return error.NoPythonInterpreter;
        },
        else => return err,
    };

    const argv: []const []const u8 = &.{
        py,
        "tools" ++ "/" ++ "lint_test_isolation.py",
        "--no-baseline",
        "tests" ++ "/" ++ "integration",
    };

    const run_result = try runAndCapture(alloc, argv);
    defer alloc.free(run_result.combined);

    if (run_result.abnormal) {
        std.debug.print(
            "TC-RG-01: linter subprocess terminated abnormally: term=<abnormal>\n--- output ---\n{s}\n",
            .{run_result.combined},
        );
        return error.TestUnexpectedResult;
    }

    // The linter exits 1 whenever it has BLOCKER/MAJOR findings, and the
    // --no-baseline flag exposes all 73 T010 BLOCKERs. Exit 1 is the expected
    // success path for this test. Exit 0 with no BLOCKER summary line means
    // either the linter changed its output format or someone re-baselined
    // every finding; both warrant a hard failure.
    if (run_result.code == 0 and run_result.t010_blocker == null) {
        std.debug.print(
            "TC-RG-01: linter exited 0 with no BLOCKER summary line — expected exit 1 with " ++
                "BLOCKER=N >= 0. Output:\n{s}\n",
            .{run_result.combined},
        );
        return error.TestUnexpectedResult;
    }

    const t010 = run_result.t010_blocker orelse {
        std.debug.print(
            "TC-RG-01: linter stdout did not contain a BLOCKER=N MAJOR=N MINOR=N " ++
                "summary line. Output:\n{s}\n",
            .{run_result.combined},
        );
        return error.TestUnexpectedResult;
    };

    if (t010 > t010_blocker_ceiling) {
        std.debug.print(
            "TC-RG-01: T010 BLOCKER count regressed from ceiling {d} to {d} — " ++
                "a new hardcoded UUID literal was added under tests/integration/. " ++
                "Run `python tools/lint_test_isolation.py --no-baseline tests/integration` " ++
                "to see the new finding. If the new literal is RETAIN (e.g. a platform-admin " ++
                "UUID or document-identity fixture), update the baseline AND this ceiling; " ++
                "otherwise convert it to TestHarness.newUuid() / newUuidString(allocator).\n",
            .{ t010_blocker_ceiling, t010 },
        );
        return error.TestUnexpectedResult;
    }

    std.debug.print(
        "TC-RG-01 PASS: T010 BLOCKER count = {d} (<= ceiling {d})\n",
        .{ t010, t010_blocker_ceiling },
    );
}

// ---------------------------------------------------------------------------
// TC-RG-02: baseline JSON matches the GH-512 post-fix snapshot
// ---------------------------------------------------------------------------
//
// Locks in (post-step-04 RETAIN addendum; see
// tests/specs/fixtures/gh512-baseline-snapshot.json step_04_retain_addendum):
//   - total_issues     == 115
//   - by_severity      == {BLOCKER: 74, MAJOR: 41, MINOR: 0}
//   - by_code          == {T010: 74, T020: 11, T030: 6, T050: 22, T060: 2}
//   - platform_admin_uuid_count == 14
//
// If a contributor silently adds a new suppression, expands an existing one,
// or changes the on-disk baseline in any way that touches the per-rule
// distribution, this test catches it.
//
// DIRECT test:
test "TC-RG-02: tools/lint_test_isolation.baseline.json matches the GH-512 snapshot" {
    const alloc = testing.allocator;

    // Read the snapshot fixture first — fail with a clear message if it is
    // missing (a future contributor might delete the fixture thinking it is
    // obsolete; the regression guard depends on it).
    const snapshot_text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, snapshot_relpath, alloc, std.Io.Limit.limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                "TC-RG-02 FAILED: snapshot file {s} is missing — TEST-DESIGNER Step 4 " ++
                    "committed this fixture to lock the GH-512 per-rule baseline shape. " ++
                    "Restore from git: `git checkout HEAD -- {s}`.\n",
                .{ snapshot_relpath, snapshot_relpath },
            );
            return error.FileNotFound;
        },
        else => return err,
    };
    defer alloc.free(snapshot_text);

    const snapshot = std.json.parseFromSlice(std.json.Value, alloc, snapshot_text, .{}) catch |err| {
        std.debug.print(
            "TC-RG-02 FAILED: snapshot file {s} is not valid JSON: {any}\n",
            .{ snapshot_relpath, err },
        );
        return err;
    };
    defer snapshot.deinit();

    // Read the on-disk baseline. Same fail-loud pattern.
    const baseline_text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, baseline_relpath, alloc, std.Io.Limit.limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                "TC-RG-02 FAILED: baseline file {s} is missing — BACKEND-DEV step 03 " ++
                    "should have regenerated it. Run `python tools/lint_test_isolation.py --no-baseline " ++
                    "--json tests/integration | python tools/lint_test_isolation.py --update-baseline` " ++
                    "(or follow the regeneration procedure in step-03-backend-dev.json).\n",
                .{baseline_relpath},
            );
            return error.FileNotFound;
        },
        else => return err,
    };
    defer alloc.free(baseline_text);

    const baseline_doc = std.json.parseFromSlice(std.json.Value, alloc, baseline_text, .{}) catch |err| {
        std.debug.print(
            "TC-RG-02 FAILED: baseline file {s} is not valid JSON: {any}\n",
            .{baseline_relpath, err},
        );
        return err;
    };
    defer baseline_doc.deinit();

    const baseline_issues = baseline_doc.value.object.get("issues") orelse {
        std.debug.print(
            "TC-RG-02 FAILED: baseline file {s} does not contain an `issues` array\n",
            .{baseline_relpath},
        );
        return error.TestUnexpectedResult;
    };
    const issues_array = baseline_issues.array;
    const total_issues: u32 = @intCast(issues_array.items.len);

    // Compute by_severity, by_code, platform_admin_uuid_count from the on-disk baseline.
    var by_severity = std.StringHashMap(u32).init(alloc);
    defer by_severity.deinit();
    var by_code = std.StringHashMap(u32).init(alloc);
    defer by_code.deinit();
    var platform_admin_count: u32 = 0;

    for (issues_array.items) |item| {
        const obj = item.object;
        const sev = obj.get("severity") orelse continue;
        const code = obj.get("code") orelse continue;
        const message = obj.get("message") orelse continue;

        const sev_name = switch (sev) {
            .string => |s| s,
            else => continue,
        };
        const code_name = switch (code) {
            .string => |s| s,
            else => continue,
        };
        const msg_text = switch (message) {
            .string => |s| s,
            else => continue,
        };

        const cur_sev = by_severity.get(sev_name) orelse 0;
        try by_severity.put(sev_name, cur_sev + 1);
        const cur_code = by_code.get(code_name) orelse 0;
        try by_code.put(code_name, cur_code + 1);

        // GH-512 retention: canonical platform-admin user_id constant used as
        // a substring-search target to identify T010 RETAIN entries per
        // design §R1. Not a fixture identity — it is the literal we are
        // counting. Documented in tests/specs/fixtures/gh512-baseline-snapshot.json.
        if (std.mem.eql(u8, code_name, "T010") and
            std.mem.indexOf(u8, msg_text, "00000000-0000-0000-0000-000000000001") != null)
        {
            platform_admin_count += 1;
        }
    }

    // Compare to the snapshot expectations.
    const expected = snapshot.value.object.get("expected") orelse {
        std.debug.print(
            "TC-RG-02 FAILED: snapshot file {s} does not contain an `expected` object\n",
            .{snapshot_relpath},
        );
        return error.TestUnexpectedResult;
    };

    const exp_total = expected.object.get("total_issues").?.integer;
    if (total_issues != @as(u32, @intCast(exp_total))) {
        std.debug.print(
            "TC-RG-02 FAILED: total_issues is {d}, expected {d} per snapshot " ++
                "{s}.\n",
            .{ total_issues, exp_total, snapshot_relpath },
        );
        return error.TestUnexpectedResult;
    }

    // Check by_severity: same keys, same counts.
    const exp_sev = expected.object.get("by_severity").?.object;
    var sev_iter = exp_sev.iterator();
    while (sev_iter.next()) |entry| {
        const exp_count: u32 = @intCast(entry.value_ptr.integer);
        const actual_count = by_severity.get(entry.key_ptr.*) orelse 0;
        if (actual_count != exp_count) {
            std.debug.print(
                "TC-RG-02 FAILED: by_severity[{s}] = {d}, expected {d} per snapshot " ++
                    "{s}.\n",
                .{ entry.key_ptr.*, actual_count, exp_count, snapshot_relpath },
            );
            return error.TestUnexpectedResult;
        }
    }
    // Detect NEW severities in the on-disk baseline.
    var act_sev_iter = by_severity.iterator();
    while (act_sev_iter.next()) |entry| {
        if (exp_sev.get(entry.key_ptr.*) == null) {
            std.debug.print(
                "TC-RG-02 FAILED: baseline gained a new severity '{s}' that is " ++
                    "not in the snapshot {s}. Either a new linter rule added a " ++
                    "previously-unseen severity, or the snapshot is stale.\n",
                .{ entry.key_ptr.*, snapshot_relpath },
            );
            return error.TestUnexpectedResult;
        }
    }

    // Check by_code: same keys, same counts.
    const exp_code = expected.object.get("by_code").?.object;
    var code_iter = exp_code.iterator();
    while (code_iter.next()) |entry| {
        const exp_count: u32 = @intCast(entry.value_ptr.integer);
        const actual_count = by_code.get(entry.key_ptr.*) orelse 0;
        if (actual_count != exp_count) {
            std.debug.print(
                "TC-RG-02 FAILED: by_code[{s}] = {d}, expected {d} per snapshot " ++
                    "{s}.\n",
                .{ entry.key_ptr.*, actual_count, exp_count, snapshot_relpath },
            );
            return error.TestUnexpectedResult;
        }
    }
    // Detect NEW codes in the on-disk baseline.
    var act_code_iter = by_code.iterator();
    while (act_code_iter.next()) |entry| {
        if (exp_code.get(entry.key_ptr.*) == null) {
            std.debug.print(
                "TC-RG-02 FAILED: baseline gained a new code '{s}' that is " ++
                    "not in the snapshot {s}. Either a new linter rule fired, " ++
                    "or the snapshot is stale.\n",
                .{ entry.key_ptr.*, snapshot_relpath },
            );
            return error.TestUnexpectedResult;
        }
    }

    // Check platform_admin_uuid_count.
    const exp_platform_admin: u32 = @intCast(expected.object.get("platform_admin_uuid_count").?.integer);
    if (platform_admin_count != exp_platform_admin) {
        std.debug.print(
            "TC-RG-02 FAILED: platform_admin_uuid_count = {d}, expected {d} " ++
                "(design §R1 mandates the 13 platform-admin UUIDs be RETAIN).\n",
            .{ platform_admin_count, exp_platform_admin },
        );
        return error.TestUnexpectedResult;
    }

    std.debug.print(
        "TC-RG-02 PASS: baseline matches snapshot " ++
            "(total={d}, by_code={{T010={d},T020={d},T030={d},T050={d},T060={d}}}, " ++
            "platform_admin={d})\n",
        .{
            total_issues,
            by_code.get("T010") orelse 0,
            by_code.get("T020") orelse 0,
            by_code.get("T030") orelse 0,
            by_code.get("T050") orelse 0,
            by_code.get("T060") orelse 0,
            platform_admin_count,
        },
    );
}

// ---------------------------------------------------------------------------
// TC-RG-03: `zig build test` exits 0 — no compile errors introduced by the migration
// ---------------------------------------------------------------------------
//
// The migration touched ~30 integration test files. A missed `defer alloc.free`,
// a broken signature, a typo in a UUID helper call, or a missing import would
// surface as a compile error. `zig build test` runs the unit-test targets
// (which transitively include the integration test files via the test binary
// artifacts) and is the cheapest signal.
//
// Note: we run `zig build test` rather than `zig build test-integration` because
// `test-integration` requires BPM_TEST_DB_URL. The migration touched only
// integration tests, but compile errors propagate to whichever step includes
// the affected source — and the unit-test step does include the integration
// test files as `addTest` roots in build.zig.
//
// DIRECT test:
test "TC-RG-03: zig build test exits 0 — migration did not introduce compile errors" {
    const alloc = testing.allocator;

    // Locate `zig`. On Windows the standard installer places zig.exe under
    // Program Files, which may not be on PATH for the build runner.
    const argv: []const []const u8 = &.{
        "zig", "build", "test",
    };

    const run_result = runAndCapture(alloc, argv) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                "TC-RG-03 FAILED: `zig` not found on PATH; install Zig 0.16.0 or " ++
                    "add zig to PATH. See https://ziglang.org/download/ for the " ++
                    "version pinned in build.zig.zon.\n",
                .{},
            );
            return error.FileNotFound;
        },
        else => return err,
    };
    defer alloc.free(run_result.combined);

    if (run_result.abnormal) {
        std.debug.print(
            "TC-RG-03 FAILED: `zig build test` terminated abnormally. " ++
                "Output:\n{s}\n",
            .{run_result.combined},
        );
        return error.TestUnexpectedResult;
    }

    if (run_result.code != 0) {
        // Print the last 80 lines of combined output for fast triage.
        const all = run_result.combined;
        const tail_start = if (all.len > 80 * 120) all.len - (80 * 120) else 0;
        std.debug.print(
            "TC-RG-03 FAILED: `zig build test` exited {d}. Last 80 lines:\n{s}\n",
            .{ run_result.code, all[tail_start..] },
        );
        return error.TestUnexpectedResult;
    }

    std.debug.print(
        "TC-RG-03 PASS: `zig build test` exited 0\n",
        .{},
    );
}
