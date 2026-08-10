//! ISS-0605 / GH-537 — regression test for the C4 schema-baseline self-heal.
//!
//! Covers: ISS-0605 AC-3 (the design verifies that
//! `tools/verify_test_env.py` invokes the GH-443 / ISS-0140 orphan-row
//! DELETE sweep from `tools/clean_test_db.py` BEFORE
//! `verify_schema_baseline.py --check-tenants` runs, so the legacy C4
//! failure mode — reporting orphan rows forever without removing them — is
//! closed permanently).
//!
//! Test cases:
//!   TC-ISS-0605-01  Insert a half-provisioned public.tenant row with
//!                    storage_mode='SCHEMA' but no matching tenant_schemas
//!                    entry, run `python tools/verify_test_env.py --quick`
//!                    as a subprocess, then assert the row is gone and the
//!                    gate exit code is 0.
//!
//! BPM_TEST_DB_URL must be set. DIRECTIVE T-1: no mocks, no in-memory
//! fakes, no SkipZigTest on a MUST test. Per-test UUID and defers ensure
//! isolated cleanup that survives partial failure.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const helpers = @import("helpers.zig");
const python_interp = @import("python_interp");
const build_options = @import("build_options");

const bpm = @import("bpm");
const pg = @import("pg");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

// Root-level export required so pool connections apply tenant-schema
// search_path instead of falling back to search_path=public. See
// helpers.zig::ensureSchemaReady for the same pattern.
pub const api_tenant_context = bpm.api_tenant_context;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Read BPM_TEST_DB_URL. Returns MissingTestDatabaseUrl when the variable
/// is absent so the test fails clearly with a named error rather than
/// silently skipping. Mirrors tenant_config_realm_test.zig::testDbUrl.
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is required for ISS-0605 orphan-self-heal integration tests\n",
                .{},
            );
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

/// Generate a UUID v4 string (36 chars, dash-separated). Same pattern as
/// tenant_config_realm_test.zig::generateUuid.
fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 10xx
    return std.fmt.allocPrint(allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            raw[0],  raw[1],  raw[2],  raw[3],
            raw[4],  raw[5],
            raw[6],  raw[7],
            raw[8],  raw[9],
            raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
        });
}

/// Make a pool with the tenant context set to the default tenant_id so
/// connections apply search_path=tenant_default,public (same pattern as
/// tenant_config_realm_test.zig::makePool).
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    try helpers.ensureSchemaReady(allocator);
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 3,
    });
}

/// ISS-0659 / GH-681: self-managed-pool binary must serialize against
/// TestHarness peers via the bpm_test_migrations_public advisory lock for the
/// binary's full lifetime. PR #494 / ISS-0162 extended this lock inside
/// TestHarness.init(); this entry point lets a makePool-based binary acquire
/// the same lock around its own test block. Pair with
/// `helpers.releaseIntegrationLock(&lock_conn)` via defer at the top of every
/// `test` block.
fn acquireLock(allocator: std.mem.Allocator) anyerror!pg.Conn {
    return helpers.acquireIntegrationLock(allocator);
}

/// Run `python tools/verify_test_env.py --quick` as a subprocess and
/// return (exit_code, combined_output). The subprocess inherits the
/// caller environment — the build runner / CI shell already exports
/// BPM_TEST_DB_URL, BPM_DB_URL, and BPM_MIGRATIONS_DIR, and verify_test_env
/// reads those exact variables (C0/C3/C4/C7 paths).
///
/// Note: we deliberately do NOT construct a custom env_map here. Zig 0.16's
/// std.process.Environ.Map has no equivalent to the previous getEnvMap()
/// helper, and writing a portable block-by-block re-importer is more
/// surface area than this regression test warrants. The parent process
/// shell is the source of truth for env, and the test runner already
/// configures BPM_TEST_DB_URL via the same shell (see `zig build
/// test-integration-cmd` task definition in .vscode/tasks.json).
fn runVerifyTestEnv(
    allocator: std.mem.Allocator,
    test_db_url: []u8,
) !struct {
    code: u8,
    combined: []u8,
} {
    _ = test_db_url; // sanity-checked by the caller before subprocess run
    const py = python_interp.resolveCached(allocator, std.testing.io) catch |err| {
        std.debug.print("iss0605: python_interp.resolveCached failed: {}\n", .{err});
        return err;
    };

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ py, "tools/verify_test_env.py", "--quick" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => {
            std.debug.print(
                "iss0605: verify_test_env.py terminated abnormally: {}\n",
                .{result.term},
            );
            return error.TestUnexpectedResult;
        },
    };

    // Combine stdout/stderr so callers see the same surface the gate prints.
    const combined = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ result.stdout, result.stderr });
    return .{ .code = exit_code, .combined = combined };
}

// ---------------------------------------------------------------------------
// TC-ISS-0605-01: half-provisioned public.tenant row is removed by C4's
// _run_clean_test_db_sweep() pre-step.
// ---------------------------------------------------------------------------
//
// This test inserts a single orphan public.tenant row (storage_mode='SCHEMA',
// no tenant_schemas entry, no tenant_<uuid> schema) — the exact half-provisioned
// state that has accumulated on the shared db_test database since 2026-08-07
// and that caused every C4 run since then to fail. It then runs the gate
// end-to-end and asserts (a) the gate exits 0 and (b) the orphan row is gone
// from the database. If either Layer-1 helper is broken (helper not invoked,
// sweep does not match this row's predicates, downstream gate fails on the
// persisted orphan), the test fails loudly.
//
// Direct test:
test "TC-ISS-0605-01: half-provisioned public.tenant row is removed by C4 self-heal" {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    const alloc = testing.allocator;

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    // Per-test UUID so concurrent runs of this binary cannot collide. We
    // use the same UUID for the test-id slug and the production_tenant_id
    // placeholder so the INSERT does not require a real production tenant
    // to be referenced.
    const orphan_id = try randomUuidStr(alloc);
    defer alloc.free(orphan_id);

    const slug = try std.fmt.allocPrint(alloc, "iss0605-orphan-{s}", .{orphan_id[0..12]});
    defer alloc.free(slug);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Step 1: Insert the orphan row. We use a fresh connection outside the
    // pool's transaction so the row is visible to every subsequent
    // connection — including the gate's subprocess.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        try conn.exec(
            \\INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
            \\VALUES ($1::uuid, $2, $3, 'ACTIVE', $4, 'test', $5::uuid)
        , &[_][]const u8{ orphan_id, slug, slug, "iss0605-orphan-realm", "00000000-0000-0000-0000-000000000000" });

        // Flip storage_mode to 'SCHEMA' (the orphan pattern). The INSERT
        // itself does not include storage_mode, which would default to
        // 'LEGACY_RLS' per migration 105. The UPDATE is the second half of
        // the orphan pattern; skipping it would not leave a SCHEMA-mode
        // orphan and the sweep would not target this row.
        try conn.exec(
            "UPDATE public.tenant SET storage_mode = 'SCHEMA' WHERE id = $1::uuid",
            &[_][]const u8{orphan_id},
        );
    }

    // Defer cleanup for the orphan row. Idempotent: if the gate's sweep
    // already removed it, the DELETE is a no-op. We swallow all errors
    // here — this is best-effort cleanup, and any failure will be picked
    // up by the next test run's C4 sweep (ISS-0605 self-heal).
    defer {
        if (pool.acquire()) |conn| {
            defer pool.release(conn);
            _ = conn.exec(
                "DELETE FROM public.tenant WHERE id = $1::uuid",
                &[_][]const u8{orphan_id},
            ) catch {};
        } else |_| {
            // Pool exhausted or DB unavailable — the C4 sweep will catch
            // any leftover row on the next test invocation.
        }
    }

    // Step 2: Sanity-check the pre-condition — the row must exist with
    // storage_mode='SCHEMA' before the gate runs. If this fails, the
    // next assertion is meaningless (the gate would have nothing to remove).
    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        var rows = try conn.query(
            alloc,
            "SELECT storage_mode FROM public.tenant WHERE id = $1::uuid",
            &[_][]const u8{orphan_id},
        );
        defer rows.deinit();

        try testing.expectEqual(@as(usize, 1), rows.rows.len);
        const mode = rows.rows[0][0] orelse "";
        try testing.expectEqualStrings("SCHEMA", mode);
    }

    // Step 3: Run `python tools/verify_test_env.py --quick` as a subprocess.
    // --quick skips C2 (zig build) and C3 (migrate) — they are not relevant
    // to the self-heal contract and would slow this test significantly.
    const run_result = try runVerifyTestEnv(alloc, url);
    defer alloc.free(run_result.combined);

    if (run_result.code != 0) {
        std.debug.print(
            "TC-ISS-0605-01: verify_test_env.py --quick exited {d}, expected 0\n",
            .{run_result.code},
        );
        std.debug.print("combined output:\n{s}\n", .{run_result.combined});
    }
    try testing.expectEqual(@as(u8, 0), run_result.code);

    // Step 4: Assert the orphan row is gone. The C4 self-heal pre-step
    // invokes clean_test_db.py, which runs DELETE ... WHERE
    // storage_mode='SCHEMA' AND slug != 'default' AND NOT EXISTS (SELECT 1
    // FROM public.tenant_schemas ts WHERE ts.tenant_id = t.id). This row
    // matches every predicate.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        var rows = try conn.query(
            alloc,
            "SELECT count(*) FROM public.tenant WHERE id = $1::uuid",
            &[_][]const u8{orphan_id},
        );
        defer rows.deinit();

        try testing.expectEqual(@as(usize, 1), rows.rows.len);
        const count_str = rows.rows[0][0] orelse "0";
        const count = try std.fmt.parseInt(usize, count_str, 10);
        try testing.expectEqual(@as(usize, 0), count);
    }
}
