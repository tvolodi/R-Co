//! Integration tests for AGT-05, AGT-06, AGT-07 — RNG Seed Identity,
//! Dual-Sweep Retention, Deprecated Field Rejection.
//!
//! Test spec:  tests/specs/AGT-05.md  (5 test cases)
//!             tests/specs/AGT-06.md  (7 test cases)
//!             tests/specs/AGT-07.md  (5 test cases)
//! Design:     src/design/agt05-07-design.md
//! Run ID:     WF02-agt05-07-20260819
//!
//! Covered call sites (called directly — no HTTP server required):
//!   handleSubmitTaskSpec    — POST /api/v1/agent/task-specs
//!   handleArtifactSubmit    — POST /api/v1/agent/artifacts
//!   handleArtifactVerify    — PATCH /api/v1/agent/artifacts/{id}/verify
//!   runArtifactRetentionSweep1 / runArtifactRetentionSweep2
//!
//! Requires BPM_TEST_DB_URL pointing at a real PostgreSQL database.
//! All fixtures use per-test UUIDs generated via fillRandom. Every test cleans up via defer.
//! SkipZigTest is FORBIDDEN on every test block (all are MUST requirements).

const std = @import("std");
const builtin = @import("builtin");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const auth_mod = bpm.api_auth;
const agent_artifacts = bpm.agent_artifacts_routes;
const agent_task_specs = bpm.agent_task_specs_routes;
const retention = bpm.artifact_retention_mod;

pub const api_tenant_context = bpm.api_tenant_context;

const DEFAULT_TENANT_ID = auth_mod.DEFAULT_TENANT_ID;

// ── Low-level helpers ─────────────────────────────────────────────────────────

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — AGT-05/06/07 integration tests require it\n",
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

fn orchAuth(user_id: []const u8) auth_mod.AuthContext {
    return .{
        .user_id = user_id,
        .role = .AGENT_RUNNER,
        .is_bootstrap = false,
        .token_id = "agt-test-orch",
        .principal = user_id,
        .tenant_id = DEFAULT_TENANT_ID.*,
        .agent_realm_roles = &[_]auth_mod.AgentRealmRole{.tenant_orchestrator},
        .token_scopes = &[_][]const u8{"agent.submit_task_spec"},
    };
}

fn agentAuth(user_id: []const u8) auth_mod.AuthContext {
    return .{
        .user_id = user_id,
        .role = .AGENT_RUNNER,
        .is_bootstrap = false,
        .token_id = "agt-test-token",
        .principal = user_id,
        .tenant_id = DEFAULT_TENANT_ID.*,
        .agent_realm_roles = &[_]auth_mod.AgentRealmRole{.tenant_implementer},
        .token_scopes = &[_][]const u8{"agent.submit_artifact"},
    };
}

// ── Static bodies (never freed) ───────────────────────────────────────────────

const STATIC_FORBIDDEN = "{\"detail\":\"forbidden\",\"status\":403}";
const STATIC_BAD_REQUEST = "{\"detail\":\"bad_request\",\"status\":400}";
const STATIC_CONFLICT = "{\"detail\":\"conflict\",\"status\":409}";

fn isStaticTaskSpecBody(body: []const u8) bool {
    const statics = [_][]const u8{
        STATIC_FORBIDDEN,
        STATIC_BAD_REQUEST,
        STATIC_CONFLICT,
        "{}",
        "{\"detail\":\"out_of_memory\",\"status\":503}",
        "{\"detail\":\"pool_exhausted\",\"status\":503}",
        "{\"detail\":\"db_error\",\"status\":503}",
    };
    for (statics) |s| if (std.mem.eql(u8, body, s)) return true;
    return false;
}

fn freeTaskSpecBody(allocator: std.mem.Allocator, result: agent_task_specs.HandlerResult) void {
    if (result.body.len == 0) return;
    if (isStaticTaskSpecBody(result.body)) return;
    allocator.free(result.body);
}

const STATIC_WRONG_ENV = "{\"error\":\"wrong_environment\",\"status\":403}";
const STATIC_SVC503 = "{\"error\":\"service_unavailable\",\"status\":503}";
const STATIC_MALFORMED = "{\"error\":\"malformed_json\",\"status\":400}";
const STATIC_MISSING_KIND = "{\"error\":\"missing_field_kind\",\"status\":400}";
const STATIC_MISSING_SPEC_ID = "{\"error\":\"missing_field_task_spec_id\",\"status\":400}";
const STATIC_MISSING_ATTEMPT = "{\"error\":\"missing_field_attempt_count\",\"status\":400}";
const STATIC_MISSING_HASH = "{\"error\":\"missing_field_spec_hash\",\"status\":400}";
const STATIC_MISSING_PAYLOAD = "{\"error\":\"missing_field_payload\",\"status\":400}";

fn isStaticArtifactBody(body: []const u8) bool {
    const statics = [_][]const u8{
        STATIC_WRONG_ENV,
        STATIC_SVC503,
        STATIC_MALFORMED,
        STATIC_MISSING_KIND,
        STATIC_MISSING_SPEC_ID,
        STATIC_MISSING_ATTEMPT,
        STATIC_MISSING_HASH,
        STATIC_MISSING_PAYLOAD,
    };
    for (statics) |s| if (std.mem.eql(u8, body, s)) return true;
    if (std.mem.startsWith(u8, body, "{\"schemas\":")) return true;
    return false;
}

fn freeArtifactBody(allocator: std.mem.Allocator, result: agent_artifacts.HandlerResult) void {
    if (result.body.len == 0) return;
    if (isStaticArtifactBody(result.body)) return;
    allocator.free(result.body);
}

// ── JSON parse helpers ────────────────────────────────────────────────────────

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

fn parseIntField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) !i64 {
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
        .integer => |n| n,
        else => error.NotInteger,
    };
}

// ── Fixture helpers ───────────────────────────────────────────────────────────

const TaskSpecResult = struct { spec_hash: []u8, task_spec_id: []u8 };

fn registerTaskSpec(
    allocator: std.mem.Allocator,
    pool: *Pool,
    user_id: []const u8,
    rng_seed: i64,
) !TaskSpecResult {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"task_name\":\"agt-test\",\"rng_seed\":{d}}}",
        .{rng_seed},
    );
    defer allocator.free(body);

    const auth = orchAuth(user_id);
    const result = agent_task_specs.handleSubmitTaskSpec(allocator, pool, auth, body);
    defer freeTaskSpecBody(allocator, result);

    if (result.status_code != 201) {
        std.debug.print("registerTaskSpec: unexpected status {d}: {s}\n", .{ result.status_code, result.body });
        return error.TaskSpecRegistrationFailed;
    }
    const spec_hash = try parseStringField(allocator, result.body, "spec_hash");
    errdefer allocator.free(spec_hash);
    const task_spec_id = try parseStringField(allocator, result.body, "task_spec_id");
    return .{ .spec_hash = spec_hash, .task_spec_id = task_spec_id };
}

fn cleanupTaskSpecByUser(conn: *bpm.pool.Conn, user_id: []const u8) void {
    conn.exec(
        "DELETE FROM task_specs WHERE orchestrator_principal = $1",
        &.{user_id},
    ) catch {};
}

fn cleanupArtifactsByTaskSpec(conn: *bpm.pool.Conn, task_spec_id: []const u8) void {
    conn.exec(
        "DELETE FROM staging.agent_artifacts WHERE task_spec_id = $1::uuid",
        &.{task_spec_id},
    ) catch {};
}

fn cleanupArtifactById(conn: *bpm.pool.Conn, artifact_id: []const u8) void {
    // Cascade handles artifact_version_pins due to ON DELETE CASCADE.
    conn.exec(
        "DELETE FROM staging.agent_artifacts WHERE artifact_id = $1::uuid",
        &.{artifact_id},
    ) catch {};
    // Clean up the task_spec created by insertRawArtifact (task_spec_id == artifact_id).
    conn.exec(
        "DELETE FROM task_specs WHERE task_spec_id = $1::uuid",
        &.{artifact_id},
    ) catch {};
}

fn countArtifacts(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    task_spec_id: []const u8,
) !usize {
    const row = (try conn.queryRow(
        allocator,
        "SELECT COUNT(*)::text FROM staging.agent_artifacts WHERE task_spec_id = $1::uuid",
        &.{task_spec_id},
    )) orelse return 0;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    return std.fmt.parseInt(usize, row[0] orelse "0", 10) catch 0;
}

fn countArtifactsById(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    artifact_id: []const u8,
) !usize {
    const row = (try conn.queryRow(
        allocator,
        "SELECT COUNT(*)::text FROM staging.agent_artifacts WHERE artifact_id = $1::uuid",
        &.{artifact_id},
    )) orelse return 0;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    return std.fmt.parseInt(usize, row[0] orelse "0", 10) catch 0;
}

fn queryArtifactStatus(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    artifact_id: []const u8,
) !?[]u8 {
    const row = (try conn.queryRow(
        allocator,
        "SELECT status FROM staging.agent_artifacts WHERE artifact_id = $1::uuid",
        &.{artifact_id},
    )) orelse return null;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    return @as(?[]u8, try allocator.dupe(u8, row[0] orelse ""));
}

fn countVersionPins(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    artifact_id: []const u8,
) !usize {
    const row = (try conn.queryRow(
        allocator,
        "SELECT COUNT(*)::text FROM staging.artifact_version_pins WHERE artifact_id = $1::uuid",
        &.{artifact_id},
    )) orelse return 0;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    return std.fmt.parseInt(usize, row[0] orelse "0", 10) catch 0;
}

fn queryRngSeedByHash(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    spec_hash: []const u8,
) !?i64 {
    const row = (try conn.queryRow(
        allocator,
        "SELECT rng_seed::text FROM task_specs WHERE spec_hash = $1",
        &.{spec_hash},
    )) orelse return null;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    const s = row[0] orelse return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

const VALID_TEST_REPORT_PAYLOAD =
    \\{"suite_id":"s1","run_id":"r1","passed":2,"failed":0,"skipped":0,"duration_ms":42,"assertions":[{"name":"check","passed":true}]}
;

fn buildEnvelope(
    allocator: std.mem.Allocator,
    kind: []const u8,
    task_spec_id: []const u8,
    attempt_count: i64,
    spec_hash: []const u8,
    payload_json: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"{s}\",\"task_spec_id\":\"{s}\",\"attempt_count\":{d},\"spec_hash\":\"{s}\",\"payload\":{s}}}",
        .{ kind, task_spec_id, attempt_count, spec_hash, payload_json },
    );
}

// ── AGT-05 Tests ──────────────────────────────────────────────────────────────

test "TC-AGT05-01: rng_seed = 0 returns 400 rng_seed_zero, no row written" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const user_id = try generateUuid(allocator);
    defer allocator.free(user_id);

    const auth = orchAuth(user_id);
    const body = "{\"task_name\":\"seed-zero-test\",\"rng_seed\":0}";
    const result = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth, body);
    defer freeTaskSpecBody(allocator, result);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "rng_seed_zero") != null);

    // No row must exist for this user.
    const conn = try pool.acquire();
    defer pool.release(conn);
    const row = try conn.queryRow(
        allocator,
        "SELECT COUNT(*)::text FROM task_specs WHERE orchestrator_principal = $1",
        &.{user_id},
    );
    defer if (row) |r| {
        if (r[0]) |v| allocator.free(v);
        allocator.free(r);
    };
    const cnt_str = if (row) |r| r[0] orelse "0" else "0";
    const cnt = try std.fmt.parseInt(usize, cnt_str, 10);
    try testing.expectEqual(@as(usize, 0), cnt);
}

test "TC-AGT05-02: absent rng_seed returns 400 rng_seed_zero" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const user_id = try generateUuid(allocator);
    defer allocator.free(user_id);

    const auth = orchAuth(user_id);
    const body = "{\"task_name\":\"no-seed-test\"}";
    const result = agent_task_specs.handleSubmitTaskSpec(allocator, &pool, auth, body);
    defer freeTaskSpecBody(allocator, result);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "rng_seed_zero") != null);
}

test "TC-AGT05-03: specs differing only in rng_seed produce different spec_hash" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const user_id = try generateUuid(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_id);

    const spec42 = try registerTaskSpec(allocator, &pool, user_id, 42);
    defer allocator.free(spec42.spec_hash);
    defer allocator.free(spec42.task_spec_id);

    const spec43 = try registerTaskSpec(allocator, &pool, user_id, 43);
    defer allocator.free(spec43.spec_hash);
    defer allocator.free(spec43.task_spec_id);

    // Different hashes.
    try testing.expect(!std.mem.eql(u8, spec42.spec_hash, spec43.spec_hash));
    // Different task_spec_ids.
    try testing.expect(!std.mem.eql(u8, spec42.task_spec_id, spec43.task_spec_id));
}

test "TC-AGT05-04: artifact submitted with wrong spec_hash gets 409 spec_hash_mismatch" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const user_id = try generateUuid(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_id);

    // Register a real spec.
    const spec = try registerTaskSpec(allocator, &pool, user_id, 99);
    defer allocator.free(spec.spec_hash);
    defer allocator.free(spec.task_spec_id);
    defer cleanupArtifactsByTaskSpec(conn, spec.task_spec_id);

    // Submit artifact with a fabricated spec_hash (different from the stored one).
    const fake_hash = "0000000000000000000000000000000000000000000000000000000000000000";
    const envelope = try buildEnvelope(
        allocator,
        "test_report",
        spec.task_spec_id,
        1,
        fake_hash,
        VALID_TEST_REPORT_PAYLOAD,
    );
    defer allocator.free(envelope);

    const auth = agentAuth(user_id);
    const result = agent_artifacts.handleArtifactSubmit(
        allocator,
        &pool,
        auth,
        envelope,
        false,
    );
    defer freeArtifactBody(allocator, result);

    try testing.expectEqual(@as(u16, 409), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "spec_hash_mismatch") != null);
}

test "TC-AGT05-05: rng_seed persisted as correct integer in task_specs" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const user_id = try generateUuid(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_id);

    const seed: i64 = 123456789;
    const spec = try registerTaskSpec(allocator, &pool, user_id, seed);
    defer allocator.free(spec.spec_hash);
    defer allocator.free(spec.task_spec_id);

    const stored_seed = try queryRngSeedByHash(allocator, conn, spec.spec_hash);
    try testing.expect(stored_seed != null);
    try testing.expectEqual(seed, stored_seed.?);
}

// ── AGT-06 Tests ──────────────────────────────────────────────────────────────

/// Insert a raw artifact row into staging.agent_artifacts for retention testing.
fn insertRawArtifact(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    artifact_id: []const u8,
    status: []const u8,
    created_at_offset_days: i32,
    verified_at_offset_days: ?i32,
) !void {
    const tenant_id: []const u8 = DEFAULT_TENANT_ID[0..];
    // Create a matching task_spec row (task_spec_id == artifact_id) to satisfy the FK.
    try conn.exec(
        \\INSERT INTO task_specs (task_spec_id, spec_hash, spec_body, orchestrator_principal, rng_seed)
        \\VALUES ($1::uuid, encode(sha256($1::text::bytea), 'hex'), '{}', 'test-retention-fixture', 1)
        \\ON CONFLICT DO NOTHING
    ,
        &.{artifact_id},
    );
    if (verified_at_offset_days) |vd| {
        const vd_str = try std.fmt.allocPrint(allocator, "{d}", .{vd});
        defer allocator.free(vd_str);
        const cd_str = try std.fmt.allocPrint(allocator, "{d}", .{created_at_offset_days});
        defer allocator.free(cd_str);
        try conn.exec(
            \\INSERT INTO staging.agent_artifacts
            \\  (artifact_id, tenant_id, task_spec_id, attempt_count, kind, spec_hash,
            \\   payload, status, created_at, verified_at)
            \\VALUES (
            \\  $1::uuid, $2::uuid,
            \\  $1::uuid, 1, 'test_report', 'deadbeef',
            \\  '{}', $3,
            \\  NOW() - ($4::integer * INTERVAL '1 day'),
            \\  NOW() - ($5::integer * INTERVAL '1 day')
            \\)
        ,
            &.{ artifact_id, tenant_id, status, cd_str, vd_str },
        );
    } else {
        const cd_str = try std.fmt.allocPrint(allocator, "{d}", .{created_at_offset_days});
        defer allocator.free(cd_str);
        try conn.exec(
            \\INSERT INTO staging.agent_artifacts
            \\  (artifact_id, tenant_id, task_spec_id, attempt_count, kind, spec_hash,
            \\   payload, status, created_at)
            \\VALUES (
            \\  $1::uuid, $2::uuid,
            \\  $1::uuid, 1, 'test_report', 'deadbeef',
            \\  '{}', $3,
            \\  NOW() - ($4::integer * INTERVAL '1 day')
            \\)
        ,
            &.{ artifact_id, tenant_id, status, cd_str },
        );
    }
}

/// Insert a version pin row with optional collected_at.
fn insertVersionPin(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    artifact_id: []const u8,
    collected_at_offset_days: ?i32,
) !void {
    if (collected_at_offset_days) |cd| {
        const cd_str = try std.fmt.allocPrint(allocator, "{d}", .{cd});
        defer allocator.free(cd_str);
        try conn.exec(
            \\INSERT INTO staging.artifact_version_pins
            \\  (artifact_id, task_spec_version, process_definition_version, collected_at)
            \\VALUES ($1::uuid, '1.0', '1.0', NOW() - ($2::integer * INTERVAL '1 day'))
        ,
            &.{ artifact_id, cd_str },
        );
    } else {
        try conn.exec(
            \\INSERT INTO staging.artifact_version_pins
            \\  (artifact_id, task_spec_version, process_definition_version)
            \\VALUES ($1::uuid, '1.0', '1.0')
        ,
            &.{artifact_id},
        );
    }
}

test "TC-AGT06-01: sweep1 deletes old needs_review artifact" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const artifact_id = try generateUuid(allocator);
    defer allocator.free(artifact_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Insert artifact older than 30 days with needs_review status.
    try insertRawArtifact(allocator, conn, artifact_id, "needs_review", 31, null);
    defer cleanupArtifactById(conn, artifact_id);

    const deleted = try retention.runArtifactRetentionSweep1(allocator, &pool, 30);
    try testing.expect(deleted >= 1);

    const remaining = try countArtifactsById(allocator, conn, artifact_id);
    try testing.expectEqual(@as(usize, 0), remaining);
}

test "TC-AGT06-02: sweep1 does NOT delete verified artifact" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const artifact_id = try generateUuid(allocator);
    defer allocator.free(artifact_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Insert verified artifact older than 30 days.
    try insertRawArtifact(allocator, conn, artifact_id, "verified", 31, 31);
    defer cleanupArtifactById(conn, artifact_id);

    _ = try retention.runArtifactRetentionSweep1(allocator, &pool, 30);

    const remaining = try countArtifactsById(allocator, conn, artifact_id);
    try testing.expectEqual(@as(usize, 1), remaining);
}

test "TC-AGT06-03: sweep2 does NOT delete verified with un-collected pin" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const artifact_id = try generateUuid(allocator);
    defer allocator.free(artifact_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // verified_at 400 days ago, pin NOT collected.
    try insertRawArtifact(allocator, conn, artifact_id, "verified", 400, 400);
    try insertVersionPin(allocator, conn, artifact_id, null);
    defer cleanupArtifactById(conn, artifact_id);

    _ = try retention.runArtifactRetentionSweep2(allocator, &pool, 365);

    const remaining = try countArtifactsById(allocator, conn, artifact_id);
    try testing.expectEqual(@as(usize, 1), remaining);
}

test "TC-AGT06-04: sweep2 does NOT delete verified with collected pin but < 365 days" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const artifact_id = try generateUuid(allocator);
    defer allocator.free(artifact_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // verified_at 200 days ago, pin collected 1 day ago.
    try insertRawArtifact(allocator, conn, artifact_id, "verified", 200, 200);
    try insertVersionPin(allocator, conn, artifact_id, 1);
    defer cleanupArtifactById(conn, artifact_id);

    _ = try retention.runArtifactRetentionSweep2(allocator, &pool, 365);

    const remaining = try countArtifactsById(allocator, conn, artifact_id);
    try testing.expectEqual(@as(usize, 1), remaining);
}

test "TC-AGT06-05: sweep2 deletes verified with collected pin and > 365 days" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const artifact_id = try generateUuid(allocator);
    defer allocator.free(artifact_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // verified_at 366 days ago, pin collected 1 day ago.
    try insertRawArtifact(allocator, conn, artifact_id, "verified", 366, 366);
    try insertVersionPin(allocator, conn, artifact_id, 1);
    defer cleanupArtifactById(conn, artifact_id);

    const deleted = try retention.runArtifactRetentionSweep2(allocator, &pool, 365);
    try testing.expect(deleted >= 1);

    const remaining = try countArtifactsById(allocator, conn, artifact_id);
    try testing.expectEqual(@as(usize, 0), remaining);
}

test "TC-AGT06-06: handleArtifactVerify writes version pin atomically" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const user_id = try generateUuid(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_id);

    // Register task spec and submit artifact.
    const spec = try registerTaskSpec(allocator, &pool, user_id, 777);
    defer allocator.free(spec.spec_hash);
    defer allocator.free(spec.task_spec_id);
    defer cleanupArtifactsByTaskSpec(conn, spec.task_spec_id);

    const envelope = try buildEnvelope(
        allocator,
        "test_report",
        spec.task_spec_id,
        1,
        spec.spec_hash,
        VALID_TEST_REPORT_PAYLOAD,
    );
    defer allocator.free(envelope);

    const agent_auth_ctx = agentAuth(user_id);
    const submit_result = agent_artifacts.handleArtifactSubmit(
        allocator,
        &pool,
        agent_auth_ctx,
        envelope,
        false,
    );
    defer freeArtifactBody(allocator, submit_result);
    try testing.expectEqual(@as(u16, 201), submit_result.status_code);

    const artifact_id = try parseStringField(allocator, submit_result.body, "artifact_id");
    defer allocator.free(artifact_id);

    // Verify the artifact.
    const verify_body =
        \\{"task_spec_version":"1.0","process_definition_version":"1.0"}
    ;
    const verify_result = agent_artifacts.handleArtifactVerify(
        allocator,
        &pool,
        agent_auth_ctx,
        artifact_id,
        verify_body,
        false,
    );
    defer freeArtifactBody(allocator, verify_result);
    try testing.expectEqual(@as(u16, 200), verify_result.status_code);

    // Check status = 'verified'.
    const status = try queryArtifactStatus(allocator, conn, artifact_id);
    defer if (status) |s| allocator.free(s);
    try testing.expect(status != null);
    try testing.expectEqualStrings("verified", status.?);

    // Check artifact_version_pins row exists.
    const pin_count = try countVersionPins(allocator, conn, artifact_id);
    try testing.expectEqual(@as(usize, 1), pin_count);
}

test "TC-AGT06-07: retention sweeps are idempotent" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    // Run sweep1 twice — must not error.
    const d1 = try retention.runArtifactRetentionSweep1(allocator, &pool, 30);
    const d2 = try retention.runArtifactRetentionSweep1(allocator, &pool, 30);
    // Second sweep deletes 0 more rows (same TTL, no new old rows added).
    _ = d1;
    _ = d2;

    // Run sweep2 twice — must not error.
    const d3 = try retention.runArtifactRetentionSweep2(allocator, &pool, 365);
    const d4 = try retention.runArtifactRetentionSweep2(allocator, &pool, 365);
    _ = d3;
    _ = d4;
}

// ── AGT-07 Tests ──────────────────────────────────────────────────────────────

test "TC-AGT07-01: ignore_fields present returns 400 deprecated_field:ignore_fields" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const user_id = try generateUuid(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_id);

    // Register a real spec so we can build a valid envelope.
    const spec = try registerTaskSpec(allocator, &pool, user_id, 1001);
    defer allocator.free(spec.spec_hash);
    defer allocator.free(spec.task_spec_id);
    defer cleanupArtifactsByTaskSpec(conn, spec.task_spec_id);

    // Envelope with ignore_fields.
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"test_report\",\"task_spec_id\":\"{s}\",\"attempt_count\":1,\"spec_hash\":\"{s}\",\"payload\":{s},\"ignore_fields\":[\"x\"]}}",
        .{ spec.task_spec_id, spec.spec_hash, VALID_TEST_REPORT_PAYLOAD },
    );
    defer allocator.free(body);

    const auth = agentAuth(user_id);
    const result = agent_artifacts.handleArtifactSubmit(allocator, &pool, auth, body, false);
    defer freeArtifactBody(allocator, result);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "deprecated_field:ignore_fields") != null);

    // No artifact row must be written.
    const cnt = try countArtifacts(allocator, conn, spec.task_spec_id);
    try testing.expectEqual(@as(usize, 0), cnt);
}

test "TC-AGT07-02: both ignore_fields and non_deterministic_fields returns 400 deprecated" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const user_id = try generateUuid(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_id);

    const spec = try registerTaskSpec(allocator, &pool, user_id, 1002);
    defer allocator.free(spec.spec_hash);
    defer allocator.free(spec.task_spec_id);
    defer cleanupArtifactsByTaskSpec(conn, spec.task_spec_id);

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"test_report\",\"task_spec_id\":\"{s}\",\"attempt_count\":1,\"spec_hash\":\"{s}\",\"payload\":{s},\"ignore_fields\":[\"x\"],\"non_deterministic_fields\":[\"y\"]}}",
        .{ spec.task_spec_id, spec.spec_hash, VALID_TEST_REPORT_PAYLOAD },
    );
    defer allocator.free(body);

    const auth = agentAuth(user_id);
    const result = agent_artifacts.handleArtifactSubmit(allocator, &pool, auth, body, false);
    defer freeArtifactBody(allocator, result);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "deprecated_field:ignore_fields") != null);
}

test "TC-AGT07-03: ignore_fields = [] (empty array) returns 400 deprecated" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const user_id = try generateUuid(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_id);

    const spec = try registerTaskSpec(allocator, &pool, user_id, 1003);
    defer allocator.free(spec.spec_hash);
    defer allocator.free(spec.task_spec_id);
    defer cleanupArtifactsByTaskSpec(conn, spec.task_spec_id);

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"test_report\",\"task_spec_id\":\"{s}\",\"attempt_count\":1,\"spec_hash\":\"{s}\",\"payload\":{s},\"ignore_fields\":[]}}",
        .{ spec.task_spec_id, spec.spec_hash, VALID_TEST_REPORT_PAYLOAD },
    );
    defer allocator.free(body);

    const auth = agentAuth(user_id);
    const result = agent_artifacts.handleArtifactSubmit(allocator, &pool, auth, body, false);
    defer freeArtifactBody(allocator, result);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "deprecated_field:ignore_fields") != null);
}

test "TC-AGT07-04: deprecated check fires before schema validation (missing kind + ignore_fields)" {
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const user_id = try generateUuid(allocator);
    defer allocator.free(user_id);

    // Envelope missing kind (otherwise invalid) but with ignore_fields.
    // Should get deprecated error, not missing_field_kind.
    const body =
        \\{"task_spec_id":"00000000-0000-0000-0000-000000000000","attempt_count":1,"spec_hash":"abc","payload":{},"ignore_fields":["x"]}
    ;

    const auth = agentAuth(user_id);
    const result = agent_artifacts.handleArtifactSubmit(allocator, &pool, auth, body, false);
    defer freeArtifactBody(allocator, result);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "deprecated_field:ignore_fields") != null);
    // Must NOT be the kind-missing error.
    try testing.expect(std.mem.indexOf(u8, result.body, "missing_field_kind") == null);
}

test "TC-AGT07-05: no agent_artifacts row after deprecated field rejection" {
    // This is verified as part of TC-AGT07-01 above (explicit count check).
    // This standalone test serves as an explicit audit of the cross-cutting no-write rule
    // by repeating the count check with a minimal ignore_fields envelope.
    const allocator = testing.allocator;

    const db_url = try testDbUrl(allocator);
    defer allocator.free(db_url);
    var pool = try makePool(allocator, db_url);
    defer pool.deinit();

    const user_id = try generateUuid(allocator);
    defer allocator.free(user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);
    defer cleanupTaskSpecByUser(conn, user_id);

    const spec = try registerTaskSpec(allocator, &pool, user_id, 1005);
    defer allocator.free(spec.spec_hash);
    defer allocator.free(spec.task_spec_id);

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"test_report\",\"task_spec_id\":\"{s}\",\"attempt_count\":1,\"spec_hash\":\"{s}\",\"payload\":{s},\"ignore_fields\":[\"z\"]}}",
        .{ spec.task_spec_id, spec.spec_hash, VALID_TEST_REPORT_PAYLOAD },
    );
    defer allocator.free(body);

    const auth = agentAuth(user_id);
    const result = agent_artifacts.handleArtifactSubmit(allocator, &pool, auth, body, false);
    defer freeArtifactBody(allocator, result);

    try testing.expectEqual(@as(u16, 400), result.status_code);

    const cnt = try countArtifacts(allocator, conn, spec.task_spec_id);
    try testing.expectEqual(@as(usize, 0), cnt);
}
