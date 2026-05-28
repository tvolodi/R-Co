const std = @import("std");
const event_store = @import("../event_store/store.zig");

pub const SimulationRunId = [16]u8;
pub const TenantId = [16]u8;

pub const SimulationSeed = struct {
    uuid_seed: u64,
    time_epoch_ms: i64,
};

pub const SimulationContext = struct {
    run_id: SimulationRunId,
    simulation_tenant_id: TenantId,
    seed: SimulationSeed,
    now_ms: i64,
};

pub const EventAppendInput = struct {
    instance_id: event_store.Uuid,
    event_type: []const u8,
    payload: []const u8,
    actor_id: event_store.Uuid,
    idempotency_key: []const u8,
    metadata: ?[]const u8 = null,
    pipeline_run_id: ?[]const u8 = null,
};

pub const EventQueryFilter = struct {
    after_global_seq: ?i64 = null,
    limit: u32 = 100,
};

pub const ServiceRequest = struct {
    request_fingerprint: []const u8,
    method: []const u8 = "POST",
    path: []const u8 = "",
    headers_json: ?[]const u8 = null,
    body: []const u8 = "",
};

pub const MockResponse = struct {
    status_code: u16,
    headers_json: []const u8,
    body: []const u8,

    pub fn clone(self: MockResponse, allocator: std.mem.Allocator) !MockResponse {
        return MockResponse{
            .status_code = self.status_code,
            .headers_json = try allocator.dupe(u8, self.headers_json),
            .body = try allocator.dupe(u8, self.body),
        };
    }

    pub fn deinit(self: MockResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.headers_json);
        allocator.free(self.body);
    }
};

pub const SimulationError = error{
    InvalidScenarioId,
    ScenarioNotFound,
    InvalidServiceKey,
    InvalidRequestFingerprint,
    InvalidSimulationContext,
    SimulationTenantIsolationViolation,
    SimulationVisibilityViolation,
    MockCatalogMissing,
    MockResponseNotFound,
    NetworkCallForbiddenInSimulation,
    InvalidSimulationTimeAdvance,
    SimulationTimeOverflow,
    DeterministicUuidSeedInvalid,
    DeterministicUuidSequenceExhausted,
    ScenarioContractViolation,
    PersistenceFailure,
    SerializationFailure,
    OutOfMemory,
};
