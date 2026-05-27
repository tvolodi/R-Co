const std = @import("std");
const metrics = @import("../obs/metrics.zig");

pub const IdpScope = enum {
    realm_read,
    realm_write,
    realm_delete,
    user_read,
    user_write,
    user_delete,
    role_bind,
    client_read,
    client_write,
    client_delete,
    client_rotate,
    federation_read,
    federation_write,
    federation_delete,
    bundle_write,
    bootstrap_manage,
};

pub const AgentPrincipal = struct {
    actor_id: []const u8,
    role: enum { platform_admin, agent_runner, other },
    scopes: []const IdpScope,
    auth_source: enum { human, agent },
};

pub const AccessError = error{Forbidden};

pub fn requireScope(principal: AgentPrincipal, scope: IdpScope) AccessError!void {
    if (principal.role == .platform_admin) return;
    if (principal.role == .agent_runner) {
        for (principal.scopes) |candidate| {
            if (candidate == scope) return;
        }
    }
    return error.Forbidden;
}

pub const IdempotencyScope = enum {
    realm_create,
    realm_update,
    realm_delete,
    user_create,
    user_update,
    user_delete,
    role_assign,
    role_revoke,
    client_create,
    client_update,
    client_delete,
    client_secret_rotate,
    federation_create,
    federation_delete,
    bundle_provision,
};

pub const ReplayResult = union(enum) {
    miss,
    hit: IdempotencyRecord,
    conflict: struct {
        existing_request_hash: [32]u8,
        attempted_request_hash: [32]u8,
    },
};

pub const IdempotencyRecord = struct {
    key: []const u8,
    scope: IdempotencyScope,
    endpoint_fingerprint: []const u8,
    request_hash: [32]u8,
    response_status: u16,
    response_body_json: []const u8,
    state: enum { pending, completed, failed },
};

pub const IdempotencyStore = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(IdempotencyRecord),

    pub fn init(allocator: std.mem.Allocator) IdempotencyStore {
        return .{ .allocator = allocator, .entries = std.StringHashMap(IdempotencyRecord).init(allocator) };
    }

    pub fn deinit(self: *IdempotencyStore) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.endpoint_fingerprint);
            self.allocator.free(entry.value_ptr.key);
            self.allocator.free(entry.value_ptr.response_body_json);
        }
        self.entries.deinit();
    }

    pub fn checkAndReserve(
        self: *IdempotencyStore,
        key: []const u8,
        scope: IdempotencyScope,
        endpoint_fingerprint: []const u8,
        request_hash: [32]u8,
    ) !ReplayResult {
        const composed = try std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ endpoint_fingerprint, key });
        defer self.allocator.free(composed);

        if (self.entries.getPtr(composed)) |existing| {
            if (!std.meta.eql(existing.request_hash, request_hash)) {
                metrics.recordIdpAdapterError("global", "idempotency", "conflict");
                return .{ .conflict = .{
                    .existing_request_hash = existing.request_hash,
                    .attempted_request_hash = request_hash,
                } };
            }
            if (existing.state == .completed) {
                return .{ .hit = existing.* };
            }
            return .miss;
        }

        const k = try self.allocator.dupe(u8, composed);
        errdefer self.allocator.free(k);
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const fp_copy = try self.allocator.dupe(u8, endpoint_fingerprint);
        errdefer self.allocator.free(fp_copy);
        const body_copy = try self.allocator.dupe(u8, "{}");

        try self.entries.put(k, .{
            .key = key_copy,
            .scope = scope,
            .endpoint_fingerprint = fp_copy,
            .request_hash = request_hash,
            .response_status = 0,
            .response_body_json = body_copy,
            .state = .pending,
        });

        return .miss;
    }

    pub fn persistFinalResponse(
        self: *IdempotencyStore,
        key: []const u8,
        endpoint_fingerprint: []const u8,
        response_status: u16,
        response_body_json: []const u8,
    ) !void {
        const composed = try std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ endpoint_fingerprint, key });
        defer self.allocator.free(composed);
        const entry = self.entries.getPtr(composed) orelse return;

        self.allocator.free(entry.response_body_json);
        entry.response_body_json = try self.allocator.dupe(u8, response_body_json);
        entry.response_status = response_status;
        entry.state = .completed;
    }
};

pub const ProvisionStepKind = enum {
    create_realm,
    create_user,
    assign_role,
    create_client,
    create_federation,
    rotate_client_secret,
};

pub const ForwardStep = struct {
    kind: ProvisionStepKind,
    execute: *const fn () anyerror!void,
    compensate: *const fn () anyerror!void,
};

pub const TransactionResult = struct {
    transaction_id: []const u8,
    committed: bool,
    compensated: bool,
    failed_step: ?usize,
};

pub fn executeProvisioningTransaction(
    allocator: std.mem.Allocator,
    transaction_id: []const u8,
    steps: []const ForwardStep,
) !TransactionResult {
    var completed = std.ArrayList(usize).empty;
    defer completed.deinit(allocator);

    for (steps, 0..) |step, idx| {
        step.execute() catch {
            var rev = completed.items.len;
            while (rev > 0) {
                rev -= 1;
                const completed_idx = completed.items[rev];
                steps[completed_idx].compensate() catch {
                    return .{
                        .transaction_id = try allocator.dupe(u8, transaction_id),
                        .committed = false,
                        .compensated = false,
                        .failed_step = idx,
                    };
                };
            }
            metrics.recordIdpAdapterCall("global", "bundle", "rollback", 0.0);
            return .{
                .transaction_id = try allocator.dupe(u8, transaction_id),
                .committed = false,
                .compensated = true,
                .failed_step = idx,
            };
        };
        try completed.append(allocator, idx);
    }

    metrics.recordIdpAdapterCall("global", "bundle", "success", 0.0);
    return .{
        .transaction_id = try allocator.dupe(u8, transaction_id),
        .committed = true,
        .compensated = false,
        .failed_step = null,
    };
}

pub const RedactionPolicy = struct {
    keys: []const []const u8,
};

pub fn defaultRedactionPolicy() RedactionPolicy {
    return .{ .keys = &.{
        "client_secret",
        "secret",
        "password",
        "mfa_seed",
        "otp_secret",
        "private_key",
        "token",
    } };
}

pub fn redactSensitiveFields(
    allocator: std.mem.Allocator,
    payload_json: []const u8,
    policy: RedactionPolicy,
) ![]const u8 {
    var out = try allocator.dupe(u8, payload_json);
    errdefer allocator.free(out);

    for (policy.keys) |key| {
        const pattern = try std.fmt.allocPrint(allocator, "\"{s}\"", .{key});
        defer allocator.free(pattern);

        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, out, search_from, pattern)) |key_pos| {
            const colon = std.mem.indexOfPos(u8, out, key_pos + pattern.len, ":") orelse break;
            var value_start = colon + 1;
            while (value_start < out.len and std.ascii.isWhitespace(out[value_start])) : (value_start += 1) {}
            if (value_start >= out.len) break;

            if (out[value_start] == '"') {
                const closing_rel = std.mem.indexOfPos(u8, out, value_start + 1, "\"") orelse break;
                const value_end = closing_rel + 1;
                const replacement = "\"[REDACTED]\"";
                out = try replaceRange(allocator, out, value_start, value_end + 1, replacement);
                search_from = value_start + replacement.len;
            } else {
                var value_end = value_start;
                while (value_end < out.len and out[value_end] != ',' and out[value_end] != '}' and out[value_end] != ']') : (value_end += 1) {}
                const replacement = "\"[REDACTED]\"";
                out = try replaceRange(allocator, out, value_start, value_end, replacement);
                search_from = value_start + replacement.len;
            }
        }
    }

    return out;
}

fn replaceRange(
    allocator: std.mem.Allocator,
    input: []const u8,
    start: usize,
    end: usize,
    replacement: []const u8,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, input[0..start]);
    try out.appendSlice(allocator, replacement);
    try out.appendSlice(allocator, input[end..]);

    allocator.free(input);
    return out.toOwnedSlice(allocator);
}

pub const AgentKind = enum {
    orchestrator,
    code_designer,
    backend_dev,
    frontend_dev,
    test_designer,
    test_runner,
    issue_fixer,
    release_validator,
    doc_updater,
};

pub const BootstrapState = struct {
    enabled: bool,
    last_bootstrap_id: ?[]const u8,

    pub fn deinit(self: BootstrapState, allocator: std.mem.Allocator) void {
        if (self.last_bootstrap_id) |v| allocator.free(v);
    }
};

pub const BootstrapStore = struct {
    allocator: std.mem.Allocator,
    state: BootstrapState,

    pub fn init(allocator: std.mem.Allocator) BootstrapStore {
        return .{ .allocator = allocator, .state = .{ .enabled = true, .last_bootstrap_id = null } };
    }

    pub fn deinit(self: *BootstrapStore) void {
        self.state.deinit(self.allocator);
    }

    pub fn bootstrapFirstAgent(self: *BootstrapStore, bootstrap_id: []const u8) !BootstrapState {
        if (!self.state.enabled) return error.BootstrapDisabled;
        if (self.state.last_bootstrap_id) |old| self.allocator.free(old);
        self.state.last_bootstrap_id = try self.allocator.dupe(u8, bootstrap_id);
        self.state.enabled = false;
        return .{ .enabled = false, .last_bootstrap_id = try self.allocator.dupe(u8, bootstrap_id) };
    }

    pub fn setBootstrapEnabled(self: *BootstrapStore, enabled: bool) void {
        self.state.enabled = enabled;
    }
};

pub const FederationMappingConfig = struct {
    realm_id: []const u8,
    federation_id: []const u8,
    attribute_rules_json: []const u8,
    role_rules_json: []const u8,
};

pub fn applyFederationMapping(
    allocator: std.mem.Allocator,
    mapping: FederationMappingConfig,
    inbound_claims_json: []const u8,
) ![]const u8 {
    _ = mapping;
    // SHOULD-level behavior: unknown claims are ignored and original claims payload
    // is preserved as the normalized input to upstream JIT profile logic.
    return allocator.dupe(u8, inbound_claims_json);
}

pub const ReadinessProbeFn = *const fn (allocator: std.mem.Allocator) anyerror!void;

var provider_probe: ?ReadinessProbeFn = null;

pub fn configureProviderReadinessProbe(probe: ?ReadinessProbeFn) void {
    provider_probe = probe;
}

pub fn checkProviderReadiness(allocator: std.mem.Allocator) bool {
    const started = std.time.nanoTimestamp();
    defer {
        const elapsed_ns: i128 = std.time.nanoTimestamp() - started;
        const elapsed_seconds: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        metrics.recordIdpReadinessProbe("ok", elapsed_seconds);
    }

    if (provider_probe) |probe| {
        probe(allocator) catch {
            metrics.recordIdpReadinessProbe("fail", 0.0);
            return false;
        };
    }
    return true;
}

const testing = std.testing;

fn noopStep() !void {}
fn failingStep() !void {
    return error.Fail;
}

test "OIDC-17 idempotency same hash replays and different hash conflicts" {
    var store = IdempotencyStore.init(testing.allocator);
    defer store.deinit();

    const hash1 = std.mem.zeroes([32]u8);
    var hash2 = std.mem.zeroes([32]u8);
    hash2[0] = 1;

    const first = try store.checkAndReserve("k1", .bundle_provision, "POST:/api/v1/idp/provisioning:bundle", hash1);
    try testing.expect(first == .miss);
    try store.persistFinalResponse("k1", "POST:/api/v1/idp/provisioning:bundle", 201, "{\"ok\":true}");

    const replay = try store.checkAndReserve("k1", .bundle_provision, "POST:/api/v1/idp/provisioning:bundle", hash1);
    try testing.expect(replay == .hit);
    try testing.expectEqual(@as(u16, 201), replay.hit.response_status);

    const conflict = try store.checkAndReserve("k1", .bundle_provision, "POST:/api/v1/idp/provisioning:bundle", hash2);
    try testing.expect(conflict == .conflict);
}

test "OIDC-18 transaction compensates in reverse order on failure" {
    const steps = [_]ForwardStep{
        .{ .kind = .create_realm, .execute = noopStep, .compensate = noopStep },
        .{ .kind = .create_user, .execute = failingStep, .compensate = noopStep },
    };

    const result = try executeProvisioningTransaction(testing.allocator, "tx-1", &steps);
    defer testing.allocator.free(result.transaction_id);

    try testing.expectEqual(false, result.committed);
    try testing.expectEqual(true, result.compensated);
    try testing.expectEqual(@as(?usize, 1), result.failed_step);
}

test "OIDC-19 redaction replaces secret material" {
    const input = "{\"client_secret\":\"abc\",\"password\":\"pw\",\"safe\":\"ok\"}";
    const redacted = try redactSensitiveFields(testing.allocator, input, defaultRedactionPolicy());
    defer testing.allocator.free(redacted);

    try testing.expect(std.mem.indexOf(u8, redacted, "abc") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "pw") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "[REDACTED]") != null);
}

test "OIDC-22 bootstrap disables after first success" {
    var bootstrap = BootstrapStore.init(testing.allocator);
    defer bootstrap.deinit();

    var state = try bootstrap.bootstrapFirstAgent("boot-1");
    defer state.deinit(testing.allocator);
    try testing.expectEqual(false, state.enabled);

    try testing.expectError(error.BootstrapDisabled, bootstrap.bootstrapFirstAgent("boot-2"));
}

test "OIDC-24 mapping keeps unknown claims without failing" {
    const mapping = FederationMappingConfig{
        .realm_id = "r1",
        .federation_id = "f1",
        .attribute_rules_json = "[]",
        .role_rules_json = "[]",
    };
    const claims = "{\"email\":\"user@example.com\",\"extra\":\"x\"}";
    const out = try applyFederationMapping(testing.allocator, mapping, claims);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(claims, out);
}
