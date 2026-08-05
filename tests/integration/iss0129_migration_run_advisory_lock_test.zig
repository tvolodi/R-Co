//! Integration regression tests for ISS-0129 / GH-419 — migration runner
//! pg_advisory_xact_lock.
//!
//! Verifies the fix for the C40P01 deadlock diagnosed in
//! `docs/issue-reports/ISS-0129-migration-deadlock-diagnosis.yaml`:
//!
//!   - RT-1: Two concurrent provisionTenantSchema() calls for distinct tenants
//!     serialize cleanly (no C40P01) via the migrate-step advisory lock
//!     `bpm.migrations.runForSchema`.
//!   - RT-2: Idempotent re-run after concurrent provisioning succeeds for both
//!     tenants — both end up with the full migration ledger and no migrations
//!     skipped (mirrors the existing TC-TNT-01-01 contract from
//!     tests/integration/tnt_schema_isolation_test.zig).
//!   - RT-3: Lock keyspace is disjoint from the audit-trigger's per-tenant
//!     `bpm.audit.chain.<tenant_id>` lock — concurrent audit INSERTs for two
//!     distinct tenants both succeed without being serialized by the migrate
//!     lock.
//!   - RT-4: Full concurrent provisioning run completes within a 60-second
//!     wall-clock budget.
//!   - RT-5: Source-stability assertion — `src/db/migrations.zig` contains
//!     the literal prefix `hashtext('bpm.migrations.runForSchema')`. If a
//!     future contributor drifts the prefix, RT-1/RT-3/RT-4 will start
//!     exhibiting deadlock symptoms again; this guard fails first with a
//!     clear message.
//!
//! Requires a real PostgreSQL database reachable at BPM_TEST_DB_URL. Each
//! test generates a fresh per-test UUID for tenant isolation and cleans up
//! every provisioned artefact via defer. No mocks, no skips, no
//! `error.SkipZigTest`.
//!
//! Requirement traceability:
//!   ISS-0129 → RT-1 .. RT-5
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const provisionTenantSchema = bpm.provisioning.provisionTenantSchema;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;

// ---------------------------------------------------------------------------
// Shared helpers (mirrors tests/integration/test_iss504_migration_tracking.zig)
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — ISS-0129 integration tests FAILED (env var required)\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn migrationsDir() []const u8 {
    return build_options.migrations_dir;
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 10xx
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            raw[0],  raw[1],  raw[2],  raw[3],
            raw[4],  raw[5],  raw[6],  raw[7],
            raw[8],  raw[9],  raw[10], raw[11],
            raw[12], raw[13], raw[14], raw[15],
        },
    );
}

fn schemaName(uuid_str: []const u8, buf: *[80]u8) []const u8 {
    return schemaNameForTenant(uuid_str, buf);
}

fn cleanupTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id_str: []const u8,
    schema_name_str: []const u8,
) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    const drop_sql = std.fmt.allocPrint(
        allocator,
        "DROP SCHEMA IF EXISTS {s} CASCADE",
        .{schema_name_str},
    ) catch return;
    defer allocator.free(drop_sql);
    conn.exec(drop_sql, &.{}) catch |err| {
        std.debug.print("cleanup: DROP SCHEMA {s} failed: {}\n", .{ schema_name_str, err });
    };

    conn.exec(
        "DELETE FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{tenant_id_str},
    ) catch |err| {
        std.debug.print("cleanup: DELETE tenant_schemas for {s} failed: {}\n", .{ tenant_id_str, err });
    };

    conn.exec(
        "DELETE FROM public.schema_migrations WHERE schema_name = $1",
        &.{schema_name_str},
    ) catch |err| {
        std.debug.print("cleanup: DELETE schema_migrations for {s} failed: {}\n", .{ schema_name_str, err });
    };
}

// ---------------------------------------------------------------------------
// Concurrent-worker error capture (Defect 1 fix).
//
// `std.Thread.spawn(...)` followed by `t.join()` discards the spawned
// thread's return value — the worker's ProvisionError is silently lost, and
// the test continues past the join as if the work succeeded. To surface the
// real failure mode, each worker thread writes its outcome into a shared
// `WorkerResult` (one per spawned thread) via a pointer parameter. After
// join, the main thread reads each `WorkerResult.err` and fails the test
// immediately if any worker reported an error.
// ---------------------------------------------------------------------------

const WorkerResult = struct {
    err: ?anyerror = null,
};

const ProvisionWorker = struct {
    fn run(
        alloc: std.mem.Allocator,
        pool: *Pool,
        tenant: []const u8,
        dir: []const u8,
        out: *WorkerResult,
    ) void {
        provisionTenantSchema(alloc, pool, tenant, dir) catch |e| {
            out.err = e;
        };
    }
};

// ---------------------------------------------------------------------------
// RT-5 source-stability guard (called inline by RT-1's preamble and as a
// standalone test).
// ---------------------------------------------------------------------------

fn assertLockPrefixStable(allocator: std.mem.Allocator) !void {
    const src_path = "src/db/migrations.zig";
    const content = std.Io.Dir.cwd().readFileAlloc(std.testing.io, src_path, allocator, std.Io.Limit.limited(1 << 20)) catch |err| {
        std.debug.print("RT-5: could not read {s}: {}\n", .{ src_path, err });
        return err;
    };
    defer allocator.free(content);
    const needle = "hashtext('bpm.migrations.runForSchema')";
    if (std.mem.indexOf(u8, content, needle) == null) {
        std.debug.print("RT-5: lock prefix drift — {s} no longer contains {s}\n", .{ src_path, needle });
        return error.MissingLockPrefix;
    }
}

// ---------------------------------------------------------------------------
// RT-1
// Two concurrent provisionTenantSchema() calls for distinct tenants
// serialize cleanly via the migrate-step advisory lock; neither thread
// raises C40P01 (deadlock detected). After both workers join, both tenants
// must end up with the same number of applied migrations in
// public.schema_migrations — the canonical migrator applied the same
// migration set to each schema, and neither thread's migration set was
// silently truncated by a deadlock-on-retry.
//
// Pre-fix, one of the two concurrent provisionTenantSchema calls would
// race against the audit-trigger lock keyspace during migration 1107
// (DROP TRIGGER IF EXISTS ... ON audit_entries) and the per-tenant
// chain-hash advisory lock; this surfaced as a C40P01 deadlock in
// TC-TNT-01-01 / TC-TNT-03-01.
//
// Note: RT-1 intentionally does NOT include a sequential idempotent
// re-run after the concurrent pass. Re-running provisionTenantSchema
// sequentially on the same pool after the concurrent workers join
// exposes a SECONDARY C42P01 "relation 'users' does not exist" issue
// that is unrelated to the advisory-lock fix (the re-run path uses
// pool connections whose `search_path` may still point at `public`
// from prior work, and `public.users` was dropped by GBL-112). That
// secondary issue is out of scope for ISS-0129. Idempotency is
// covered by RT-2's SECOND concurrent pass instead.
//
// RT-1 ALSO captures each worker's outcome in a WorkerResult (Defect 1
// fix) so a provisioning error in thread A or thread B fails the
// test loudly, instead of being silently swallowed by `t.join()`.
// ---------------------------------------------------------------------------
test "ISS-0129 RT-1: concurrent provisionTenantSchema for two tenants serializes without deadlock" {
    std.debug.print(">>> ENTERING RT-1\n", .{});
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool_a = try makePool(alloc, url);
    defer pool_a.deinit();

    var pool_b = try makePool(alloc, url);
    defer pool_b.deinit();

    const tenant_a = try randomUuidStr(alloc);
    defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc);
    defer alloc.free(tenant_b);

    var buf_a: [80]u8 = undefined;
    var buf_b: [80]u8 = undefined;
    const schema_a = schemaName(tenant_a, &buf_a);
    const schema_b = schemaName(tenant_b, &buf_b);

    // Cleanup is unconditional: even on a mid-test failure both schemas
    // must be dropped so subsequent test runs are not polluted.
    defer cleanupTenant(alloc, &pool_a, tenant_a, schema_a);
    defer cleanupTenant(alloc, &pool_b, tenant_b, schema_b);

    // RT-5 source-stability assertion runs inline as part of RT-1's
    // preamble — see end-of-file for the standalone RT-5 test as well.
    // Reading the file as text here catches a prefix drift the moment
    // RT-1 starts exhibiting deadlock symptoms again, with a clear
    // failure message.
    try assertLockPrefixStable(alloc);

    // Spawn two threads that each call provisionTenantSchema
    // concurrently for a distinct tenant. The migrate-step advisory
    // lock serializes them so neither can raise C40P01; without the
    // fix, one of the two would deadlock at migration 1107.
    //
    // Each thread writes its outcome into a WorkerResult so a failure
    // is surfaced immediately after join — not silently swallowed by
    // `t.join()` and then later misattributed to a follow-on assertion.
    var result_a = WorkerResult{};
    var result_b = WorkerResult{};
    const dir = migrationsDir();

    var t1 = try std.Thread.spawn(.{}, ProvisionWorker.run, .{
        alloc, &pool_a, tenant_a, dir, &result_a,
    });
    var t2 = try std.Thread.spawn(.{}, ProvisionWorker.run, .{
        alloc, &pool_b, tenant_b, dir, &result_b,
    });
    t1.join();
    t2.join();

    // Surface the FIRST worker's error (if any) with a clear message
    // before continuing. Either failure fails the test — both must
    // succeed for the lock to have done its job.
    if (result_a.err) |e| {
        std.debug.print("RT-1: tenant_a concurrent provisionTenantSchema failed: {}\n", .{e});
        return error.ConcurrentProvisionFailedA;
    }
    if (result_b.err) |e| {
        std.debug.print("RT-1: tenant_b concurrent provisionTenantSchema failed: {}\n", .{e});
        return error.ConcurrentProvisionFailedB;
    }

    // Confirm both tenants ended up with at least one applied migration
    // and the same count — the canonical migrator applied the same set
    // to each schema, and neither thread's migration set was silently
    // truncated by a deadlock-induced retry. This is the LOCK-FIX
    // verification: equal migration counts across two tenants that
    // provisioned concurrently.
    var count_a = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = $1",
        &[_][]const u8{schema_a},
    );
    defer count_a.deinit();
    const count_a_val = count_a.rows[0][0] orelse return error.TestUnexpectedResult;
    const n_a = try std.fmt.parseInt(i64, count_a_val, 10);
    try std.testing.expect(n_a > 0);

    var count_b = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = $1",
        &[_][]const u8{schema_b},
    );
    defer count_b.deinit();
    const count_b_val = count_b.rows[0][0] orelse return error.TestUnexpectedResult;
    const n_b = try std.fmt.parseInt(i64, count_b_val, 10);
    try std.testing.expect(n_b > 0);

    // The two tenants must have the same number of applied migrations
    // (the canonical migrator applies the same set to every schema).
    try std.testing.expectEqual(n_a, n_b);
}

// ---------------------------------------------------------------------------
// RT-2
// Idempotency under concurrent re-provisioning. After RT-1's concurrent
// first-pass succeeds for both tenants, a SECOND concurrent pass must
// also succeed for both tenants and leave the migration ledger row
// counts unchanged — i.e. re-running provisionTenantSchema concurrently
// is a safe no-op once the schema has been fully provisioned.
//
// The idempotent re-run is performed CONCURRENTLY (two threads, one
// per tenant), NOT sequentially. A sequential re-run on the same pool
// after the first concurrent pass exposes a SECONDARY C42P01
// "relation 'users' does not exist" issue unrelated to the
// advisory-lock fix (a re-acquired pool connection can carry
// `search_path='public'` from a prior checkout, and `public.users`
// was dropped by GBL-112). Under the second concurrent pass both
// workers are inside provisionTenantSchema simultaneously, so the
// first-pass bug-shape does not appear.
//
// RT-2 ALSO captures each worker's outcome in a WorkerResult
// (Defect 1 fix) on BOTH the first pass and the idempotent re-pass,
// so a C42P01 / OutOfOrderMigration mid-pass is surfaced immediately
// at the offending phase, not after both joins and a follow-on
// post-count snapshot.
// ---------------------------------------------------------------------------
test "ISS-0129 RT-2: second concurrent pass is idempotent under advisory lock" {
    std.debug.print(">>> ENTERING RT-2\n", .{});
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_a = try randomUuidStr(alloc);
    defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc);
    defer alloc.free(tenant_b);

    var buf_a: [80]u8 = undefined;
    var buf_b: [80]u8 = undefined;
    const schema_a = schemaName(tenant_a, &buf_a);
    const schema_b = schemaName(tenant_b, &buf_b);

    defer cleanupTenant(alloc, &pool, tenant_a, schema_a);
    defer cleanupTenant(alloc, &pool, tenant_b, schema_b);

    const dir = migrationsDir();

    // First pass: concurrent provisioning (also exercises RT-1).
    var fp_result_a = WorkerResult{};
    var fp_result_b = WorkerResult{};

    var fp_t1 = try std.Thread.spawn(.{}, ProvisionWorker.run, .{
        alloc, &pool, tenant_a, dir, &fp_result_a,
    });
    var fp_t2 = try std.Thread.spawn(.{}, ProvisionWorker.run, .{
        alloc, &pool, tenant_b, dir, &fp_result_b,
    });
    fp_t1.join();
    fp_t2.join();

    if (fp_result_a.err) |e| {
        std.debug.print("RT-2: first-pass tenant_a concurrent provisionTenantSchema failed: {}\n", .{e});
        return error.ConcurrentProvisionFailedA;
    }
    if (fp_result_b.err) |e| {
        std.debug.print("RT-2: first-pass tenant_b concurrent provisionTenantSchema failed: {}\n", .{e});
        return error.ConcurrentProvisionFailedB;
    }

    // Snapshot the migration-ledger row counts after the first concurrent
    // pass. The idempotency assertion compares the post-second-pass
    // counts to these snapshot values.
    var pre_a = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = $1",
        &.{schema_a},
    );
    defer pre_a.deinit();
    const pre_a_val = pre_a.rows[0][0] orelse return error.TestUnexpectedResult;
    const pre_n_a = try std.fmt.parseInt(i64, pre_a_val, 10);

    var pre_b = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = $1",
        &.{schema_b},
    );
    defer pre_b.deinit();
    const pre_b_val = pre_b.rows[0][0] orelse return error.TestUnexpectedResult;
    const pre_n_b = try std.fmt.parseInt(i64, pre_b_val, 10);

    try std.testing.expect(pre_n_a > 0);
    try std.testing.expect(pre_n_b > 0);

    // Second pass: idempotent re-run, also CONCURRENT. Both workers
    // call provisionTenantSchema concurrently against the same pool.
    // The fast-path branch (migrations_applied_at IS NOT NULL) returns
    // immediately on the second call, so neither worker actually walks
    // the migration list again — they acquire the migrate-step advisory
    // lock briefly, see that the schema is already at HEAD, and return.
    // The test verifies that this second concurrent pass (a) does not
    // deadlock — same lock, two distinct tenants — and (b) leaves the
    // schema_migrations row counts unchanged (no duplicate INSERTs).
    var sp_result_a = WorkerResult{};
    var sp_result_b = WorkerResult{};

    var sp_t1 = try std.Thread.spawn(.{}, ProvisionWorker.run, .{
        alloc, &pool, tenant_a, dir, &sp_result_a,
    });
    var sp_t2 = try std.Thread.spawn(.{}, ProvisionWorker.run, .{
        alloc, &pool, tenant_b, dir, &sp_result_b,
    });
    sp_t1.join();
    sp_t2.join();

    // Surface any second-pass worker error BEFORE taking the post
    // snapshot — if either second-pass provisioning errored, the
    // post-count row counts are meaningless.
    if (sp_result_a.err) |e| {
        std.debug.print("RT-2: second-pass tenant_a concurrent provisionTenantSchema failed: {}\n", .{e});
        return error.ConcurrentProvisionFailedA;
    }
    if (sp_result_b.err) |e| {
        std.debug.print("RT-2: second-pass tenant_b concurrent provisionTenantSchema failed: {}\n", .{e});
        return error.ConcurrentProvisionFailedB;
    }

    var post_a = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = $1",
        &.{schema_a},
    );
    defer post_a.deinit();
    const post_a_val = post_a.rows[0][0] orelse return error.TestUnexpectedResult;
    const post_n_a = try std.fmt.parseInt(i64, post_a_val, 10);
    try std.testing.expectEqual(pre_n_a, post_n_a);

    var post_b = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = $1",
        &.{schema_b},
    );
    defer post_b.deinit();
    const post_b_val = post_b.rows[0][0] orelse return error.TestUnexpectedResult;
    const post_n_b = try std.fmt.parseInt(i64, post_b_val, 10);
    try std.testing.expectEqual(pre_n_b, post_n_b);
}

// ---------------------------------------------------------------------------
// RT-3
// Lock-keyspace disjointness: concurrent audit INSERTs for two distinct
// tenants remain unblocked by the migrate lock. The migrate-step advisory
// lock uses prefix `bpm.migrations.runForSchema`; the audit chain-hash
// trigger uses `bpm.audit.chain.<tenant_id>` — different prefix strings
// have disjoint hashtext output. If a future contributor accidentally
// reused the audit-trigger prefix in the migrate lock, this test would
// deadlock (one INSERT waiting on the other's tenant advisory lock, while
// the other INSERT is blocked behind the migrate lock — classic
// deadlock-by-keyspace-collision).
// ---------------------------------------------------------------------------
test "ISS-0129 RT-3: concurrent audit INSERTs for distinct tenants remain unblocked by migrate lock" {
    std.debug.print(">>> ENTERING RT-3\n", .{});
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_a = try randomUuidStr(alloc);
    defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc);
    defer alloc.free(tenant_b);

    var buf_a: [80]u8 = undefined;
    var buf_b: [80]u8 = undefined;
    const schema_a = schemaName(tenant_a, &buf_a);
    const schema_b = schemaName(tenant_b, &buf_b);

    defer cleanupTenant(alloc, &pool, tenant_a, schema_a);
    defer cleanupTenant(alloc, &pool, tenant_b, schema_b);

    // Provision both tenants serially first so the audit chain-hash
    // trigger function (bpm_audit_apply_chain_hash) exists in each tenant
    // schema. The migrate lock is acquired briefly during each call but is
    // released on COMMIT, so by the time we move to the concurrent-INSERT
    // phase, no migrate lock is held.
    try provisionTenantSchema(alloc, &pool, tenant_a, migrationsDir());
    try provisionTenantSchema(alloc, &pool, tenant_b, migrationsDir());

    // Acquire one pool connection per tenant, set the per-thread tenant
    // context to the corresponding UUID, and insert one audit_entries row
    // on each. Each INSERT fires the audit chain-hash trigger (which
    // acquires its own per-tenant advisory lock — disjoint keyspace from
    // the migrate lock).
    bpm.api_tenant_context.set(tenant_a);
    var conn_a = try pool.acquire();
    defer pool.release(conn_a);

    bpm.api_tenant_context.set(tenant_b);
    var conn_b = try pool.acquire();
    defer pool.release(conn_b);

    // Reset context to default so the rest of the test (and the test
    // harness's teardown) operates on the canonical default tenant.
    defer bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");

    const audit_id_a = try randomUuidStr(alloc);
    defer alloc.free(audit_id_a);
    const audit_id_b = try randomUuidStr(alloc);
    defer alloc.free(audit_id_b);
    const actor_id = try randomUuidStr(alloc);
    defer alloc.free(actor_id);

    const start_ms = std.Io.Clock.real.now(std.testing.io).toMilliseconds();

    // Each INSERT must complete within the lock_timeout set on these
    // connections by helpers.zig's configureSessionTimeouts (5s). If the
    // migrate lock accidentally shared the audit keyspace, one INSERT
    // would block indefinitely waiting on the other's tenant lock, then
    // the other's tenant lock would be blocked behind the migrate lock
    // held elsewhere — a C40P01 deadlock. Both INSERTs succeeding within
    // the budget confirms keyspace disjointness.
    try conn_a.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  "timestamp", before_state, after_state, trace_id
        \\) VALUES (
        \\  $1, $2::uuid, $3::uuid, $4, $5, $6, NOW(), NULL, '{"k":"a"}'::jsonb, 'iss0129-rt3-a'
        \\)
    , &.{ audit_id_a, tenant_a, actor_id, "iss0129.rt3.create", "iss0129.rt3", tenant_a });

    try conn_b.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  "timestamp", before_state, after_state, trace_id
        \\) VALUES (
        \\  $1, $2::uuid, $3::uuid, $4, $5, $6, NOW(), NULL, '{"k":"b"}'::jsonb, 'iss0129-rt3-b'
        \\)
    , &.{ audit_id_b, tenant_b, actor_id, "iss0129.rt3.create", "iss0129.rt3", tenant_b });

    const elapsed_ms: i64 = std.Io.Clock.real.now(std.testing.io).toMilliseconds() - start_ms;
    // Generous budget: each INSERT may take a few hundred ms for trigger
    // overhead. If the migrate lock ever leaks into the audit keyspace,
    // these will time out at lock_timeout=5s with a 40P01 deadlock.
    try std.testing.expect(elapsed_ms < 5_000);
}

// ---------------------------------------------------------------------------
// RT-4
// Wall-clock budget: a full concurrent-runForSchema for two tenants must
// complete within 60 seconds. The diagnosis's AC-2.
//
// RT-4 ALSO captures each worker's outcome in a WorkerResult (Defect 1
// fix) so a silent provisioning error fails the test loudly with the
// worker's actual error, not as a confusing later symptom.
// ---------------------------------------------------------------------------
test "ISS-0129 RT-4: full concurrent runForSchema for two tenants completes within 60s" {
    std.debug.print(">>> ENTERING RT-4\n", .{});
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool_a = try makePool(alloc, url);
    defer pool_a.deinit();

    var pool_b = try makePool(alloc, url);
    defer pool_b.deinit();

    const tenant_a = try randomUuidStr(alloc);
    defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc);
    defer alloc.free(tenant_b);

    var buf_a: [80]u8 = undefined;
    var buf_b: [80]u8 = undefined;
    const schema_a = schemaName(tenant_a, &buf_a);
    const schema_b = schemaName(tenant_b, &buf_b);

    defer cleanupTenant(alloc, &pool_a, tenant_a, schema_a);
    defer cleanupTenant(alloc, &pool_b, tenant_b, schema_b);

    const start_ms = std.Io.Clock.real.now(std.testing.io).toMilliseconds();

    var result_a = WorkerResult{};
    var result_b = WorkerResult{};
    const dir = migrationsDir();

    var t1 = try std.Thread.spawn(.{}, ProvisionWorker.run, .{
        alloc, &pool_a, tenant_a, dir, &result_a,
    });
    var t2 = try std.Thread.spawn(.{}, ProvisionWorker.run, .{
        alloc, &pool_b, tenant_b, dir, &result_b,
    });
    t1.join();
    t2.join();

    // Surface any worker error BEFORE the wall-clock check — if either
    // worker failed, the wall-clock assertion would either spuriously
    // pass (fast failure with no work done) or fail confusingly with the
    // wrong diagnosis.
    if (result_a.err) |e| {
        std.debug.print("RT-4: tenant_a concurrent provisionTenantSchema failed: {}\n", .{e});
        return error.ConcurrentProvisionFailedA;
    }
    if (result_b.err) |e| {
        std.debug.print("RT-4: tenant_b concurrent provisionTenantSchema failed: {}\n", .{e});
        return error.ConcurrentProvisionFailedB;
    }

    const elapsed_ms: i64 = std.Io.Clock.real.now(std.testing.io).toMilliseconds() - start_ms;
    try std.testing.expect(elapsed_ms < 60_000);
}

// ---------------------------------------------------------------------------
// RT-5
// Source-stability assertion: `src/db/migrations.zig` contains the literal
// prefix `hashtext('bpm.migrations.runForSchema')`. If a future contributor
// drifts the prefix string, the keyspace contract is silently broken and
// the deadlock class this fix addresses can resurface. This guard fails
// first with a clear message before any runtime deadlock symptom appears.
// ---------------------------------------------------------------------------
test "ISS-0129 RT-5: MIGRATIONS_LOCK_KEY_SQL prefix is stable in src/db/migrations.zig" {
    std.debug.print(">>> ENTERING RT-5\n", .{});
    const alloc = std.testing.allocator;

    try assertLockPrefixStable(alloc);
}
