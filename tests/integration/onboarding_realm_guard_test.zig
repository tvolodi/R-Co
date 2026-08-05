//! Integration tests for ISS-0071 Fix B — realm-existence guard in GET /api/v1/onboarding/:id.
//!
//! All tests require a real PostgreSQL database via BPM_TEST_DB_URL.
//!
//! DIRECTIVE T-1: No mocks for DB — all state is persisted to real PostgreSQL.
//! The identity-provider (Keycloak) is an external system; a minimal test
//! adapter that controls the checkRealmExists return value is used, per the
//! T-1 exception for third-party external systems.
//!
//! No error.SkipZigTest on any test block.
//! All fixtures use per-test UUIDs.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const pool_mod = bpm.db_pool;
const identity_registry = bpm.identity_registry;
const identity_service = bpm.identity_service;
const onboarding_routes = bpm.onboarding_routes;
const provider_interface = bpm.identity_provider.interface;
const provider_types = bpm.identity_provider.types;
const provider_errors = bpm.identity_provider.errors;
const provider_manager = bpm.identity_provider.manager;
const tenant_ctx = bpm.api_tenant_context;

// ── Helpers ───────────────────────────────────────────────────────────────────

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-0071 realm guard integration tests and is not set\n", .{});
            return err;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !pool_mod.Pool {
    return pool_mod.Pool.init(std.testing.io, allocator, .{ .url = url, .pool_size = 3 });
}

/// Generate a random UUID v4 hex string (36 chars with dashes).
/// Uses stack-address entropy — sufficient for per-test uniqueness.
fn generateUuidHex(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    const seed: u64 = @truncate(@intFromPtr(&raw));
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, 36);
    // 8-4-4-4-12 format — byte counts per dash-group: 4,2,2,2,6
    const parts = [_]usize{ 4, 2, 2, 2, 6 };
    var o: usize = 0;
    var b: usize = 0;
    for (parts, 0..) |byte_count, pi| {
        if (pi > 0) {
            out[o] = '-';
            o += 1;
        }
        for (0..byte_count) |_| {
            out[o] = hex_chars[raw[b] >> 4];
            out[o + 1] = hex_chars[raw[b] & 0x0f];
            o += 2;
            b += 1;
        }
    }
    return out;
}

fn adminActor() bpm.api_auth.AuthContext {
    return .{
        .user_id = "00000000-0000-0000-0000-000000000000",
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = true,
        .token_id = "test-iss0071",
        .principal = "test-iss0071",
        .tenant_id = bpm.api_auth.DEFAULT_TENANT_ID.*,
        .tenant_source = .default_fallback,
    };
}

/// Free a HandlerResult body returned by route handlers.
/// Only the OOM-fallback static literal must NOT be freed — all other bodies
/// are heap-allocated by the handler and must be freed by the caller.
fn freeBody(alloc: std.mem.Allocator, body: []const u8) void {
    // errorResult falls back to this static literal on OOM; do not free it.
    const static_oom_fallback = "{\"error\":\"internal_error\"}";
    if (std.mem.eql(u8, body, static_oom_fallback)) return;
    alloc.free(body);
}

// ── Test-scoped IDP adapters ──────────────────────────────────────────────────
//
// Keycloak is an external system (T-1 exception). We provide two minimal
// adapters that control only the `checkRealmExists` return value. All other
// function pointers return error.NotImplemented — the handler does not call them.

// Shared dummy context (no state needed; the adapters are stateless).
// `const` (not `var`) since the value is never mutated — only its address is
// taken as an opaque context pointer.
const dummy_ctx_byte: u8 = 0;

fn notImplVerify(_: *anyopaque, _: std.mem.Allocator, _: provider_types.VerifyTokenInput) provider_errors.ProviderError!provider_types.VerifiedPrincipal {
    return error.NotImplemented;
}
fn notImplLookupUser(_: *anyopaque, _: std.mem.Allocator, _: provider_types.LookupUserInput) provider_errors.ProviderError!?provider_types.ProviderUser {
    return error.NotImplemented;
}
fn notImplProvisionRealm(_: *anyopaque, _: std.mem.Allocator, _: provider_types.ProvisionRealmInput) provider_errors.ProviderError!provider_types.ProvisionRealmResult {
    return error.NotImplemented;
}
fn notImplProvisionUser(_: *anyopaque, _: std.mem.Allocator, _: provider_types.ProvisionUserInput) provider_errors.ProviderError!provider_types.ProvisionUserResult {
    return error.NotImplemented;
}
fn notImplGrantRoles(_: *anyopaque, _: std.mem.Allocator, _: provider_types.GrantRolesInput) provider_errors.ProviderError!provider_types.GrantRolesResult {
    return error.NotImplemented;
}
fn notImplProvisionClient(_: *anyopaque, _: std.mem.Allocator, _: provider_types.ProvisionClientInput) provider_errors.ProviderError!provider_types.ProvisionClientResult {
    return error.NotImplemented;
}
fn notImplUpsertFederation(_: *anyopaque, _: std.mem.Allocator, _: provider_types.UpsertFederationInput) provider_errors.ProviderError!provider_types.FederationResult {
    return error.NotImplemented;
}
fn notImplDeleteFederation(_: *anyopaque, _: std.mem.Allocator, _: provider_types.DeleteFederationInput) provider_errors.ProviderError!void {
    return error.NotImplemented;
}
fn notImplListAuditEvents(_: *anyopaque, _: std.mem.Allocator, _: provider_types.ListAuditEventsInput) provider_errors.ProviderError!provider_types.AuditEventPage {
    return error.NotImplemented;
}
fn notImplCreateProtocolMapper(_: *anyopaque, _: std.mem.Allocator, _: provider_types.CreateProtocolMapperInput) provider_errors.ProviderError!provider_types.CreateProtocolMapperResult {
    return error.NotImplemented;
}
fn notImplToggleRealm(_: *anyopaque, _: std.mem.Allocator, _: provider_types.ToggleRealmInput) provider_errors.ProviderError!provider_types.RealmLifecycleResult {
    return error.NotImplemented;
}
fn notImplDeleteRealm(_: *anyopaque, _: std.mem.Allocator, _: provider_types.DeleteRealmInput) provider_errors.ProviderError!void {
    return error.NotImplemented;
}
fn notImplUpdateClient(_: *anyopaque, _: std.mem.Allocator, _: provider_types.UpdateClientInput) provider_errors.ProviderError!provider_types.UpdateClientResult {
    return error.NotImplemented;
}
fn notImplUpdateRealmFrontendUrl(_: *anyopaque, _: std.mem.Allocator, _: provider_types.UpdateRealmFrontendUrlInput) provider_errors.ProviderError!void {
    return error.NotImplemented;
}

/// checkRealmExists adapter that simulates a missing realm (Keycloak returned 404).
fn checkRealmMissingFn(_: *anyopaque, _: std.mem.Allocator, _: provider_types.CheckRealmExistsInput) provider_errors.ProviderError!bool {
    return false;
}

/// checkRealmExists adapter that simulates a present realm (Keycloak returned 200).
fn checkRealmPresentFn(_: *anyopaque, _: std.mem.Allocator, _: provider_types.CheckRealmExistsInput) provider_errors.ProviderError!bool {
    return true;
}

/// Build a Manager whose provider returns realmExists=false.
fn makeMissingRealmManager() provider_manager.Manager {
    const provider = provider_interface.IdentityProvider{
        .ctx = @constCast(@ptrCast(&dummy_ctx_byte)),
        .verifyTokenFn = notImplVerify,
        .lookupUserFn = notImplLookupUser,
        .provisionRealmFn = notImplProvisionRealm,
        .provisionUserFn = notImplProvisionUser,
        .grantRolesFn = notImplGrantRoles,
        .provisionClientFn = notImplProvisionClient,
        .upsertFederationFn = notImplUpsertFederation,
        .deleteFederationFn = notImplDeleteFederation,
        .listAuditEventsFn = notImplListAuditEvents,
        .createProtocolMapperFn = notImplCreateProtocolMapper,
        .toggleRealmFn = notImplToggleRealm,
        .deleteRealmFn = notImplDeleteRealm,
        .updateClientFn = notImplUpdateClient,
        .updateRealmFrontendUrlFn = notImplUpdateRealmFrontendUrl,
        .checkRealmExistsFn = checkRealmMissingFn,
    };
    // Allocate the provider in a stable location on the stack of the test
    // (the manager stores a copy by value — no heap allocation needed).
    return provider_manager.Manager{
        .provider = provider,
        .auth_mode = .local_only,
        .expected_audience = "",
        .expected_issuer = null,
    };
}

/// Build a Manager whose provider returns realmExists=true.
fn makePresentRealmManager() provider_manager.Manager {
    const provider = provider_interface.IdentityProvider{
        .ctx = @constCast(@ptrCast(&dummy_ctx_byte)),
        .verifyTokenFn = notImplVerify,
        .lookupUserFn = notImplLookupUser,
        .provisionRealmFn = notImplProvisionRealm,
        .provisionUserFn = notImplProvisionUser,
        .grantRolesFn = notImplGrantRoles,
        .provisionClientFn = notImplProvisionClient,
        .upsertFederationFn = notImplUpsertFederation,
        .deleteFederationFn = notImplDeleteFederation,
        .listAuditEventsFn = notImplListAuditEvents,
        .createProtocolMapperFn = notImplCreateProtocolMapper,
        .toggleRealmFn = notImplToggleRealm,
        .deleteRealmFn = notImplDeleteRealm,
        .updateClientFn = notImplUpdateClient,
        .updateRealmFrontendUrlFn = notImplUpdateRealmFrontendUrl,
        .checkRealmExistsFn = checkRealmPresentFn,
    };
    return provider_manager.Manager{
        .provider = provider,
        .auth_mode = .local_only,
        .expected_audience = "",
        .expected_issuer = null,
    };
}

/// Insert a completed onboarding_registry row using a committed connection.
/// The caller is responsible for cleanup via deleteOnboardingRow.
fn insertCompletedOnboardingRow(
    alloc: std.mem.Allocator,
    pool: *pool_mod.Pool,
    onboarding_id: []const u8,
    idempotency_key: []const u8,
    idp_realm_id: []const u8,
) !void {
    const response_body = try std.fmt.allocPrint(
        alloc,
        \\{{"state":"completed","idp_realm_id":"{s}","slug":"test-slug","onboarding_id":"{s}"}}
    ,
        .{ idp_realm_id, onboarding_id },
    );
    defer alloc.free(response_body);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO onboarding_registry
        \\  (onboarding_id, idempotency_key, request_hash, tenant_id, hostname,
        \\   response_status, response_body, state, completed_at)
        \\VALUES
        \\  ($1::uuid, $2, '\\x00'::bytea, NULL, 'iss0071-test.example.com',
        \\   201, $3::jsonb, 'completed', NOW())
    ,
        &[_][]const u8{ onboarding_id, idempotency_key, response_body },
    );
}

/// Insert a failed onboarding_registry row using a committed connection.
fn insertFailedOnboardingRow(
    alloc: std.mem.Allocator,
    pool: *pool_mod.Pool,
    onboarding_id: []const u8,
    idempotency_key: []const u8,
) !void {
    _ = alloc;
    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO onboarding_registry
        \\  (onboarding_id, idempotency_key, request_hash, tenant_id, hostname,
        \\   response_status, response_body, state, completed_at)
        \\VALUES
        \\  ($1::uuid, $2, '\\x00'::bytea, NULL, 'iss0071-failed.example.com',
        \\   422, '{"state":"failed","error":"prior_error"}'::jsonb, 'failed', NOW())
    ,
        &[_][]const u8{ onboarding_id, idempotency_key },
    );
}

/// Delete an onboarding_registry row by onboarding_id. Called in defer blocks.
fn deleteOnboardingRow(pool: *pool_mod.Pool, onboarding_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM onboarding_registry WHERE onboarding_id = $1::uuid",
        &[_][]const u8{onboarding_id},
    ) catch {};
}

/// Read back the state column of an onboarding_registry row.
/// Returns a heap-allocated string that the caller must free.
fn readOnboardingState(
    alloc: std.mem.Allocator,
    pool: *pool_mod.Pool,
    onboarding_id: []const u8,
) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = try conn.queryRow(
        alloc,
        "SELECT state FROM onboarding_registry WHERE onboarding_id = $1::uuid LIMIT 1",
        &[_][]const u8{onboarding_id},
    );
    const row_val = row orelse return error.TestUnexpectedResult;
    defer {
        for (row_val) |col| {
            if (col) |c| alloc.free(c);
        }
        alloc.free(row_val);
    }
    const state_raw = row_val[0] orelse return error.TestUnexpectedResult;
    return alloc.dupe(u8, state_raw);
}

// ── Test cases ────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS0071-01: realm missing → handleGetOnboarding transitions state to failed
// ─────────────────────────────────────────────────────────────────────────────

test "TC-ISS0071-01: realm missing guard transitions state to failed and response has error=realm_missing" {
    const alloc = testing.allocator;

    // Route pool connections to tenant_default schema (where onboarding_registry lives).
    tenant_ctx.set(tenant_ctx.DEFAULT_TENANT_ID);
    tenant_ctx.setStorageMode(.SCHEMA);
    defer tenant_ctx.clear();

    const db_url = try testDbUrl(alloc);
    defer alloc.free(db_url);

    var pool = try makePool(alloc, db_url);
    defer pool.deinit();

    // Per-test UUIDs.
    const onboarding_id = try generateUuidHex(alloc);
    defer alloc.free(onboarding_id);
    const idempotency_key = try generateUuidHex(alloc);
    defer alloc.free(idempotency_key);
    const realm_id = "iss0071-missing-realm-01";

    // Insert committed row with state='completed' and idp_realm_id in response_body.
    try insertCompletedOnboardingRow(alloc, &pool, onboarding_id, idempotency_key, realm_id);
    defer deleteOnboardingRow(&pool, onboarding_id);

    // Build service and manager.
    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);
    const manager = makeMissingRealmManager();

    // Call the handler — the missing-realm guard should fire.
    const result = onboarding_routes.handleGetOnboarding(
        &service,
        manager,
        alloc,
        adminActor(),
        onboarding_id,
    );
    defer freeBody(alloc, result.body);

    // Response: 200 with state=failed, error=realm_missing.
    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "realm_missing"));
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "failed"));

    // DB row must now be state='failed'.
    const db_state = try readOnboardingState(alloc, &pool, onboarding_id);
    defer alloc.free(db_state);
    try testing.expectEqualStrings("failed", db_state);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS0071-02: realm present → handleGetOnboarding returns stored body unchanged
// ─────────────────────────────────────────────────────────────────────────────

test "TC-ISS0071-02: realm present leaves state=completed and returns stored body unchanged" {
    const alloc = testing.allocator;

    // Route pool connections to tenant_default schema.
    tenant_ctx.set(tenant_ctx.DEFAULT_TENANT_ID);
    tenant_ctx.setStorageMode(.SCHEMA);
    defer tenant_ctx.clear();

    const db_url = try testDbUrl(alloc);
    defer alloc.free(db_url);

    var pool = try makePool(alloc, db_url);
    defer pool.deinit();

    // Per-test UUIDs.
    const onboarding_id = try generateUuidHex(alloc);
    defer alloc.free(onboarding_id);
    const idempotency_key = try generateUuidHex(alloc);
    defer alloc.free(idempotency_key);
    const realm_id = "iss0071-present-realm-02";

    // Insert committed row with state='completed'.
    try insertCompletedOnboardingRow(alloc, &pool, onboarding_id, idempotency_key, realm_id);
    defer deleteOnboardingRow(&pool, onboarding_id);

    // Build service and manager (realm exists → true via presentRealmManager).
    var registry = identity_registry.Registry.init(&pool);
    var service = identity_service.Service.init(&registry);
    const manager = makePresentRealmManager();

    // Call the handler — guard must not fire because realm exists.
    const result = onboarding_routes.handleGetOnboarding(
        &service,
        manager,
        alloc,
        adminActor(),
        onboarding_id,
    );
    defer freeBody(alloc, result.body);

    // Response: 200 with state=completed (no realm_missing transition).
    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "completed"));
    try testing.expect(!std.mem.containsAtLeast(u8, result.body, 1, "realm_missing"));

    // DB row must still be state='completed'.
    const db_state = try readOnboardingState(alloc, &pool, onboarding_id);
    defer alloc.free(db_state);
    try testing.expectEqualStrings("completed", db_state);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS0071-03: markOnboardingRealmMissing idempotency — WHERE state='completed'
//               guard prevents update when row is already state='failed'
// ─────────────────────────────────────────────────────────────────────────────

test "TC-ISS0071-03: realm missing guard is idempotent — already-failed row is not modified" {
    const alloc = testing.allocator;

    // Route pool connections to tenant_default schema.
    tenant_ctx.set(tenant_ctx.DEFAULT_TENANT_ID);
    tenant_ctx.setStorageMode(.SCHEMA);
    defer tenant_ctx.clear();

    const db_url = try testDbUrl(alloc);
    defer alloc.free(db_url);

    var pool = try makePool(alloc, db_url);
    defer pool.deinit();

    // Per-test UUIDs.
    const onboarding_id = try generateUuidHex(alloc);
    defer alloc.free(onboarding_id);
    const idempotency_key = try generateUuidHex(alloc);
    defer alloc.free(idempotency_key);

    // Insert a row already in state='failed' (prior onboarding failure).
    try insertFailedOnboardingRow(alloc, &pool, onboarding_id, idempotency_key);
    defer deleteOnboardingRow(&pool, onboarding_id);

    // Execute the exact UPDATE that markOnboardingRealmMissing runs.
    // The WHERE state='completed' clause must prevent it from matching.
    const conn = try pool.acquire();
    defer pool.release(conn);

    const update_row = conn.queryRow(
        alloc,
        \\UPDATE onboarding_registry
        \\SET state         = 'failed',
        \\    response_body = (COALESCE(response_body, '{}'::jsonb)
        \\                     || '{"state":"failed","error":"realm_missing"}'::jsonb),
        \\    completed_at  = NOW()
        \\WHERE onboarding_id = $1::uuid
        \\  AND state = 'completed'
        \\RETURNING id::text
    ,
        &[_][]const u8{onboarding_id},
    ) catch null;

    // No row should be returned — the WHERE clause filtered it out.
    try testing.expect(update_row == null);

    // Verify the row still has its original prior_error (not realm_missing).
    const check_conn = try pool.acquire();
    defer pool.release(check_conn);

    const check_row = try check_conn.queryRow(
        alloc,
        "SELECT state, response_body::text FROM onboarding_registry WHERE onboarding_id = $1::uuid LIMIT 1",
        &[_][]const u8{onboarding_id},
    );
    const check_row_val = check_row orelse return error.TestUnexpectedResult;
    // Capture column values before the defer frees them.
    const db_state = try alloc.dupe(u8, check_row_val[0] orelse return error.TestUnexpectedResult);
    defer alloc.free(db_state);
    const db_body = try alloc.dupe(u8, check_row_val[1] orelse return error.TestUnexpectedResult);
    defer alloc.free(db_body);
    // Free the queryRow-allocated row and column strings.
    for (check_row_val) |col| {
        if (col) |c| alloc.free(c);
    }
    alloc.free(check_row_val);

    try testing.expectEqualStrings("failed", db_state);
    // Body must still contain the original error, not realm_missing.
    try testing.expect(std.mem.containsAtLeast(u8, db_body, 1, "prior_error"));
    try testing.expect(!std.mem.containsAtLeast(u8, db_body, 1, "realm_missing"));
}
