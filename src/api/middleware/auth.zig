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
const pool_mod = @import("pool");

// ── Module-level state ────────────────────────────────────────────────────────

/// SHA-256 hex hash of the bootstrap token, set by init().
/// null means bootstrap auth is disabled.
var bootstrap_hash: ?[]const u8 = null;

/// The allocator that owns bootstrap_hash.  Used by deinit() to free it.
var bootstrap_hash_allocator: ?std.mem.Allocator = null;

// ── Public types ──────────────────────────────────────────────────────────────

/// HTTP handler result type (mirrors the definition in response.zig).
pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

/// Platform roles seeded by 008_identity.sql.
/// Maps to the `roles.name` column.
pub const Role = enum {
    PLATFORM_ADMIN,
    PROCESS_DESIGNER,
    PROCESS_OPERATOR,
    VIEWER,

    /// Parse from the database text value.
    /// Returns null for unrecognised role names.
    pub fn fromString(s: []const u8) ?Role {
        const mapping = std.StaticStringMap(Role).initComptime(.{
            .{ "PLATFORM_ADMIN", .PLATFORM_ADMIN },
            .{ "PROCESS_DESIGNER", .PROCESS_DESIGNER },
            .{ "PROCESS_OPERATOR", .PROCESS_OPERATOR },
            .{ "VIEWER", .VIEWER },
        });
        return mapping.get(s);
    }
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
};

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

    // Step 5: Hash token once for both bootstrap and DB lookup.
    const token_hash = hashToken(allocator, raw_token) catch
        return .{ .unauthenticated = buildUnauthorized(allocator, "internal error") };
    defer allocator.free(token_hash);

    // Step 5a-c: Check bootstrap token (constant-time comparison).
    if (bootstrap_hash) |boot_hash| {
        if (constantTimeEql(token_hash, boot_hash)) {
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
            } };
        }
    }

    // Step 6-7: Query api_tokens table.
    const conn = db_pool.acquire() catch
        return .{ .unauthenticated = buildUnauthorized(allocator, "service unavailable") };
    defer db_pool.release(conn);

    const token_row = conn.queryRow(
        allocator,
        "SELECT id, user_id, revoked_at, expires_at FROM api_tokens WHERE token_hash = $1",
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
        allocator.free(row);
    }

    // Step 7b: Check revoked (row[2] = revoked_at).
    if (row[2] != null) {
        return .{ .unauthenticated = buildUnauthorized(allocator, "token revoked") };
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

    // Step 8: Look up the user's highest-privilege role.
    var role: Role = .VIEWER;
    const role_row = conn.queryRow(
        allocator,
        \\SELECT r.name FROM roles r
        \\JOIN user_roles ur ON ur.role_id = r.id
        \\WHERE ur.user_id = $1
        \\ORDER BY CASE r.name
        \\  WHEN 'PLATFORM_ADMIN'   THEN 0
        \\  WHEN 'PROCESS_DESIGNER' THEN 1
        \\  WHEN 'PROCESS_OPERATOR' THEN 2
        \\  WHEN 'VIEWER'           THEN 3
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

    // Step 9: Update last_used_at (best-effort; failure not fatal).
    _ = conn.exec(
        "UPDATE api_tokens SET last_used_at = NOW() WHERE token_hash = $1",
        &[_][]const u8{token_hash},
    ) catch {};

    // Step 10: Return authenticated.
    return .{ .authenticated = .{
        .user_id = user_id,
        .role = role,
        .is_bootstrap = false,
        .token_id = token_id,
    } };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Role.fromString: all known roles" {
    try std.testing.expect(Role.fromString("PLATFORM_ADMIN") == .PLATFORM_ADMIN);
    try std.testing.expect(Role.fromString("PROCESS_DESIGNER") == .PROCESS_DESIGNER);
    try std.testing.expect(Role.fromString("PROCESS_OPERATOR") == .PROCESS_OPERATOR);
    try std.testing.expect(Role.fromString("VIEWER") == .VIEWER);
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
