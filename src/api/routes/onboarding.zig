const std = @import("std");
const auth = @import("../middleware/auth.zig");
const identity_service = @import("../../identity/service.zig");
const onboarding_mod = @import("../../identity/onboarding.zig");
const pool_mod = @import("pool");
const errors = @import("../errors.zig");

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

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
                return errorResult(allocator, 409, "onboarding_in_progress");
            }
            const cached_body = allocator.dupe(u8, record.response_body_json) catch
                return errorResult(allocator, 500, "internal_error");
            return .{ .status_code = record.response_status, .body = cached_body };
        },
        .fresh => |onboarding_id| {
            // Fresh request: execute the saga.
            const manager = auth.getIdentityProviderManager();
            const result = onboarding_mod.executeSaga(
                allocator,
                manager,
                service.registry.pool,
                input.value,
            ) catch |err| {
                // Persist failure and return error.
                const err_status: u16 = onboardingErrorToStatus(err);
                const err_body = if (err == onboarding_mod.OnboardingError.ValidationFailed)
                    "{\"error\":\"validation_failed\"}"
                else
                    "{\"error\":\"onboarding_failed\"}";

                persistOnboardingResult(
                    service.registry.pool,
                    onboarding_id,
                    err_status,
                    err_body,
                    .failed,
                ) catch {};

                return .{ .status_code = err_status, .body = err_body };
            };
            defer result.deinit(allocator);

            const json_body = serializeOnboardingResult(allocator, &result) catch
                return errorResult(allocator, 500, "serialization_failed");

            // Persist success.
            persistOnboardingResult(
                service.registry.pool,
                onboarding_id,
                201,
                json_body,
                .completed,
            ) catch {};

            return .{ .status_code = 201, .body = json_body };
        },
    }
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

    const body = allocator.dupe(u8, record_val.response_body_json) catch
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

    const body = allocator.dupe(u8, record_val.response_body_json) catch
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
        \\INSERT INTO onboarding_registry (onboarding_id, idempotency_key, request_hash, tenant_id, hostname, state)
        \\VALUES ($1::uuid, $2, decode($3, 'hex'), NULL, $4, 'pending')
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
        \\SELECT onboarding_id::text, idempotency_key, encode(request_hash, 'hex'), response_status, COALESCE(response_body::text, '{}'), state, created_at::text, completed_at::text
        \\FROM onboarding_registry
        \\WHERE idempotency_key = $1
        \\LIMIT 1
    ,
        &[_][]const u8{key},
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
        \\WHERE onboarding_id::text = $1
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
        \\SELECT onboarding_id::text, idempotency_key, ''::text, encode(request_hash, 'hex'), response_status, COALESCE(response_body::text, '{}'), state, created_at::text, completed_at::text
        \\FROM onboarding_registry
        \\WHERE onboarding_id::text = $1
        \\LIMIT 1
    ,
        &[_][]const u8{onboarding_id},
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
        \\SELECT onboarding_id::text, idempotency_key, ''::text, encode(request_hash, 'hex'), response_status, COALESCE(response_body::text, '{}'), state, created_at::text, completed_at::text
        \\FROM onboarding_registry
        \\WHERE hostname = $1 AND state = 'completed'
        \\LIMIT 1
    ,
        &[_][]const u8{hostname},
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

    try buf.appendSlice(allocator, "{\"onboarding_id\":");
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
    // Fill with bytes from a simple PRNG seeded from timestamp.
    const seed: u64 = @truncate(@intFromPtr(&raw));
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(&raw);
    // Set UUID v4 bits
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    // Encode as hex string
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
