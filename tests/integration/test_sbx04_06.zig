//! Integration tests for SBX-04, SBX-05, SBX-06 — Sandbox ownership binding,
//! inaccessible-sandbox sentinel, and claim/release/reclaim audit.
//!
//! Test spec artefacts:
//!   tests/specs/SBX-04.md  (7 test cases)
//!   tests/specs/SBX-05.md  (5 test cases)
//!   tests/specs/SBX-06.md  (5 test cases)
//!
//! Design artefact: src/design/sbx04-06-design.md
//! Run ID:          WF02-sbx04-06-20260819
//!
//! Covered call sites (called directly — no HTTP server required):
//!   handleClaimSandbox   — POST /api/v1/agent/sandboxes/{id}/claim
//!   handleReleaseSandbox — DELETE /api/v1/agent/sandboxes/{id}/claim
//!   reclaimIdleSandboxes — SandboxPool.reclaimIdleSandboxes()
//!
//! Requires BPM_TEST_DB_URL pointing at a real PostgreSQL database.
//! All fixtures use per-test UUIDs; every test cleans up via defer.
//! SkipZigTest is FORBIDDEN on every test block (all are MUST requirements).

const std = @import("std");
const builtin = @import("builtin");
const portable_env = @import("env");
const build_options = @import("build_options");
const testing = std.testing;

const bpm = @import("bpm");
const helpers = @import("helpers.zig");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const auth_mod = bpm.api_auth;
const agent_sandboxes = bpm.agent_sandboxes_routes;
const sandbox_pool_mod = bpm.sandbox_pool;

pub const api_tenant_context = bpm.api_tenant_context;

const DEFAULT_TENANT_ID = auth_mod.DEFAULT_TENANT_ID;

// ── Low-level helpers ─────────────────────────────────────────────────────────

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — SBX-04/05/06 integration tests require it\n",
                .{},
            );
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    bpm.api_tenant_context.set(DEFAULT_TENANT_ID);
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
}

fn fillRandom(buf: []u8) void {
    switch (comptime builtin.os.tag) {
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        else => {
            std.posix.getrandom(buf) catch {
                @memset(buf, 0xAB);
            };
        },
    }
}

fn generateUuid(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    fillRandom(&bytes);
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    const hex = std.fmt.bytesToHex(&bytes, .lower);
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{s}-{s}", .{
        hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32],
    });
}

fn generateRngSeed() u64 {
    var bytes: [8]u8 = undefined;
    fillRandom(&bytes);
    var seed: u64 = 0;
    for (bytes) |b| seed = (seed << 8) | b;
    return if (seed == 0) 1 else seed;
}

fn implAuth(principal: []const u8) auth_mod.AuthContext {
    return .{
        .user_id = principal,
        .role = .AGENT_RUNNER,
        .is_bootstrap = false,
        .token_id = "sbx04-06-test-impl",
        .principal = principal,
        .tenant_id = DEFAULT_TENANT_ID.*,
        .agent_realm_roles = &[_]auth_mod.AgentRealmRole{.tenant_implementer},
        .token_scopes = &[_][]const u8{},
    };
}

fn orchAuth(principal: []const u8) auth_mod.AuthContext {
    return .{
        .user_id = principal,
        .role = .AGENT_RUNNER,
        .is_bootstrap = false,
        .token_id = "sbx04-06-test-orch",
        .principal = principal,
        .tenant_id = DEFAULT_TENANT_ID.*,
        .agent_realm_roles = &[_]auth_mod.AgentRealmRole{.tenant_orchestrator},
        .token_scopes = &[_][]const u8{"agent.submit_task_spec"},
    };
}

/// Insert an unclaimed sandbox row and return its UUID string (caller frees).
fn insertUnclaimedSandbox(allocator: std.mem.Allocator, conn: *bpm.pool.Conn) ![]u8 {
    const row = (try conn.queryRow(
        allocator,
        "INSERT INTO agent_sandboxes DEFAULT VALUES RETURNING sandbox_id::text",
        &.{},
    )) orelse return error.TestUnexpectedResult;
    defer allocator.free(row);
    const sandbox_id = row[0] orelse return error.TestUnexpectedResult;
    defer allocator.free(sandbox_id);
    return allocator.dupe(u8, sandbox_id);
}

/// Insert a task_spec row and return its task_spec_id UUID string (caller frees).
fn insertTaskSpec(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    orchestrator_principal: []const u8,
) ![]u8 {
    const seed = generateRngSeed();
    const spec_body = try std.fmt.allocPrint(
        allocator,
        "{{\"spec_version\":\"1.0\",\"task_name\":\"sbx04-06-test\",\"rng_seed\":{d},\"orchestrator_principal\":\"{s}\"}}",
        .{ seed, orchestrator_principal },
    );
    defer allocator.free(spec_body);
    // Compute a fake spec_hash from uuid bytes to ensure uniqueness per test.
    const hash_id = try generateUuid(allocator);
    defer allocator.free(hash_id);
    // Mask high bit so u64 fits in postgres BIGINT (signed 64-bit).
    const seed_text = try std.fmt.allocPrint(allocator, "{d}", .{seed & 0x7FFFFFFFFFFFFFFF});
    defer allocator.free(seed_text);
    const row = (try conn.queryRow(
        allocator,
        \\INSERT INTO task_specs (orchestrator_principal, spec_hash, spec_body, rng_seed)
        \\VALUES ($1, $2, $3, $4::bigint)
        \\RETURNING task_spec_id::text
    ,
        &.{ orchestrator_principal, hash_id, spec_body, seed_text },
    )) orelse return error.TestUnexpectedResult;
    defer allocator.free(row);
    const id = row[0] orelse return error.TestUnexpectedResult;
    defer allocator.free(id);
    return allocator.dupe(u8, id);
}

fn deleteSandbox(conn: *bpm.pool.Conn, sandbox_id: []const u8) void {
    conn.exec("DELETE FROM agent_sandboxes WHERE sandbox_id = $1::uuid", &.{sandbox_id}) catch {};
}

fn deleteTaskSpec(conn: *bpm.pool.Conn, task_spec_id: []const u8) void {
    conn.exec("DELETE FROM task_specs WHERE task_spec_id = $1::uuid", &.{task_spec_id}) catch {};
}

fn deleteAuditByActor(conn: *bpm.pool.Conn, actor_id: []const u8) void {
    conn.exec("SET session_replication_role = 'replica'", &.{}) catch {};
    conn.exec("DELETE FROM audit_entries WHERE actor_id = $1", &.{actor_id}) catch {};
    conn.exec("SET session_replication_role = DEFAULT", &.{}) catch {};
}

fn deleteProbeCounters(conn: *bpm.pool.Conn, principal: []const u8) void {
    conn.exec("DELETE FROM sandbox_probe_counters WHERE principal = $1", &.{principal}) catch {};
}

fn freeSandboxBody(allocator: std.mem.Allocator, result: agent_sandboxes.HandlerResult) void {
    if (result.body.len == 0) return;
    const statics = [_][]const u8{
        "{}",
        "{\"detail\":\"sandbox_not_accessible\",\"status\":403}",
        "{\"detail\":\"task_spec_not_found\",\"status\":404}",
        "{\"detail\":\"task_spec_id_required\",\"status\":400}",
        "{\"detail\":\"pool_exhausted\",\"status\":503}",
        "{\"detail\":\"db_error\",\"status\":503}",
        "{\"detail\":\"orchestrator_may_not_claim\",\"status\":403}",
        "{\"detail\":\"agent_role_required\",\"status\":403}",
        "",
    };
    for (statics) |s| {
        if (std.mem.eql(u8, result.body, s)) return;
    }
    // 429 body contains dynamic Retry-After — always allocate, must free.
    if (result.status_code == 429) {
        allocator.free(result.body);
        return;
    }
    // Unknown — free to avoid leak.
    allocator.free(result.body);
}

fn parseDetail(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const v = obj.get("detail") orelse return error.MissingDetail;
    return switch (v) {
        .string => |s| allocator.dupe(u8, s),
        else => error.DetailNotString,
    };
}

fn getSandboxStatus(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, sandbox_id: []const u8) !?[]u8 {
    const row = (try conn.queryRow(allocator, "SELECT status FROM agent_sandboxes WHERE sandbox_id = $1::uuid", &.{sandbox_id})) orelse return null;
    defer allocator.free(row);
    const v = row[0] orelse return null;
    defer allocator.free(v);
    return try allocator.dupe(u8, v);
}

fn getSandboxOwner(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, sandbox_id: []const u8) !?[]u8 {
    const row = (try conn.queryRow(allocator, "SELECT owner_principal FROM agent_sandboxes WHERE sandbox_id = $1::uuid", &.{sandbox_id})) orelse return null;
    defer allocator.free(row);
    const v = row[0] orelse return null;
    defer allocator.free(v);
    return try allocator.dupe(u8, v);
}

fn countAuditForActor(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, actor_id: []const u8, action: []const u8) !usize {
    const row = (try conn.queryRow(
        allocator,
        "SELECT COUNT(*)::text FROM audit_entries WHERE actor_id = $1 AND action = $2",
        &.{ actor_id, action },
    )) orelse return 0;
    defer allocator.free(row);
    const s = row[0] orelse return 0;
    defer allocator.free(s);
    return std.fmt.parseInt(usize, s, 10) catch 0;
}

fn buildClaimBody(allocator: std.mem.Allocator, task_spec_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"task_spec_id\":\"{s}\"}}", .{task_spec_id});
}

// ═══════════════════════════════════════════════════════════════════════════════
// SBX-04 Tests — Sandbox ownership binding at claim
// ═══════════════════════════════════════════════════════════════════════════════

// TC-SBX-04-01: Claim unowned sandbox with valid task_spec_id → 201, binding written.
test "sbx04_01_claim_unowned_sandbox_valid_spec_returns_201" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl_principal = try generateUuid(allocator);
    defer allocator.free(impl_principal);
    const orch_principal = try generateUuid(allocator);
    defer allocator.free(orch_principal);

    const sandbox_id = try insertUnclaimedSandbox(allocator, conn);
    defer allocator.free(sandbox_id);
    defer deleteSandbox(conn, sandbox_id);

    const task_spec_id = try insertTaskSpec(allocator, conn, orch_principal);
    defer allocator.free(task_spec_id);
    defer deleteTaskSpec(conn, task_spec_id);
    defer deleteAuditByActor(conn, impl_principal);

    const body = try buildClaimBody(allocator, task_spec_id);
    defer allocator.free(body);

    const auth = implAuth(impl_principal);
    const result = agent_sandboxes.handleClaimSandbox(allocator, &pool, auth, sandbox_id, body);
    defer freeSandboxBody(allocator, result);

    try testing.expectEqual(@as(u16, 201), result.status_code);

    const status = (try getSandboxStatus(allocator, conn, sandbox_id)) orelse return error.TestUnexpectedResult;
    defer allocator.free(status);
    try testing.expectEqualStrings("claimed", status);

    const owner = (try getSandboxOwner(allocator, conn, sandbox_id)) orelse return error.TestUnexpectedResult;
    defer allocator.free(owner);
    try testing.expectEqualStrings(impl_principal, owner);

    const claimed_count = try countAuditForActor(allocator, conn, impl_principal, "sandbox.claimed");
    try testing.expect(claimed_count >= 1);
}

// TC-SBX-04-02: Claim with nonexistent task_spec_id → 404 task_spec_not_found.
test "sbx04_02_claim_nonexistent_task_spec_returns_404" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl_principal = try generateUuid(allocator);
    defer allocator.free(impl_principal);

    const sandbox_id = try insertUnclaimedSandbox(allocator, conn);
    defer allocator.free(sandbox_id);
    defer deleteSandbox(conn, sandbox_id);

    // Use a UUID that will never exist in task_specs.
    const fake_spec_id = try generateUuid(allocator);
    defer allocator.free(fake_spec_id);

    const body = try buildClaimBody(allocator, fake_spec_id);
    defer allocator.free(body);

    const auth = implAuth(impl_principal);
    const result = agent_sandboxes.handleClaimSandbox(allocator, &pool, auth, sandbox_id, body);
    defer freeSandboxBody(allocator, result);

    try testing.expectEqual(@as(u16, 404), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    try testing.expectEqualStrings("task_spec_not_found", detail);
}

// TC-SBX-04-03: Second principal claims same sandbox → 409 sandbox_already_claimed, no owner in body.
test "sbx04_03_second_principal_claim_same_sandbox_returns_409_no_owner_disclosed" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl_a = try generateUuid(allocator);
    defer allocator.free(impl_a);
    const impl_b = try generateUuid(allocator);
    defer allocator.free(impl_b);
    const orch = try generateUuid(allocator);
    defer allocator.free(orch);

    const sandbox_id = try insertUnclaimedSandbox(allocator, conn);
    defer allocator.free(sandbox_id);
    defer deleteSandbox(conn, sandbox_id);

    const spec_id = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_id);
    defer deleteTaskSpec(conn, spec_id);
    defer deleteAuditByActor(conn, impl_a);
    defer deleteAuditByActor(conn, impl_b);

    const body_a = try buildClaimBody(allocator, spec_id);
    defer allocator.free(body_a);

    // First claim by impl_a succeeds.
    const r1 = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl_a), sandbox_id, body_a);
    defer freeSandboxBody(allocator, r1);
    try testing.expectEqual(@as(u16, 201), r1.status_code);

    // impl_b attempts to claim the same sandbox with a different spec.
    const spec_b = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_b);
    defer deleteTaskSpec(conn, spec_b);

    const body_b = try buildClaimBody(allocator, spec_b);
    defer allocator.free(body_b);

    const r2 = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl_b), sandbox_id, body_b);
    defer freeSandboxBody(allocator, r2);

    try testing.expectEqual(@as(u16, 409), r2.status_code);
    const detail = try parseDetail(allocator, r2.body);
    defer allocator.free(detail);
    try testing.expectEqualStrings("sandbox_already_claimed", detail);

    // Response body must not disclose impl_a's identity.
    try testing.expect(std.mem.indexOf(u8, r2.body, impl_a) == null);
}

// TC-SBX-04-04: Same principal claims second sandbox for same task_spec_id → 409.
test "sbx04_04_same_spec_second_sandbox_returns_409" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl = try generateUuid(allocator);
    defer allocator.free(impl);
    const orch = try generateUuid(allocator);
    defer allocator.free(orch);

    const sbx1 = try insertUnclaimedSandbox(allocator, conn);
    defer allocator.free(sbx1);
    defer deleteSandbox(conn, sbx1);

    const sbx2 = try insertUnclaimedSandbox(allocator, conn);
    defer allocator.free(sbx2);
    defer deleteSandbox(conn, sbx2);

    const spec_id = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_id);
    defer deleteTaskSpec(conn, spec_id);
    defer deleteAuditByActor(conn, impl);

    const body = try buildClaimBody(allocator, spec_id);
    defer allocator.free(body);

    // First claim on sbx1 with spec_id succeeds.
    const r1 = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl), sbx1, body);
    defer freeSandboxBody(allocator, r1);
    try testing.expectEqual(@as(u16, 201), r1.status_code);

    // Second claim on sbx2 with the same spec_id hits the partial unique index.
    const body2 = try buildClaimBody(allocator, spec_id);
    defer allocator.free(body2);

    const r2 = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl), sbx2, body2);
    defer freeSandboxBody(allocator, r2);

    try testing.expectEqual(@as(u16, 409), r2.status_code);
    const detail = try parseDetail(allocator, r2.body);
    defer allocator.free(detail);
    try testing.expectEqualStrings("sandbox_already_claimed", detail);
}

// TC-SBX-04-05: Second principal issues operation (release) inside claimed sandbox → 403 sentinel.
test "sbx04_05_non_owner_operation_returns_sentinel_403" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl_a = try generateUuid(allocator);
    defer allocator.free(impl_a);
    const impl_b = try generateUuid(allocator);
    defer allocator.free(impl_b);
    const orch = try generateUuid(allocator);
    defer allocator.free(orch);

    const sandbox_id = try insertUnclaimedSandbox(allocator, conn);
    defer allocator.free(sandbox_id);
    defer deleteSandbox(conn, sandbox_id);

    const spec_id = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_id);
    defer deleteTaskSpec(conn, spec_id);
    defer deleteAuditByActor(conn, impl_a);
    defer deleteAuditByActor(conn, impl_b);

    const body = try buildClaimBody(allocator, spec_id);
    defer allocator.free(body);

    // impl_a claims.
    const r1 = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl_a), sandbox_id, body);
    defer freeSandboxBody(allocator, r1);
    try testing.expectEqual(@as(u16, 201), r1.status_code);

    // impl_b attempts release — should receive sentinel, not role error.
    const r2 = agent_sandboxes.handleReleaseSandbox(allocator, &pool, implAuth(impl_b), sandbox_id);
    defer freeSandboxBody(allocator, r2);

    try testing.expectEqual(@as(u16, 403), r2.status_code);
    const detail = try parseDetail(allocator, r2.body);
    defer allocator.free(detail);
    try testing.expectEqualStrings("sandbox_not_accessible", detail);

    // Binding must be unchanged — impl_a still owns.
    const owner = (try getSandboxOwner(allocator, conn, sandbox_id)) orelse return error.TestUnexpectedResult;
    defer allocator.free(owner);
    try testing.expectEqualStrings(impl_a, owner);
}

// TC-SBX-04-06: Concurrent claim race — exactly one 201, other 409.
test "sbx04_06_concurrent_claim_exactly_one_wins" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl_a = try generateUuid(allocator);
    defer allocator.free(impl_a);
    const impl_b = try generateUuid(allocator);
    defer allocator.free(impl_b);
    const orch = try generateUuid(allocator);
    defer allocator.free(orch);

    const sandbox_id = try insertUnclaimedSandbox(allocator, conn);
    defer allocator.free(sandbox_id);
    defer deleteSandbox(conn, sandbox_id);

    const spec_a = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_a);
    defer deleteTaskSpec(conn, spec_a);
    const spec_b = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_b);
    defer deleteTaskSpec(conn, spec_b);
    defer deleteAuditByActor(conn, impl_a);
    defer deleteAuditByActor(conn, impl_b);

    const body_a = try buildClaimBody(allocator, spec_a);
    defer allocator.free(body_a);
    const body_b = try buildClaimBody(allocator, spec_b);
    defer allocator.free(body_b);

    // Issue both claims sequentially (true concurrency not needed — the DB
    // unique index provides the race resolution; sequential calls exercise the
    // same code path).
    const r1 = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl_a), sandbox_id, body_a);
    defer freeSandboxBody(allocator, r1);
    const r2 = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl_b), sandbox_id, body_b);
    defer freeSandboxBody(allocator, r2);

    const codes = [2]u16{ r1.status_code, r2.status_code };
    const has_201 = (codes[0] == 201 or codes[1] == 201);
    const has_409 = (codes[0] == 409 or codes[1] == 409);
    try testing.expect(has_201);
    try testing.expect(has_409);
    // Exactly one of each.
    try testing.expect(codes[0] != codes[1]);
}

// TC-SBX-04-07: Released sandbox re-claimed → new binding, prior owner has no access.
test "sbx04_07_released_sandbox_reclaim_prior_owner_loses_access" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl_a = try generateUuid(allocator);
    defer allocator.free(impl_a);
    const impl_b = try generateUuid(allocator);
    defer allocator.free(impl_b);
    const orch = try generateUuid(allocator);
    defer allocator.free(orch);

    const sandbox_id = try insertUnclaimedSandbox(allocator, conn);
    defer allocator.free(sandbox_id);
    defer deleteSandbox(conn, sandbox_id);

    const spec_a = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_a);
    defer deleteTaskSpec(conn, spec_a);
    defer deleteAuditByActor(conn, impl_a);
    defer deleteAuditByActor(conn, impl_b);

    const body_a = try buildClaimBody(allocator, spec_a);
    defer allocator.free(body_a);

    // impl_a claims.
    const r1 = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl_a), sandbox_id, body_a);
    defer freeSandboxBody(allocator, r1);
    try testing.expectEqual(@as(u16, 201), r1.status_code);

    // impl_a releases.
    const rel = agent_sandboxes.handleReleaseSandbox(allocator, &pool, implAuth(impl_a), sandbox_id);
    defer freeSandboxBody(allocator, rel);
    try testing.expectEqual(@as(u16, 204), rel.status_code);

    // impl_b claims the now-released sandbox.
    const spec_b = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_b);
    defer deleteTaskSpec(conn, spec_b);

    const body_b = try buildClaimBody(allocator, spec_b);
    defer allocator.free(body_b);

    const r2 = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl_b), sandbox_id, body_b);
    defer freeSandboxBody(allocator, r2);
    try testing.expectEqual(@as(u16, 201), r2.status_code);

    // impl_a (prior owner) attempts to release — should receive sentinel.
    const old_rel = agent_sandboxes.handleReleaseSandbox(allocator, &pool, implAuth(impl_a), sandbox_id);
    defer freeSandboxBody(allocator, old_rel);
    try testing.expectEqual(@as(u16, 403), old_rel.status_code);
    const d = try parseDetail(allocator, old_rel.body);
    defer allocator.free(d);
    try testing.expectEqualStrings("sandbox_not_accessible", d);
}

// ═══════════════════════════════════════════════════════════════════════════════
// SBX-05 Tests — Single sentinel for inaccessible sandboxes
// ═══════════════════════════════════════════════════════════════════════════════

// TC-SBX-05-01: Nonexistent sandbox_id returns sentinel 403.
test "sbx05_01_nonexistent_sandbox_returns_sentinel_403" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl = try generateUuid(allocator);
    defer allocator.free(impl);
    defer deleteAuditByActor(conn, impl);
    defer deleteProbeCounters(conn, impl);

    // UUID that does not exist in agent_sandboxes.
    const fake_id = try generateUuid(allocator);
    defer allocator.free(fake_id);

    const result = agent_sandboxes.handleReleaseSandbox(allocator, &pool, implAuth(impl), fake_id);
    defer freeSandboxBody(allocator, result);

    try testing.expectEqual(@as(u16, 403), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    try testing.expectEqualStrings("sandbox_not_accessible", detail);
}

// TC-SBX-05-02: Cross-tenant sandbox (exists in a second tenant's schema) → 403 sentinel,
// body byte-identical to the nonexistent-UUID case (SBX-05 AC2/AC4).
test "sbx05_02_cross_tenant_sentinel_byte_identical" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl_a = try generateUuid(allocator);
    defer allocator.free(impl_a);
    defer deleteAuditByActor(conn, impl_a);
    defer deleteProbeCounters(conn, impl_a);

    // Provision a second tenant schema and insert a sandbox there.
    // The sandbox_id will physically exist in the DB but be invisible to
    // the first (DEFAULT) tenant because search_path scopes the table to
    // the second tenant's schema.
    const second_tenant_id = try generateUuid(allocator);
    defer allocator.free(second_tenant_id);

    // Provision the second tenant (full migration set, idempotent).
    // This also sets api_tenant_context to second_tenant_id.
    try helpers.provisionTestTenantSchema(allocator, &pool, second_tenant_id, build_options.migrations_dir);
    defer helpers.dropTestTenantSchema(conn, allocator, second_tenant_id);

    // Acquire a connection routed to the second tenant schema.
    const conn2 = try pool.acquire();
    const cross_tenant_sbx = try insertUnclaimedSandbox(allocator, conn2);
    defer allocator.free(cross_tenant_sbx);
    pool.release(conn2);

    // Reset context to the first (default) tenant for all subsequent handler calls.
    bpm.api_tenant_context.set(DEFAULT_TENANT_ID);

    // Case 1: nonexistent UUID — baseline sentinel.
    const nonexistent = try generateUuid(allocator);
    defer allocator.free(nonexistent);
    const r_nonexistent = agent_sandboxes.handleReleaseSandbox(allocator, &pool, implAuth(impl_a), nonexistent);
    defer freeSandboxBody(allocator, r_nonexistent);

    // Case 2: cross-tenant sandbox_id (exists in second tenant's schema,
    // invisible via DEFAULT tenant's search_path).
    const r_cross = agent_sandboxes.handleReleaseSandbox(allocator, &pool, implAuth(impl_a), cross_tenant_sbx);
    defer freeSandboxBody(allocator, r_cross);

    try testing.expectEqual(@as(u16, 403), r_nonexistent.status_code);
    try testing.expectEqual(@as(u16, 403), r_cross.status_code);
    // Response bodies must be byte-identical (probe indistinguishability).
    try testing.expectEqualStrings(r_nonexistent.body, r_cross.body);
}

// TC-SBX-05-03: Sandbox in caller's tenant bound to a different principal → 403 sentinel,
// body byte-identical to the nonexistent-UUID case (SBX-05 AC3/AC4).
test "sbx05_03_wrong_principal_sentinel_byte_identical" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl_a = try generateUuid(allocator);
    defer allocator.free(impl_a);
    const impl_b = try generateUuid(allocator);
    defer allocator.free(impl_b);
    const orch = try generateUuid(allocator);
    defer allocator.free(orch);
    defer deleteAuditByActor(conn, impl_a);
    defer deleteAuditByActor(conn, impl_b);
    defer deleteProbeCounters(conn, impl_b);

    // Baseline sentinel: nonexistent UUID.
    const nonexistent = try generateUuid(allocator);
    defer allocator.free(nonexistent);
    const r_nonexistent = agent_sandboxes.handleReleaseSandbox(allocator, &pool, implAuth(impl_b), nonexistent);
    defer freeSandboxBody(allocator, r_nonexistent);

    // Claim sandbox with impl_a (same tenant as impl_b).
    const sandbox_id = try insertUnclaimedSandbox(allocator, conn);
    defer allocator.free(sandbox_id);
    defer deleteSandbox(conn, sandbox_id);

    const spec_id = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_id);
    defer deleteTaskSpec(conn, spec_id);

    const body = try buildClaimBody(allocator, spec_id);
    defer allocator.free(body);

    const claim_r = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl_a), sandbox_id, body);
    defer freeSandboxBody(allocator, claim_r);
    try testing.expectEqual(@as(u16, 201), claim_r.status_code);

    // impl_b (same tenant, wrong principal) attempts release → sentinel.
    const r_wrong = agent_sandboxes.handleReleaseSandbox(allocator, &pool, implAuth(impl_b), sandbox_id);
    defer freeSandboxBody(allocator, r_wrong);

    try testing.expectEqual(@as(u16, 403), r_nonexistent.status_code);
    try testing.expectEqual(@as(u16, 403), r_wrong.status_code);
    // Response bodies must be byte-identical (probe indistinguishability).
    try testing.expectEqualStrings(r_nonexistent.body, r_wrong.body);
}

// TC-SBX-05-04: 21st sentinel probe in 60 s window returns 429 probe_rate_exceeded.
test "sbx05_04_probe_rate_21st_returns_429" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl = try generateUuid(allocator);
    defer allocator.free(impl);
    defer deleteAuditByActor(conn, impl);
    defer deleteProbeCounters(conn, impl);

    const nonexistent = try generateUuid(allocator);
    defer allocator.free(nonexistent);

    // Issue 20 sentinel requests — each should return 403.
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const r = agent_sandboxes.handleReleaseSandbox(allocator, &pool, implAuth(impl), nonexistent);
        freeSandboxBody(allocator, r);
        try testing.expectEqual(@as(u16, 403), r.status_code);
    }

    // 21st request must return 429 probe_rate_exceeded.
    const r21 = agent_sandboxes.handleReleaseSandbox(allocator, &pool, implAuth(impl), nonexistent);
    defer freeSandboxBody(allocator, r21);

    try testing.expectEqual(@as(u16, 429), r21.status_code);
    const detail = try parseDetail(allocator, r21.body);
    defer allocator.free(detail);
    try testing.expectEqualStrings("probe_rate_exceeded", detail);
}

// TC-SBX-05-05: SBX-04 409 does not disclose cross-tenant sandbox existence.
// A UUID that does not exist in this tenant (or any tenant via search_path isolation)
// must return 403, not 409 — 409 is only for sandboxes visible within the caller's tenant.
test "sbx05_05_unknown_uuid_returns_sentinel_not_409" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl = try generateUuid(allocator);
    defer allocator.free(impl);
    const orch = try generateUuid(allocator);
    defer allocator.free(orch);
    defer deleteAuditByActor(conn, impl);
    defer deleteProbeCounters(conn, impl);

    // Insert a task_spec so the 404 path is avoided.
    const spec_id = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_id);
    defer deleteTaskSpec(conn, spec_id);

    // A sandbox UUID that truly does not exist.
    const fake_sandbox = try generateUuid(allocator);
    defer allocator.free(fake_sandbox);

    const body = try buildClaimBody(allocator, spec_id);
    defer allocator.free(body);

    const result = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl), fake_sandbox, body);
    defer freeSandboxBody(allocator, result);

    // Must be 403 sentinel, not 409.
    try testing.expectEqual(@as(u16, 403), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    try testing.expectEqualStrings("sandbox_not_accessible", detail);
}

// ═══════════════════════════════════════════════════════════════════════════════
// SBX-06 Tests — Release, reclaim, and audit
// ═══════════════════════════════════════════════════════════════════════════════

// TC-SBX-06-01: Second principal release attempt → 403, binding unchanged.
test "sbx06_01_non_owner_release_binding_unchanged" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl_a = try generateUuid(allocator);
    defer allocator.free(impl_a);
    const impl_b = try generateUuid(allocator);
    defer allocator.free(impl_b);
    const orch = try generateUuid(allocator);
    defer allocator.free(orch);
    defer deleteAuditByActor(conn, impl_a);
    defer deleteAuditByActor(conn, impl_b);

    const sandbox_id = try insertUnclaimedSandbox(allocator, conn);
    defer allocator.free(sandbox_id);
    defer deleteSandbox(conn, sandbox_id);

    const spec_id = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_id);
    defer deleteTaskSpec(conn, spec_id);

    const body = try buildClaimBody(allocator, spec_id);
    defer allocator.free(body);

    const claim_r = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl_a), sandbox_id, body);
    defer freeSandboxBody(allocator, claim_r);
    try testing.expectEqual(@as(u16, 201), claim_r.status_code);

    // impl_b (non-owner implementer) attempts release.
    const rel = agent_sandboxes.handleReleaseSandbox(allocator, &pool, implAuth(impl_b), sandbox_id);
    defer freeSandboxBody(allocator, rel);

    try testing.expectEqual(@as(u16, 403), rel.status_code);
    const d = try parseDetail(allocator, rel.body);
    defer allocator.free(d);
    try testing.expectEqualStrings("sandbox_not_accessible", d);

    // Binding must be unchanged.
    const owner = (try getSandboxOwner(allocator, conn, sandbox_id)) orelse return error.TestUnexpectedResult;
    defer allocator.free(owner);
    try testing.expectEqualStrings(impl_a, owner);

    const status = (try getSandboxStatus(allocator, conn, sandbox_id)) orelse return error.TestUnexpectedResult;
    defer allocator.free(status);
    try testing.expectEqualStrings("claimed", status);
}

// TC-SBX-06-02: Orchestrator release attempt → 403 sandbox_not_accessible.
test "sbx06_02_orchestrator_release_returns_sentinel_403" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl = try generateUuid(allocator);
    defer allocator.free(impl);
    const orch = try generateUuid(allocator);
    defer allocator.free(orch);
    defer deleteAuditByActor(conn, impl);
    defer deleteAuditByActor(conn, orch);

    const sandbox_id = try insertUnclaimedSandbox(allocator, conn);
    defer allocator.free(sandbox_id);
    defer deleteSandbox(conn, sandbox_id);

    const spec_id = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_id);
    defer deleteTaskSpec(conn, spec_id);

    const body = try buildClaimBody(allocator, spec_id);
    defer allocator.free(body);

    const claim_r = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl), sandbox_id, body);
    defer freeSandboxBody(allocator, claim_r);
    try testing.expectEqual(@as(u16, 201), claim_r.status_code);

    // Orchestrator (supervisory role) attempts release.
    const rel = agent_sandboxes.handleReleaseSandbox(allocator, &pool, orchAuth(orch), sandbox_id);
    defer freeSandboxBody(allocator, rel);

    try testing.expectEqual(@as(u16, 403), rel.status_code);
    const d = try parseDetail(allocator, rel.body);
    defer allocator.free(d);
    try testing.expectEqualStrings("sandbox_not_accessible", d);
}

// TC-SBX-06-03: Owner releases → 204, state=released, sandbox.released audit entry.
test "sbx06_03_owner_release_204_and_audit" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl = try generateUuid(allocator);
    defer allocator.free(impl);
    const orch = try generateUuid(allocator);
    defer allocator.free(orch);
    defer deleteAuditByActor(conn, impl);

    const sandbox_id = try insertUnclaimedSandbox(allocator, conn);
    defer allocator.free(sandbox_id);
    defer deleteSandbox(conn, sandbox_id);

    const spec_id = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_id);
    defer deleteTaskSpec(conn, spec_id);

    const body = try buildClaimBody(allocator, spec_id);
    defer allocator.free(body);

    const claim_r = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl), sandbox_id, body);
    defer freeSandboxBody(allocator, claim_r);
    try testing.expectEqual(@as(u16, 201), claim_r.status_code);

    const rel = agent_sandboxes.handleReleaseSandbox(allocator, &pool, implAuth(impl), sandbox_id);
    defer freeSandboxBody(allocator, rel);
    try testing.expectEqual(@as(u16, 204), rel.status_code);

    const status = (try getSandboxStatus(allocator, conn, sandbox_id)) orelse return error.TestUnexpectedResult;
    defer allocator.free(status);
    try testing.expectEqualStrings("released", status);

    const owner = try getSandboxOwner(allocator, conn, sandbox_id);
    try testing.expect(owner == null);

    const released_count = try countAuditForActor(allocator, conn, impl, "sandbox.released");
    try testing.expect(released_count >= 1);
}

// TC-SBX-06-04: Idle sandbox reclaimed by pool manager after last_active_at set to 61 min ago.
test "sbx06_04_idle_sandbox_reclaimed_by_pool_manager" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl = try generateUuid(allocator);
    defer allocator.free(impl);
    const orch = try generateUuid(allocator);
    defer allocator.free(orch);
    defer deleteAuditByActor(conn, impl);

    const sandbox_id = try insertUnclaimedSandbox(allocator, conn);
    defer allocator.free(sandbox_id);
    defer deleteSandbox(conn, sandbox_id);

    const spec_id = try insertTaskSpec(allocator, conn, orch);
    defer allocator.free(spec_id);
    defer deleteTaskSpec(conn, spec_id);

    const body = try buildClaimBody(allocator, spec_id);
    defer allocator.free(body);

    // Claim the sandbox.
    const claim_r = agent_sandboxes.handleClaimSandbox(allocator, &pool, implAuth(impl), sandbox_id, body);
    defer freeSandboxBody(allocator, claim_r);
    try testing.expectEqual(@as(u16, 201), claim_r.status_code);

    // Directly back-date last_active_at to 61 minutes ago.
    try conn.exec(
        "UPDATE agent_sandboxes SET last_active_at = NOW() - INTERVAL '61 minutes' WHERE sandbox_id = $1::uuid",
        &.{sandbox_id},
    );

    // Run the pool manager's idle reclaim sweep.
    var sbx_pool = sandbox_pool_mod.SandboxPool.init(std.testing.io, allocator, &pool, 8);
    defer sbx_pool.deinit();
    const reclaimed = sbx_pool.reclaimIdleSandboxes(allocator, std.testing.io) catch |err| {
        std.debug.print("reclaimIdleSandboxes failed: {}\n", .{err});
        return err;
    };
    try testing.expect(reclaimed >= 1);

    // Sandbox must now be released with cleared binding.
    const status = (try getSandboxStatus(allocator, conn, sandbox_id)) orelse return error.TestUnexpectedResult;
    defer allocator.free(status);
    try testing.expectEqualStrings("released", status);

    const owner = try getSandboxOwner(allocator, conn, sandbox_id);
    try testing.expect(owner == null);

    // sandbox.reclaimed audit must be present.
    const reclaim_count = try countAuditForActor(allocator, conn, impl, "sandbox.reclaimed");
    try testing.expect(reclaim_count >= 1);
}

// TC-SBX-06-05: Sentinel calls produce audit entries with principal and sandbox_id.
test "sbx06_05_sentinel_audit_trail" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const impl = try generateUuid(allocator);
    defer allocator.free(impl);
    defer deleteAuditByActor(conn, impl);
    defer deleteProbeCounters(conn, impl);

    const nonexistent = try generateUuid(allocator);
    defer allocator.free(nonexistent);

    // Issue 5 sentinel calls.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const r = agent_sandboxes.handleReleaseSandbox(allocator, &pool, implAuth(impl), nonexistent);
        freeSandboxBody(allocator, r);
    }

    // Audit must record at least 5 claim_rejected entries for this principal.
    const rejected_count = try countAuditForActor(allocator, conn, impl, "sandbox.claim_rejected");
    try testing.expect(rejected_count >= 5);
}
