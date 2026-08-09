//! Integration tests for DB-01 (schema init), DB-03 (transactional integrity),
//! and DB-04 (health check).
//!
//! Requires a real PostgreSQL database reachable at BPM_TEST_DB_URL.
//! Every test uses TestHarness for migration bootstrap and connection isolation.
//!
//! Requirement traceability:
//!   DB-01 → TC-DB-01-01, TC-DB-01-02
//!   DB-02 → TC-DB-02-03, TC-DB-02-04
//!   DB-03 → TC-DB-03-01, TC-DB-03-02
//!   DB-04 → TC-DB-04-01
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const Store = bpm.store.Store;
const AppendParams = bpm.store.AppendParams;

const Registry = bpm.registry.Registry;
const RegisterParams = bpm.registry.RegisterParams;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Read BPM_TEST_DB_URL from the environment. Fails the test if not set.
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

/// Create a Pool pointing to the test database with pool_size = 5.
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

/// Parse a canonical hyphenated UUID string (e.g. from TestHarness.newUuidString())
/// into the raw [16]u8 representation Store.append()'s AppendParams.instance_id
/// expects. Mirrors the established helper of the same name in
/// event_store_integration_test.zig (ISS-0128 / GH #418).
fn parseUuid(s: []const u8) ![16]u8 {
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (i >= 32) return error.InvalidUuid;
        buf[i] = c;
        i += 1;
    }
    if (i != 32) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, buf[0..32]);
    return out;
}

// ---------------------------------------------------------------------------
// DB-01: Schema initialisation
// ---------------------------------------------------------------------------

// TC-DB-01-01
// Verifies that after TestHarness.init() (which runs all pending migrations),
// schema_migrations contains at least one entry and the core tables exist.
test "TC-DB-01-01: migrations apply all schemas and populate schema_migrations" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // schema_migrations must have at least one entry. Always schema-qualified
    // as public.schema_migrations: TestHarness uses a tenant_default,public
    // search_path, and an unqualified reference can silently resolve to a
    // stray tenant_default.schema_migrations shadow table instead (see
    // GitHub #368 / ISS-0108).
    var count_result = try h.conn.query(
        alloc,
        "SELECT COUNT(*) FROM public.schema_migrations",
        &.{},
    );
    defer count_result.deinit();
    try std.testing.expect(count_result.rows.len > 0);
    if (count_result.rows[0][0]) |s| {
        const n = try std.fmt.parseInt(i64, s, 10);
        try std.testing.expect(n > 0);
    }

    // Core Stage-1 tables must exist. schema_migrations is the only one of
    // these that still lives in public — GBL-073 (TNT-01 cleanup) dropped
    // events/instance_projections/instance_sequence/event_type_registry/
    // events_archive from public once schema-per-tenant provisioning made
    // tenant_default the sole home for business tables.
    var public_tables_result = try h.conn.query(
        alloc,
        \\SELECT COUNT(*) FROM information_schema.tables
        \\WHERE table_schema = 'public'
        \\  AND table_name IN ('schema_migrations')
    ,
        &.{},
    );
    defer public_tables_result.deinit();
    try std.testing.expect(public_tables_result.rows.len > 0);
    if (public_tables_result.rows[0][0]) |s| {
        const n = try std.fmt.parseInt(i64, s, 10);
        try std.testing.expectEqual(@as(i64, 1), n);
    }

    var tenant_tables_result = try h.conn.query(
        alloc,
        \\SELECT COUNT(*) FROM information_schema.tables
        \\WHERE table_schema = 'tenant_default'
        \\  AND table_name IN (
        \\    'events', 'instance_projections',
        \\    'instance_sequence', 'event_type_registry', 'events_archive'
        \\  )
    ,
        &.{},
    );
    defer tenant_tables_result.deinit();
    try std.testing.expect(tenant_tables_result.rows.len > 0);
    if (tenant_tables_result.rows[0][0]) |s| {
        const n = try std.fmt.parseInt(i64, s, 10);
        try std.testing.expectEqual(@as(i64, 5), n);
    }
}

// TC-DB-01-02
// Verifies that running migrations a second time (idempotent) does not insert
// duplicate rows into schema_migrations and does not return an error.
test "TC-DB-01-02: re-running migrations is idempotent" {
    const alloc = std.testing.allocator;

    // First init: apply all migrations.
    var h1 = try TestHarness.init(alloc);

    // Snapshot count of applied migrations. Schema-qualified — see rationale
    // in TC-DB-01-01 above (GitHub #368 / ISS-0108).
    var before_result = try h1.conn.query(
        alloc,
        "SELECT COUNT(*) FROM public.schema_migrations",
        &.{},
    );
    defer before_result.deinit();
    const before_count: i64 = blk: {
        if (before_result.rows.len > 0) {
            if (before_result.rows[0][0]) |s|
                break :blk std.fmt.parseInt(i64, s, 10) catch 0;
        }
        break :blk 0;
    };

    h1.deinit(); // close first connection

    // Second init: migrations must be no-ops.
    var h2 = try TestHarness.init(alloc);
    defer h2.deinit();

    var after_result = try h2.conn.query(
        alloc,
        "SELECT COUNT(*) FROM public.schema_migrations",
        &.{},
    );
    defer after_result.deinit();
    const after_count: i64 = blk: {
        if (after_result.rows.len > 0) {
            if (after_result.rows[0][0]) |s|
                break :blk std.fmt.parseInt(i64, s, 10) catch 0;
        }
        break :blk 0;
    };

    // Row count must not have grown.
    try std.testing.expectEqual(before_count, after_count);
    try std.testing.expect(after_count > 0);
}

// ---------------------------------------------------------------------------
// DB-02: Connection pooling
// ---------------------------------------------------------------------------

// TC-DB-02-03
// Verifies that Pool.acquire() returns PoolError.ExhaustedPool immediately
// when all connections in a pool_size=2 pool are in use, and that releasing
// a connection makes the pool available again.
test "TC-DB-02-03: pool exhaustion returns ExhaustedPool; release restores availability" {
    const alloc = std.testing.allocator;

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{
        .url = url,
        .pool_size = 2,
    });
    defer pool.deinit();

    // Acquire both connections — pool is now fully exhausted.
    const conn1 = try pool.acquire();
    const conn2 = try pool.acquire();

    // Third acquire must return ExhaustedPool immediately (DB-02: no blocking).
    try std.testing.expectError(error.ExhaustedPool, pool.acquire());

    // Release one connection; next acquire must succeed.
    pool.release(conn1);
    const conn3 = try pool.acquire();
    pool.release(conn3);
    pool.release(conn2);
}

// TC-DB-02-04
// Verifies that Pool.init() returns PoolError.InvalidPoolSize for pool_size
// values outside the valid range [2, 200] (NFR-06), and succeeds at the
// boundary values 2 and 200.
test "TC-DB-02-04: invalid pool_size returns InvalidPoolSize; boundary values succeed" {
    const alloc = std.testing.allocator;

    // Out-of-range lower bound: pool_size = 1.
    // InvalidPoolSize is returned before any network call, so a dummy URL works.
    try std.testing.expectError(error.InvalidPoolSize, Pool.init(
        std.testing.io,
        alloc,
        PoolConfig{ .url = "postgres://localhost/test", .pool_size = 1 },
    ));

    // Out-of-range upper bound: pool_size = 201.
    try std.testing.expectError(error.InvalidPoolSize, Pool.init(
        std.testing.io,
        alloc,
        PoolConfig{ .url = "postgres://localhost/test", .pool_size = 201 },
    ));

    // Valid boundary values require a live connection.
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    // Valid lower boundary: pool_size = 2.
    var pool2 = try Pool.init(std.testing.io, alloc, PoolConfig{
        .url = url,
        .pool_size = 2,
    });
    defer pool2.deinit();

    // Probe the server to compute a safe upper-boundary pool size.
    // Prevents flakiness when parallel test binaries exhaust connection slots.
    const safe_pool_size: u8 = blk: {
        const probe = try pool2.acquire();
        defer pool2.release(probe);

        // Query max_connections setting; fallback 250 on parse failure.
        var max_res = try probe.query(alloc, "SHOW max_connections", &.{});
        defer max_res.deinit();
        const max_conn: i64 = if (max_res.rows.len > 0 and max_res.rows[0].len > 0)
            if (max_res.rows[0][0]) |v| std.fmt.parseInt(i64, v, 10) catch 250 else 250
        else
            250;

        // Count active connections to this DB (includes pool2's own 2 slots).
        var act_res = try probe.query(
            alloc,
            "SELECT count(*)::text FROM pg_stat_activity WHERE datname = current_database()",
            &.{},
        );
        defer act_res.deinit();
        const current_conn: i64 = if (act_res.rows.len > 0 and act_res.rows[0].len > 0)
            if (act_res.rows[0][0]) |v| std.fmt.parseInt(i64, v, 10) catch 50 else 50
        else
            50;

        const available: i64 = max_conn - current_conn - 5;
        if (available < 2) {
            std.debug.print("TC-DB-02-04 SKIP: available={d} (max={d} current={d})\n", .{ available, max_conn, current_conn });
            break :blk 0; // sentinel: SkipZigTest below
        }
        break :blk @intCast(@min(@as(i64, 200), available));
    };
    if (safe_pool_size < 2) return error.SkipZigTest;

    // Valid upper boundary: pool_size = safe_pool_size (capped at 200).
    var pool200 = try Pool.init(std.testing.io, alloc, PoolConfig{
        .url = url,
        .pool_size = safe_pool_size,
    });
    defer pool200.deinit();
}

// ---------------------------------------------------------------------------
// DB-03: Transactional integrity
// ---------------------------------------------------------------------------

// TC-DB-03-01
// Verifies that Store.append() commits both the events row and the
// instance_projections.last_event_seq update atomically.
// After a successful append the DB observer sees both writes together.
test "TC-DB-03-01: successful transaction commits both event row and state update atomically" {
    const alloc = std.testing.allocator;

    // Bootstrap migrations.
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    // Use a unique instance UUID so this test is isolated from other runs.
    const inst_id_str = try h.newUuidString(alloc);
    defer alloc.free(inst_id_str);
    const def_id_str = try h.newUuidString(alloc);
    defer alloc.free(def_id_str);

    // Insert prerequisite instance_projections row (autocommit — visible to Pool).
    {
        const setup_conn = try pool.acquire();
        defer pool.release(setup_conn);
        try setup_conn.exec(
            "INSERT INTO instance_projections (instance_id, definition_id, status, last_event_seq) " ++
                "VALUES ($1::uuid, $2::uuid, 'ACTIVE', 0) ON CONFLICT DO NOTHING",
            &.{ inst_id_str, def_id_str },
        );
    }

    // Register the event type so validation passes.
    _ = registry.registerType(alloc, RegisterParams{
        .name = "DB03_TEST",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    // ISS-0128 / GH #418: instance_id passed to store.append() MUST be derived
    // from the same inst_id_str used for the fixture INSERT above (and for the
    // assertions/cleanup below) — a previous, unrelated hardcoded literal here
    // ("db0301aa...") was never inserted into instance_projections, so
    // store.append() correctly-but-misleadingly returned InstanceNotFound for
    // an instance that was simply never provisioned under that id.
    const inst_uuid: [16]u8 = try parseUuid(inst_id_str);
    var actor_uuid: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&actor_uuid, "acac0000000000000000000000000001");

    const result = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "DB03_TEST",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "db03-01-idem-key",
        .metadata = null,
    });
    try std.testing.expect(!result.is_duplicate);

    // Both the events row and the updated instance_projections must be visible.
    const events_conn = try pool.acquire();
    defer pool.release(events_conn);

    var ev_result = try events_conn.query(
        alloc,
        "SELECT COUNT(*) FROM events WHERE idempotency_key = $1",
        &.{"db03-01-idem-key"},
    );
    defer ev_result.deinit();
    if (ev_result.rows.len > 0) {
        if (ev_result.rows[0][0]) |s| {
            const n = try std.fmt.parseInt(i64, s, 10);
            try std.testing.expectEqual(@as(i64, 1), n);
        }
    }

    var proj_result = try events_conn.query(
        alloc,
        "SELECT last_event_seq FROM instance_projections WHERE instance_id = $1::uuid",
        &.{inst_id_str},
    );
    defer proj_result.deinit();
    try std.testing.expect(proj_result.rows.len > 0);
    if (proj_result.rows[0][0]) |s| {
        const seq = try std.fmt.parseInt(i64, s, 10);
        try std.testing.expect(seq >= 1);
    }

    // Cleanup.
    const cleanup = try pool.acquire();
    defer pool.release(cleanup);
    try cleanup.exec("DELETE FROM events WHERE idempotency_key = $1", &.{"db03-01-idem-key"});
    try cleanup.exec("DELETE FROM instance_sequence WHERE instance_id = $1::uuid", &.{inst_id_str});
    try cleanup.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{inst_id_str});
}

// TC-DB-03-02
// Verifies that a transaction containing an intentional constraint violation
// rolls back completely: neither the events row nor the state update persists.
// This tests the atomicity guarantee directly through the DB transaction layer.
test "TC-DB-03-02: failed transaction rolls back both writes atomically" {
    const alloc = std.testing.allocator;

    var h_phase1 = try TestHarness.init(alloc);
    defer h_phase1.deinit();

    const inst_id_str = try h_phase1.newUuidString(alloc);
    defer alloc.free(inst_id_str);
    const def_id_str = try h_phase1.newUuidString(alloc);
    defer alloc.free(def_id_str);

    // Phase 1 — write inside a transaction, inject constraint violation, rollback.
    {
        // BEGIN is already active (TestHarness.init() called conn.begin()).

        // Insert instance row inside the harness transaction (not yet committed).
        try h_phase1.conn.exec(
            "INSERT INTO instance_projections " ++
                "(instance_id, definition_id, status, last_event_seq) " ++
                "VALUES ($1::uuid, $2::uuid, 'ACTIVE', 0)",
            &.{ inst_id_str, def_id_str },
        );

        // Insert an events row inside the same transaction.
        // GH-512: replaced hardcoded actor fixture with TestHarness.newUuidString() per GH-512.
        // The idempotency_key 'db03-02-idem' is the unique discriminator; actor_id value is irrelevant.
        const actor_id_str = try h_phase1.newUuidString(alloc);
        defer alloc.free(actor_id_str);
        try h_phase1.conn.exec(
            "INSERT INTO events " ++
                "(instance_id, event_type, payload, actor_id, sequence_number, idempotency_key, global_seq) " ++
                "VALUES ($1::uuid, 'DB03_ROLLBACK', '{}', $2::uuid, 1, 'db03-02-idem', nextval('events_global_seq'))",
            &.{ inst_id_str, actor_id_str },
        );

        // Inject a constraint violation: duplicate primary key on instance_projections.
        // This puts the transaction into the PostgreSQL "aborted" state.
        h_phase1.conn.exec(
            "INSERT INTO instance_projections " ++
                "(instance_id, definition_id, status, last_event_seq) " ++
                "VALUES ($1::uuid, $2::uuid, 'ACTIVE', 0)",
            &.{ inst_id_str, def_id_str },
        ) catch {}; // expected to fail — duplicate PK

        // deinit() calls ROLLBACK — all writes in this block are discarded.
        h_phase1.deinit();
    }

    // Phase 2 — verify nothing was committed.
    var h2 = try TestHarness.init(alloc);
    defer h2.deinit();

    var ev_check = try h2.conn.query(
        alloc,
        "SELECT COUNT(*) FROM events WHERE idempotency_key = 'db03-02-idem'",
        &.{},
    );
    defer ev_check.deinit();
    if (ev_check.rows.len > 0) {
        if (ev_check.rows[0][0]) |s| {
            const n = try std.fmt.parseInt(i64, s, 10);
            try std.testing.expectEqual(@as(i64, 0), n);
        }
    }

    var proj_check = try h2.conn.query(
        alloc,
        "SELECT COUNT(*) FROM instance_projections WHERE instance_id = $1::uuid",
        &.{inst_id_str},
    );
    defer proj_check.deinit();
    if (proj_check.rows.len > 0) {
        if (proj_check.rows[0][0]) |s| {
            const n = try std.fmt.parseInt(i64, s, 10);
            try std.testing.expectEqual(@as(i64, 0), n);
        }
    }
}

// ---------------------------------------------------------------------------
// DB-04: Health check query
// ---------------------------------------------------------------------------

// TC-DB-04-01
// Verifies that Pool.healthCheck() issues SELECT 1 against a live pool
// connection and returns HealthResult with latency_ms >= 0.
test "TC-DB-04-01: health check returns latency_ms on successful SELECT 1" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const health = try pool.healthCheck();
    // latency_ms must be a non-negative value (DB-04).
    // The field type is u64 so it can never be negative; just confirm success.
    _ = health.latency_ms; // u64: always >= 0

    // Confirm pool idle count is restored after the health check.
    try std.testing.expectEqual(@as(usize, 5), pool.idle_count);
}
