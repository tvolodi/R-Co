//! Service catalog for Lua service calls (LUA-12).
//!
//! Maintains a registry of external services that can be called via platform.call_service().
//! Each service includes endpoint, auth method, and optional schema information.

const std = @import("std");

pub const AuthMethod = enum {
    NONE,
    BEARER,
    API_KEY,
    OAUTH2,
};

pub const RegisteredService = struct {
    service_id: []const u8,
    endpoint_url: []const u8,
    request_schema: ?[]const u8,
    response_schema: ?[]const u8,
    auth_method: AuthMethod,
};

pub const ServiceCatalog = struct {
    services: std.StringHashMap(RegisteredService),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ServiceCatalog {
        return ServiceCatalog{
            .services = std.StringHashMap(RegisteredService).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ServiceCatalog) void {
        var iter = self.services.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // ISS-0625 / GH #592 — endpoint_url is also a heap-allocated
            // copy made in `register` (matching `service_id`/key, and
            // request_schema/response_schema); freeing it here closes the
            // leak the LUA-12 regression test surfaced.
            self.allocator.free(entry.value_ptr.endpoint_url);
            if (entry.value_ptr.request_schema) |s| {
                self.allocator.free(s);
            }
            if (entry.value_ptr.response_schema) |s| {
                self.allocator.free(s);
            }
        }
        self.services.deinit();
    }

    /// Register a service in the catalog.
    pub fn register(
        self: *ServiceCatalog,
        service_id: []const u8,
        endpoint_url: []const u8,
        request_schema: ?[]const u8,
        response_schema: ?[]const u8,
        auth_method: AuthMethod,
    ) !void {
        const service_id_copy = try self.allocator.dupe(u8, service_id);
        errdefer self.allocator.free(service_id_copy);

        const endpoint_copy = try self.allocator.dupe(u8, endpoint_url);
        errdefer self.allocator.free(endpoint_copy);

        var req_schema: ?[]const u8 = null;
        if (request_schema) |s| {
            req_schema = try self.allocator.dupe(u8, s);
            errdefer if (req_schema) |rs| self.allocator.free(rs);
        }

        var resp_schema: ?[]const u8 = null;
        if (response_schema) |s| {
            resp_schema = try self.allocator.dupe(u8, s);
            errdefer if (resp_schema) |rs| self.allocator.free(rs);
        }

        const service = RegisteredService{
            .service_id = service_id_copy,
            .endpoint_url = endpoint_copy,
            .request_schema = req_schema,
            .response_schema = resp_schema,
            .auth_method = auth_method,
        };

        try self.services.put(service_id_copy, service);
    }

    /// Look up a service by ID. Returns null if not found.
    pub fn lookup(self: *const ServiceCatalog, service_id: []const u8) ?RegisteredService {
        return self.services.get(service_id);
    }
};
