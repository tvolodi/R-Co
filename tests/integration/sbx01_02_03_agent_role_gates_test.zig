//! Integration tests for SBX-01, SBX-02, SBX-03 — Agent role gates.
//!
//! Test spec artefact: tests/specs/SBX-01-03.md
//! Design artefact:    src/design/WF02-qry05-sbx01-03-20260818.md
//! Run ID:             WF02-qry05-sbx01-03-20260818
//!
//! Covered endpoints (called directly):
//!   handleSubmitTaskSpec  — POST /api/v1/agent/task-specs
//!   handleListSandboxes   — GET  /api/v1/agent/sandboxes
//!   handleClaimSandbox    — POST /api/v1/agent/sandboxes/{sandbox_id}/claim
//!
//! Requires BPM_TEST_DB_URL pointing at a real PostgreSQL database.
//! All fixtures use per-test UUIDs. Every test cleans up via defer.

const std = @import("std");
const builtin = @import("builtin");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const helpers = @import("helpers.zig");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const auth_mod = bpm.api_auth;
const agent_task_specs = bpm.agent_task_specs_routes;
const agent_sandboxes = bpm.agent_sandboxes_routes;

pub const api_tenant_context = bpm.api_tenant_context;

const DEFAULT_TENANT_ID = auth_mod.DEFAULT_TENANT_ID;

// ── Utilities ─────────────────────────────────────────────────────────────────

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — SBX-01/02/03 integration tests require it\n",
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

fn generateTestUserId(allocator: std.mem.Allocator) ![]u8 {
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
    for (bytes) |b| {
        seed = (seed << 8) | b;
    }
    // Ensure non-zero
    return if (seed == 0) 1 else seed;
}

/// Build an orchestrator AuthContext (has both scope and role for task-spec submission).
fn orchAuth(user_id: []const u8) auth_mod.AuthContext {
    return .{
        .user_id = user_id,
        .role = .AGENT_RUNNER,
        .is_bootstrap = false,
        .token_id = "sbx-test-orch",
        .principal = user_id,
        .tenant_id = DEFAULT_TENANT_ID.*,
        .agent_realm_roles = &[_]auth_mod.AgentRealmRole{.tenant_orchestrator},
        .token_scopes = &[_][]const u8{"agent.submit_task_spec"},
    };
}

/// Build an implementer AuthContext (has implementer role, no scope).
fn implAuth(user_id: []const u8) auth_mod.AuthContext {
    return .{
        .user_id = user_id,
        .role = .AGENT_RUNNER,
        .is_bootstrap = false,
        .token_id = "sbx-test-impl",
        .principal = user_id,
        .tenant_id = DEFAULT_TENANT_ID.*,
        .agent_realm_roles = &[_]auth_mod.AgentRealmRole{.tenant_implementer},
        .token_scopes = &[_][]const u8{},
    };
}

/// Build an AuthContext with scope but NO orchestrator role (SBX-01-AC1 scenario).
fn scopeOnlyAuth(user_id: []const u8) auth_mod.AuthContext {
    return .{
        .user_id = user_id,
        .role = .AGENT_RUNNER,
        .is_bootstrap = false,
        .token_id = "sbx-test-scope-only",
        .principal = user_id,
        .tenant_id = DEFAULT_TENANT_ID.*,
        .agent_realm_roles = &[_]auth_mod.AgentRealmRole{},
        .token_scopes = &[_][]const u8{"agent.submit_task_spec"},
    };
}

/// Build an AuthContext with orchestrator role but NO scope (SBX-01-AC2 scenario).
fn roleOnlyAuth(user_id: []const u8) auth_mod.AuthContext {
    return .{
        .user_id = user_id,
        .role = .AGENT_RUNNER,
        .is_bootstrap = false,
        .token_id = "sbx-test-role-only",
        .principal = user_id,
        .tenant_id = DEFAULT_TENANT_ID.*,
        .agent_realm_roles = &[_]auth_mod.AgentRealmRole{.tenant_orchestrator},
        .token_scopes = &[_][]const u8{},
    };
}

/// Build an AuthContext with no agent realm roles at all.
fn noAgentRoleAuth(user_id: []const u8) auth_mod.AuthContext {
    return .{
        .user_id = user_id,
        .role = .TASK_WORKER,
        .is_bootstrap = false,
        .token_id = "sbx-test-no-role",
        .principal = user_id,
        .tenant_id = DEFAULT_TENANT_ID.*,
        .agent_realm_roles = &[_]auth_mod.AgentRealmRole{},
        .token_scopes = &[_][]const u8{},
    };
}

/// Build an AuthContext carrying BOTH agent realm roles (conflict scenario — SEC-MINOR-01).
fn conflictingRolesAuth(user_id: []const u8) auth_mod.AuthContext {
    return .{
        .user_id = user_id,
        .role = .AGENT_RUNNER,
        .is_bootstrap = false,
        .token_id = "sbx-test-conflict",
        .principal = user_id,
        .tenant_id = DEFAULT_TENANT_ID.*,
        .agent_realm_roles = &[_]auth_mod.AgentRealmRole{ .tenant_orchestrator, .tenant_implementer },
        .token_scopes = &[_][]const u8{"agent.submit_task_spec"},
    };
}

fn freeBody(allocator: std.mem.Allocator, result: agent_task_specs.HandlerResult) void {
    if (result.body.len == 0) return;
    const static_bodies = [_][]const u8{
        "{\"detail\":\"forbidden\",\"status\":403}",
        "{\"detail\":\"bad_request\",\"status\":400}",
        "{\"detail\":\"conflict\",\"status\":409}",
        "{}",
    };
    for (static_bodies) |sb| {
        if (std.mem.eql(u8, result.body, sb)) return;
    }
    allocator.free(result.body);
}

fn freeSandboxBody(allocator: std.mem.Allocator, result: agent_sandboxes.HandlerResult) void {
    if (result.body.len == 0) return;
    const static_bodies = [_][]const u8{
        "{\"detail\":\"forbidden\",\"status\":403}",
        "{\"detail\":\"conflict\",\"status\":409}",
        "{}",
    };
    for (static_bodies) |sb| {
        if (std.mem.eql(u8, result.body, sb)) return;
    }
    allocator.free(result.body);
}

fn parseDetail(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const detail_val = obj.get("detail") orelse return error.MissingDetail;
    return switch (detail_val) {
        .string => |s| allocator.dupe(u8, s),
        else => error.DetailNotString,
    };
}

fn parseStringField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const val = obj.get(field) orelse return error.MissingField;
    return switch (val) {
        .string => |s| allocator.dupe(u8, s),
        else => error.NotString,
    };
}

fn parseItemCount(allocator: std.mem.Allocator, body: []const u8) !usize {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const items_val = obj.get("items") orelse return error.MissingItems;
    return switch (items_val) {
        .array => |a| a.items.len,
        else => error.ItemsNotArray,
    };
}

/// Build a minimal valid task spec body with a random rng_seed.
fn buildSpecBody(allocator: std.mem.Allocator, rng_seed: u64) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"spec_version\":\"1.0\",\"task_name\":\"sbx-test\",\"rng_seed\":{d}}}",
        .{rng_seed},
    );
}

/// Insert an unclaimed sandbox row for the given tenant and return its UUID text.
fn insertUnclamedSandbox(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    tenant_id: []const u8,
) ![]u8 {
    _ = tenant_id;
    const row = (try conn.queryRow(
        allocator,
        "INSERT INTO agent_sandboxes DEFAULT VALUES RETURNING sandbox_id::text",
        &.{},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    const sandbox_id = row[0] orelse return error.TestUnexpectedResult;
    return allocator.dupe(u8, sandbox_id);
}

fn cleanupSandbox(conn: *bpm.pool.Conn, sandbox_id: []const u8) void {
    conn.exec(
        "DELETE FROM agent_sandboxes WHERE sandbox_id = $1::uuid",
        &.{sandbox_id},
    ) catch {};
}

fn cleanupTaskSpec(conn: *bpm.pool.Conn, spec_hash: []const u8) void {
    conn.exec(
        "DELETE FROM task_specs WHERE spec_hash = $1",
        &.{spec_hash},
    ) catch {};
}

fn cleanupTaskSpecByUser(conn: *bpm.pool.Conn, user_id: []const u8) void {
    conn.exec(
        "DELETE FROM task_specs WHERE orchestrator_principal = $1",
        &.{user_id},
    ) catch {};
}

fn cleanupAuditByActor(conn: *bpm.pool.Conn, actor_id: []const u8) void {
    conn.exec(
        "DELETE FROM audit_entries WHERE actor_id = $1::uuid",
        &.{actor_id},
    ) catch {};
}

/// Query audit_entries for a given actor and event_name; returns the row count.
fn countAuditEvents(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    actor_id: []const u8,
    event_name: []const u8,
) !usize {
    const row = (try conn.queryRow(
        allocator,
        "SELECT COUNT(*)::text FROM audit_entries WHERE actor_id = $1::uuid AND event_name = $2",
        &.{ actor_id, event_name },
    )) orelse return 0;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    const count_str = row[0] orelse "0";
    return std.fmt.parseInt(usize, count_str, 10) catch 0;
}

/// Returns the orchestrator_principal stored in task_specs for the given task_spec_id.
fn getStoredPrincipal(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    task_spec_id: []const u8,
) !?[]u8 {
    const row = (try conn.queryRow(
        allocator,
        "SELECT orchestrator_principal FROM task_specs WHERE task_spec_id = $1::uuid",
        &.{task_spec_id},
    )) orelse return null;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    const principal = row[0] orelse return null;
    return try allocator.dupe(u8, principal);
}

/// Returns the owner_principal stored in agent_sandboxes for the given sandbox_id.
fn getSandboxOwner(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    sandbox_id: []const u8,
) !?[]u8 {
    const row = (try conn.queryRow(
        allocator,
        "SELECT owner_principal FROM agent_sandboxes WHERE sandbox_id = $1::uuid",
        &.{sandbox_id},
    )) orelse return null;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    const owner = row[0] orelse return null;
    return try allocator.dupe(u8, owner);
}

/// Returns the sandbox status string.
fn getSandboxStatus(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    sandbox_id: []const u8,
) !?[]u8 {
    const row = (try conn.queryRow(
        allocator,
        "SELECT status FROM agent_sandboxes WHERE sandbox_id = $1::uuid",
        &.{sandbox_id},
    )) orelse return null;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    const status = row[0] orelse return null;
    return try allocator.dupe(u8, status);
}

// ── TC-SBX-01-01: Scope only → HTTP 403 orchestrator_role_required ───────────

test "sbx01_01_scope_only_no_role_returns_403" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);
    defer cleanupAuditByActor(pool.acquire() catch unreachable, user_id);

    const body = try buildSpecBody(allocator, generateRngSeed());
    defer allocator.free(body);

    const auth = scopeOnlyAuth(user_id);
    const result = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth, body);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 403), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    try testing.expect(std.mem.eql(u8, detail, "orchestrator_role_required"));
}

// ── TC-SBX-01-02: Role only → HTTP 403 orchestrator_role_required ────────────

test "sbx01_02_role_only_no_scope_returns_403" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupAuditByActor(conn, user_id);

    const body = try buildSpecBody(allocator, generateRngSeed());
    defer allocator.free(body);

    const auth = roleOnlyAuth(user_id);
    const result = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth, body);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 403), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    try testing.expect(std.mem.eql(u8, detail, "orchestrator_role_required"));
}

// ── TC-SBX-01-03: Both credentials → task spec accepted and persisted ─────────

test "sbx01_03_both_credentials_task_spec_accepted" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_id);
    defer cleanupAuditByActor(conn, user_id);

    const body = try buildSpecBody(allocator, generateRngSeed());
    defer allocator.free(body);

    const auth = orchAuth(user_id);
    const result = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth, body);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 201), result.status_code);

    const task_spec_id = try parseStringField(allocator, result.body, "task_spec_id");
    defer allocator.free(task_spec_id);
    try testing.expect(task_spec_id.len > 0);

    const spec_hash = try parseStringField(allocator, result.body, "spec_hash");
    defer allocator.free(spec_hash);
    try testing.expectEqual(@as(usize, 64), spec_hash.len);

    // Verify row exists in task_specs
    const stored = try getStoredPrincipal(allocator, conn, task_spec_id);
    try testing.expect(stored != null);
    if (stored) |p| {
        defer allocator.free(p);
        try testing.expect(std.mem.eql(u8, p, user_id));
    }
}

// ── TC-SBX-01-04: Both agent roles — conflicting_agent_roles absent from audit ─
// SEC-MINOR-01 known-gap documentation test.
// In production, authenticate() rejects tokens with both roles before
// reaching any handler. This test documents that requireOrchestratorSubmit
// (the handler gate) does not produce a conflicting_agent_roles audit entry
// because it is never invoked in that path; the handler itself would succeed
// when called directly with both roles and a valid scope.

test "sbx01_04_conflicting_roles_no_conflicting_audit_known_gap_sec_minor_01" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_id);
    defer cleanupAuditByActor(conn, user_id);

    const body = try buildSpecBody(allocator, generateRngSeed());
    defer allocator.free(body);

    // This auth context would be rejected by authenticate() in production.
    // Called directly here to document the known gap: the handler itself
    // does not emit a conflicting_agent_roles audit entry.
    const auth = conflictingRolesAuth(user_id);
    const result = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth, body);
    defer freeBody(allocator, result);

    // The handler's own gate (requireOrchestratorSubmit) passes because
    // orchestrator role + scope are present — it does not check for conflict.
    // This documents that the conflicting_agent_roles rejection and its
    // absence from audit must be tested in the auth middleware test suite.
    try testing.expect(result.status_code == 201 or result.status_code == 409);

    // Verify no audit entry for "conflicting_agent_roles" was produced by
    // the handler path (the middleware path never reaches this code).
    const conflict_audit_count = try countAuditEvents(
        allocator,
        conn,
        user_id,
        "task_spec.conflicting_agent_roles",
    );
    try testing.expectEqual(@as(usize, 0), conflict_audit_count);
}

// ── TC-SBX-01-05: Rejected submission writes TaskSpecSubmissionRejected ───────

test "sbx01_05_rejected_submission_writes_rejection_audit" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupAuditByActor(conn, user_id);

    const body = try buildSpecBody(allocator, generateRngSeed());
    defer allocator.free(body);

    // Scope only — gate rejects and must write audit
    const auth = scopeOnlyAuth(user_id);
    const result = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth, body);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 403), result.status_code);

    const audit_count = try countAuditEvents(
        allocator,
        conn,
        user_id,
        "task_spec.submission_rejected",
    );
    try testing.expect(audit_count >= 1);
}

// ── TC-SBX-01-06: Implementer token (wrong role, no scope) → HTTP 403 ────────
// SBX-01 AC4: tenant_implementer role is not tenant_orchestrator; gate rejects.

test "sbx01_06_implementer_role_no_scope_returns_403" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupAuditByActor(conn, user_id);

    const body = try buildSpecBody(allocator, generateRngSeed());
    defer allocator.free(body);

    // Implementer has tenant_implementer role and no agent.submit_task_spec scope.
    const auth = implAuth(user_id);
    const result = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth, body);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 403), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    try testing.expect(std.mem.eql(u8, detail, "orchestrator_role_required"));
}

// ── TC-SBX-02-01: No orchestrator_principal in body → server sets token subject

test "sbx02_01_no_principal_in_body_server_sets_token_subject" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_id);
    defer cleanupAuditByActor(conn, user_id);

    const body = try buildSpecBody(allocator, generateRngSeed());
    defer allocator.free(body);

    const auth = orchAuth(user_id);
    const result = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth, body);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 201), result.status_code);

    const task_spec_id = try parseStringField(allocator, result.body, "task_spec_id");
    defer allocator.free(task_spec_id);

    const stored = try getStoredPrincipal(allocator, conn, task_spec_id);
    defer if (stored) |p| allocator.free(p);
    try testing.expect(stored != null);
    try testing.expect(std.mem.eql(u8, stored.?, user_id));
}

// ── TC-SBX-02-02: orchestrator_principal in body is discarded silently ────────

test "sbx02_02_body_principal_discarded_server_value_persisted" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_id);
    defer cleanupAuditByActor(conn, user_id);

    // Body carries a bogus orchestrator_principal that must be discarded
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"spec_version\":\"1.0\",\"task_name\":\"sbx-test\",\"rng_seed\":{d},\"orchestrator_principal\":\"orch-bogus-should-be-discarded\"}}",
        .{generateRngSeed()},
    );
    defer allocator.free(body);

    const auth = orchAuth(user_id);
    const result = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth, body);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 201), result.status_code);

    const task_spec_id = try parseStringField(allocator, result.body, "task_spec_id");
    defer allocator.free(task_spec_id);

    const stored = try getStoredPrincipal(allocator, conn, task_spec_id);
    defer if (stored) |p| allocator.free(p);
    try testing.expect(stored != null);
    // Must be the token subject, not "orch-bogus-should-be-discarded"
    try testing.expect(std.mem.eql(u8, stored.?, user_id));
    try testing.expect(!std.mem.eql(u8, stored.?, "orch-bogus-should-be-discarded"));
}

// ── TC-SBX-02-03: Two orchestrators same body → different spec_hash ───────────

test "sbx02_03_two_orchestrators_same_body_different_spec_hash" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_a = try generateTestUserId(allocator);
    defer allocator.free(user_a);
    const user_b = try generateTestUserId(allocator);
    defer allocator.free(user_b);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_a);
    defer cleanupTaskSpecByUser(conn, user_b);
    defer cleanupAuditByActor(conn, user_a);
    defer cleanupAuditByActor(conn, user_b);

    // Same payload, same rng_seed
    const fixed_seed: u64 = 0xAB12CD34EF567890;
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"spec_version\":\"1.0\",\"task_name\":\"shared-task\",\"rng_seed\":{d}}}",
        .{fixed_seed},
    );
    defer allocator.free(body);

    const auth_a = orchAuth(user_a);
    const result_a = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth_a, body);
    defer freeBody(allocator, result_a);
    try testing.expectEqual(@as(u16, 201), result_a.status_code);
    const hash_a = try parseStringField(allocator, result_a.body, "spec_hash");
    defer allocator.free(hash_a);

    const auth_b = orchAuth(user_b);
    const result_b = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth_b, body);
    defer freeBody(allocator, result_b);
    try testing.expectEqual(@as(u16, 201), result_b.status_code);
    const hash_b = try parseStringField(allocator, result_b.body, "spec_hash");
    defer allocator.free(hash_b);

    // Hashes must differ because orchestrator_principal differs
    try testing.expect(!std.mem.eql(u8, hash_a, hash_b));
}

// ── TC-SBX-02-04: TaskSpecSubmitted audit entry has correct principal ──────────

test "sbx02_04_task_spec_submitted_audit_has_correct_principal" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_id);
    defer cleanupAuditByActor(conn, user_id);

    const body = try buildSpecBody(allocator, generateRngSeed());
    defer allocator.free(body);

    const auth = orchAuth(user_id);
    const result = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth, body);
    defer freeBody(allocator, result);
    try testing.expectEqual(@as(u16, 201), result.status_code);

    const audit_count = try countAuditEvents(allocator, conn, user_id, "task_spec.submitted");
    try testing.expect(audit_count >= 1);
}

// ── TC-SBX-02-05: Body carries orch-b principal; hash is computed over token orch-a ─
// SBX-02 AC3: spec_hash covers server-authoritative orchestrator_principal.
// The 409 spec_hash_mismatch on artifact submission is exercised by AGT-03 tests.

test "sbx02_05_hash_based_on_token_principal_not_body_principal" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const orch_a = try generateTestUserId(allocator);
    defer allocator.free(orch_a);
    const orch_b = try generateTestUserId(allocator);
    defer allocator.free(orch_b);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, orch_a);
    defer cleanupTaskSpecByUser(conn, orch_b);
    defer cleanupAuditByActor(conn, orch_a);
    defer cleanupAuditByActor(conn, orch_b);

    const fixed_seed: u64 = 0xC0FFEE1234567890;

    // Step 1: orch-a submits a spec where the body explicitly names orch-b as
    // orchestrator_principal. The handler must discard it and store orch-a.
    const body_with_orch_b = try std.fmt.allocPrint(
        allocator,
        "{{\"spec_version\":\"1.0\",\"task_name\":\"ac3-test\",\"rng_seed\":{d},\"orchestrator_principal\":\"{s}\"}}",
        .{ fixed_seed, orch_b },
    );
    defer allocator.free(body_with_orch_b);

    const auth_a = orchAuth(orch_a);
    const result_a = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth_a, body_with_orch_b);
    defer freeBody(allocator, result_a);
    try testing.expectEqual(@as(u16, 201), result_a.status_code);

    const task_spec_id_a = try parseStringField(allocator, result_a.body, "task_spec_id");
    defer allocator.free(task_spec_id_a);
    const hash_a = try parseStringField(allocator, result_a.body, "spec_hash");
    defer allocator.free(hash_a);

    // Confirm stored orchestrator_principal is orch-a (body's orch-b was discarded).
    const stored_principal = try getStoredPrincipal(allocator, conn, task_spec_id_a);
    defer if (stored_principal) |p| allocator.free(p);
    try testing.expect(stored_principal != null);
    try testing.expect(std.mem.eql(u8, stored_principal.?, orch_a));
    try testing.expect(!std.mem.eql(u8, stored_principal.?, orch_b));

    // Step 2: orch-b submits the same spec without overriding orchestrator_principal.
    // This produces hash_b = SHA256(canonical({..., orchestrator_principal: orch-b})).
    const body_clean = try std.fmt.allocPrint(
        allocator,
        "{{\"spec_version\":\"1.0\",\"task_name\":\"ac3-test\",\"rng_seed\":{d}}}",
        .{fixed_seed},
    );
    defer allocator.free(body_clean);

    const auth_b = orchAuth(orch_b);
    const result_b = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth_b, body_clean);
    defer freeBody(allocator, result_b);
    try testing.expectEqual(@as(u16, 201), result_b.status_code);

    const hash_b = try parseStringField(allocator, result_b.body, "spec_hash");
    defer allocator.free(hash_b);

    // SBX-02 AC3: hash_a was computed over orch-a, not orch-b.
    // A client that pre-computed its hash over orch-b would get hash_b != hash_a,
    // and therefore receive HTTP 409 spec_hash_mismatch on artifact submission.
    try testing.expect(!std.mem.eql(u8, hash_a, hash_b));
}

// ── TC-SBX-03-01: Orchestrator calls claim endpoint → HTTP 403 ────────────────

test "sbx03_01_orchestrator_claim_returns_403_orchestrator_may_not_claim" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupAuditByActor(conn, user_id);

    const sandbox_id = try insertUnclamedSandbox(allocator, conn, DEFAULT_TENANT_ID);
    defer allocator.free(sandbox_id);
    defer cleanupSandbox(conn, sandbox_id);

    const auth = orchAuth(user_id);
    const result = agent_sandboxes.handleClaimSandbox(allocator, &pool, auth, sandbox_id, "{}");
    defer freeSandboxBody(allocator, result);

    try testing.expectEqual(@as(u16, 403), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    try testing.expect(std.mem.eql(u8, detail, "orchestrator_may_not_claim"));

    // Sandbox must remain unclaimed
    const status = try getSandboxStatus(allocator, conn, sandbox_id);
    defer if (status) |s| allocator.free(s);
    try testing.expect(std.mem.eql(u8, status.?, "unclaimed"));
}

// ── TC-SBX-03-02: No agent role calls claim endpoint → HTTP 403 ───────────────

test "sbx03_02_no_agent_role_claim_returns_403_implementer_role_required" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupAuditByActor(conn, user_id);

    const sandbox_id = try insertUnclamedSandbox(allocator, conn, DEFAULT_TENANT_ID);
    defer allocator.free(sandbox_id);
    defer cleanupSandbox(conn, sandbox_id);

    const auth = noAgentRoleAuth(user_id);
    const result = agent_sandboxes.handleClaimSandbox(allocator, &pool, auth, sandbox_id, "{}");
    defer freeSandboxBody(allocator, result);

    try testing.expectEqual(@as(u16, 403), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    try testing.expect(std.mem.eql(u8, detail, "implementer_role_required"));
}

// ── TC-SBX-03-03: Implementer claims sandbox → HTTP 201, bound to principal ───

test "sbx03_03_implementer_claim_sandbox_201_bound" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const sandbox_id = try insertUnclamedSandbox(allocator, conn, DEFAULT_TENANT_ID);
    defer allocator.free(sandbox_id);
    defer cleanupSandbox(conn, sandbox_id);

    const auth = implAuth(user_id);
    const result = agent_sandboxes.handleClaimSandbox(allocator, &pool, auth, sandbox_id, "{}");
    defer freeSandboxBody(allocator, result);

    try testing.expectEqual(@as(u16, 201), result.status_code);

    const owner = try getSandboxOwner(allocator, conn, sandbox_id);
    defer if (owner) |o| allocator.free(o);
    try testing.expect(owner != null);
    try testing.expect(std.mem.eql(u8, owner.?, user_id));

    const status = try getSandboxStatus(allocator, conn, sandbox_id);
    defer if (status) |s| allocator.free(s);
    try testing.expect(std.mem.eql(u8, status.?, "claimed"));
}

// ── TC-SBX-03-04: Orchestrator GET sandboxes → receives all tenant sandboxes ──

test "sbx03_04_orchestrator_list_sees_all_tenant_sandboxes" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const orch_id = try generateTestUserId(allocator);
    defer allocator.free(orch_id);
    const impl_id = try generateTestUserId(allocator);
    defer allocator.free(impl_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Insert two sandboxes: one unclaimed, one claimed by impl
    const sandbox_a = try insertUnclamedSandbox(allocator, conn, DEFAULT_TENANT_ID);
    defer allocator.free(sandbox_a);
    defer cleanupSandbox(conn, sandbox_a);

    const sandbox_b = try insertUnclamedSandbox(allocator, conn, DEFAULT_TENANT_ID);
    defer allocator.free(sandbox_b);
    defer cleanupSandbox(conn, sandbox_b);

    // Claim sandbox_b as impl
    try conn.exec(
        "UPDATE agent_sandboxes SET status = 'claimed', owner_principal = $1 WHERE sandbox_id = $2::uuid",
        &.{ impl_id, sandbox_b },
    );

    const auth = orchAuth(orch_id);
    const result = agent_sandboxes.handleListSandboxes(allocator, &pool, auth, null, null);
    defer freeSandboxBody(allocator, result);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    // Orchestrator must see at least the two sandboxes inserted in this test
    const count = try parseItemCount(allocator, result.body);
    try testing.expect(count >= 2);
}

// ── TC-SBX-03-05: Implementer GET sandboxes → receives only own sandboxes ─────

test "sbx03_05_implementer_list_sees_only_own_sandboxes" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const impl_x = try generateTestUserId(allocator);
    defer allocator.free(impl_x);
    const impl_y = try generateTestUserId(allocator);
    defer allocator.free(impl_y);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // sandbox owned by impl_x
    const sandbox_x = try insertUnclamedSandbox(allocator, conn, DEFAULT_TENANT_ID);
    defer allocator.free(sandbox_x);
    defer cleanupSandbox(conn, sandbox_x);
    try conn.exec(
        "UPDATE agent_sandboxes SET status = 'claimed', owner_principal = $1 WHERE sandbox_id = $2::uuid",
        &.{ impl_x, sandbox_x },
    );

    // sandbox owned by impl_y — should NOT appear in impl_x list
    const sandbox_y = try insertUnclamedSandbox(allocator, conn, DEFAULT_TENANT_ID);
    defer allocator.free(sandbox_y);
    defer cleanupSandbox(conn, sandbox_y);
    try conn.exec(
        "UPDATE agent_sandboxes SET status = 'claimed', owner_principal = $1 WHERE sandbox_id = $2::uuid",
        &.{ impl_y, sandbox_y },
    );

    const auth = implAuth(impl_x);
    const result = agent_sandboxes.handleListSandboxes(allocator, &pool, auth, null, null);
    defer freeSandboxBody(allocator, result);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    // impl_x should see exactly sandbox_x; sandbox_y must not appear
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        result.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const items_val = switch (parsed.value) {
        .object => |o| o.get("items") orelse return error.MissingItems,
        else => return error.NotObject,
    };
    const items = switch (items_val) {
        .array => |a| a,
        else => return error.ItemsNotArray,
    };

    var found_x = false;
    var found_y = false;
    for (items.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const sid = switch (item_obj.get("sandbox_id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, sid, sandbox_x)) found_x = true;
        if (std.mem.eql(u8, sid, sandbox_y)) found_y = true;
    }

    try testing.expect(found_x);
    try testing.expect(!found_y);
}

// ── TC-SBX-03-06: Rejected orchestrator claim writes SandboxClaimRejected ─────

test "sbx03_06_rejected_orchestrator_claim_writes_sandbox_claim_rejected_audit" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupAuditByActor(conn, user_id);

    const sandbox_id = try insertUnclamedSandbox(allocator, conn, DEFAULT_TENANT_ID);
    defer allocator.free(sandbox_id);
    defer cleanupSandbox(conn, sandbox_id);

    const auth = orchAuth(user_id);
    const result = agent_sandboxes.handleClaimSandbox(allocator, &pool, auth, sandbox_id, "{}");
    defer freeSandboxBody(allocator, result);

    try testing.expectEqual(@as(u16, 403), result.status_code);

    const audit_count = try countAuditEvents(allocator, conn, user_id, "sandbox.claim_rejected");
    try testing.expect(audit_count >= 1);
}
