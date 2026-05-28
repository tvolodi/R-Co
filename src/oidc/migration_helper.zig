const std = @import("std");
const pool_mod = @import("pool");
const identity_provider = @import("identity_provider");

pub const MigrationCandidateFilter = struct {
    tenant_id: ?[]const u8 = null,
    page_size: u16 = 100,
    cursor: ?[]const u8 = null,
};

pub const UnlinkedUserCandidate = struct {
    local_user_id: []const u8,
    username: []const u8,
    email: []const u8,
    tenant_id: []const u8,
    suggested_provider_username: []const u8,

    pub fn deinit(self: UnlinkedUserCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.local_user_id);
        allocator.free(self.username);
        allocator.free(self.email);
        allocator.free(self.tenant_id);
        allocator.free(self.suggested_provider_username);
    }
};

pub const BulkProvisionRequest = struct {
    realm_id: []const u8,
    candidates: []const UnlinkedUserCandidate,
    dry_run: bool,
    idempotency_key: []const u8,
};

pub const BulkProvisionResult = struct {
    migration_job_id: []const u8,
    attempted: u32,
    provisioned: u32,
    linked: u32,
    failed: u32,

    pub fn deinit(self: BulkProvisionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.migration_job_id);
    }
};

pub const OidcMigrationHelperError = error{
    Unauthorized,
    CandidateQueryFailed,
    ProviderProvisionFailed,
    LinkUpdateFailed,
    JobPersistenceFailed,
    RollbackFailed,
    CoexistenceSafetyViolation,
    PoolExhausted,
    OutOfMemory,
};

pub fn listUnlinkedInternalUsers(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    filter: MigrationCandidateFilter,
) OidcMigrationHelperError![]UnlinkedUserCandidate {
    const conn = pool.acquire() catch return error.PoolExhausted;
    defer pool.release(conn);

    const limit = if (filter.page_size == 0) 100 else filter.page_size;
    const limit_text = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    defer allocator.free(limit_text);

    const rows = if (filter.tenant_id) |tenant_id|
        conn.query(
            allocator,
            \\SELECT u.id::text, u.username, COALESCE(u.email,''), u.tenant_id::text, COALESCE(u.username, '')
            \\FROM users u
            \\WHERE u.auth_source = 'internal'
            \\  AND u.external_id IS NULL
            \\  AND u.tenant_id = $1::uuid
            \\  AND u.username NOT LIKE 'agent-%'
            \\ORDER BY u.created_at ASC
            \\LIMIT $2::int
        ,
            &[_][]const u8{ tenant_id, limit_text },
        ) catch return error.CandidateQueryFailed
    else
        conn.query(
            allocator,
            \\SELECT u.id::text, u.username, COALESCE(u.email,''), COALESCE(u.tenant_id::text, '00000000-0000-0000-0000-000000000000'), COALESCE(u.username, '')
            \\FROM users u
            \\WHERE u.auth_source = 'internal'
            \\  AND u.external_id IS NULL
            \\  AND u.username NOT LIKE 'agent-%'
            \\ORDER BY u.created_at ASC
            \\LIMIT $1::int
        ,
            &[_][]const u8{limit_text},
        ) catch return error.CandidateQueryFailed;
    defer rows.deinit();

    var out = std.ArrayList(UnlinkedUserCandidate).empty;
    defer out.deinit(allocator);

    for (rows.rows) |row| {
        if (row.len < 5) continue;
        const id = row[0] orelse continue;
        const username = row[1] orelse continue;
        const email = row[2] orelse "";
        const tenant = row[3] orelse "00000000-0000-0000-0000-000000000000";
        const suggested = row[4] orelse username;
        try out.append(allocator, .{
            .local_user_id = try allocator.dupe(u8, id),
            .username = try allocator.dupe(u8, username),
            .email = try allocator.dupe(u8, email),
            .tenant_id = try allocator.dupe(u8, tenant),
            .suggested_provider_username = try allocator.dupe(u8, suggested),
        });
    }

    return out.toOwnedSlice(allocator);
}

pub fn provisionAndLinkUsers(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    manager: *const identity_provider.manager.Manager,
    request: BulkProvisionRequest,
) OidcMigrationHelperError!BulkProvisionResult {
    const conn = pool.acquire() catch return error.PoolExhausted;
    defer pool.release(conn);

    // UUID via DB for deterministic format.
    const uuid_row = conn.queryRow(allocator, "SELECT gen_random_uuid()::text", &[_][]const u8{}) catch return error.JobPersistenceFailed;
    const job_id = if (uuid_row) |r| blk: {
        defer {
            for (r) |col| if (col) |c| allocator.free(c);
            allocator.free(r);
        }
        break :blk try allocator.dupe(u8, r[0] orelse return error.JobPersistenceFailed);
    } else return error.JobPersistenceFailed;

    errdefer allocator.free(job_id);

    const attempted_txt = try std.fmt.allocPrint(allocator, "{d}", .{request.candidates.len});
    defer allocator.free(attempted_txt);

    _ = conn.exec(
        \\INSERT INTO oidc_migration_job
        \\(migration_job_id, realm_id, initiated_by, dry_run, status, attempted_count, provisioned_count, linked_count, failed_count)
        \\VALUES ($1::uuid, $2, 'system', $3::boolean, 'RUNNING', $4::int, 0, 0, 0)
    ,
        &[_][]const u8{ job_id, request.realm_id, if (request.dry_run) "true" else "false", attempted_txt },
    ) catch return error.JobPersistenceFailed;

    var provisioned: u32 = 0;
    var linked: u32 = 0;
    var failed: u32 = 0;

    for (request.candidates) |candidate| {
        if (request.dry_run) {
            continue;
        }

        const provider_result = manager.provisionUser(allocator, .{
            .tenant_id = candidate.tenant_id,
            .external_realm = request.realm_id,
            .external_id = candidate.local_user_id,
            .preferred_username = candidate.suggested_provider_username,
            .display_name = candidate.username,
            .email = if (candidate.email.len == 0) null else candidate.email,
            .initial_roles = &.{},
        }) catch {
            failed += 1;
            continue;
        };
        defer provider_result.deinit(allocator);
        provisioned += 1;

        _ = conn.exec(
            "UPDATE users SET auth_source='oidc', external_realm=$1, external_id=$2 WHERE id=$3::uuid",
            &[_][]const u8{ request.realm_id, provider_result.external_user_id, candidate.local_user_id },
        ) catch {
            failed += 1;
            continue;
        };
        linked += 1;
    }

    const status = if (failed == 0) "COMPLETED" else if (linked > 0) "PARTIAL" else "FAILED";
    const prov_txt = try std.fmt.allocPrint(allocator, "{d}", .{provisioned});
    defer allocator.free(prov_txt);
    const linked_txt = try std.fmt.allocPrint(allocator, "{d}", .{linked});
    defer allocator.free(linked_txt);
    const failed_txt = try std.fmt.allocPrint(allocator, "{d}", .{failed});
    defer allocator.free(failed_txt);

    _ = conn.exec(
        "UPDATE oidc_migration_job SET status=$1, provisioned_count=$2::int, linked_count=$3::int, failed_count=$4::int, completed_at=NOW() WHERE migration_job_id=$5::uuid",
        &[_][]const u8{ status, prov_txt, linked_txt, failed_txt, job_id },
    ) catch return error.JobPersistenceFailed;

    return .{
        .migration_job_id = job_id,
        .attempted = @intCast(request.candidates.len),
        .provisioned = provisioned,
        .linked = linked,
        .failed = failed,
    };
}

pub fn rollbackMigrationJob(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    migration_job_id: []const u8,
) OidcMigrationHelperError!void {
    _ = allocator;
    const conn = pool.acquire() catch return error.PoolExhausted;
    defer pool.release(conn);

    _ = conn.exec(
        "UPDATE oidc_migration_job SET status='ROLLED_BACK', completed_at=NOW() WHERE migration_job_id=$1::uuid",
        &[_][]const u8{migration_job_id},
    ) catch return error.RollbackFailed;
}
