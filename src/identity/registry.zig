const std = @import("std");
const pool_mod = @import("pool");

pub const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

pub const UserStatus = enum {
    ACTIVE,
    INACTIVE,

    pub fn fromString(s: []const u8) ?UserStatus {
        if (std.mem.eql(u8, s, "ACTIVE")) return .ACTIVE;
        if (std.mem.eql(u8, s, "INACTIVE")) return .INACTIVE;
        return null;
    }

    pub fn asString(self: UserStatus) []const u8 {
        return switch (self) {
            .ACTIVE => "ACTIVE",
            .INACTIVE => "INACTIVE",
        };
    }
};

pub const TenantStatus = enum {
    ACTIVE,
    INACTIVE,

    pub fn fromString(s: []const u8) ?TenantStatus {
        if (std.mem.eql(u8, s, "ACTIVE")) return .ACTIVE;
        if (std.mem.eql(u8, s, "INACTIVE")) return .INACTIVE;
        return null;
    }

    pub fn asString(self: TenantStatus) []const u8 {
        return switch (self) {
            .ACTIVE => "ACTIVE",
            .INACTIVE => "INACTIVE",
        };
    }
};

pub const User = struct {
    user_id: []const u8,
    username: []const u8,
    display_name: []const u8,
    email: []const u8,
    status: UserStatus,
    created_at: []const u8,

    pub fn deinit(self: User, allocator: std.mem.Allocator) void {
        allocator.free(self.user_id);
        allocator.free(self.username);
        allocator.free(self.display_name);
        allocator.free(self.email);
        allocator.free(self.created_at);
    }
};

pub const Tenant = struct {
    tenant_id: []const u8,
    slug: []const u8,
    display_name: []const u8,
    status: TenantStatus,
    idp_realm_id: ?[]const u8,
    created_at: []const u8,
    // ENV-01: test tenant environment
    tenant_type: []const u8,              // 'production' or 'test'
    production_tenant_id: ?[]const u8,   // UUID string, non-null only for test tenants

    pub fn deinit(self: Tenant, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.slug);
        allocator.free(self.display_name);
        if (self.idp_realm_id) |v| allocator.free(v);
        allocator.free(self.created_at);
        allocator.free(self.tenant_type);
        if (self.production_tenant_id) |v| allocator.free(v);
    }
};

pub const Group = struct {
    group_id: []const u8,
    name: []const u8,
    display_name: []const u8,
    description: []const u8,
    is_system: bool,
    member_count: u64,
    created_at: []const u8,

    pub fn deinit(self: Group, allocator: std.mem.Allocator) void {
        allocator.free(self.group_id);
        allocator.free(self.name);
        allocator.free(self.display_name);
        allocator.free(self.description);
        allocator.free(self.created_at);
    }
};

pub const GroupListPage = struct {
    items: []Group,
    total: u64,

    pub fn deinit(self: GroupListPage, allocator: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const GroupMember = struct {
    group_id: []const u8,
    user_id: []const u8,
    added_at: []const u8,

    pub fn deinit(self: GroupMember, allocator: std.mem.Allocator) void {
        allocator.free(self.group_id);
        allocator.free(self.user_id);
        allocator.free(self.added_at);
    }
};

pub const GroupMemberRecord = struct {
    member: User,
    added_at_us: i64,

    pub fn deinit(self: GroupMemberRecord, allocator: std.mem.Allocator) void {
        self.member.deinit(allocator);
    }
};

pub const CreateUserInput = struct {
    username: []const u8,
    display_name: []const u8,
    email: []const u8,
    status: UserStatus,
};

pub const CreateOidcUserInput = struct {
    username: []const u8,
    display_name: []const u8,
    email: []const u8,
    status: UserStatus,
    external_realm: []const u8,
    external_id: []const u8,
};

pub const CreateTenantInput = struct {
    tenant_id: ?[]const u8,
    slug: []const u8,
    display_name: []const u8,
    status: TenantStatus,
    idp_realm_id: ?[]const u8,
};

pub const ListUsersParams = struct {
    search: ?[]const u8,
    status: ?UserStatus,
    limit: u16,
    offset: u32,
};

pub const ListTenantsParams = struct {
    search: ?[]const u8,
    limit: u16,
    offset: u32,
};

pub const TenantListPage = struct {
    items: []Tenant,
    total: u64,

    pub fn deinit(self: TenantListPage, allocator: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const UserListPage = struct {
    items: []User,
    total: u64,

    pub fn deinit(self: UserListPage, allocator: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

/// A single role binding row from user_roles joined with roles.
pub const UserRoleBinding = struct {
    role_slug: []const u8,
    role_source: []const u8, // "oidc" or "internal"

    pub fn deinit(self: *UserRoleBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.role_slug);
        allocator.free(self.role_source);
    }
};

pub const RegistryError = error{
    DuplicateUsername,
    DuplicateTenantSlug,
    DuplicateRealmBinding,
    DuplicateGroupName,
    ExternalIdentityCollision,
    NotFound,
    TenantNotFound,
    GroupNotFound,
    UserNotFound,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

pub const Registry = struct {
    pool: *pool_mod.Pool,

    pub fn init(pool: *pool_mod.Pool) Registry {
        return .{ .pool = pool };
    }

    pub fn createUser(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        input: CreateUserInput,
    ) RegistryError!User {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const exists = conn.queryRow(
            allocator,
            "SELECT id::text FROM users WHERE username = $1 LIMIT 1",
            &[_][]const u8{input.username},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        if (exists) |row| {
            defer freeRow(allocator, row);
            return error.DuplicateUsername;
        }

        const active_str: []const u8 = switch (input.status) {
            .ACTIVE => "true",
            .INACTIVE => "false",
        };
        const status_str = input.status.asString();

        const row = conn.queryRow(
            allocator,
            \\INSERT INTO users (tenant_id, email, display_name, password_hash, is_active, username, status)
            \\VALUES ($1::uuid, $2, $3, $4, $5::boolean, $6, $7)
            \\RETURNING id::text, username, display_name, email, status, created_at::text
        ,
            &[_][]const u8{
                tenant_id,
                input.email,
                input.display_name,
                "__API_ONLY__",
                active_str,
                input.username,
                status_str,
            },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (row == null) return error.PersistenceFailed;
        return materializeUser(allocator, row.?);
    }

    pub fn createTenant(
        self: *Registry,
        allocator: std.mem.Allocator,
        input: CreateTenantInput,
    ) RegistryError!Tenant {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        if (input.idp_realm_id) |realm| {
            if (try self.selectTenantByRealmId(allocator, realm)) |existing| {
                existing.deinit(allocator);
                return error.DuplicateRealmBinding;
            }
        }

        const status_str = input.status.asString();

        const row = blk: {
            if (input.tenant_id) |tenant_id| {
                if (input.idp_realm_id) |realm| {
                    break :blk conn.queryRow(
                        allocator,
                        \\INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
                        \\VALUES ($1::uuid, $2, $3, $4, $5)
                        \\ON CONFLICT (slug) DO NOTHING
                        \\RETURNING id::text, slug, display_name, status, idp_realm_id, created_at::text,
                        \\          tenant_type, production_tenant_id::text
                    ,
                        &[_][]const u8{ tenant_id, input.slug, input.display_name, status_str, realm },
                    );
                }

                break :blk conn.queryRow(
                    allocator,
                    \\INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
                    \\VALUES ($1::uuid, $2, $3, $4, NULL)
                    \\ON CONFLICT (slug) DO NOTHING
                    \\RETURNING id::text, slug, display_name, status, idp_realm_id, created_at::text,
                    \\          tenant_type, production_tenant_id::text
                ,
                    &[_][]const u8{ tenant_id, input.slug, input.display_name, status_str },
                );
            }

            if (input.idp_realm_id) |realm| {
                break :blk conn.queryRow(
                    allocator,
                    \\INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
                    \\VALUES (gen_random_uuid(), $1, $2, $3, $4)
                    \\ON CONFLICT (slug) DO NOTHING
                    \\RETURNING id::text, slug, display_name, status, idp_realm_id, created_at::text,
                    \\          tenant_type, production_tenant_id::text
                ,
                    &[_][]const u8{ input.slug, input.display_name, status_str, realm },
                );
            }

            break :blk conn.queryRow(
                allocator,
                \\INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
                \\VALUES (gen_random_uuid(), $1, $2, $3, NULL)
                \\ON CONFLICT (slug) DO NOTHING
                \\RETURNING id::text, slug, display_name, status, idp_realm_id, created_at::text,
                \\          tenant_type, production_tenant_id::text
            ,
                &[_][]const u8{ input.slug, input.display_name, status_str },
            );
        };

        const inserted = row catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (inserted == null) return error.DuplicateTenantSlug;
        return materializeTenant(allocator, inserted.?);
    }

    pub fn selectTenantById(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
    ) RegistryError!?Tenant {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const row = conn.queryRow(
            allocator,
            \\SELECT id::text, slug, display_name, status, idp_realm_id, created_at::text,
            \\       tenant_type, production_tenant_id::text
            \\FROM tenant
            \\WHERE id = $1::uuid
            \\LIMIT 1
        ,
            &[_][]const u8{tenant_id},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (row == null) return null;
        const tenant = try materializeTenant(allocator, row.?);
        return tenant;
    }

    pub fn selectTenantByRealmId(
        self: *Registry,
        allocator: std.mem.Allocator,
        realm_id: []const u8,
    ) RegistryError!?Tenant {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const row = conn.queryRow(
            allocator,
            \\SELECT id::text, slug, display_name, status, idp_realm_id, created_at::text,
            \\       tenant_type, production_tenant_id::text
            \\FROM tenant
            \\WHERE idp_realm_id = $1
            \\LIMIT 1
        ,
            &[_][]const u8{realm_id},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (row == null) return null;
        const tenant = try materializeTenant(allocator, row.?);
        return tenant;
    }

    pub fn selectTenantBySlug(
        self: *Registry,
        allocator: std.mem.Allocator,
        slug: []const u8,
    ) RegistryError!?Tenant {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const row = conn.queryRow(
            allocator,
            \\SELECT id::text, slug, display_name, status, idp_realm_id, created_at::text,
            \\       tenant_type, production_tenant_id::text
            \\FROM tenant
            \\WHERE slug = $1
            \\LIMIT 1
        ,
            &[_][]const u8{slug},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (row == null) return null;
        return try materializeTenant(allocator, row.?);
    }

    pub fn updateTenantDisplayName(
        self: *Registry,
        allocator: std.mem.Allocator,
        slug: []const u8,
        display_name: []const u8,
    ) RegistryError!Tenant {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const row = conn.queryRow(
            allocator,
            \\UPDATE tenant
            \\SET display_name = $2, updated_at = NOW()
            \\WHERE slug = $1
            \\RETURNING id::text, slug, display_name, status, idp_realm_id, created_at::text,
            \\          tenant_type, production_tenant_id::text
        ,
            &[_][]const u8{ slug, display_name },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (row == null) return error.TenantNotFound;
        return materializeTenant(allocator, row.?);
    }

    pub fn updateTenantStatusBySlug(
        self: *Registry,
        allocator: std.mem.Allocator,
        slug: []const u8,
        status: TenantStatus,
    ) RegistryError!Tenant {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const row = conn.queryRow(
            allocator,
            \\UPDATE tenant
            \\SET status = $2, updated_at = NOW()
            \\WHERE slug = $1
            \\RETURNING id::text, slug, display_name, status, idp_realm_id, created_at::text,
            \\          tenant_type, production_tenant_id::text
        ,
            &[_][]const u8{ slug, status.asString() },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (row == null) return error.TenantNotFound;
        return materializeTenant(allocator, row.?);
    }

    pub fn listTenants(
        self: *Registry,
        allocator: std.mem.Allocator,
        params: ListTenantsParams,
    ) RegistryError!TenantListPage {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const search_text = params.search orelse "";
        const offset_text = std.fmt.allocPrint(allocator, "{d}", .{params.offset}) catch return error.OutOfMemory;
        defer allocator.free(offset_text);
        const limit_text = std.fmt.allocPrint(allocator, "{d}", .{params.limit}) catch return error.OutOfMemory;
        defer allocator.free(limit_text);

        const count_row = conn.queryRow(
            allocator,
            \\SELECT COUNT(*)::text
            \\FROM tenant
            \\WHERE ($1 = '' OR slug ILIKE '%' || $1 || '%' OR display_name ILIKE '%' || $1 || '%')
        ,
            &[_][]const u8{search_text},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (count_row == null) return error.PersistenceFailed;
        defer freeRow(allocator, count_row.?);
        const total_raw = count_row.?[0] orelse return error.PersistenceFailed;
        const total = std.fmt.parseInt(u64, total_raw, 10) catch return error.PersistenceFailed;

        var rows = conn.query(
            allocator,
            \\SELECT id::text, slug, display_name, status, idp_realm_id, created_at::text,
            \\       tenant_type, production_tenant_id::text
            \\FROM tenant
            \\WHERE ($1 = '' OR slug ILIKE '%' || $1 || '%' OR display_name ILIKE '%' || $1 || '%')
            \\ORDER BY created_at DESC
            \\OFFSET $2::int
            \\LIMIT $3::int
        ,
            &[_][]const u8{ search_text, offset_text, limit_text },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer rows.deinit();

        const items = allocator.alloc(Tenant, rows.rows.len) catch return error.OutOfMemory;
        var initialized: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized) : (i += 1) {
                items[i].deinit(allocator);
            }
            allocator.free(items);
        }

        for (rows.rows, 0..) |row, idx| {
            items[idx] = try materializeTenantBorrowedRow(allocator, row);
            initialized += 1;
        }

        return .{ .items = items, .total = total };
    }

    pub fn updateUserStatus(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        user_id: []const u8,
        status: UserStatus,
    ) RegistryError!User {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const status_str = status.asString();
        const active_str: []const u8 = switch (status) {
            .ACTIVE => "true",
            .INACTIVE => "false",
        };

        const row = conn.queryRow(
            allocator,
            \\UPDATE users
            \\SET status = $3, is_active = $4::boolean, updated_at = NOW()
            \\WHERE id::text = $1 AND tenant_id = $2::uuid
            \\RETURNING id::text, username, display_name, email, status, created_at::text
        ,
            &[_][]const u8{ user_id, tenant_id, status_str, active_str },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (row == null) return error.NotFound;
        return materializeUser(allocator, row.?);
    }

    pub fn getUserStatusById(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        user_id: []const u8,
    ) RegistryError!?UserStatus {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const row = conn.queryRow(
            allocator,
            "SELECT status, is_active::text FROM users WHERE id::text = $1 AND tenant_id = $2::uuid",
            &[_][]const u8{ user_id, tenant_id },
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

        const status_raw = row.?[0] orelse "";
        if (UserStatus.fromString(status_raw)) |s| return s;

        const active_raw = row.?[1] orelse "f";
        if (std.mem.eql(u8, active_raw, "t") or std.mem.eql(u8, active_raw, "true")) {
            return .ACTIVE;
        }
        return .INACTIVE;
    }

    pub fn getUserById(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        user_id: []const u8,
    ) RegistryError!?User {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const row = conn.queryRow(
            allocator,
            \\SELECT id::text, username, display_name, email, status, created_at::text
            \\FROM users
            \\WHERE id::text = $1 AND tenant_id = $2::uuid
            \\LIMIT 1
        ,
            &[_][]const u8{ user_id, tenant_id },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (row == null) return null;
        return try materializeUser(allocator, row.?);
    }

    pub fn listUsers(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        params: ListUsersParams,
    ) RegistryError!UserListPage {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const search_text = params.search orelse "";
        const status_text = if (params.status) |status| status.asString() else "";
        const offset_text = std.fmt.allocPrint(allocator, "{d}", .{params.offset}) catch return error.OutOfMemory;
        defer allocator.free(offset_text);
        const limit_text = std.fmt.allocPrint(allocator, "{d}", .{params.limit}) catch return error.OutOfMemory;
        defer allocator.free(limit_text);

        const count_row = conn.queryRow(
            allocator,
            \\SELECT COUNT(*)::text
            \\FROM users
            \\WHERE tenant_id = $1::uuid
            \\  AND ($2 = '' OR username ILIKE '%' || $2 || '%' OR display_name ILIKE '%' || $2 || '%' OR email ILIKE '%' || $2 || '%')
            \\  AND ($3 = '' OR status = $3)
        ,
            &[_][]const u8{ tenant_id, search_text, status_text },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (count_row == null) return error.PersistenceFailed;
        defer freeRow(allocator, count_row.?);
        const total_raw = count_row.?[0] orelse return error.PersistenceFailed;
        const total = std.fmt.parseInt(u64, total_raw, 10) catch return error.PersistenceFailed;

        var rows = conn.query(
            allocator,
            \\SELECT id::text, username, display_name, email, status, created_at::text
            \\FROM users
            \\WHERE tenant_id = $1::uuid
            \\  AND ($2 = '' OR username ILIKE '%' || $2 || '%' OR display_name ILIKE '%' || $2 || '%' OR email ILIKE '%' || $2 || '%')
            \\  AND ($3 = '' OR status = $3)
            \\ORDER BY created_at DESC, id DESC
            \\OFFSET $4::int
            \\LIMIT $5::int
        ,
            &[_][]const u8{ tenant_id, search_text, status_text, offset_text, limit_text },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer rows.deinit();

        const items = allocator.alloc(User, rows.rows.len) catch return error.OutOfMemory;
        var initialized: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized) : (i += 1) {
                items[i].deinit(allocator);
            }
            allocator.free(items);
        }

        for (rows.rows, 0..) |row, idx| {
            items[idx] = try materializeUserBorrowedRow(allocator, row);
            initialized += 1;
        }

        return .{ .items = items, .total = total };
    }

    pub fn selectUserByExternalIdentity(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        external_realm: []const u8,
        external_id: []const u8,
    ) RegistryError!?User {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const row = conn.queryRow(
            allocator,
            \\SELECT id::text, username, display_name, email, status, created_at::text
            \\FROM users
            \\WHERE tenant_id = $1::uuid
            \\  AND external_realm = $2
            \\  AND external_id = $3
            \\LIMIT 1
        ,
            &[_][]const u8{ tenant_id, external_realm, external_id },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (row == null) return null;
        const user = try materializeUser(allocator, row.?);
        return user;
    }

    pub fn createOrGetJitOidcUser(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        input: CreateOidcUserInput,
    ) RegistryError!struct { user: User, created: bool } {
        if (try self.selectUserByExternalIdentity(allocator, tenant_id, input.external_realm, input.external_id)) |existing| {
            return .{ .user = existing, .created = false };
        }

        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const active_str: []const u8 = switch (input.status) {
            .ACTIVE => "true",
            .INACTIVE => "false",
        };
        const status_str = input.status.asString();

        const inserted = conn.queryRow(
            allocator,
            \\INSERT INTO users (
            \\    tenant_id,
            \\    email,
            \\    display_name,
            \\    password_hash,
            \\    is_active,
            \\    username,
            \\    status,
            \\    auth_source,
            \\    external_realm,
            \\    external_id
            \\)
            \\VALUES ($1::uuid, $2, $3, $4, $5::boolean, $6, $7, 'oidc', $8, $9)
            \\ON CONFLICT (external_realm, external_id) WHERE external_id IS NOT NULL DO NOTHING
            \\RETURNING id::text, username, display_name, email, status, created_at::text
        ,
            &[_][]const u8{
                tenant_id,
                input.email,
                input.display_name,
                "__OIDC_ONLY__",
                active_str,
                input.username,
                status_str,
                input.external_realm,
                input.external_id,
            },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (inserted) |row| {
            return .{ .user = try materializeUser(allocator, row), .created = true };
        }

        if (try self.selectUserByExternalIdentity(allocator, tenant_id, input.external_realm, input.external_id)) |existing| {
            return .{ .user = existing, .created = false };
        }

        return error.ExternalIdentityCollision;
    }

    /// Update display_name, email, and status for a user.
    /// Returns the updated User record.
    /// Returns error.NotFound if the user does not exist.
    pub fn updateUserProfile(
        self: *Registry,
        allocator: std.mem.Allocator,
        user_id: []const u8,
        tenant_id: []const u8,
        display_name: []const u8,
        email: []const u8,
        status: UserStatus,
    ) RegistryError!User {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const status_str = status.asString();
        const active_str: []const u8 = switch (status) {
            .ACTIVE => "true",
            .INACTIVE => "false",
        };

        const row = conn.queryRow(
            allocator,
            \\UPDATE users
            \\SET display_name = $3, email = $4, status = $5,
            \\    is_active = $6::boolean, updated_at = NOW()
            \\WHERE id::text = $1 AND tenant_id = $2::uuid
            \\RETURNING id::text, username, display_name, email, status, created_at::text
        ,
            &[_][]const u8{ user_id, tenant_id, display_name, email, status_str, active_str },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (row == null) return error.NotFound;
        return materializeUser(allocator, row.?);
    }

    /// Read all role bindings for a user, including the source column.
    pub fn selectUserRoles(
        self: *Registry,
        allocator: std.mem.Allocator,
        user_id: []const u8,
    ) RegistryError![]UserRoleBinding {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const rows = conn.query(
            allocator,
            \\SELECT r.name AS role_slug, ur.role_source
            \\FROM user_roles ur
            \\JOIN roles r ON r.id = ur.role_id
            \\WHERE ur.user_id = $1::uuid
        ,
            &[_][]const u8{user_id},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        errdefer {
            for (rows) |row| freeRow(allocator, row);
            allocator.free(rows);
        }

        const result = try allocator.alloc(UserRoleBinding, rows.len);
        errdefer {
            for (result) |*b| b.deinit(allocator);
            allocator.free(result);
        }

        for (rows, 0..) |row, i| {
            const role_slug = row[0] orelse return error.PersistenceFailed;
            const role_source = row[1] orelse return error.PersistenceFailed;
            result[i] = .{
                .role_slug = try allocator.dupe(u8, role_slug),
                .role_source = try allocator.dupe(u8, role_source),
            };
        }

        return result;
    }

    /// Insert an OIDC-sourced role binding for a user.
    /// Looks up the role_id from the `roles` table by slug.
    /// Idempotent: ON CONFLICT DO NOTHING.
    pub fn insertOidcRoleBinding(
        self: *Registry,
        allocator: std.mem.Allocator,
        user_id: []const u8,
        role_slug: []const u8,
    ) RegistryError!void {
        _ = allocator;
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        _ = conn.exec(
            \\INSERT INTO user_roles (user_id, role_id, role_source)
            \\SELECT $1::uuid, r.id, 'oidc'
            \\FROM roles r
            \\WHERE r.name = $2
            \\  AND NOT EXISTS (
            \\    SELECT 1 FROM user_roles ur
            \\    WHERE ur.user_id = $1::uuid AND ur.role_id = r.id
            \\  )
            \\ON CONFLICT (user_id, role_id) DO NOTHING
        ,
            &[_][]const u8{ user_id, role_slug },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
    }

    /// Delete an OIDC-sourced role binding for a user.
    /// Only deletes rows where role_source = 'oidc'.
    /// Idempotent: no-op if the binding does not exist or is not OIDC-sourced.
    pub fn deleteOidcRoleBinding(
        self: *Registry,
        allocator: std.mem.Allocator,
        user_id: []const u8,
        role_slug: []const u8,
    ) RegistryError!void {
        _ = allocator;
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        _ = conn.exec(
            \\DELETE FROM user_roles
            \\WHERE user_id = $1::uuid
            \\  AND role_id = (SELECT id FROM roles WHERE name = $2)
            \\  AND role_source = 'oidc'
        ,
            &[_][]const u8{ user_id, role_slug },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
    }

    pub fn createGroup(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        name: []const u8,
        display_name: []const u8,
        description: ?[]const u8,
    ) RegistryError!Group {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const row = conn.queryRow(
            allocator,
            \\INSERT INTO groups (tenant_id, name, display_name, description, is_system)
            \\VALUES ($1::uuid, $2, $3, $4, false)
            \\ON CONFLICT (name) DO NOTHING
            \\RETURNING id::text,
            \\          name,
            \\          display_name,
            \\          COALESCE(description, ''),
            \\          is_system::text,
            \\          created_at::text,
            \\          '0'
        ,
            &[_][]const u8{ tenant_id, name, display_name, description orelse "" },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (row == null) return error.DuplicateGroupName;
        return materializeGroup(allocator, row.?);
    }

    pub fn listGroups(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
    ) RegistryError!GroupListPage {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        var rows = conn.query(
            allocator,
            \\SELECT g.id::text,
            \\       g.name,
            \\       g.display_name,
            \\       COALESCE(g.description, ''),
            \\       g.is_system::text,
            \\       g.created_at::text,
            \\       COUNT(gm.user_id)::text
            \\FROM groups g
            \\LEFT JOIN group_members gm ON gm.group_id = g.id
            \\WHERE g.tenant_id = $1::uuid
            \\GROUP BY g.id, g.name, g.display_name, g.description, g.is_system, g.created_at
            \\ORDER BY g.name ASC
        ,
            &[_][]const u8{tenant_id},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer rows.deinit();

        const items = allocator.alloc(Group, rows.rows.len) catch return error.OutOfMemory;
        errdefer allocator.free(items);

        var count: usize = 0;
        errdefer {
            for (items[0..count]) |item| item.deinit(allocator);
        }

        for (rows.rows) |row| {
            items[count] = materializeGroupBorrowedRow(allocator, row) catch return error.OutOfMemory;
            count += 1;
        }

        return .{ .items = items, .total = @as(u64, @intCast(count)) };
    }

    pub fn deleteGroupIfEmpty(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        group_id: []const u8,
    ) RegistryError!bool {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const deleted = conn.queryRow(
            allocator,
            \\DELETE FROM groups g
            \\WHERE g.tenant_id = $1::uuid
            \\  AND g.id = $2::uuid
            \\  AND NOT EXISTS (
            \\      SELECT 1
            \\      FROM group_members gm
            \\      WHERE gm.group_id = g.id
            \\  )
            \\RETURNING 1::text
        ,
            &[_][]const u8{ tenant_id, group_id },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (deleted) |row| {
            freeRow(allocator, row);
            return true;
        }
        return false;
    }

    pub fn groupExists(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        group_id: []const u8,
    ) RegistryError!bool {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const row = conn.queryRow(
            allocator,
            "SELECT id::text FROM groups WHERE id::text = $1 AND tenant_id = $2::uuid LIMIT 1",
            &[_][]const u8{ group_id, tenant_id },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        if (row == null) return false;
        defer freeRow(allocator, row.?);
        return true;
    }

    pub fn addGroupMember(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        group_id: []const u8,
        user_id: []const u8,
    ) RegistryError!struct { member: GroupMember, created: bool } {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const inserted = conn.queryRow(
            allocator,
            \\INSERT INTO group_members (group_id, user_id)
            \\SELECT g.id, u.id
            \\FROM groups g
            \\JOIN users u ON u.id = $3::uuid
            \\WHERE g.id = $2::uuid
            \\  AND g.tenant_id = $1::uuid
            \\  AND u.tenant_id = $1::uuid
            \\ON CONFLICT (group_id, user_id) DO NOTHING
            \\RETURNING group_id::text, user_id::text, added_at::text
        ,
            &[_][]const u8{ tenant_id, group_id, user_id },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (inserted) |row| {
            return .{ .member = materializeGroupMember(allocator, row) catch return error.OutOfMemory, .created = true };
        }

        const existing = conn.queryRow(
            allocator,
            \\SELECT gm.group_id::text, gm.user_id::text, gm.added_at::text
            \\FROM group_members gm
            \\JOIN groups g ON g.id = gm.group_id
            \\JOIN users u ON u.id = gm.user_id
            \\WHERE gm.group_id = $2::uuid
            \\  AND gm.user_id = $3::uuid
            \\  AND g.tenant_id = $1::uuid
            \\  AND u.tenant_id = $1::uuid
        ,
            &[_][]const u8{ tenant_id, group_id, user_id },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (existing == null) return error.PersistenceFailed;
        return .{ .member = materializeGroupMember(allocator, existing.?) catch return error.OutOfMemory, .created = false };
    }

    pub fn removeGroupMember(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        group_id: []const u8,
        user_id: []const u8,
    ) RegistryError!void {
        _ = allocator;
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        _ = conn.exec(
            \\DELETE FROM group_members gm
            \\USING groups g
            \\WHERE gm.group_id = $2::uuid
            \\  AND gm.user_id = $3::uuid
            \\  AND g.id = gm.group_id
            \\  AND g.tenant_id = $1::uuid
        ,
            &[_][]const u8{ tenant_id, group_id, user_id },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
    }

    pub fn listGroupMemberRecords(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        group_id: []const u8,
        cursor_added_at_us: ?i64,
        cursor_user_id: ?[]const u8,
        page_size: u16,
    ) RegistryError![]GroupMemberRecord {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var params = std.ArrayList([]const u8).empty;
        var conditions = std.ArrayList([]const u8).empty;

        params.append(a, group_id) catch return error.PersistenceFailed;
        conditions.append(a, "gm.group_id = $1::uuid") catch return error.PersistenceFailed;
        params.append(a, tenant_id) catch return error.PersistenceFailed;
        conditions.append(a, "g.tenant_id = $2::uuid") catch return error.PersistenceFailed;
        conditions.append(a, "u.tenant_id = $2::uuid") catch return error.PersistenceFailed;

        if (cursor_added_at_us) |added_at_us| {
            if (cursor_user_id) |cur_user_id| {
                const added_str = std.fmt.allocPrint(a, "{d}", .{added_at_us}) catch return error.PersistenceFailed;
                params.append(a, added_str) catch return error.PersistenceFailed;
                const added_idx = params.items.len;

                params.append(a, cur_user_id) catch return error.PersistenceFailed;
                const user_idx = params.items.len;

                const cond = std.fmt.allocPrint(
                    a,
                    "(gm.added_at, gm.user_id) < (to_timestamp(${d}::bigint / 1000000.0), ${d}::uuid)",
                    .{ added_idx, user_idx },
                ) catch return error.PersistenceFailed;
                conditions.append(a, cond) catch return error.PersistenceFailed;
            }
        }

        const fetch_size: u32 = @as(u32, page_size) + 1;
        const fetch_str = std.fmt.allocPrint(a, "{d}", .{fetch_size}) catch return error.PersistenceFailed;
        params.append(a, fetch_str) catch return error.PersistenceFailed;
        const limit_idx = params.items.len;

        var sql_buf = std.ArrayList(u8).empty;
        sql_buf.appendSlice(a,
            \\SELECT
            \\    gm.group_id::text,
            \\    gm.user_id::text,
            \\    u.username,
            \\    u.display_name,
            \\    u.email,
            \\    u.status,
            \\    u.created_at::text,
            \\    (EXTRACT(EPOCH FROM gm.added_at) * 1000000)::bigint
            \\FROM group_members gm
            \\JOIN users u ON u.id = gm.user_id
            \\JOIN groups g ON g.id = gm.group_id
        ) catch return error.PersistenceFailed;

        if (conditions.items.len > 0) {
            sql_buf.appendSlice(a, "\nWHERE ") catch return error.PersistenceFailed;
            for (conditions.items, 0..) |cond, i| {
                if (i > 0) sql_buf.appendSlice(a, "\n  AND ") catch return error.PersistenceFailed;
                sql_buf.appendSlice(a, cond) catch return error.PersistenceFailed;
            }
        }

        const tail = std.fmt.allocPrint(
            a,
            "\nORDER BY gm.added_at DESC, gm.user_id DESC\nLIMIT ${d}",
            .{limit_idx},
        ) catch return error.PersistenceFailed;
        sql_buf.appendSlice(a, tail) catch return error.PersistenceFailed;

        const rows = conn.query(allocator, sql_buf.items, params.items) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer {
            var r = rows;
            r.deinit();
        }

        const records = allocator.alloc(GroupMemberRecord, rows.rows.len) catch return error.OutOfMemory;
        for (rows.rows, 0..) |row, i| {
            records[i] = materializeGroupMemberRecord(allocator, row) catch {
                for (records[0..i]) |rec| rec.deinit(allocator);
                allocator.free(records);
                return error.PersistenceFailed;
            };
        }
        return records;
    }

    pub fn isActiveGroupMember(
        self: *Registry,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        group_id: []const u8,
        user_id: []const u8,
    ) RegistryError!bool {
        const conn = self.pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const row = conn.queryRow(
            allocator,
            \\SELECT 1
            \\FROM group_members gm
            \\JOIN users u ON u.id = gm.user_id
            \\JOIN groups g ON g.id = gm.group_id
            \\WHERE g.tenant_id = $1::uuid
            \\  AND u.tenant_id = $1::uuid
            \\  AND gm.group_id = $2::uuid
            \\  AND gm.user_id = $3::uuid
            \\  AND u.status = 'ACTIVE'
            \\LIMIT 1
        ,
            &[_][]const u8{ tenant_id, group_id, user_id },
        ) catch |err| return switch (err) {
            pool_mod.PoolError.StaleConnection,
            pool_mod.PoolError.ConnectionFailed,
            pool_mod.PoolError.QueryFailed,
            => error.PersistenceFailed,
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };

        if (row == null) return false;
        defer freeRow(allocator, row.?);
        return true;
    }
};

fn materializeGroup(allocator: std.mem.Allocator, row: []?[]u8) RegistryError!Group {
    defer freeRow(allocator, row);
    return materializeGroupBorrowedRow(allocator, row);
}

fn materializeGroupBorrowedRow(allocator: std.mem.Allocator, row: []?[]u8) RegistryError!Group {
    if (row.len < 7) return error.PersistenceFailed;

    const group_id = row[0] orelse return error.PersistenceFailed;
    const name = row[1] orelse return error.PersistenceFailed;
    const display_name = row[2] orelse return error.PersistenceFailed;
    const description = row[3] orelse return error.PersistenceFailed;
    const is_system_raw = row[4] orelse return error.PersistenceFailed;
    const created_at = row[5] orelse return error.PersistenceFailed;
    const member_count_raw = row[6] orelse return error.PersistenceFailed;

    const member_count = std.fmt.parseInt(u64, member_count_raw, 10) catch return error.PersistenceFailed;
    const is_system = std.mem.eql(u8, is_system_raw, "t") or std.mem.eql(u8, is_system_raw, "true");

    return .{
        .group_id = allocator.dupe(u8, group_id) catch return error.OutOfMemory,
        .name = allocator.dupe(u8, name) catch return error.OutOfMemory,
        .display_name = allocator.dupe(u8, display_name) catch return error.OutOfMemory,
        .description = allocator.dupe(u8, description) catch return error.OutOfMemory,
        .is_system = is_system,
        .member_count = member_count,
        .created_at = allocator.dupe(u8, created_at) catch return error.OutOfMemory,
    };
}

fn materializeGroupMember(allocator: std.mem.Allocator, row: []?[]u8) RegistryError!GroupMember {
    defer freeRow(allocator, row);
    if (row.len < 3) return error.PersistenceFailed;

    const group_id = row[0] orelse return error.PersistenceFailed;
    const user_id = row[1] orelse return error.PersistenceFailed;
    const added_at = row[2] orelse return error.PersistenceFailed;

    return .{
        .group_id = allocator.dupe(u8, group_id) catch return error.OutOfMemory,
        .user_id = allocator.dupe(u8, user_id) catch return error.OutOfMemory,
        .added_at = allocator.dupe(u8, added_at) catch return error.OutOfMemory,
    };
}

fn materializeGroupMemberRecord(allocator: std.mem.Allocator, row: []?[]u8) RegistryError!GroupMemberRecord {
    if (row.len < 8) return error.PersistenceFailed;

    const user_id = row[1] orelse return error.PersistenceFailed;
    const username = row[2] orelse return error.PersistenceFailed;
    const display_name = row[3] orelse return error.PersistenceFailed;
    const email = row[4] orelse return error.PersistenceFailed;
    const status_str = row[5] orelse return error.PersistenceFailed;
    const created_at = row[6] orelse return error.PersistenceFailed;
    const added_at_us_raw = row[7] orelse return error.PersistenceFailed;

    const status = UserStatus.fromString(status_str) orelse return error.PersistenceFailed;
    const added_at_us = std.fmt.parseInt(i64, added_at_us_raw, 10) catch return error.PersistenceFailed;

    return .{
        .member = .{
            .user_id = allocator.dupe(u8, user_id) catch return error.OutOfMemory,
            .username = allocator.dupe(u8, username) catch return error.OutOfMemory,
            .display_name = allocator.dupe(u8, display_name) catch return error.OutOfMemory,
            .email = allocator.dupe(u8, email) catch return error.OutOfMemory,
            .status = status,
            .created_at = allocator.dupe(u8, created_at) catch return error.OutOfMemory,
        },
        .added_at_us = added_at_us,
    };
}

fn materializeUser(allocator: std.mem.Allocator, row: []?[]u8) RegistryError!User {
    defer freeRow(allocator, row);
    return materializeUserBorrowedRow(allocator, row);
}

fn materializeUserBorrowedRow(allocator: std.mem.Allocator, row: []?[]u8) RegistryError!User {
    if (row.len < 6) return error.PersistenceFailed;

    const user_id = row[0] orelse return error.PersistenceFailed;
    const username = row[1] orelse return error.PersistenceFailed;
    const display_name = row[2] orelse return error.PersistenceFailed;
    const email = row[3] orelse return error.PersistenceFailed;
    const status_str = row[4] orelse return error.PersistenceFailed;
    const created_at = row[5] orelse return error.PersistenceFailed;

    const status = UserStatus.fromString(status_str) orelse blk: {
        // Legacy fallback: some older rows may have boolean-like values.
        break :blk UserStatus.ACTIVE;
    };

    return .{
        .user_id = allocator.dupe(u8, user_id) catch return error.OutOfMemory,
        .username = allocator.dupe(u8, username) catch return error.OutOfMemory,
        .display_name = allocator.dupe(u8, display_name) catch return error.OutOfMemory,
        .email = allocator.dupe(u8, email) catch return error.OutOfMemory,
        .status = status,
        .created_at = allocator.dupe(u8, created_at) catch return error.OutOfMemory,
    };
}

fn materializeTenant(allocator: std.mem.Allocator, row: []?[]u8) RegistryError!Tenant {
    defer freeRow(allocator, row);
    return materializeTenantBorrowedRow(allocator, row);
}

fn materializeTenantBorrowedRow(allocator: std.mem.Allocator, row: []?[]u8) RegistryError!Tenant {
    if (row.len < 8) return error.PersistenceFailed;

    const tenant_id = row[0] orelse return error.PersistenceFailed;
    const slug = row[1] orelse return error.PersistenceFailed;
    const display_name = row[2] orelse return error.PersistenceFailed;
    const status_str = row[3] orelse return error.PersistenceFailed;
    const idp_realm_id_raw = row[4]; // nullable
    const created_at = row[5] orelse return error.PersistenceFailed;
    // ENV-01 columns (row[6] = tenant_type, row[7] = production_tenant_id)
    const tenant_type_raw = row[6];
    const production_tenant_id_raw = row[7]; // nullable

    const status = TenantStatus.fromString(status_str) orelse .ACTIVE;

    const idp_realm_id: ?[]u8 = if (idp_realm_id_raw) |v|
        allocator.dupe(u8, v) catch return error.OutOfMemory
    else
        null;
    errdefer if (idp_realm_id) |v| allocator.free(v);

    const tenant_type = allocator.dupe(u8, tenant_type_raw orelse "production") catch return error.OutOfMemory;
    errdefer allocator.free(tenant_type);

    const production_tenant_id: ?[]u8 = if (production_tenant_id_raw) |v|
        allocator.dupe(u8, v) catch return error.OutOfMemory
    else
        null;
    errdefer if (production_tenant_id) |v| allocator.free(v);

    return .{
        .tenant_id = allocator.dupe(u8, tenant_id) catch return error.OutOfMemory,
        .slug = allocator.dupe(u8, slug) catch return error.OutOfMemory,
        .display_name = allocator.dupe(u8, display_name) catch return error.OutOfMemory,
        .status = status,
        .idp_realm_id = idp_realm_id,
        .created_at = allocator.dupe(u8, created_at) catch return error.OutOfMemory,
        .tenant_type = tenant_type,
        .production_tenant_id = production_tenant_id,
    };
}

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |maybe_val| {
        if (maybe_val) |v| allocator.free(v);
    }
    allocator.free(row);
}
