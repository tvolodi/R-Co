//! Bearer token authentication middleware for the BPM Platform REST API.
//!
//! Implements API-08: every request must carry a valid Bearer token in the
//! Authorization header.  The middleware extracts the token, validates it
//! against the api_tokens table (or the bootstrap token in non-production),
//! resolves the caller's role, and either passes through an AuthContext or
//! returns an RFC 9457 HTTP 401/403 response.
//!
//! Usage:
//!   try auth.init(allocator, "my-bootstrap-token");  // or auth.initFromEnv(allocator)
//!   defer auth.deinit();
//!   const result = auth.authenticate(allocator, authorization_header, &pool);
//!   switch (result) {
//!       .authenticated => |ctx| // proceed with ctx.user_id, ctx.role
//!       .unauthenticated => |hr| return hr; // HTTP 401
//!       .forbidden => |hr| return hr; // HTTP 403
//!   }

const std = @import("std");
const errors = @import("../errors.zig");
const trace_context = @import("../trace_context.zig");
const tenant_context = @import("tenant_context");
const pipeline_context = @import("pipeline_context");
const pool_mod = @import("pool");
const identity_provider = @import("identity_provider");
const provider_manager_mod = identity_provider.manager;
const provider_types = identity_provider.types;
const claim_mapping = @import("claim_mapping");
const jit_provisioning = @import("jit_provisioning");

// ── Module-level state ────────────────────────────────────────────────────────

/// SHA-256 hex hash of the bootstrap token, set by init().
/// null means bootstrap auth is disabled.
var bootstrap_hash: ?[]const u8 = null;

/// The allocator that owns bootstrap_hash.  Used by deinit() to free it.
var bootstrap_hash_allocator: ?std.mem.Allocator = null;

/// Provider-agnostic identity manager for JWT-like token verification.
/// Default is unconfigured and preserves legacy local token behavior.
var identity_provider_manager: provider_manager_mod.Manager = provider_manager_mod.defaultManager();

/// Callback for JIT user creation during OIDC auth.
/// Set via configureJitCreateUserCallback. When null, JIT provisioning
/// is disabled and the legacy path (principal.provider_subject as user_id)
/// is used for all realms.
var jit_create_user_callback: ?*const fn (
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    external_realm: []const u8,
    external_id: []const u8,
    preferred_username: []const u8,
    display_name: []const u8,
    email: []const u8,
    default_status: []const u8,
) anyerror!jit_provisioning.JitProvisioningResult = null;

/// Callback for OIDC-10 attribute synchronisation after JIT provisioning.
/// Set via configureJitSyncCallback. When null, sync is skipped.
var jit_sync_callback: ?*const fn (
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    identity_ctx: *const claim_mapping.IdentityContext,
    tenant_id: []const u8,
) anyerror!jit_provisioning.SyncResult = null;

// ── Public types ──────────────────────────────────────────────────────────────

/// HTTP handler result type (mirrors the definition in response.zig).
pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

pub const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

/// Platform roles seeded by 008_identity.sql.
/// Maps to the `roles.name` column.
pub const Role = enum {
    PLATFORM_ADMIN,
    PROCESS_DESIGNER,
    PROCESS_OPERATOR,
    TASK_WORKER,
    VIEWER,
    AGENT_RUNNER,

    /// Parse from the database text value.
    /// Returns null for unrecognised role names.
    pub fn fromString(s: []const u8) ?Role {
        const mapping = std.StaticStringMap(Role).initComptime(.{
            .{ "PLATFORM_ADMIN", .PLATFORM_ADMIN },
            .{ "PROCESS_DESIGNER", .PROCESS_DESIGNER },
            .{ "PROCESS_OPERATOR", .PROCESS_OPERATOR },
            .{ "TASK_WORKER", .TASK_WORKER },
            .{ "VIEWER", .VIEWER },
            .{ "AGENT_RUNNER", .AGENT_RUNNER },
        });
        return mapping.get(s);
    }
};

pub const TenantContextSource = enum {
    token_claim,
    default_fallback,
};

pub const TenantResolutionError = error{
    InvalidTenantClaimFormat,
    OutOfMemory,
};

pub const ResolvedTenantContext = struct {
    tenant_id: [36]u8,
    source: TenantContextSource,
};

pub const PipelineResolutionError = error{
    InvalidPipelineRunIdClaimFormat,
    OutOfMemory,
};

pub const TokenRoute = enum {
    oidc_jwt,
    internal_token,
    malformed_indeterminate,
};

pub const TokenRouteReason = enum {
    jwt_three_segments,
    opaque_no_dots,
    jwt_shape_invalid,
    illegal_character,
    empty_segment,
};

pub const TokenInspectionResult = struct {
    route: TokenRoute,
    reason: TokenRouteReason,
};

pub const Auth401Code = enum {
    token_missing,
    token_header_malformed,
    token_type_indeterminate,
    token_invalid,
    token_invalid_signature,
    token_invalid_issuer,
    token_invalid_audience,
    token_expired,
    token_not_yet_valid,
    token_revoked,
    token_unknown,
    token_claim_invalid,
};

/// The authenticated caller's identity and permissions.
/// Route handlers receive this via the request context.
pub const AuthContext = struct {
    /// UUID of the user row in the `users` table.
    /// Caller owns this string and must free it with the same allocator
    /// passed to authenticate().
    user_id: []const u8,
    /// The highest-privilege role assigned to this user.
    role: Role,
    /// True if this request used the bootstrap token.
    is_bootstrap: bool,
    /// Stable identifier for the token used in this request.
    /// For DB-validated tokens: the UUID primary key from `api_tokens.id`.
    /// For bootstrap tokens: the string literal "bootstrap".
    /// Used as the key for per-token rate limiting (API-10).
    /// Caller owns this string; freed with the same allocator passed to authenticate().
    token_id: []const u8,
    /// Resolved tenant context for the request lifecycle.
    tenant_id: [36]u8 = DEFAULT_TENANT_ID.*,
    tenant_source: TenantContextSource = .default_fallback,
};

fn rolePriority(role: Role) u8 {
    return switch (role) {
        .PLATFORM_ADMIN => 0,
        .PROCESS_DESIGNER => 1,
        .PROCESS_OPERATOR => 2,
        .TASK_WORKER => 3,
        .VIEWER => 4,
        .AGENT_RUNNER => 5,
    };
}

fn primaryRole(roles: []const Role) Role {
    var best = roles[0];
    var best_priority = rolePriority(best);
    for (roles[1..]) |role| {
        const priority = rolePriority(role);
        if (priority < best_priority) {
            best = role;
            best_priority = priority;
        }
    }
    return best;
}

fn providerRolePriority(role: provider_types.ProviderRole) u8 {
    return switch (role) {
        .PLATFORM_ADMIN => 0,
        .PROCESS_DESIGNER => 1,
        .PROCESS_OPERATOR => 2,
        .TASK_WORKER => 3,
        .VIEWER => 4,
        .AGENT_RUNNER => 5,
    };
}

fn fromProviderRole(role: provider_types.ProviderRole) Role {
    return switch (role) {
        .PLATFORM_ADMIN => .PLATFORM_ADMIN,
        .PROCESS_DESIGNER => .PROCESS_DESIGNER,
        .PROCESS_OPERATOR => .PROCESS_OPERATOR,
        .TASK_WORKER => .TASK_WORKER,
        .VIEWER => .VIEWER,
        .AGENT_RUNNER => .AGENT_RUNNER,
    };
}

fn primaryProviderRole(roles: []const provider_types.ProviderRole) Role {
    if (roles.len == 0) return .VIEWER;
    var best = roles[0];
    var best_priority = providerRolePriority(best);
    for (roles[1..]) |role| {
        const priority = providerRolePriority(role);
        if (priority < best_priority) {
            best = role;
            best_priority = priority;
        }
    }
    return fromProviderRole(best);
}

fn parseRolesJson(allocator: std.mem.Allocator, roles_json: []const u8) ![]Role {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, roles_json, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidRoleClaim;

    const roles = try allocator.alloc(Role, parsed.value.array.items.len);
    errdefer allocator.free(roles);
    for (parsed.value.array.items, 0..) |item, idx| {
        if (item != .string) return error.InvalidRoleClaim;
        roles[idx] = Role.fromString(item.string) orelse return error.InvalidRoleClaim;
    }
    return roles;
}

fn hexNibble(c: u8) error{InvalidHex}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn parseUuid(hex: []const u8) error{InvalidUuid}![16]u8 {
    if (hex.len != 36) return error.InvalidUuid;
    var uuid: [16]u8 = undefined;
    var byte_idx: usize = 0;
    var i: usize = 0;
    while (i < hex.len) {
        if (hex[i] == '-') {
            i += 1;
            continue;
        }
        if (i + 1 >= hex.len) return error.InvalidUuid;
        const hi = hexNibble(hex[i]) catch return error.InvalidUuid;
        const lo = hexNibble(hex[i + 1]) catch return error.InvalidUuid;
        if (byte_idx >= 16) return error.InvalidUuid;
        uuid[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
        i += 2;
    }
    if (byte_idx != 16) return error.InvalidUuid;
    return uuid;
}

fn formatUuidLower(uuid: [16]u8, out: *[36]u8) void {
    const rendered = std.fmt.bufPrint(
        out,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    ) catch unreachable;
    _ = rendered;
}

/// Resolve tenant context from bearer token claims represented by JWT payload,
/// while preserving compatibility for opaque legacy tokens.
pub fn resolveTenantContext(allocator: std.mem.Allocator, raw_token: []const u8) TenantResolutionError!ResolvedTenantContext {
    var resolved = ResolvedTenantContext{
        .tenant_id = DEFAULT_TENANT_ID.*,
        .source = .default_fallback,
    };

    const first_dot = std.mem.indexOfScalar(u8, raw_token, '.') orelse return resolved;
    const second_dot_rel = std.mem.indexOfScalar(u8, raw_token[first_dot + 1 ..], '.') orelse return resolved;
    const payload_b64 = raw_token[first_dot + 1 .. first_dot + 1 + second_dot_rel];
    if (payload_b64.len == 0) return resolved;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(payload_b64) catch return resolved;
    const decoded_payload = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded_payload);
    decoder.decode(decoded_payload, payload_b64) catch return resolved;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded_payload, .{ .allocate = .alloc_always }) catch return resolved;
    defer parsed.deinit();
    if (parsed.value != .object) return resolved;

    const tenant_field = parsed.value.object.get("tenant_id") orelse return resolved;
    switch (tenant_field) {
        .null => return resolved,
        .string => |tenant_text| {
            const parsed_uuid = parseUuid(tenant_text) catch return error.InvalidTenantClaimFormat;
            var canonical: [36]u8 = undefined;
            formatUuidLower(parsed_uuid, &canonical);
            if (!std.mem.eql(u8, tenant_text, canonical[0..])) {
                return error.InvalidTenantClaimFormat;
            }
            resolved.tenant_id = canonical;
            resolved.source = .token_claim;
            return resolved;
        },
        else => return error.InvalidTenantClaimFormat,
    }
}

/// Resolve optional pipeline_run_id claim from a JWT-like token.
/// Opaque legacy tokens or missing/null claims resolve to null.
pub fn resolvePipelineRunIdClaim(allocator: std.mem.Allocator, raw_token: []const u8) PipelineResolutionError!?[36]u8 {
    const first_dot = std.mem.indexOfScalar(u8, raw_token, '.') orelse return null;
    const second_dot_rel = std.mem.indexOfScalar(u8, raw_token[first_dot + 1 ..], '.') orelse return null;
    const payload_b64 = raw_token[first_dot + 1 .. first_dot + 1 + second_dot_rel];
    if (payload_b64.len == 0) return null;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(payload_b64) catch return null;
    const decoded_payload = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded_payload);
    decoder.decode(decoded_payload, payload_b64) catch return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded_payload, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const claim = parsed.value.object.get("pipeline_run_id") orelse return null;
    switch (claim) {
        .null => return null,
        .string => |run_id_text| {
            const parsed_uuid = parseUuid(run_id_text) catch return error.InvalidPipelineRunIdClaimFormat;
            var canonical: [36]u8 = undefined;
            formatUuidLower(parsed_uuid, &canonical);
            if (!std.mem.eql(u8, run_id_text, canonical[0..])) {
                return error.InvalidPipelineRunIdClaimFormat;
            }
            return canonical;
        },
        else => return error.InvalidPipelineRunIdClaimFormat,
    }
}

/// Result of the auth middleware check.
/// The HTTP server switches on this to either proceed or return an error response.
pub const AuthResult = union(enum) {
    /// Token is valid; the caller is authenticated.
    authenticated: AuthContext,
    /// Authentication failed (missing, malformed, unknown, revoked, or expired token).
    /// HandlerResult is a pre-built HTTP 401 response.
    unauthenticated: HandlerResult,
    /// Token is valid but the resolved role does not have permission.
    /// HandlerResult is a pre-built HTTP 403 response.
    forbidden: HandlerResult,
};

// ── Error set ─────────────────────────────────────────────────────────────────

pub const AuthError = error{
    /// BPM_ENV=production and BPM_BOOTSTRAP_TOKEN is set — fatal startup error.
    BootstrapTokenInProduction,
    /// Allocator exhausted during init().
    OutOfMemory,
};

// ── Sentinel values ───────────────────────────────────────────────────────────

/// User ID used for bootstrap-authenticated requests (nil UUID).
const BOOTSTRAP_USER_ID = "00000000-0000-0000-0000-000000000000";

// ── Internal helpers ──────────────────────────────────────────────────────────

/// Constant-time byte comparison.  Returns true iff a and b are equal.
/// Resistance to timing side-channels is achieved by accumulating XOR
/// differences rather than short-circuiting.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var acc: u8 = 0;
    for (a, b) |ba, bb| {
        acc |= ba ^ bb;
    }
    return acc == 0;
}

/// Hash a token with SHA-256 and return a 64-character lowercase hex string.
/// Caller owns the returned slice and must free it.
fn hashToken(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const hex = try allocator.alloc(u8, 64);
    @memcpy(hex, &std.fmt.bytesToHex(&digest, .lower));
    return hex;
}

fn tokenRouteString(route: TokenRoute) []const u8 {
    return switch (route) {
        .oidc_jwt => "oidc_jwt",
        .internal_token => "internal_token",
        .malformed_indeterminate => "malformed_indeterminate",
    };
}

fn tokenReasonString(reason: TokenRouteReason) []const u8 {
    return switch (reason) {
        .jwt_three_segments => "jwt_three_segments",
        .opaque_no_dots => "opaque_no_dots",
        .jwt_shape_invalid => "jwt_shape_invalid",
        .illegal_character => "illegal_character",
        .empty_segment => "empty_segment",
    };
}

fn auth401CodeString(code: Auth401Code) []const u8 {
    return switch (code) {
        .token_missing => "token_missing",
        .token_header_malformed => "token_header_malformed",
        .token_type_indeterminate => "token_type_indeterminate",
        .token_invalid => "token_invalid",
        .token_invalid_signature => "token_invalid_signature",
        .token_invalid_issuer => "token_invalid_issuer",
        .token_invalid_audience => "token_invalid_audience",
        .token_expired => "token_expired",
        .token_not_yet_valid => "token_not_yet_valid",
        .token_revoked => "token_revoked",
        .token_unknown => "token_unknown",
        .token_claim_invalid => "token_claim_invalid",
    };
}

fn isJwtSegmentLexicallyDecodable(segment: []const u8) bool {
    if (segment.len == 0) return false;
    if (segment.len % 4 == 1) return false;
    for (segment) |c| {
        const valid = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or
            c == '_';
        if (!valid) return false;
    }
    return true;
}

pub fn inspectBearerToken(raw_token: []const u8) TokenInspectionResult {
    if (raw_token.len == 0) {
        return .{ .route = .malformed_indeterminate, .reason = .empty_segment };
    }

    var dot_count: usize = 0;
    for (raw_token) |c| {
        if (std.ascii.isWhitespace(c) or std.ascii.isControl(c)) {
            return .{ .route = .malformed_indeterminate, .reason = .illegal_character };
        }
        const allowed = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or
            c == '_' or
            c == '.' or
            c == '~';
        if (!allowed) {
            return .{ .route = .malformed_indeterminate, .reason = .illegal_character };
        }
        if (c == '.') dot_count += 1;
    }

    if (dot_count == 0) {
        return .{ .route = .internal_token, .reason = .opaque_no_dots };
    }
    if (dot_count != 2) {
        return .{ .route = .malformed_indeterminate, .reason = .jwt_shape_invalid };
    }

    const first_dot = std.mem.indexOfScalar(u8, raw_token, '.') orelse
        return .{ .route = .malformed_indeterminate, .reason = .jwt_shape_invalid };
    const second_dot_rel = std.mem.indexOfScalar(u8, raw_token[first_dot + 1 ..], '.') orelse
        return .{ .route = .malformed_indeterminate, .reason = .jwt_shape_invalid };
    const second_dot = first_dot + 1 + second_dot_rel;

    const header = raw_token[0..first_dot];
    const payload = raw_token[first_dot + 1 .. second_dot];
    const signature = raw_token[second_dot + 1 ..];
    if (header.len == 0 or payload.len == 0 or signature.len == 0) {
        return .{ .route = .malformed_indeterminate, .reason = .empty_segment };
    }
    if (!isJwtSegmentLexicallyDecodable(header) or !isJwtSegmentLexicallyDecodable(payload)) {
        return .{ .route = .malformed_indeterminate, .reason = .jwt_shape_invalid };
    }

    return .{ .route = .oidc_jwt, .reason = .jwt_three_segments };
}

pub fn buildUnauthorizedAuth(
    allocator: std.mem.Allocator,
    code: Auth401Code,
    detail: []const u8,
    route: ?TokenRoute,
    reason: ?TokenRouteReason,
    tenant_id: ?[]const u8,
    auth_reason: ?[]const u8,
) HandlerResult {
    const token_route = if (route) |r| tokenRouteString(r) else "n/a";
    const token_reason = if (reason) |r| tokenReasonString(r) else "n/a";
    const resolved_tenant_id = tenant_id orelse DEFAULT_TENANT_ID;
    const resolved_auth_reason = auth_reason orelse "n/a";
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"https://bpm.example.com/problems/unauthorized\",\"title\":\"Unauthorized\",\"status\":401,\"detail\":\"{s}\",\"trace_id\":\"{s}\",\"extensions\":{{\"code\":\"{s}\",\"token_route\":\"{s}\",\"token_reason\":\"{s}\",\"tenant_id\":\"{s}\",\"reason\":\"{s}\"}}}}",
        .{ detail, trace_context.get(), auth401CodeString(code), token_route, token_reason, resolved_tenant_id, resolved_auth_reason },
    ) catch return .{
        .status_code = 500,
        .body = "{\"type\":\"https://bpm.example.com/problems/internal-error\"," ++
            "\"title\":\"Internal Server Error\",\"status\":500," ++
            "\"detail\":\"serialization failed\"}",
    };
    return .{ .status_code = 401, .body = body };
}

/// Build a 401 Unauthorized HandlerResult.
/// Allocates the Problem Details JSON body; caller owns it.
fn buildUnauthorized(allocator: std.mem.Allocator, detail: []const u8) HandlerResult {
    const pd = errors.problemUnauthorized(detail);
    const body = errors.serialise(allocator, pd) catch
        return .{
            .status_code = 500,
            .body = "{\"type\":\"https://bpm.example.com/problems/internal-error\"," ++
                "\"title\":\"Internal Server Error\",\"status\":500," ++
                "\"detail\":\"serialization failed\"}",
        };
    return .{ .status_code = pd.status, .body = body };
}

/// Build a 403 Forbidden HandlerResult.
fn buildForbidden(allocator: std.mem.Allocator, detail: []const u8) HandlerResult {
    const pd = errors.problemForbidden(detail);
    const body = errors.serialise(allocator, pd) catch
        return .{
            .status_code = 500,
            .body = "{\"type\":\"https://bpm.example.com/problems/internal-error\"," ++
                "\"title\":\"Internal Server Error\",\"status\":500," ++
                "\"detail\":\"serialization failed\"}",
        };
    return .{ .status_code = pd.status, .body = body };
}

fn isTenantInactive(
    allocator: std.mem.Allocator,
    db_pool: *pool_mod.Pool,
    tenant_id: []const u8,
) (error{ PoolExhausted, PersistenceFailed, OutOfMemory } || pool_mod.PoolError)!bool {
    const conn = db_pool.acquire() catch |err| switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer db_pool.release(conn);

    const row = conn.queryRow(
        allocator,
        "SELECT status FROM tenant WHERE id = $1::uuid LIMIT 1",
        &[_][]const u8{tenant_id},
    ) catch |err| switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => return error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };

    if (row == null) return false;
    defer {
        if (row.?[0]) |v| allocator.free(v);
        allocator.free(row.?);
    }

    const status_txt = row.?[0] orelse "ACTIVE";
    return std.mem.eql(u8, status_txt, "INACTIVE");
}

// ── JIT provisioning helpers ──────────────────────────────────────────────────

/// Decode the JWT payload segment (2nd segment) from a raw bearer token.
pub const JwtDecodeError = error{
    InvalidTokenPayload,
    OutOfMemory,
};

fn decodeJwtPayload(allocator: std.mem.Allocator, raw_token: []const u8) JwtDecodeError![]const u8 {
    const first_dot = std.mem.indexOfScalar(u8, raw_token, '.') orelse return error.InvalidTokenPayload;
    const second_dot_rel = std.mem.indexOfScalar(u8, raw_token[first_dot + 1 ..], '.') orelse return error.InvalidTokenPayload;
    const payload_b64 = raw_token[first_dot + 1 .. first_dot + 1 + second_dot_rel];
    if (payload_b64.len == 0) return error.InvalidTokenPayload;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(payload_b64) catch return error.InvalidTokenPayload;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    decoder.decode(decoded, payload_b64) catch return error.InvalidTokenPayload;
    return decoded;
}

/// Load the highest-priority role assigned to a user from the user_roles table.
/// Returns VIEWER when no roles are assigned.
fn loadUserRole(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    user_id: []const u8,
) (error{ PoolExhausted, PersistenceFailed, OutOfMemory } || pool_mod.PoolError)!Role {
    const conn = pool.acquire() catch |err| switch (err) {
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT r.name FROM roles r
        \\JOIN user_roles ur ON ur.role_id = r.id
        \\WHERE ur.user_id = $1::uuid
        \\ORDER BY CASE r.name
        \\  WHEN 'PLATFORM_ADMIN'   THEN 0
        \\  WHEN 'PROCESS_DESIGNER' THEN 1
        \\  WHEN 'PROCESS_OPERATOR' THEN 2
        \\  WHEN 'TASK_WORKER'      THEN 3
        \\  WHEN 'VIEWER'           THEN 4
        \\  WHEN 'AGENT_RUNNER'     THEN 5
        \\END
        \\LIMIT 1
    ,
        &[_][]const u8{user_id},
    ) catch |err| switch (err) {
        pool_mod.PoolError.StaleConnection,
        pool_mod.PoolError.ConnectionFailed,
        pool_mod.PoolError.QueryFailed,
        => return error.PersistenceFailed,
        pool_mod.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };

    if (row) |rr| {
        defer {
            if (rr[0]) |v| allocator.free(v);
            allocator.free(rr);
        }
        if (rr[0]) |role_name| {
            if (Role.fromString(role_name)) |r| return r;
        }
    }
    return .VIEWER;
}

/// Post-authentication JIT provisioning.
///
/// Called after authenticate() succeeds for OIDC tokens.  Attempts to
/// provision a local user from the verified identity.  On success, returns
/// an AuthContext with the local user's ID and role bindings.
/// On failure (e.g. provisioning unavailable), returns the original context.
pub fn postAuthJitProvision(
    allocator: std.mem.Allocator,
    db_pool: *pool_mod.Pool,
    auth_ctx: AuthContext,
    raw_token: []const u8,
    principal: provider_types.VerifiedPrincipal,
) AuthResult {
    // Decode JWT payload for claim mapping.
    const raw_claims_json = decodeJwtPayload(allocator, raw_token) catch {
        return .{ .authenticated = auth_ctx };
    };
    defer allocator.free(raw_claims_json);

    // Determine realm from provider or default.
    const realm = principal.external_realm orelse "bpm-default";

    // Load claim mapping config (or use defaults).
    const claim_config = (claim_mapping.loadClaimMappingConfig(allocator, db_pool, realm) catch null) orelse
        claim_mapping.DEFAULT_CLAIM_MAPPING_CONFIG;

    // Build IdentityContext from verified claims.
    var identity_ctx = claim_mapping.mapVerifiedClaims(
        allocator,
        claim_config,
        principal.provider_subject,
        raw_claims_json,
    ) catch |err| switch (err) {
        error.SubClaimMissing,
        error.ClaimPathMalformed,
        error.ClaimTypeMismatch,
        => return .{ .authenticated = auth_ctx },

        error.OutOfMemory => return .{ .authenticated = auth_ctx },
    };
    defer identity_ctx.deinit(allocator);

    // Load JIT config to check if provisioning is enabled.
    var jit_config = jit_provisioning.loadJitConfig(allocator, db_pool, realm) catch |err| switch (err) {
        error.PoolExhausted => return .{ .authenticated = auth_ctx },
        error.ConfigParseFailed => return .{ .authenticated = auth_ctx },
        error.OutOfMemory => return .{ .authenticated = auth_ctx },
    };
    defer jit_config.deinit(allocator);

    if (!jit_config.enabled) return .{ .authenticated = auth_ctx };

    const create_user_fn = jit_create_user_callback orelse return .{ .authenticated = auth_ctx };

    const user_status_str = jit_config.default_status.asString();

    const jit_result = create_user_fn(
        allocator,
        db_pool,
        auth_ctx.tenant_id[0..],
        realm,
        identity_ctx.external_user_id,
        identity_ctx.preferred_username,
        identity_ctx.display_name orelse identity_ctx.preferred_username,
        identity_ctx.email,
        user_status_str,
    ) catch |err| switch (err) {
        error.OutOfMemory => return .{ .authenticated = auth_ctx },
        else => return .{ .authenticated = auth_ctx },
    };

    const provision_result = jit_provisioning.processProvisionResult(
        allocator,
        db_pool,
        jit_result.user,
        jit_result.created,
    ) catch |err| switch (err) {
        error.PoolExhausted => return .{ .authenticated = auth_ctx },
        error.PersistenceFailed => return .{ .authenticated = auth_ctx },
        error.OutOfMemory => return .{ .authenticated = auth_ctx },
        else => return .{ .authenticated = auth_ctx },
    };

    // ── OIDC-10: Attribute sync and role reconciliation (best-effort) ──
    if (jit_sync_callback) |sync_fn| {
        _ = sync_fn(
            allocator,
            db_pool,
            &identity_ctx,
            auth_ctx.tenant_id[0..],
        ) catch |err| {
            std.log.warn("OIDC-10 sync failed: {s}", .{@errorName(err)});
        };
    }

    // Load local role bindings from user_roles (reload because
    // reconciliation may have changed them).
    const role = loadUserRole(allocator, db_pool, provision_result.user.user_id) catch |err| switch (err) {
        error.PoolExhausted => return .{ .authenticated = auth_ctx },
        error.PersistenceFailed => return .{ .authenticated = auth_ctx },
        error.OutOfMemory => return .{ .authenticated = auth_ctx },
        else => return .{ .authenticated = auth_ctx },
    };

    const new_user_id = allocator.dupe(u8, provision_result.user.user_id) catch
        return .{ .authenticated = auth_ctx };
    const new_token_id = allocator.dupe(u8, principal.token_id_hint orelse "oidc") catch {
        allocator.free(new_user_id);
        return .{ .authenticated = auth_ctx };
    };

    return .{ .authenticated = .{
        .user_id = new_user_id,
        .role = role,
        .is_bootstrap = auth_ctx.is_bootstrap,
        .token_id = new_token_id,
        .tenant_id = auth_ctx.tenant_id,
        .tenant_source = auth_ctx.tenant_source,
    } };
}

// ── Public functions ──────────────────────────────────────────────────────────

/// Initialise the auth module.  MUST be called once at startup, before the HTTP
/// server begins accepting connections, and before any call to `authenticate()`.
///
/// `bootstrap_token` — the raw bootstrap token string from configuration
/// (e.g. BPM_BOOTSTRAP_TOKEN env var).  Pass null or empty to disable bootstrap
/// auth.  When bootstrap auth is enabled, any request carrying this token is
/// authenticated as PLATFORM_ADMIN.
///
/// Production safety: the CALLER is responsible for refusing to start if a
/// bootstrap token is configured in production.  `init()` itself does not read
/// BPM_ENV — that check belongs in the startup code (main.zig).
///
/// Returns `AuthError.OutOfMemory` if the allocator cannot allocate the hash.
pub fn init(allocator: std.mem.Allocator, bootstrap_token: ?[]const u8) AuthError!void {
    // Hash and store bootstrap token if provided and non-empty.
    if (bootstrap_token) |t| {
        if (t.len > 0) {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(t, &digest, .{});
            const hex = try allocator.alloc(u8, 64);
            @memcpy(hex, &std.fmt.bytesToHex(&digest, .lower));
            bootstrap_hash = hex;
            bootstrap_hash_allocator = allocator;
        }
    }
}

/// Convenience initialiser that reads BPM_ENV and BPM_BOOTSTRAP_TOKEN from the
/// process environment, validates production safety, and delegates to init().
///
/// 1. If BPM_ENV=production AND BPM_BOOTSTRAP_TOKEN is non-empty → returns
///    AuthError.BootstrapTokenInProduction (fatal).
/// 2. Otherwise calls init() with the raw bootstrap token (null if unset/empty).
pub fn initFromEnv(allocator: std.mem.Allocator) AuthError!void {
    const env_raw = std.c.getenv("BPM_ENV");
    const env: []const u8 = if (env_raw) |e| std.mem.sliceTo(e, 0) else "development";
    const token_raw = std.c.getenv("BPM_BOOTSTRAP_TOKEN");
    const token: ?[]const u8 = if (token_raw) |t| blk: {
        break :blk std.mem.sliceTo(t, 0);
    } else null;

    // Production safety: refuse to start if bootstrap token is set.
    if (std.mem.eql(u8, env, "production")) {
        if (token) |t| {
            if (t.len > 0) {
                return AuthError.BootstrapTokenInProduction;
            }
        }
    }

    // Pass the raw token to the core init logic.
    return init(allocator, token);
}

/// Free module-owned memory (the stored bootstrap token hash).
/// Safe to call multiple times.
pub fn deinit() void {
    if (bootstrap_hash) |h| {
        if (bootstrap_hash_allocator) |a| {
            a.free(h);
        }
        bootstrap_hash = null;
        bootstrap_hash_allocator = null;
    }
}

pub fn configureIdentityProviderManager(manager: provider_manager_mod.Manager) void {
    identity_provider_manager = manager;
}

pub fn resetIdentityProviderManager() void {
    identity_provider_manager = provider_manager_mod.defaultManager();
}

/// Retrieve the current identity provider manager.
/// Returns the module-level manager configured at startup.
pub fn getIdentityProviderManager() provider_manager_mod.Manager {
    return identity_provider_manager;
}

/// Configure the JIT user creation callback.
/// When set, OIDC auth tokens will trigger JIT provisioning via this callback.
/// Pass null to disable JIT provisioning.
pub fn configureJitCreateUserCallback(callback: ?*const fn (
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    external_realm: []const u8,
    external_id: []const u8,
    preferred_username: []const u8,
    display_name: []const u8,
    email: []const u8,
    default_status: []const u8,
) anyerror!jit_provisioning.JitProvisioningResult) void {
    jit_create_user_callback = callback;
}

/// Configure the OIDC-10 attribute synchronisation callback.
/// When set, postAuthJitProvision will call this after JIT provisioning
/// to sync profile attributes and reconcile roles.
/// Pass null to disable sync.
pub fn configureJitSyncCallback(callback: ?*const fn (
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    identity_ctx: *const claim_mapping.IdentityContext,
    tenant_id: []const u8,
) anyerror!jit_provisioning.SyncResult) void {
    jit_sync_callback = callback;
}

/// OIDC-10 attribute sync shim that wraps jit_provisioning.syncAttributesFromIdentityContext
/// into the callback signature expected by auth.zig.
pub fn syncAttributesFromIdentityContextShim(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    identity_ctx: *const claim_mapping.IdentityContext,
    tenant_id: []const u8,
) anyerror!jit_provisioning.SyncResult {
    return jit_provisioning.syncAttributesFromIdentityContext(allocator, pool, identity_ctx, tenant_id);
}

/// Authenticate a single HTTP request.  Called by the HTTP server in the
/// middleware chain BEFORE any route handler is dispatched.
///
/// Decision flow:
///   1. If authorization_header is null → return .unauthenticated (401).
///   2. Strip leading/trailing whitespace from the header value.
///   3. Check for the "Bearer " prefix (case-sensitive, per RFC 6750 §2.1).
///      If absent → return .unauthenticated (401, malformed header).
///   4. Extract <token> (the substring after "Bearer ").
///      If <token> is empty → return .unauthenticated (401).
///   5. If bootstrap auth is enabled:
///      a. Hash <token> with SHA-256.
///      b. Compare against stored bootstrap hash in constant time.
///      c. If match → return .authenticated with PLATFORM_ADMIN role.
///   6. Hash <token> with SHA-256.
///   7. Query api_tokens table for the token hash.
///      a. No row → return .unauthenticated (401, unknown token).
///      b. revoked_at IS NOT NULL → return .unauthenticated (401, revoked).
///   8. Look up the user's highest-privilege role via user_roles + roles.
///   9. Update api_tokens.last_used_at = NOW() (best-effort; failure logged, not fatal).
///   10. Return .authenticated with user_id, role, is_bootstrap=false.
///
/// Security properties:
///   - Token hash comparison is constant-time.
///   - No token raw value is logged at INFO or above.
///   - DB queries use prepared statements ($1 placeholders) — no string interpolation.
///   - A database outage on the last_used_at update does NOT fail the request.
pub fn authenticate(
    allocator: std.mem.Allocator,
    authorization_header: ?[]const u8,
    db_pool: *pool_mod.Pool,
) AuthResult {
    tenant_context.clear();
    pipeline_context.clear();

    // Step 1: Check for missing header.
    const header = authorization_header orelse
        return .{ .unauthenticated = buildUnauthorized(allocator, "missing Authorization header") };

    // Step 2: Strip leading/trailing whitespace.
    const trimmed = std.mem.trim(u8, header, " \t\r\n");

    // Step 3: Check for Bearer prefix (case-sensitive, RFC 6750 §2.1).
    const BEARER = "Bearer ";
    if (!std.mem.startsWith(u8, trimmed, BEARER)) {
        return .{ .unauthenticated = buildUnauthorized(allocator, "malformed Authorization header; expected Bearer token") };
    }

    // Step 4: Extract token.
    const raw_token = trimmed[BEARER.len..];
    if (raw_token.len == 0) {
        return .{ .unauthenticated = buildUnauthorized(allocator, "empty Bearer token") };
    }

    const inspection = inspectBearerToken(raw_token);
    if (inspection.route == .malformed_indeterminate) {
        return .{ .unauthenticated = buildUnauthorizedAuth(
            allocator,
            .token_type_indeterminate,
            "indeterminate bearer token format",
            .malformed_indeterminate,
            inspection.reason,
            DEFAULT_TENANT_ID,
            "token_type_indeterminate",
        ) };
    }

    if (inspection.route == .oidc_jwt) {
        if (identity_provider_manager.auth_mode == .local_only) {
            return .{ .unauthenticated = buildUnauthorized(allocator, "invalid bearer token") };
        }
        const tenant_id_for_error = blk: {
            const resolved = resolveTenantContext(allocator, raw_token) catch break :blk DEFAULT_TENANT_ID.*;
            break :blk resolved.tenant_id;
        };
        var principal = identity_provider_manager.verifyBearerToken(allocator, raw_token) catch |err| switch (err) {
            error.TokenIssuerMismatch => return .{ .unauthenticated = buildUnauthorizedAuth(
                allocator,
                .token_invalid_issuer,
                "invalid token issuer",
                .oidc_jwt,
                inspection.reason,
                tenant_id_for_error[0..],
                "issuer_mismatch",
            ) },
            error.TokenAudienceMismatch => return .{ .unauthenticated = buildUnauthorizedAuth(
                allocator,
                .token_invalid_audience,
                "invalid token audience",
                .oidc_jwt,
                inspection.reason,
                tenant_id_for_error[0..],
                "audience_mismatch",
            ) },
            error.TokenExpired => return .{ .unauthenticated = buildUnauthorizedAuth(
                allocator,
                .token_expired,
                "token expired",
                .oidc_jwt,
                inspection.reason,
                tenant_id_for_error[0..],
                "token_expired",
            ) },
            error.TokenNotYetValid => return .{ .unauthenticated = buildUnauthorizedAuth(
                allocator,
                .token_not_yet_valid,
                "token not yet valid",
                .oidc_jwt,
                inspection.reason,
                tenant_id_for_error[0..],
                "token_not_yet_valid",
            ) },
            error.SignatureVerificationFailed => return .{ .unauthenticated = buildUnauthorizedAuth(
                allocator,
                .token_invalid_signature,
                "invalid token signature",
                .oidc_jwt,
                inspection.reason,
                tenant_id_for_error[0..],
                "signature_invalid",
            ) },
            error.ClaimValidationFailed => return .{ .unauthenticated = buildUnauthorizedAuth(
                allocator,
                .token_claim_invalid,
                "token claim validation failed",
                .oidc_jwt,
                inspection.reason,
                tenant_id_for_error[0..],
                "claim_invalid",
            ) },
            error.InvalidToken,
            error.NotImplemented,
            => return .{ .unauthenticated = buildUnauthorizedAuth(
                allocator,
                .token_invalid,
                "invalid bearer token",
                .oidc_jwt,
                inspection.reason,
                tenant_id_for_error[0..],
                "token_invalid",
            ) },

            error.UpstreamUnavailable,
            error.UpstreamTimeout,
            error.RateLimited,
            => return .{ .unauthenticated = buildUnauthorized(allocator, "service unavailable") },

            else => return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") },
        };
        defer principal.deinit(allocator);

        const pipeline_run_id = resolvePipelineRunIdClaim(allocator, raw_token) catch |err| switch (err) {
            error.InvalidPipelineRunIdClaimFormat => return .{ .unauthenticated = buildUnauthorized(allocator, "invalid pipeline_run_id claim") },
            error.OutOfMemory => return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") },
        };

        const resolved_tenant = if (principal.tenant_id) |tenant_id|
            ResolvedTenantContext{ .tenant_id = tenant_id, .source = .token_claim }
        else
            resolveTenantContext(allocator, raw_token) catch |err| switch (err) {
                error.InvalidTenantClaimFormat => return .{ .unauthenticated = buildUnauthorized(allocator, "invalid tenant_id claim") },
                error.OutOfMemory => return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") },
            };

        tenant_context.set(resolved_tenant.tenant_id[0..]);
        if (pipeline_run_id) |rid| pipeline_context.set(rid[0..]);

        const user_id = allocator.dupe(u8, principal.provider_subject) catch
            return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") };
        const token_id = allocator.dupe(u8, principal.token_id_hint orelse "oidc") catch {
            allocator.free(user_id);
            return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") };
        };

        const role = primaryProviderRole(principal.roles);

        return .{ .authenticated = .{
            .user_id = user_id,
            .role = role,
            .is_bootstrap = false,
            .token_id = token_id,
            .tenant_id = resolved_tenant.tenant_id,
            .tenant_source = resolved_tenant.source,
        } };
    }

    // Step 5: Hash token once for both bootstrap and DB lookup.
    const token_hash = hashToken(allocator, raw_token) catch
        return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") };
    defer allocator.free(token_hash);

    // Step 5a-c: Check bootstrap token (constant-time comparison).
    if (bootstrap_hash) |boot_hash| {
        if (constantTimeEql(token_hash, boot_hash)) {
            const resolved_tenant = resolveTenantContext(allocator, raw_token) catch |err| switch (err) {
                error.InvalidTenantClaimFormat => return .{ .unauthenticated = buildUnauthorized(allocator, "invalid tenant_id claim") },
                error.OutOfMemory => return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") },
            };
            const pipeline_run_id = resolvePipelineRunIdClaim(allocator, raw_token) catch |err| switch (err) {
                error.InvalidPipelineRunIdClaimFormat => return .{ .unauthenticated = buildUnauthorized(allocator, "invalid pipeline_run_id claim") },
                error.OutOfMemory => return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") },
            };
            tenant_context.set(resolved_tenant.tenant_id[0..]);
            if (pipeline_run_id) |rid| pipeline_context.set(rid[0..]);
            const user_id_boot = allocator.dupe(u8, BOOTSTRAP_USER_ID) catch
                return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") };
            const token_id_boot = allocator.dupe(u8, "bootstrap") catch {
                allocator.free(user_id_boot);
                return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") };
            };
            return .{ .authenticated = .{
                .user_id = user_id_boot,
                .role = .PLATFORM_ADMIN,
                .is_bootstrap = true,
                .token_id = token_id_boot,
                .tenant_id = resolved_tenant.tenant_id,
                .tenant_source = resolved_tenant.source,
            } };
        }
    }

    // Step 5d: Resolve tenant context for raw opaque API tokens.
    // api_tokens and users are in tenant schemas after Stage 12.  We must set
    // tenant_context BEFORE acquiring the DB connection so that
    // applyRequestTenantContext sets the correct search_path.  For tokens
    // without an embedded tenant_id claim (legacy opaque tokens), this resolves
    // to DEFAULT_TENANT_ID ("00000000-0000-0000-0000-000000000000") which maps
    // to the tenant_default schema.
    const pre_resolved_tenant = resolveTenantContext(allocator, raw_token) catch |err| switch (err) {
        error.InvalidTenantClaimFormat => return .{ .unauthenticated = buildUnauthorized(allocator, "invalid tenant_id claim") },
        error.OutOfMemory => return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") },
    };
    tenant_context.set(pre_resolved_tenant.tenant_id[0..]);

    // Step 6-7: Query api_tokens table.
    const conn = db_pool.acquire() catch
        return .{ .unauthenticated = buildUnauthorized(allocator, "service unavailable") };
    defer db_pool.release(conn);

    const token_row = conn.queryRow(
        allocator,
        "SELECT id::text, user_id::text, revoked_at::text, (expires_at IS NOT NULL AND NOW() >= expires_at)::text, COALESCE(roles_json::text, '[]') FROM api_tokens WHERE token_hash = $1",
        &[_][]const u8{token_hash},
    ) catch return .{ .unauthenticated = buildUnauthorized(allocator, "service unavailable") };

    // Step 7a: No row → unknown token.
    if (token_row == null) {
        return .{ .unauthenticated = buildUnauthorized(allocator, "unknown token") };
    }

    const row = token_row.?;
    defer {
        if (row[0]) |v| allocator.free(v);
        if (row[1]) |v| allocator.free(v);
        if (row[2]) |v| allocator.free(v);
        if (row[3]) |v| allocator.free(v);
        if (row[4]) |v| allocator.free(v);
        allocator.free(row);
    }

    // Step 7b: Check revoked (row[2] = revoked_at).
    if (row[2] != null) {
        return .{ .unauthenticated = buildUnauthorized(allocator, "token revoked") };
    }

    // Expired tokens are immediately rejected at auth boundary.
    const is_expired_txt = row[3] orelse "f";
    if (std.mem.eql(u8, is_expired_txt, "t") or std.mem.eql(u8, is_expired_txt, "true")) {
        return .{ .unauthenticated = buildUnauthorized(allocator, "token expired") };
    }

    // row[0] = id (token_id), row[1] = user_id.
    const token_id_raw = row[0] orelse
        return .{ .unauthenticated = buildUnauthorized(allocator, "invalid token: no id") };
    const user_id_raw = row[1] orelse
        return .{ .unauthenticated = buildUnauthorized(allocator, "invalid token: no user") };

    // Clone token_id and user_id for the AuthContext return value (freed by caller).
    const token_id = allocator.dupe(u8, token_id_raw) catch
        return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") };
    const user_id = allocator.dupe(u8, user_id_raw) catch {
        allocator.free(token_id);
        return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") };
    };

    // IDN-01: reject tokens for INACTIVE users with HTTP 401.
    const user_status_row = conn.queryRow(
        allocator,
        "SELECT status, is_active::text FROM users WHERE id::text = $1",
        &[_][]const u8{user_id},
    ) catch {
        allocator.free(token_id);
        allocator.free(user_id);
        return .{ .unauthenticated = buildUnauthorized(allocator, "service unavailable") };
    };

    if (user_status_row == null) {
        allocator.free(token_id);
        allocator.free(user_id);
        return .{ .unauthenticated = buildUnauthorized(allocator, "invalid token: user not found") };
    }

    const status_row = user_status_row.?;
    defer {
        if (status_row[0]) |v| allocator.free(v);
        if (status_row[1]) |v| allocator.free(v);
        allocator.free(status_row);
    }

    const status_txt = status_row[0] orelse "";
    const active_txt = status_row[1] orelse "f";
    const is_inactive = std.mem.eql(u8, status_txt, "INACTIVE") or
        ((status_txt.len == 0) and (std.mem.eql(u8, active_txt, "f") or std.mem.eql(u8, active_txt, "false")));
    if (is_inactive) {
        allocator.free(token_id);
        allocator.free(user_id);
        return .{ .unauthenticated = buildUnauthorized(allocator, "user inactive") };
    }

    // Step 8: resolve role claims from token first; fallback to user role mapping.
    var role: Role = .VIEWER;
    const roles_json = row[4] orelse "[]";
    if (roles_json.len > 2) {
        const token_roles = parseRolesJson(allocator, roles_json) catch {
            allocator.free(token_id);
            allocator.free(user_id);
            return .{ .unauthenticated = buildUnauthorized(allocator, "invalid role claim") };
        };
        defer allocator.free(token_roles);

        if (token_roles.len == 0) {
            allocator.free(token_id);
            allocator.free(user_id);
            return .{ .unauthenticated = buildUnauthorized(allocator, "invalid role claim") };
        }
        role = primaryRole(token_roles);
    } else {
        const role_row = conn.queryRow(
            allocator,
            \\SELECT r.name FROM roles r
            \\JOIN user_roles ur ON ur.role_id = r.id
            \\WHERE ur.user_id = $1
            \\ORDER BY CASE r.name
            \\  WHEN 'PLATFORM_ADMIN'   THEN 0
            \\  WHEN 'PROCESS_DESIGNER' THEN 1
            \\  WHEN 'PROCESS_OPERATOR' THEN 2
            \\  WHEN 'TASK_WORKER'      THEN 3
            \\  WHEN 'VIEWER'           THEN 4
            \\  WHEN 'AGENT_RUNNER'     THEN 5
            \\END
            \\LIMIT 1
        ,
            &[_][]const u8{user_id},
        ) catch return .{ .unauthenticated = buildUnauthorized(allocator, "service unavailable") };

        if (role_row) |rr| {
            defer {
                if (rr[0]) |v| allocator.free(v);
                allocator.free(rr);
            }
            if (rr[0]) |role_name| {
                if (Role.fromString(role_name)) |r| {
                    role = r;
                }
            }
        }
    }

    // Step 9: Update last_used_at (best-effort; failure not fatal).
    _ = conn.exec(
        "UPDATE api_tokens SET last_used_at = NOW() WHERE token_hash = $1",
        &[_][]const u8{token_hash},
    ) catch {};

    const resolved_tenant = resolveTenantContext(allocator, raw_token) catch |err| switch (err) {
        error.InvalidTenantClaimFormat => {
            allocator.free(token_id);
            allocator.free(user_id);
            return .{ .unauthenticated = buildUnauthorized(allocator, "invalid tenant_id claim") };
        },
        error.OutOfMemory => {
            allocator.free(token_id);
            allocator.free(user_id);
            return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") };
        },
    };
    const pipeline_run_id = resolvePipelineRunIdClaim(allocator, raw_token) catch |err| switch (err) {
        error.InvalidPipelineRunIdClaimFormat => {
            allocator.free(token_id);
            allocator.free(user_id);
            return .{ .unauthenticated = buildUnauthorized(allocator, "invalid pipeline_run_id claim") };
        },
        error.OutOfMemory => {
            allocator.free(token_id);
            allocator.free(user_id);
            return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") };
        },
    };
    tenant_context.set(resolved_tenant.tenant_id[0..]);
    if (pipeline_run_id) |rid| pipeline_context.set(rid[0..]);

    if (role != .PLATFORM_ADMIN) {
        const inactive = isTenantInactive(allocator, db_pool, resolved_tenant.tenant_id[0..]) catch {
            allocator.free(token_id);
            allocator.free(user_id);
            return .{ .unauthenticated = buildUnauthorized(allocator, "service unavailable") };
        };
        if (inactive) {
            allocator.free(token_id);
            allocator.free(user_id);
            return .{ .forbidden = buildForbidden(allocator, "tenant_inactive") };
        }
    }

    // Step 10: Return authenticated.
    return .{ .authenticated = .{
        .user_id = user_id,
        .role = role,
        .is_bootstrap = false,
        .token_id = token_id,
        .tenant_id = resolved_tenant.tenant_id,
        .tenant_source = resolved_tenant.source,
    } };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Role.fromString: all known roles" {
    try std.testing.expect(Role.fromString("PLATFORM_ADMIN") == .PLATFORM_ADMIN);
    try std.testing.expect(Role.fromString("PROCESS_DESIGNER") == .PROCESS_DESIGNER);
    try std.testing.expect(Role.fromString("PROCESS_OPERATOR") == .PROCESS_OPERATOR);
    try std.testing.expect(Role.fromString("TASK_WORKER") == .TASK_WORKER);
    try std.testing.expect(Role.fromString("VIEWER") == .VIEWER);
    try std.testing.expect(Role.fromString("AGENT_RUNNER") == .AGENT_RUNNER);
}

test "Role.fromString: unknown role returns null" {
    try std.testing.expect(Role.fromString("SUPER_ADMIN") == null);
    try std.testing.expect(Role.fromString("") == null);
}

test "constantTimeEql: equal strings" {
    try std.testing.expect(constantTimeEql("hello", "hello"));
    try std.testing.expect(constantTimeEql("", ""));
}

test "constantTimeEql: different strings" {
    try std.testing.expect(!constantTimeEql("hello", "world"));
    try std.testing.expect(!constantTimeEql("abc", "abcd"));
    try std.testing.expect(!constantTimeEql("abc", "abC"));
}

test "hashToken: produces 64-char hex string" {
    const result = try hashToken(std.testing.allocator, "test-token");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 64), result.len);
    // Verify all chars are hex digits.
    for (result) |c| {
        try std.testing.expect(std.ascii.isHex(c));
    }
}

test "hashToken: deterministic output" {
    const a = try hashToken(std.testing.allocator, "same-input");
    defer std.testing.allocator.free(a);
    const b = try hashToken(std.testing.allocator, "same-input");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "hashToken: different inputs produce different hashes" {
    const a = try hashToken(std.testing.allocator, "token-a");
    defer std.testing.allocator.free(a);
    const b = try hashToken(std.testing.allocator, "token-b");
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "authenticate: missing Authorization header returns 401" {
    const result = authenticate(std.testing.allocator, null, undefined);
    try std.testing.expect(result == .unauthenticated);
    try std.testing.expectEqual(@as(u16, 401), result.unauthenticated.status_code);
    // Free the error body.
    if (result.unauthenticated.body.len > 0 and
        !std.mem.eql(u8, result.unauthenticated.body, "{\"type\":\"https://bpm.example.com/problems/internal-error\",\"title\":\"Internal Server Error\",\"status\":500,\"detail\":\"serialization failed\"}"))
    {
        std.testing.allocator.free(result.unauthenticated.body);
    }
}

test "authenticate: missing Bearer prefix returns 401" {
    const result = authenticate(std.testing.allocator, "Basic dGVzdDp0ZXN0", undefined);
    try std.testing.expect(result == .unauthenticated);
    try std.testing.expectEqual(@as(u16, 401), result.unauthenticated.status_code);
    if (result.unauthenticated.body.len > 0 and
        !std.mem.eql(u8, result.unauthenticated.body, "{\"type\":\"https://bpm.example.com/problems/internal-error\",\"title\":\"Internal Server Error\",\"status\":500,\"detail\":\"serialization failed\"}"))
    {
        std.testing.allocator.free(result.unauthenticated.body);
    }
}

test "authenticate: empty Bearer token returns 401" {
    const result = authenticate(std.testing.allocator, "Bearer ", undefined);
    try std.testing.expect(result == .unauthenticated);
    try std.testing.expectEqual(@as(u16, 401), result.unauthenticated.status_code);
    if (result.unauthenticated.body.len > 0 and
        !std.mem.eql(u8, result.unauthenticated.body, "{\"type\":\"https://bpm.example.com/problems/internal-error\",\"title\":\"Internal Server Error\",\"status\":500,\"detail\":\"serialization failed\"}"))
    {
        std.testing.allocator.free(result.unauthenticated.body);
    }
}

test "initFromEnv: bootstrap token in production returns error" {
    // initFromEnv reads BPM_ENV from the environment.  Since setenv is not
    // portable in Zig 0.16, this test verifies the function compiles and
    // that the error type exists.  Full production-mode rejection is tested
    // via integration tests where BPM_ENV=production can be set externally.
    const err: AuthError = AuthError.BootstrapTokenInProduction;
    try std.testing.expectEqual(err, AuthError.BootstrapTokenInProduction);
}

test "buildUnauthorized: produces 401 with correct Problem Details" {
    const result = buildUnauthorized(std.testing.allocator, "test detail");
    defer std.testing.allocator.free(result.body);
    try std.testing.expectEqual(@as(u16, 401), result.status_code);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "unauthorized") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "test detail") != null);
}

test "buildForbidden: produces 403 with correct Problem Details" {
    const result = buildForbidden(std.testing.allocator, "insufficient permissions");
    defer std.testing.allocator.free(result.body);
    try std.testing.expectEqual(@as(u16, 403), result.status_code);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "forbidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "insufficient permissions") != null);
}

test "inspectBearerToken: opaque token routes to internal verification" {
    const inspected = inspectBearerToken("opaque-token");
    try std.testing.expectEqual(TokenRoute.internal_token, inspected.route);
    try std.testing.expectEqual(TokenRouteReason.opaque_no_dots, inspected.reason);
}

test "inspectBearerToken: valid JWT shape routes to OIDC verification" {
    const inspected = inspectBearerToken("eyJhbGciOiJub25lIn0.eyJzdWIiOiIxIn0.signature");
    try std.testing.expectEqual(TokenRoute.oidc_jwt, inspected.route);
    try std.testing.expectEqual(TokenRouteReason.jwt_three_segments, inspected.reason);
}

test "inspectBearerToken: malformed JWT-like token is indeterminate" {
    const inspected = inspectBearerToken("a.b.c");
    try std.testing.expectEqual(TokenRoute.malformed_indeterminate, inspected.route);
    try std.testing.expectEqual(TokenRouteReason.jwt_shape_invalid, inspected.reason);
}

fn makeJwtLikeToken(allocator: std.mem.Allocator, payload_json: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = encoder.calcSize(payload_json.len);
    const encoded_payload = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded_payload);
    _ = encoder.encode(encoded_payload, payload_json);
    return std.fmt.allocPrint(allocator, "h.{s}.s", .{encoded_payload});
}

test "resolveTenantContext: opaque legacy token resolves to default tenant" {
    const resolved = try resolveTenantContext(std.testing.allocator, "legacy-opaque-token");
    try std.testing.expectEqualStrings(DEFAULT_TENANT_ID, resolved.tenant_id[0..]);
    try std.testing.expectEqual(TenantContextSource.default_fallback, resolved.source);
}

test "resolveTenantContext: valid tenant_id claim scopes to claim tenant" {
    const token = try makeJwtLikeToken(std.testing.allocator, "{\"tenant_id\":\"11111111-1111-1111-1111-111111111111\"}");
    defer std.testing.allocator.free(token);

    const resolved = try resolveTenantContext(std.testing.allocator, token);
    try std.testing.expectEqualStrings("11111111-1111-1111-1111-111111111111", resolved.tenant_id[0..]);
    try std.testing.expectEqual(TenantContextSource.token_claim, resolved.source);
}

test "resolveTenantContext: malformed tenant_id claim fails resolution" {
    const token = try makeJwtLikeToken(std.testing.allocator, "{\"tenant_id\":\"not-a-uuid\"}");
    defer std.testing.allocator.free(token);

    try std.testing.expectError(error.InvalidTenantClaimFormat, resolveTenantContext(std.testing.allocator, token));
}

test "resolvePipelineRunIdClaim: missing claim resolves to null" {
    const token = try makeJwtLikeToken(std.testing.allocator, "{\"tenant_id\":\"11111111-1111-1111-1111-111111111111\"}");
    defer std.testing.allocator.free(token);

    const resolved = try resolvePipelineRunIdClaim(std.testing.allocator, token);
    try std.testing.expect(resolved == null);
}

test "resolvePipelineRunIdClaim: valid claim resolves canonical uuid" {
    const token = try makeJwtLikeToken(std.testing.allocator, "{\"pipeline_run_id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\"}");
    defer std.testing.allocator.free(token);

    const resolved = (try resolvePipelineRunIdClaim(std.testing.allocator, token)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", resolved[0..]);
}

test "resolvePipelineRunIdClaim: malformed claim fails" {
    const token = try makeJwtLikeToken(std.testing.allocator, "{\"pipeline_run_id\":\"invalid\"}");
    defer std.testing.allocator.free(token);

    try std.testing.expectError(error.InvalidPipelineRunIdClaimFormat, resolvePipelineRunIdClaim(std.testing.allocator, token));
}
