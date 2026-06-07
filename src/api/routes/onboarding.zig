const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const auth = @import("../middleware/auth.zig");
const identity_service = @import("../../identity/service.zig");
const onboarding_mod = @import("../../identity/onboarding.zig");
const pool_mod = @import("pool");
const errors = @import("../errors.zig");

/// Fill buf with cryptographically secure random bytes (platform-aware, thread-safe).
fn fillRandom(buf: []u8) void {
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        else => {
            // Fallback: use timestamp + address mix for entropy
            const ts: u64 = @truncate(@as(u128, @intCast(std.time.nanoTimestamp())));
            const addr: u64 = @truncate(@intFromPtr(buf.ptr));
            var prng = std.Random.DefaultPrng.init(ts ^ addr);
            prng.random().bytes(buf);
        },
    }
}

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

const CompletionChecks = struct {
    tenant_visible: bool,
    oidc_authority_ready: bool,
    schema_materialized: bool,
};

const ParsedOnboardingBody = struct {
    tenant_id: ?[]u8 = null,
    slug: ?[]u8 = null,
    hostname: ?[]u8 = null,
    oidc_authority: ?[]u8 = null,
    failure_reason: ?[]u8 = null,

    fn deinit(self: *ParsedOnboardingBody, allocator: std.mem.Allocator) void {
        if (self.tenant_id) |v| allocator.free(v);
        if (self.slug) |v| allocator.free(v);
        if (self.hostname) |v| allocator.free(v);
        if (self.oidc_authority) |v| allocator.free(v);
        if (self.failure_reason) |v| allocator.free(v);
    }
};

// Allow enough time for real Keycloak + schema provisioning while still
// terminalizing genuinely stale pending rows.
const onboarding_pending_timeout_seconds_param = "240";

fn evaluateCompletionGate(checks: CompletionChecks) bool {
    return checks.tenant_visible and checks.oidc_authority_ready and checks.schema_materialized;
}

fn parseOnboardingBody(allocator: std.mem.Allocator, body: []const u8) !ParsedOnboardingBody {
    var out = ParsedOnboardingBody{};

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch {
        return out;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return out;
    const obj = parsed.value.object;

    if (obj.get("tenant_id")) |value| {
        if (value == .string and value.string.len > 0) {
            out.tenant_id = try allocator.dupe(u8, value.string);
        }
    }
    if (obj.get("slug")) |value| {
        if (value == .string and value.string.len > 0) {
            out.slug = try allocator.dupe(u8, value.string);
        }
    }
    if (obj.get("hostname")) |value| {
        if (value == .string and value.string.len > 0) {
            out.hostname = try allocator.dupe(u8, value.string);
        }
    }
    if (obj.get("oidc_authority")) |value| {
        if (value == .string and value.string.len > 0) {
            out.oidc_authority = try allocator.dupe(u8, value.string);
        }
    }
    if (obj.get("error")) |value| {
        if (value == .string and value.string.len > 0) {
            out.failure_reason = try allocator.dupe(u8, value.string);
        }
    }

    return out;
}

fn verifyTenantVisibility(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_slug: []const u8,
    expected_hostname: []const u8,
    expected_realm_id: []const u8,
) !bool {
    const conn = pool.acquire() catch return false;
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT t.id::text
        \\FROM tenant t
        \\JOIN tenant_hostnames th ON th.tenant_id = t.id
        \\WHERE t.slug = $1 AND t.idp_realm_id = $2 AND th.hostname = $3
        \\LIMIT 1
    ,
        &[_][]const u8{ tenant_slug, expected_realm_id, expected_hostname },
    ) catch return false;

    if (row) |v| {
        defer freeRow(allocator, v);
        return true;
    }
    return false;
}

fn verifyOidcAuthorityReadiness(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_slug: []const u8,
    tenant_id: []const u8,
    authority: []const u8,
) !bool {
    const uri = std.Uri.parse(authority) catch return false;
    if (!std.mem.endsWith(u8, uri.path.percent_encoded, tenant_slug)) return false;

    const conn = pool.acquire() catch return false;
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT id::text
        \\FROM tenant
        \\WHERE slug = $1 AND id::text = $2 AND idp_realm_id = $1
        \\LIMIT 1
    ,
        &[_][]const u8{ tenant_slug, tenant_id },
    ) catch return false;

    if (row) |v| {
        defer freeRow(allocator, v);
        return true;
    }
    return false;
}

fn verifySchemaMaterialization(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
) !bool {
    const conn = pool.acquire() catch return false;
    defer pool.release(conn);

    const registry_row = conn.queryRow(
        allocator,
        \\SELECT COALESCE((migrations_applied_at IS NOT NULL)::int, 0)::text
        \\FROM public.tenant_schemas
        \\WHERE tenant_id = $1::uuid
        \\LIMIT 1
    ,
        &[_][]const u8{tenant_id},
    ) catch return false;

    if (registry_row == null) return false;
    defer freeRow(allocator, registry_row.?);
    if (!std.mem.eql(u8, registry_row.?[0] orelse "0", "1")) return false;

    const expected_row = conn.queryRow(
        allocator,
        "SELECT COUNT(*)::text FROM public.schema_migrations WHERE schema_name = 'public'",
        &[_][]const u8{},
    ) catch return false;
    if (expected_row == null) return false;
    defer freeRow(allocator, expected_row.?);

    const expected_count = std.fmt.parseInt(u32, expected_row.?[0] orelse "0", 10) catch return false;
    if (expected_count == 0) return false;

    var schema_buf: [80]u8 = undefined;
    const schema_name = pool_mod.schemaNameForTenant(tenant_id, &schema_buf);
    const sql = try std.fmt.allocPrint(allocator, "SELECT COUNT(*)::text FROM {s}.schema_migrations", .{schema_name});
    defer allocator.free(sql);

    const actual_row = conn.queryRow(
        allocator,
        sql,
        &[_][]const u8{},
    ) catch return false;
    if (actual_row == null) return false;
    defer freeRow(allocator, actual_row.?);

    const actual_count = std.fmt.parseInt(u32, actual_row.?[0] orelse "0", 10) catch return false;
    return actual_count >= expected_count;
}

fn deriveCompletionChecks(
    allocator: std.mem.Allocator,
    service: *identity_service.Service,
    record: *const onboarding_mod.OnboardingRecord,
    parsed: *const ParsedOnboardingBody,
) CompletionChecks {
    if (record.state != .completed) {
        return .{ .tenant_visible = false, .oidc_authority_ready = false, .schema_materialized = false };
    }

    const tenant_slug = parsed.slug orelse return .{ .tenant_visible = false, .oidc_authority_ready = false, .schema_materialized = false };
    const tenant_id = parsed.tenant_id orelse return .{ .tenant_visible = false, .oidc_authority_ready = false, .schema_materialized = false };
    const hostname = parsed.hostname orelse return .{ .tenant_visible = false, .oidc_authority_ready = false, .schema_materialized = false };
    const oidc_authority = parsed.oidc_authority orelse return .{ .tenant_visible = false, .oidc_authority_ready = false, .schema_materialized = false };

    const tenant_visible = verifyTenantVisibility(
        allocator,
        service.registry.pool,
        tenant_slug,
        hostname,
        tenant_slug,
    ) catch false;

    const oidc_authority_ready = verifyOidcAuthorityReadiness(
        allocator,
        service.registry.pool,
        tenant_slug,
        tenant_id,
        oidc_authority,
    ) catch false;

    const schema_materialized = verifySchemaMaterialization(
        allocator,
        service.registry.pool,
        tenant_id,
    ) catch false;

    return .{
        .tenant_visible = tenant_visible,
        .oidc_authority_ready = oidc_authority_ready,
        .schema_materialized = schema_materialized,
    };
}

fn appendNullableJsonStr(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), v: ?[]const u8) !void {
    if (v) |value| {
        try appendJsonStr(allocator, buf, value);
        return;
    }
    try buf.appendSlice(allocator, "null");
}

fn buildOnboardingStatusResponse(
    allocator: std.mem.Allocator,
    service: *identity_service.Service,
    record: *const onboarding_mod.OnboardingRecord,
) ![]u8 {
    var parsed = try parseOnboardingBody(allocator, record.response_body_json);
    defer parsed.deinit(allocator);

    const checks = deriveCompletionChecks(allocator, service, record, &parsed);
    const gate_satisfied = evaluateCompletionGate(checks);

    const status: []const u8 = switch (record.state) {
        .pending => "in_progress",
        .failed => "failed",
        .completed => if (gate_satisfied) "completed" else "failed",
    };

    const state: []const u8 = if (std.mem.eql(u8, status, "completed"))
        "completed"
    else if (std.mem.eql(u8, status, "failed"))
        "failed"
    else
        "pending";

    const failure_reason: ?[]const u8 = if (std.mem.eql(u8, status, "failed"))
        (parsed.failure_reason orelse if (!gate_satisfied) "onboarding_completion_checks_incomplete" else "onboarding_failed")
    else
        null;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"onboarding_id\":");
    try appendJsonStr(allocator, &buf, record.onboarding_id);

    try buf.appendSlice(allocator, ",\"status\":");
    try appendJsonStr(allocator, &buf, status);

    try buf.appendSlice(allocator, ",\"state\":");
    try appendJsonStr(allocator, &buf, state);

    try buf.appendSlice(allocator, ",\"slug\":");
    try appendNullableJsonStr(allocator, &buf, parsed.slug);

    try buf.appendSlice(allocator, ",\"hostname\":");
    try appendNullableJsonStr(allocator, &buf, parsed.hostname);

    try buf.appendSlice(allocator, ",\"oidc_authority\":");
    try appendNullableJsonStr(allocator, &buf, parsed.oidc_authority);

    try buf.appendSlice(allocator, ",\"tenant_visible\":");
    try buf.appendSlice(allocator, if (checks.tenant_visible) "true" else "false");

    try buf.appendSlice(allocator, ",\"oidc_authority_ready\":");
    try buf.appendSlice(allocator, if (checks.oidc_authority_ready) "true" else "false");

    try buf.appendSlice(allocator, ",\"schema_materialized\":");
    try buf.appendSlice(allocator, if (checks.schema_materialized) "true" else "false");

    try buf.appendSlice(allocator, ",\"failure_reason\":");
    try appendNullableJsonStr(allocator, &buf, failure_reason);

    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

// ── POST /api/v1/onboarding ───────────────────────────────────────────────────

pub fn handleOnboarding(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    body: []const u8,
    idempotency_key: []const u8,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN) {
        return errorResult(allocator, 403, "forbidden");
    }

    // Validate idempotency key presence.
    if (idempotency_key.len == 0) {
        return errorResult(allocator, 422, "idempotency_key_required");
    }

    // Parse and validate input.
    var input = parseOnboardingInput(allocator, body) catch |err| switch (err) {
        error.ValidationFailed => return errorResult(allocator, 422, "validation_failed"),
        error.OutOfMemory => return errorResult(allocator, 500, "internal_error"),
        else => return errorResult(allocator, 422, "validation_failed"),
    };
    defer input.deinit(allocator);

    // Compute request hash for idempotency.
    const request_hash = onboarding_mod.computeRequestHash(allocator, body) catch
        return errorResult(allocator, 500, "internal_error");
    defer allocator.free(request_hash);

    // Try to insert idempotency record.
    const idempotency_result = tryClaimIdempotencyKey(
        allocator,
        service.registry.pool,
        idempotency_key,
        request_hash,
        &input.value,
    ) catch |err| switch (err) {
        onboarding_mod.OnboardingError.IdempotencyConflict => {
            const detail = std.fmt.allocPrint(
                allocator,
                "Idempotency key '{s}' was used with a different request body",
                .{idempotency_key},
            ) catch return errorResult(allocator, 500, "internal_error");
            defer allocator.free(detail);
            const pd = errors.ProblemDetails{
                .type = "https://bpm.example.com/problems/idempotency-conflict",
                .title = "Idempotency Conflict",
                .status = 409,
                .detail = detail,
            };
            const pd_body = errors.serialise(allocator, pd) catch
                return errorResult(allocator, 500, "internal_error");
            return .{ .status_code = 409, .body = pd_body };
        },
        onboarding_mod.OnboardingError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        onboarding_mod.OnboardingError.PersistenceFailed => return errorResult(allocator, 500, "internal_error"),
        onboarding_mod.OnboardingError.OutOfMemory => return errorResult(allocator, 500, "internal_error"),
        else => return errorResult(allocator, 500, "internal_error"),
    };

    switch (idempotency_result) {
        .duplicate => |record| {
            // Idempotent replay: return cached response.
            if (record.state == .pending) {
                // Include onboarding_id so the frontend can navigate to the progress screen.
                const in_progress_body = std.fmt.allocPrint(
                    allocator,
                    "{{\"error\":\"onboarding_in_progress\",\"onboarding_id\":\"{s}\"}}",
                    .{record.onboarding_id},
                ) catch return errorResult(allocator, 500, "internal_error");
                return .{ .status_code = 409, .body = in_progress_body };
            }
            const cached_body = allocator.dupe(u8, record.response_body_json) catch
                return errorResult(allocator, 500, "internal_error");
            return .{ .status_code = record.response_status, .body = cached_body };
        },
        .fresh => |onboarding_id| {
            // Fresh request: spawn the saga in a background thread and return 201
            // immediately with the onboarding_id. The frontend polls GET
            // /api/v1/onboarding/:id until state changes from 'pending' to
            // 'completed' or 'failed'.
            //
            // Memory: all saga data is duplicated onto the global smp_allocator so
            // it survives after the request arena is freed. The background thread
            // owns and frees this memory.
            const gpa = std.heap.smp_allocator;
            const saga_ctx = gpa.create(SagaContext) catch {
                return errorResult(allocator, 500, "internal_error");
            };
            saga_ctx.* = SagaContext{
                .pool = service.registry.pool,
                .manager = auth.getIdentityProviderManager(),
                .onboarding_id = gpa.dupe(u8, onboarding_id) catch {
                    gpa.destroy(saga_ctx);
                    return errorResult(allocator, 500, "internal_error");
                },
                .input = dupeOnboardingInput(gpa, input.value) catch {
                    gpa.free(saga_ctx.onboarding_id);
                    gpa.destroy(saga_ctx);
                    return errorResult(allocator, 500, "internal_error");
                },
                .migrations_dir = build_options.migrations_dir,
            };

            const thread = std.Thread.spawn(.{}, runSagaBackground, .{saga_ctx}) catch {
                // Cleanup and fall back to synchronous execution on thread spawn failure.
                freeOnboardingInput(gpa, saga_ctx.input);
                gpa.free(saga_ctx.onboarding_id);
                gpa.destroy(saga_ctx);
                return errorResult(allocator, 500, "internal_error");
            };
            thread.detach();

            // Return 201 immediately — the frontend will poll GET for status.
            const pending_body = std.fmt.allocPrint(allocator,
                "{{\"onboarding_id\":\"{s}\"}}",
                .{onboarding_id},
            ) catch return errorResult(allocator, 500, "internal_error");
            return .{ .status_code = 201, .body = pending_body };
        },
    }
}

// ── Background saga ────────────────────────────────────────────────────────────

const identity_provider = @import("identity_provider");

const SagaContext = struct {
    pool: *pool_mod.Pool,
    manager: identity_provider.manager.Manager,
    onboarding_id: []u8,
    input: onboarding_mod.OnboardingInput,
    migrations_dir: []const u8,
};

fn dupeOnboardingInput(
    allocator: std.mem.Allocator,
    src: onboarding_mod.OnboardingInput,
) !onboarding_mod.OnboardingInput {
    // Dupe optional nested string slices so they remain valid after the request
    // arena (which owns the original pointers) is freed.
    const realm_config: ?onboarding_mod.RealmConfigOverrides = if (src.realm_config) |rc| blk: {
        break :blk onboarding_mod.RealmConfigOverrides{
            .default_token_lifetime_seconds = rc.default_token_lifetime_seconds,
            .min_password_length            = rc.min_password_length,
            .require_uppercase              = rc.require_uppercase,
            .require_digit                  = rc.require_digit,
            .signing_key_algorithm          = if (rc.signing_key_algorithm) |s|
                try allocator.dupe(u8, s)
            else null,
        };
    } else null;

    const client_config: ?onboarding_mod.ClientConfigOverrides = if (src.client_config) |cc| blk: {
        const duped_uris: ?[]const []const u8 = if (cc.redirect_uris) |uris| inner: {
            const out = try allocator.alloc([]const u8, uris.len);
            for (uris, 0..) |uri, i| {
                out[i] = try allocator.dupe(u8, uri);
            }
            break :inner out;
        } else null;
        break :blk onboarding_mod.ClientConfigOverrides{
            .redirect_uris           = duped_uris,
            .service_account_enabled = cc.service_account_enabled,
        };
    } else null;

    return onboarding_mod.OnboardingInput{
        .slug               = try allocator.dupe(u8, src.slug),
        .display_name       = try allocator.dupe(u8, src.display_name),
        .admin_email        = try allocator.dupe(u8, src.admin_email),
        .admin_username     = try allocator.dupe(u8, src.admin_username),
        .admin_display_name = try allocator.dupe(u8, src.admin_display_name),
        .hostname           = try allocator.dupe(u8, src.hostname),
        .realm_config       = realm_config,
        .client_config      = client_config,
    };
}

fn freeOnboardingInput(allocator: std.mem.Allocator, input: onboarding_mod.OnboardingInput) void {
    allocator.free(input.slug);
    allocator.free(input.display_name);
    allocator.free(input.admin_email);
    allocator.free(input.admin_username);
    allocator.free(input.admin_display_name);
    allocator.free(input.hostname);
    if (input.realm_config) |rc| {
        if (rc.signing_key_algorithm) |s| allocator.free(s);
    }
    if (input.client_config) |cc| {
        if (cc.redirect_uris) |uris| {
            for (uris) |uri| allocator.free(uri);
            allocator.free(uris);
        }
    }
}

fn runSagaBackground(ctx: *SagaContext) void {
    const gpa = std.heap.smp_allocator;
    defer {
        freeOnboardingInput(gpa, ctx.input);
        gpa.free(ctx.onboarding_id);
        gpa.destroy(ctx);
    }

    const result = onboarding_mod.executeSaga(
        gpa,
        ctx.manager,
        ctx.pool,
        ctx.input,
        ctx.onboarding_id,
        ctx.migrations_dir,
    ) catch |err| {
        const err_status: u16 = onboardingErrorToStatus(err);
        const err_body = if (err == onboarding_mod.OnboardingError.ValidationFailed)
            "{\"state\":\"failed\",\"error\":\"validation_failed\"}"
        else
            "{\"state\":\"failed\",\"error\":\"onboarding_failed\"}";
        persistOnboardingResult(ctx.pool, ctx.onboarding_id, err_status, err_body, .failed) catch {};
        return;
    };
    defer result.deinit(gpa);

    const json_body = serializeOnboardingResult(gpa, &result) catch return;
    defer gpa.free(json_body);

    persistOnboardingResult(ctx.pool, ctx.onboarding_id, 201, json_body, .completed) catch {};
}

// ── GET /api/v1/onboarding/:onboarding_id ─────────────────────────────────────

pub fn handleGetOnboarding(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    onboarding_id: []const u8,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN) {
        return errorResult(allocator, 403, "forbidden");
    }

    const record = selectOnboardingById(allocator, service.registry.pool, onboarding_id) catch |err| switch (err) {
        onboarding_mod.OnboardingError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        onboarding_mod.OnboardingError.PersistenceFailed => return errorResult(allocator, 500, "internal_error"),
        onboarding_mod.OnboardingError.OutOfMemory => return errorResult(allocator, 500, "internal_error"),
        else => return errorResult(allocator, 500, "internal_error"),
    };

    const record_val = record orelse {
        const pd = errors.problemNotFound("Onboarding record not found");
        const pd_body = errors.serialise(allocator, pd) catch
            return errorResult(allocator, 500, "internal_error");
        return .{ .status_code = 404, .body = pd_body };
    };
    defer record_val.deinit(allocator);

    const body = buildOnboardingStatusResponse(allocator, service, &record_val) catch
        return errorResult(allocator, 500, "internal_error");
    return .{ .status_code = 200, .body = body };
}

// ── GET /api/v1/onboarding?hostname={hostname} ────────────────────────────────

pub fn handleGetOnboardingByHostname(
    service: *identity_service.Service,
    allocator: std.mem.Allocator,
    actor: auth.AuthContext,
    hostname: []const u8,
) HandlerResult {
    if (actor.role != .PLATFORM_ADMIN) {
        return errorResult(allocator, 403, "forbidden");
    }

    if (hostname.len == 0) {
        return errorResult(allocator, 422, "hostname_required");
    }

    const record = selectOnboardingByHostname(allocator, service.registry.pool, hostname) catch |err| switch (err) {
        onboarding_mod.OnboardingError.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        onboarding_mod.OnboardingError.PersistenceFailed => return errorResult(allocator, 500, "internal_error"),
        onboarding_mod.OnboardingError.OutOfMemory => return errorResult(allocator, 500, "internal_error"),
        else => return errorResult(allocator, 500, "internal_error"),
    };

    const record_val = record orelse {
        const pd = errors.problemNotFound("Onboarding record not found");
        const pd_body = errors.serialise(allocator, pd) catch
            return errorResult(allocator, 500, "internal_error");
        return .{ .status_code = 404, .body = pd_body };
    };
    defer record_val.deinit(allocator);

    const body = buildOnboardingStatusResponse(allocator, service, &record_val) catch
        return errorResult(allocator, 500, "internal_error");
    return .{ .status_code = 200, .body = body };
}

// ── Idempotency helpers ───────────────────────────────────────────────────────

const IdempotencyResult = union(enum) {
    duplicate: onboarding_mod.OnboardingRecord,
    fresh: []const u8, // onboarding_id
};

fn tryClaimIdempotencyKey(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    key: []const u8,
    request_hash: []const u8,
    input: *const onboarding_mod.OnboardingInput,
) (onboarding_mod.OnboardingError)!IdempotencyResult {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    // Try to insert with ON CONFLICT DO NOTHING.
    const onboarding_id = try generateUuidHex(allocator);
    errdefer allocator.free(onboarding_id);

    const hostname = input.hostname;

    // Hex-encode the raw hash bytes so they can be passed as a text parameter
    // and decoded to bytea via decode($3, 'hex').  Passing raw binary as a
    // text parameter fails because PostgreSQL's text-format bytea parser
    // expects hex-escape notation, not arbitrary binary.
    const request_hash_hex = try allocator.alloc(u8, request_hash.len * 2);
    errdefer allocator.free(request_hash_hex);
    {
        const hex_chars = "0123456789abcdef";
        for (request_hash, 0..) |byte, idx| {
            request_hash_hex[idx * 2] = hex_chars[byte >> 4];
            request_hash_hex[idx * 2 + 1] = hex_chars[byte & 0xf];
        }
    }

    const insert_row = conn.queryRow(
        allocator,
        \\INSERT INTO onboarding_registry (onboarding_id, idempotency_key, request_hash, tenant_id, hostname, state, response_body)
        \\VALUES ($1::uuid, $2, decode($3, 'hex'), NULL, $4, 'pending', '{"state":"pending"}'::jsonb)
        \\ON CONFLICT (idempotency_key) DO NOTHING
        \\RETURNING id::text
    ,
        &[_][]const u8{ onboarding_id, key, request_hash_hex, hostname },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };

    if (insert_row != null) {
        defer freeRow(allocator, insert_row.?);
        return IdempotencyResult{ .fresh = onboarding_id };
    }

    // Key already exists — fetch the record.
    const existing_row = conn.queryRow(
        allocator,
        \\SELECT onboarding_id::text,
        \\       idempotency_key,
        \\       encode(request_hash, 'hex'),
        \\       response_status,
        \\       CASE
        \\           WHEN state = 'pending' AND created_at < (NOW() - make_interval(secs => $2::int))
        \\               THEN '{"state":"failed","error":"onboarding_timeout"}'::jsonb
        \\           ELSE COALESCE(response_body, '{}'::jsonb)
        \\       END::text,
        \\       CASE
        \\           WHEN state = 'pending' AND created_at < (NOW() - make_interval(secs => $2::int))
        \\               THEN 'failed'
        \\           ELSE state
        \\       END,
        \\       created_at::text,
        \\       completed_at::text
        \\FROM onboarding_registry
        \\WHERE idempotency_key = $1
        \\LIMIT 1
    ,
        &[_][]const u8{ key, onboarding_pending_timeout_seconds_param },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };

    if (existing_row == null) return error.PersistenceFailed;
    defer freeRow(allocator, existing_row.?);

    const stored_hash_hex = existing_row.?[2] orelse return error.PersistenceFailed;

    // Compare request hashes — if different, it's an idempotency conflict.
    // request_hash_hex was computed above for the INSERT; reuse it here.
    if (!std.mem.eql(u8, stored_hash_hex, request_hash_hex)) {
        return error.IdempotencyConflict;
    }

    const onboarding_id_str = existing_row.?[0] orelse return error.PersistenceFailed;
    const key_str = existing_row.?[1] orelse return error.PersistenceFailed;
    const state_str = existing_row.?[5] orelse "pending";
    const state = onboarding_mod.OnboardingState.fromString(state_str) orelse .pending;
    const response_status = std.fmt.parseInt(u16, existing_row.?[3] orelse "200", 10) catch 200;
    const response_body = existing_row.?[4] orelse "{}";
    const created_at = existing_row.?[6] orelse "";
    const completed_at_str = existing_row.?[7];

    return IdempotencyResult{
        .duplicate = onboarding_mod.OnboardingRecord{
            .onboarding_id = try allocator.dupe(u8, onboarding_id_str),
            .idempotency_key = try allocator.dupe(u8, key_str),
            .tenant_id = try allocator.dupe(u8, ""),
            .request_hash = try allocator.dupe(u8, stored_hash_hex),
            .response_status = response_status,
            .response_body_json = try allocator.dupe(u8, response_body),
            .state = state,
            .created_at = try allocator.dupe(u8, created_at),
            .completed_at = if (completed_at_str) |v| try allocator.dupe(u8, v) else null,
        },
    };
}

fn persistOnboardingResult(
    pool: *pool_mod.Pool,
    onboarding_id: []const u8,
    status: u16,
    body_json: []const u8,
    state: onboarding_mod.OnboardingState,
) !void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    const status_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{status});
    defer std.heap.page_allocator.free(status_str);

    _ = conn.queryRow(
        std.heap.page_allocator,
        \\UPDATE onboarding_registry
        \\SET response_status = $2::smallint, response_body = $3::jsonb, state = $4, completed_at = NOW()
        \\WHERE onboarding_id = $1::uuid
        \\RETURNING id::text
    ,
        &[_][]const u8{ onboarding_id, status_str, body_json, state.asString() },
    ) catch {};
}

// ── Query helpers ─────────────────────────────────────────────────────────────

fn selectOnboardingById(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    onboarding_id: []const u8,
) (onboarding_mod.OnboardingError)!?onboarding_mod.OnboardingRecord {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT onboarding_id::text,
        \\       idempotency_key,
        \\       ''::text,
        \\       encode(request_hash, 'hex'),
        \\       response_status,
        \\       CASE
        \\           WHEN state = 'pending' AND created_at < (NOW() - make_interval(secs => $2::int))
        \\               THEN '{"state":"failed","error":"onboarding_timeout"}'::jsonb
        \\           ELSE COALESCE(response_body, '{}'::jsonb)
        \\       END::text,
        \\       CASE
        \\           WHEN state = 'pending' AND created_at < (NOW() - make_interval(secs => $2::int))
        \\               THEN 'failed'
        \\           ELSE state
        \\       END,
        \\       created_at::text,
        \\       completed_at::text
        \\FROM onboarding_registry
        \\WHERE onboarding_id = $1::uuid
        \\LIMIT 1
    ,
        &[_][]const u8{ onboarding_id, onboarding_pending_timeout_seconds_param },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };

    if (row == null) return null;
    defer freeRow(allocator, row.?);

    const record = materializeOnboardingRecord(allocator, row.?) catch |err| return switch (err) {
        onboarding_mod.OnboardingError.PersistenceFailed => error.PersistenceFailed,
        onboarding_mod.OnboardingError.OutOfMemory => error.OutOfMemory,
        else => error.PersistenceFailed,
    };
    return record;
}

fn selectOnboardingByHostname(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    hostname: []const u8,
) (onboarding_mod.OnboardingError)!?onboarding_mod.OnboardingRecord {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT onboarding_id::text,
        \\       idempotency_key,
        \\       ''::text,
        \\       encode(request_hash, 'hex'),
        \\       response_status,
        \\       CASE
        \\           WHEN state = 'pending' AND created_at < (NOW() - make_interval(secs => $2::int))
        \\               THEN '{"state":"failed","error":"onboarding_timeout"}'::jsonb
        \\           ELSE COALESCE(response_body, '{}'::jsonb)
        \\       END::text,
        \\       CASE
        \\           WHEN state = 'pending' AND created_at < (NOW() - make_interval(secs => $2::int))
        \\               THEN 'failed'
        \\           ELSE state
        \\       END,
        \\       created_at::text,
        \\       completed_at::text
        \\FROM onboarding_registry
        \\WHERE hostname = $1
        \\  AND (
        \\      state IN ('completed', 'failed')
        \\      OR (state = 'pending' AND created_at < (NOW() - make_interval(secs => $2::int)))
        \\  )
        \\ORDER BY completed_at DESC NULLS LAST, created_at DESC
        \\LIMIT 1
    ,
        &[_][]const u8{ hostname, onboarding_pending_timeout_seconds_param },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };

    if (row == null) return null;
    defer freeRow(allocator, row.?);

    const record = materializeOnboardingRecord(allocator, row.?) catch |err| return switch (err) {
        onboarding_mod.OnboardingError.PersistenceFailed => error.PersistenceFailed,
        onboarding_mod.OnboardingError.OutOfMemory => error.OutOfMemory,
        else => error.PersistenceFailed,
    };
    return record;
}

fn materializeOnboardingRecord(
    allocator: std.mem.Allocator,
    row: []?[]u8,
) onboarding_mod.OnboardingError!onboarding_mod.OnboardingRecord {
    if (row.len < 9) return error.PersistenceFailed;
    const state_str = row[6] orelse "pending";
    const state = onboarding_mod.OnboardingState.fromString(state_str) orelse return error.PersistenceFailed;
    const response_status = std.fmt.parseInt(u16, row[4] orelse "200", 10) catch 200;

    return onboarding_mod.OnboardingRecord{
        .onboarding_id = try allocator.dupe(u8, row[0] orelse return error.PersistenceFailed),
        .idempotency_key = try allocator.dupe(u8, row[1] orelse ""),
        .tenant_id = try allocator.dupe(u8, row[2] orelse ""),
        .request_hash = try allocator.dupe(u8, row[3] orelse ""),
        .response_status = response_status,
        .response_body_json = try allocator.dupe(u8, row[5] orelse "{}"),
        .state = state,
        .created_at = try allocator.dupe(u8, row[7] orelse ""),
        .completed_at = if (row[8]) |v| try allocator.dupe(u8, v) else null,
    };
}

// ── Serialization ─────────────────────────────────────────────────────────────

fn serializeOnboardingResult(allocator: std.mem.Allocator, result: *const onboarding_mod.OnboardingResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Include "state":"completed" so the frontend polling check (result.state === 'completed') works.
    try buf.appendSlice(allocator, "{\"state\":\"completed\",\"onboarding_id\":");
    try appendJsonStr(allocator, &buf, result.onboarding_id);
    try buf.appendSlice(allocator, ",\"tenant_id\":");
    try appendJsonStr(allocator, &buf, result.tenant_id);
    try buf.appendSlice(allocator, ",\"idp_realm_id\":");
    try appendJsonStr(allocator, &buf, result.idp_realm_id);
    try buf.appendSlice(allocator, ",\"client_id\":");
    try appendJsonStr(allocator, &buf, result.client_id);
    try buf.appendSlice(allocator, ",\"admin_user_id\":");
    try appendJsonStr(allocator, &buf, result.admin_user_id);
    try buf.appendSlice(allocator, ",\"hostname\":");
    try appendJsonStr(allocator, &buf, result.hostname);
    try buf.appendSlice(allocator, ",\"oidc_authority\":");
    try appendJsonStr(allocator, &buf, result.oidc_authority);
    // slug is the same as idp_realm_id (the realm is created with the input slug).
    try buf.appendSlice(allocator, ",\"slug\":");
    try appendJsonStr(allocator, &buf, result.idp_realm_id);
    try buf.appendSlice(allocator, ",\"discovery_url\":");
    try appendJsonStr(allocator, &buf, result.discovery_url);
    try buf.appendSlice(allocator, ",\"created\":");
    try buf.appendSlice(allocator, if (result.created) "true" else "false");
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

fn appendJsonStr(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn generateUuidHex(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    // Use cryptographically secure random bytes (thread-safe, platform-aware).
    fillRandom(&raw);
    // Set UUID v4 bits
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    // Encode as hex string (no dashes, 32 chars)
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, 32);
    for (raw, 0..) |byte, idx| {
        out[idx * 2] = hex_chars[byte >> 4];
        out[idx * 2 + 1] = hex_chars[byte & 0xf];
    }
    return out;
}

// ── Input parsing ─────────────────────────────────────────────────────────────

const ParsedInput = struct {
    value: onboarding_mod.OnboardingInput,
    deinitFn: *const fn (*ParsedInput, std.mem.Allocator) void,

    pub fn deinit(self: *ParsedInput, allocator: std.mem.Allocator) void {
        self.deinitFn(self, allocator);
    }
};

fn parseOnboardingInput(allocator: std.mem.Allocator, body: []const u8) !ParsedInput {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    );
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.ValidationFailed;
    const obj = parsed.value.object;

    const slug = extractString(obj, "slug") orelse return error.ValidationFailed;
    const display_name = extractString(obj, "display_name") orelse return error.ValidationFailed;
    const admin_email = extractString(obj, "admin_email") orelse return error.ValidationFailed;
    const admin_username = extractString(obj, "admin_username") orelse return error.ValidationFailed;
    const admin_display_name = extractString(obj, "admin_display_name") orelse return error.ValidationFailed;
    const hostname = extractString(obj, "hostname") orelse return error.ValidationFailed;

    // Validate slug format: 3-63 lowercase alphanumeric or hyphens.
    if (slug.len < 3 or slug.len > 63) return error.ValidationFailed;
    for (slug) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return error.ValidationFailed;
        if (std.ascii.isUpper(c)) return error.ValidationFailed;
    }

    // Validate email contains @.
    if (std.mem.indexOfScalar(u8, admin_email, '@') == null) return error.ValidationFailed;

    // Validate hostname is non-empty.
    if (hostname.len == 0) return error.ValidationFailed;

    const realm_config = if (obj.get("realm_config")) |rc| blk: {
        if (rc != .object) break :blk null;
        const rc_obj = rc.object;
        break :blk onboarding_mod.RealmConfigOverrides{
            .default_token_lifetime_seconds = if (rc_obj.get("default_token_lifetime_seconds")) |v| switch (v) {
                .integer => |n| @intCast(n),
                else => null,
            } else null,
            .min_password_length = if (rc_obj.get("min_password_length")) |v| switch (v) {
                .integer => |n| @intCast(n),
                else => null,
            } else null,
            .require_uppercase = if (rc_obj.get("require_uppercase")) |v| switch (v) {
                .bool => |b| b,
                else => null,
            } else null,
            .require_digit = if (rc_obj.get("require_digit")) |v| switch (v) {
                .bool => |b| b,
                else => null,
            } else null,
            .signing_key_algorithm = if (rc_obj.get("signing_key_algorithm")) |v| switch (v) {
                .string => |s| s,
                else => null,
            } else null,
        };
    } else null;

    const client_config = if (obj.get("client_config")) |cc| blk: {
        if (cc != .object) break :blk null;
        const cc_obj = cc.object;
        const redirect_uris = if (cc_obj.get("redirect_uris")) |ru| blk2: {
            if (ru != .array) break :blk2 null;
            const uris = try allocator.alloc([]const u8, ru.array.items.len);
            for (ru.array.items, 0..) |item, i| {
                uris[i] = switch (item) {
                    .string => |s| try allocator.dupe(u8, s),
                    else => return error.ValidationFailed,
                };
            }
            break :blk2 uris;
        } else null;
        break :blk onboarding_mod.ClientConfigOverrides{
            .redirect_uris = redirect_uris,
            .service_account_enabled = if (cc_obj.get("service_account_enabled")) |v| switch (v) {
                .bool => |b| b,
                else => null,
            } else null,
        };
    } else null;

    // Build the full OnboardingInput value (allocating owned strings).
    // Since we need owned memory, we dupe all strings.
    const input = onboarding_mod.OnboardingInput{
        .slug = try allocator.dupe(u8, slug),
        .display_name = try allocator.dupe(u8, display_name),
        .admin_email = try allocator.dupe(u8, admin_email),
        .admin_username = try allocator.dupe(u8, admin_username),
        .admin_display_name = try allocator.dupe(u8, admin_display_name),
        .hostname = try allocator.dupe(u8, hostname),
        .realm_config = realm_config,
        .client_config = client_config,
    };

    return ParsedInput{
        .value = input,
        .deinitFn = struct {
            fn deinit(p: *ParsedInput, a: std.mem.Allocator) void {
                _ = p;
                _ = a;
                // The parsed JSON owns all strings; input values borrow from it.
                // We free nothing extra here since the parsed JSON is deinit'd separately.
            }
        }.deinit,
    };
}

fn extractString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

// ── Error helpers ─────────────────────────────────────────────────────────────

fn errorResult(allocator: std.mem.Allocator, status_code: u16, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{code}) catch
        "{\"error\":\"internal_error\"}";
    return .{ .status_code = status_code, .body = body };
}

fn onboardingErrorToStatus(err: anyerror) u16 {
    return switch (err) {
        onboarding_mod.OnboardingError.ValidationFailed => 422,
        onboarding_mod.OnboardingError.Forbidden => 403,
        onboarding_mod.OnboardingError.DuplicateTenantSlug,
        onboarding_mod.OnboardingError.DuplicateHostname,
        onboarding_mod.OnboardingError.RealmAlreadyExists,
        onboarding_mod.OnboardingError.IdempotencyConflict,
        => 409,
        onboarding_mod.OnboardingError.RealmProvisioningFailed,
        onboarding_mod.OnboardingError.UserProvisioningFailed,
        onboarding_mod.OnboardingError.RoleAssignmentFailed,
        onboarding_mod.OnboardingError.ClientProvisioningFailed,
        onboarding_mod.OnboardingError.VerificationFailed,
        => 502,
        onboarding_mod.OnboardingError.HostnameBindingFailed,
        onboarding_mod.OnboardingError.PersistenceFailed,
        => 500,
        onboarding_mod.OnboardingError.PoolExhausted => 503,
        onboarding_mod.OnboardingError.OutOfMemory => 500,
        else => 500,
    };
}

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| {
        if (col) |v| allocator.free(v);
    }
    allocator.free(row);
}
