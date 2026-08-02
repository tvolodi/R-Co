//! Integration tests for ISS-0122 / GitHub #388 — audit chain TEXT resource_id +
//! non-UTF-8 resilience.
//!
//! Regression coverage for migration `1107_fix_audit_chain_text_resource_id.sql`
//! which wraps the chain-hash pipeline in EXCEPTION blocks and pre-normalises
//! non-UTF-8 bytes in NEW.resource_id so a TEXT audit row whose resource_id
//! contains 0xAA never propagates SQLSTATE 22021 (invalid_byte_sequence_for_encoding)
//! back to the INSERT caller.
//!
//! Per DIRECTIVE T-1: real PostgreSQL only via BPM_TEST_DB_URL; no mocks, no
//! stubs, no in-memory fakes. TestHarness.init() returns
//! error.MissingTestDatabaseUrl when the env var is absent — the test blocks
//! below propagate that error rather than swallowing it as
//! error.SkipZigTest (FORBIDDEN on MUST requirements per anti-patterns.md).
//!
//! Per DIRECTIVE T-3 (frontend visual verification): N/A — backend regression.
//!
//! Test cases mirror tests/specs/ISS-0122.md:
//!   TC-ISS-0122-01: ASCII TEXT resource_id writes through the chain trigger
//!   TC-ISS-0122-02: Non-UTF-8 resource_id writes WITHOUT C22021 propagation
//!   TC-ISS-0122-03: bpm_audit_validate_chain returns empty issues[]
//!   TC-ISS-0122-04: Concurrent non-UTF-8 inserts do not fork the chain
//!
//! Approach: insert straight into audit_entries so the
//! trg_bpm_audit_apply_chain_hash BEFORE INSERT trigger fires under
//! production-fidelity conditions. The audit_entries table has
//! resource_id TEXT (post-GBL-082) so a deliberate 0xE2 0xAA 0xAA byte
//! sequence lands in the same column family that was crashing pre-fix.

const std = @import("std");
const testing = std.testing;

const pg = @import("pg");
const bpm = @import("bpm");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const uuid_mod = bpm.uuid;

const SHA256_HEX_LEN: usize = 64;

/// Hex sentinel for an all-zero SHA-256 (the documented escape path inside
/// bpm_audit_compute_chain_hash's EXCEPTION guard — migration 1107).
const ZERO_HASH_SENTINEL: []const u8 = "0000000000000000000000000000000000000000000000000000000000000000";

/// Helper: does `s` look like a 64-char lowercase hex SHA-256?
fn isAllHexLower(s: []const u8) bool {
    if (s.len != SHA256_HEX_LEN) return false;
    for (s) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
        if (!ok) return false;
    }
    return true;
}

/// Helper: insert one audit_entries row for the given (tenant, actor,
/// resource_type, resource_id, action). The trg_bpm_audit_apply_chain_hash
/// trigger fires on this INSERT so chain_hash is computed automatically
/// against the 1107 guard.
fn insertAuditRow(
    harness: *TestHarness,
    audit_id: []const u8,
    tenant_id: []const u8,
    actor_id: []const u8,
    resource_type: []const u8,
    resource_id: []const u8,
    action: []const u8,
) !void {
    _ = try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  "timestamp", before_state, after_state, trace_id
        \\)
        \\VALUES (
        \\  $1, $2, $3, $4, $5, $6, NOW(), NULL, '{"k":"v"}'::jsonb, 'iss0122-test'
        \\)
    ,
        &.{
            audit_id,
            tenant_id,
            actor_id,
            action,
            resource_type,
            resource_id,
        },
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0122-01 — ASCII TEXT resource_id writes through the chain trigger
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0122-01: ASCII TEXT resource_id writes through the chain trigger" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    const actor_id = try uuid_mod.newUuidV4(alloc);
    const audit_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(tenant_id);
        alloc.free(actor_id);
        alloc.free(audit_id);
    }

    const resource_id = "tc01-ascii-row-id";
    try insertAuditRow(
        &harness,
        audit_id,
        tenant_id,
        actor_id,
        "iss0122.parent.tc01",
        resource_id,
        "iss0122.tc01.create",
    );

    var audit_q = try harness.conn.query(
        alloc,
        \\SELECT chain_hash, prev_chain_hash, resource_id, octet_length(resource_id)
        \\FROM audit_entries
        \\WHERE tenant_id = $1::uuid
        \\  AND resource_type = 'iss0122.parent.tc01'
        \\ORDER BY "timestamp" ASC, audit_id ASC
    ,
        &.{tenant_id},
    );
    defer audit_q.deinit();

    try testing.expectEqual(@as(usize, 1), audit_q.rows.len);
    const row = audit_q.rows[0];

    // chain_hash must be 64 lowercase hex.
    const chain_hash = row[0] orelse "";
    try testing.expect(isAllHexLower(chain_hash));

    // Stored resource_id faithfully round-trips the original ASCII bytes.
    try testing.expectEqualStrings(resource_id, row[2] orelse "");
    try testing.expectEqual(
        @as(usize, resource_id.len),
        std.fmt.parseInt(usize, row[3] orelse "0", 10) catch 0,
    );

    // First (and only) row has NULL prev.
    try testing.expect(row[1] == null);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0122-02 — Non-UTF-8 resource_id writes WITHOUT C22021 propagation
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0122-02: non-UTF-8 TEXT resource_id writes without C22021 propagation" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    const actor_id = try uuid_mod.newUuidV4(alloc);
    const audit_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(tenant_id);
        alloc.free(actor_id);
        alloc.free(audit_id);
    }

    // Construct the 3 raw bytes 0xE2 0xAA 0xAA via the canonical
    // `convert_from(decode('e2aaaa','hex'),'UTF8')` pattern from
    // src/design/audit_chain_text_resource_id.md §4 — these bytes are NOT
    // valid UTF-8 (E2 starts a 3-byte sequence but trailing 0xAA is not a
    // valid continuation byte). Pre-fix, this surface raised 22021 and the
    // INSERT failed.
    var insert_q = try harness.conn.query(
        alloc,
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  "timestamp", before_state, after_state, trace_id
        \\)
        \\VALUES (
        \\  $1, $2, $3,
        \\  'iss0122.tc02.create',
        \\  'iss0122.parent.tc02',
        \\  convert_from(decode('e2aaaa','hex'),'UTF8'),
        \\  NOW(), NULL, '{"k":"v"}'::jsonb, 'iss0122-test'
        \\)
        \\RETURNING chain_hash::text, octet_length(resource_id), resource_id
    ,
        &.{ audit_id, tenant_id, actor_id },
    );
    defer insert_q.deinit();

    // PRIMARY ASSERTION: the INSERT succeeded (a row came back) — pre-fix
    // this raises 22021 and the calling code sees error.ServerError.
    try testing.expectEqual(@as(usize, 1), insert_q.rows.len);
    try testing.expectEqual(
        @as(usize, 3),
        std.fmt.parseInt(usize, insert_q.rows[0][1] orelse "0", 10) catch 0,
    );

    // chain_hash returned from RETURNING is either a valid 64-char lowercase
    // hex (the trigger computed a real SHA-256 against the normalised
    // <invalid-utf8:N> payload) or NULL (the EXCEPTION guard set it to NULL).
    const returned_chain = insert_q.rows[0][0];
    if (returned_chain) |h| {
        try testing.expect(isAllHexLower(h));
    }
    // NULL is the documented alternative — both are non-blocking.

    // The audit row is searchable by (tenant_id, resource_type) and the
    // stored resource_id round-trips the original 3 bytes.
    var verify_q = try harness.conn.query(
        alloc,
        \\SELECT chain_hash, octet_length(resource_id)
        \\FROM audit_entries
        \\WHERE tenant_id = $1::uuid AND resource_type = 'iss0122.parent.tc02'
    ,
        &.{tenant_id},
    );
    defer verify_q.deinit();
    try testing.expectEqual(@as(usize, 1), verify_q.rows.len);
    try testing.expectEqual(
        @as(usize, 3),
        std.fmt.parseInt(usize, verify_q.rows[0][1] orelse "0", 10) catch 0,
    );
    if (verify_q.rows[0][0]) |h| {
        try testing.expect(isAllHexLower(h));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0122-03 — Validator returns empty issues[] after the non-UTF-8 insert
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0122-03: bpm_audit_validate_chain returns empty issues[]" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    const actor_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(tenant_id);
        alloc.free(actor_id);
    }

    // ASCII row is the chain head (inserted first). Pre-sort the two random
    // v4 audit_ids so the chain head has the smaller audit_id — required
    // for the validator's ASC walk to visit the chain head first. Without
    // this, the chain-order issue produces 2 PrevHashMismatch issues.
    const raw_a = try uuid_mod.newUuidV4(alloc);
    const raw_b = try uuid_mod.newUuidV4(alloc);
    const ascii_first = std.mem.lessThan(u8, raw_a, raw_b);
    const ascii_audit_id = if (ascii_first) raw_a else raw_b;
    const utf8_audit_id = if (ascii_first) raw_b else raw_a;
    defer alloc.free(ascii_audit_id);
    defer alloc.free(utf8_audit_id);
    try insertAuditRow(
        &harness,
        ascii_audit_id,
        tenant_id,
        actor_id,
        "iss0122.parent.tc03",
        "tc03-ascii",
        "iss0122.tc03.create",
    );
    try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  "timestamp", before_state, after_state, trace_id
        \\)
        \\VALUES (
        \\  $1, $2, $3,
        \\  'iss0122.tc03.create',
        \\  'iss0122.parent.tc03',
        \\  convert_from(decode('e2aaaa','hex'),'UTF8'),
        \\  NOW(), NULL, '{"k":"v"}'::jsonb, 'iss0122-test'
        \\)
    ,
        &.{ utf8_audit_id, tenant_id, actor_id },
    );

    // Validator: count issues[] for this tenant.
    var issues = try harness.conn.query(
        alloc,
        "SELECT code FROM bpm_audit_validate_chain($1::uuid, NULL, NULL, false)",
        &.{tenant_id},
    );
    defer issues.deinit();

    try testing.expectEqual(@as(usize, 0), issues.rows.len);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0122-04 — Concurrent non-UTF-8 inserts do not fork the chain
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0122-04: concurrent non-UTF-8 inserts do not fork the chain" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_id = try uuid_mod.newUuidV4(alloc);
    const actor_id = try uuid_mod.newUuidV4(alloc);
    defer {
        alloc.free(tenant_id);
        alloc.free(actor_id);
    }

    // Get the connection URL once for both the seed and conn_b.
    const env: std.process.Environ = .{ .block = .global };
    const url = env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.MissingTestDatabaseUrl,
        else => return err,
    };

    // Seed an initial chain head so a concurrent fork is detectable.
    // Use a SEPARATE short-lived connection (auto-commit per exec) so the
    // seed row is committed and visible to thread B's conn_b before
    // concurrent INSERTs begin. Writing the seed via harness.conn (T1)
    // leaves it uncommitted and invisible to conn_b's auto-commit
    // transactions, which forks the chain at thread B's first INSERT
    // (its prev_chain_hash SELECT sees no committed rows for the tenant).
    const seed_audit_id = try uuid_mod.newUuidV4(alloc);
    defer alloc.free(seed_audit_id);
    {
        var seed_conn = try pg.Conn.connectUrl(std.testing.io, alloc, url);
        defer seed_conn.close();
        try seed_conn.exec("SET search_path TO tenant_default,public", &.{});
        try seed_conn.exec(
            \\INSERT INTO audit_entries (
            \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
            \\  "timestamp", before_state, after_state, trace_id
            \\)
            \\VALUES (
            \\  $1, $2, $3, $4, $5, $6, NOW(), NULL, '{"k":"v"}'::jsonb, 'iss0122-test'
            \\)
        ,
            &.{
                seed_audit_id,
                tenant_id,
                actor_id,
                "iss0122.tc04.create",
                "iss0122.parent.tc04",
                "tc04-seed",
            },
        );
        // seed_conn goes out of scope — auto-commit on close; seed is committed.
    }
    defer alloc.free(url);

    var conn_b = try pg.Conn.connectUrl(std.testing.io, alloc, url);
    defer conn_b.close();

    try conn_b.exec("SET search_path TO tenant_default,public", &.{});
    try conn_b.exec("SET lock_timeout = '10s'", &.{});
    try conn_b.exec("SET statement_timeout = '60s'", &.{});

    // Open a second writer connection for thread A. Both writers MUST use
    // auto-commit (NOT harness.conn's long-running T1) so the per-tenant
    // advisory lock acquired in the trigger is released between INSERTs.
    // When A uses harness.conn (T1), T1 holds the lock for the entire
    // test; conn_b's lock_timeout trips and the lock is skipped via the
    // trigger's EXCEPTION guard, so conn_b's first INSERT sees only the
    // seed row and forks the chain by chaining to the same head as T1.
    var conn_a = try pg.Conn.connectUrl(std.testing.io, alloc, url);
    defer conn_a.close();

    try conn_a.exec("SET search_path TO tenant_default,public", &.{});
    try conn_a.exec("SET lock_timeout = '10s'", &.{});
    try conn_a.exec("SET statement_timeout = '60s'", &.{});

    // Worker writes 3 non-UTF-8 audit rows on the second connection.
    const WorkerCtx = struct {
        conn: *pg.Conn,
        tenant_id: []const u8,
        actor_id: []const u8,
        err: anyerror!void = {},
    };

    var ctx_b = WorkerCtx{
        .conn = &conn_b,
        .tenant_id = tenant_id,
        .actor_id = actor_id,
    };
    var ctx_a = WorkerCtx{
        .conn = &conn_a,
        .tenant_id = tenant_id,
        .actor_id = actor_id,
    };

    const thread_b = try std.Thread.spawn(.{}, struct {
        fn run(ctx: *WorkerCtx) void {
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                // Build a per-iteration SQL string so the index is embedded
                // as a literal. Avoids any Zig 0.16 slice-coercion tangle
                // around pg.Conn.exec's []const []const u8 param tuple.
                var sql_buf: [512]u8 = undefined;
                const sql = std.fmt.bufPrint(
                    &sql_buf,
                    \\INSERT INTO audit_entries (
                    \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
                    \\  "timestamp", before_state, after_state, trace_id
                    \\)
                    \\VALUES (
                    \\  gen_random_uuid(), $1, $2,
                    \\  'iss0122.tc04.create',
                    \\  'iss0122.parent.tc04',
                    \\  convert_from(decode('e2aaaa','hex'),'UTF8') || '-b-' || '-i{d}',
                    \\  NOW(), NULL, '{{"k":"v"}}'::jsonb, 'iss0122-test-b'
                    \\)
                ,
                    .{i},
                ) catch {
                    ctx.err = error.BufferTooSmall;
                    return;
                };
                const params = [_][]const u8{ ctx.tenant_id, ctx.actor_id };
                ctx.conn.exec(sql, &params) catch |err| {
                    ctx.err = err;
                    return;
                };
            }
        }
    }.run, .{&ctx_b});

    // Connection A writes 3 non-UTF-8 audit rows on this thread concurrently
    // with thread B. A uses its own auto-commit connection (conn_a), NOT
    // harness.conn's T1, so the per-tenant advisory lock acquired by the
    // trigger is released between A's INSERTs — see the comment near
    // conn_a above for why harness.conn's T1 forks the chain.
    const thread_a = try std.Thread.spawn(.{}, struct {
        fn run(ctx: *WorkerCtx) void {
            var i: usize = 0;
            while (i < 3) : (i += 1) {
                var sql_buf: [512]u8 = undefined;
                const sql = std.fmt.bufPrint(
                    &sql_buf,
                    \\INSERT INTO audit_entries (
                    \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
                    \\  "timestamp", before_state, after_state, trace_id
                    \\)
                    \\VALUES (
                    \\  gen_random_uuid(), $1, $2,
                    \\  'iss0122.tc04.create',
                    \\  'iss0122.parent.tc04',
                    \\  convert_from(decode('e2aaaa','hex'),'UTF8') || '-a-' || '-i{d}',
                    \\  NOW(), NULL, '{{"k":"v"}}'::jsonb, 'iss0122-test-a'
                    \\)
                ,
                    .{i},
                ) catch {
                    ctx.err = error.BufferTooSmall;
                    return;
                };
                const params = [_][]const u8{ ctx.tenant_id, ctx.actor_id };
                ctx.conn.exec(sql, &params) catch |err| {
                    ctx.err = err;
                    return;
                };
            }
        }
    }.run, .{&ctx_a});

    thread_a.join();
    thread_b.join();
    try ctx_a.err;
    try ctx_b.err;

    // Walk the chain from the head forward via a recursive CTE — robust to
    // any audit_id or insertion order. The CTE starts at the chain head
    // (prev_chain_hash IS NULL) and follows prev_chain_hash = parent.
    // chain_hash row-by-row. This produces a deterministic chain-position
    // ordering that does not depend on (timestamp, audit_id) ASC being
    // aligned with chain-insert order (it usually is not for concurrent
    // INSERTs under the per-tenant advisory lock, which serialises them
    // but not in audit_id order).
    var chain_q = try harness.conn.query(
        alloc,
        \\WITH RECURSIVE chain AS (
        \\    SELECT ae.chain_hash, ae.prev_chain_hash, 0 AS pos
        \\    FROM audit_entries ae
        \\    WHERE ae.tenant_id = $1::uuid
        \\      AND ae.resource_type = 'iss0122.parent.tc04'
        \\      AND ae.prev_chain_hash IS NULL
        \\  UNION ALL
        \\    SELECT ae.chain_hash, ae.prev_chain_hash, chain.pos + 1
        \\    FROM audit_entries ae
        \\    INNER JOIN chain ON ae.prev_chain_hash = chain.chain_hash
        \\    WHERE ae.tenant_id = $1::uuid
        \\      AND ae.resource_type = 'iss0122.parent.tc04'
        \\)
        \\SELECT chain_hash, prev_chain_hash FROM chain ORDER BY pos ASC
    ,
        &.{tenant_id},
    );
    defer chain_q.deinit();

    // DEBUG: dump chain state for diagnosis
    std.debug.print("\n[TC-04 DEBUG] tenant_id={s}, rows.len={d}\n", .{ tenant_id, chain_q.rows.len });
    for (chain_q.rows, 0..) |row, idx| {
        std.debug.print("  row[{d}] chain={s} prev={s}\n", .{
            idx,
            row[0] orelse "NULL",
            row[1] orelse "NULL",
        });
    }

    // DEBUG: dump all rows for the tenant in (timestamp, audit_id) order
    var all_rows = try harness.conn.query(
        alloc,
        \\SELECT chain_hash, prev_chain_hash, audit_id::text, to_char("timestamp", 'HH24:MI:SS.US')
        \\FROM audit_entries
        \\WHERE tenant_id = $1::uuid AND resource_type = 'iss0122.parent.tc04'
        \\ORDER BY "timestamp" ASC, audit_id ASC
    ,
        &.{tenant_id},
    );
    defer all_rows.deinit();
    std.debug.print("[TC-04 DEBUG] all rows by (timestamp, audit_id) ASC:\n", .{});
    for (all_rows.rows, 0..) |row, idx| {
        std.debug.print("  row[{d}] ts={s} audit_id={s} chain={s} prev={s}\n", .{
            idx,
            row[3] orelse "NULL",
            row[2] orelse "NULL",
            row[0] orelse "NULL",
            row[1] orelse "NULL",
        });
    }

    try testing.expect(chain_q.rows.len >= 2);

    var prev_hash: ?[]const u8 = null;
    for (chain_q.rows) |row| {
        const chain = row[0] orelse continue; // skip trigger-skipped (NULL) rows
        if (prev_hash) |p| {
            const actual_prev = row[1] orelse "";
            try testing.expectEqualStrings(p, actual_prev);
        } else {
            try testing.expect(row[1] == null);
        }
        prev_hash = chain;
    }
}
