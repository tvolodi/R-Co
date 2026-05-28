//! Service catalog registry (REPO-07)
//!
//! Service registration with endpoint URLs, request/response schemas, and auth requirements.
//! Used by SERVICE_TASK nodes and Lua service calls.
//!
//! Design artefact: src/design/repository.md (REPO-07)

const std = @import("std");
const db = @import("pool");

const Pool = db.Pool;

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const CatalogError = error{
    PoolExhausted,
    ServiceIdTooLong,
    ServiceIdEmpty,
    ServiceIdInvalid,
    ServiceNotFound,
    DuplicateService,
    InvalidAuthMethod,
    InvalidSchema,
    EndpointUrlInvalid,
    TimeoutInvalid,
    TransactionFailed,
    OutOfMemory,
    InvalidJson,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

pub const AuthMethod = enum {
    NONE,
    API_KEY,
    OAUTH2,
    MUTUAL_TLS,
};

pub const ServiceCatalogRecord = struct {
    service_id: []const u8,
    endpoint_url: []const u8,
    request_schema: []const u8,
    response_schema: []const u8,
    required_auth: AuthMethod,
    timeout_ms: u32,
    retry_policy: []const u8,
    created_at: i64,
    updated_at: i64,
};

pub const RegisterServiceParams = struct {
    service_id: []const u8,
    endpoint_url: []const u8,
    request_schema: []const u8,
    response_schema: []const u8,
    required_auth: AuthMethod,
    timeout_ms: u32,
    retry_policy: ?[]const u8,
};

pub const ServiceCatalog = struct {
    allocator: std.mem.Allocator,
    pool: *Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *Pool) ServiceCatalog {
        return ServiceCatalog{
            .allocator = allocator,
            .pool = pool,
        };
    }

    pub fn deinit(_: *ServiceCatalog) void {
        // No resources to clean up
    }

    /// Register a new service or update an existing one.
    pub fn register(
        self: *ServiceCatalog,
        allocator: std.mem.Allocator,
        params: RegisterServiceParams,
    ) CatalogError!ServiceCatalogRecord {
        _ = self;
        _ = allocator;
        _ = params;

        // TODO: Implement service registration
        //   1. Validate service_id, endpoint_url, timeout_ms
        //   2. Validate request_schema and response_schema as JSON Schema
        //   3. Insert or update service_catalog row
        //   4. Return ServiceCatalogRecord

        return CatalogError.TransactionFailed;
    }

    /// Fetch a service by ID.
    pub fn getService(
        self: *ServiceCatalog,
        allocator: std.mem.Allocator,
        service_id: []const u8,
    ) CatalogError!ServiceCatalogRecord {
        _ = self;
        _ = allocator;
        _ = service_id;

        return CatalogError.ServiceNotFound;
    }

    /// List all registered services, paginated.
    pub fn listServices(
        self: *ServiceCatalog,
        allocator: std.mem.Allocator,
        after_id: ?[]const u8,
        limit: u32,
    ) CatalogError![]ServiceCatalogRecord {
        _ = self;
        _ = allocator;
        _ = after_id;
        _ = limit;

        return &[_]ServiceCatalogRecord{};
    }

    /// Check if a service exists (used for validation during definition registration).
    pub fn exists(
        self: *ServiceCatalog,
        allocator: std.mem.Allocator,
        service_id: []const u8,
    ) CatalogError!bool {
        _ = self;
        _ = allocator;
        _ = service_id;

        return false;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ServiceCatalog initialization" {
    const allocator = std.testing.allocator;
    var catalog = ServiceCatalog.init(allocator, undefined);
    defer catalog.deinit();
    _ = catalog;
}

test "AuthMethod enum values" {
    _ = AuthMethod.NONE;
    _ = AuthMethod.API_KEY;
    _ = AuthMethod.OAUTH2;
    _ = AuthMethod.MUTUAL_TLS;
}
