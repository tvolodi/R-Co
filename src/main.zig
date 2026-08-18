const std = @import("std");
const build_options = @import("build_options");

// Module references — imported here so that `zig build` and `zig build test`
// compile and validate all Stage 1 modules.
pub const db_pool = @import("pool");
pub const db_migrations = @import("db/migrations.zig");
pub const db_provisioning = @import("db/provisioning.zig"); // SPT-01 schema-per-tenant provisioning
pub const config_mod = @import("config.zig");
pub const event_store = @import("event_store");
pub const event_registry = @import("event_store").registry_module; // single-owner: registry.zig is inside event_store_mod
pub const definition_graph = @import("graph"); // VLD-01/02/03 (WF02-vld01-03-20260816): named-import; src/validation/ reaches it from a different directory.
pub const definition_store = @import("definition/store.zig");
pub const definition_snapshot = @import("definition/snapshot.zig");
pub const definition_export_import = @import("definition/export_import.zig"); // PD-09
pub const definition_routes = @import("api/routes/definitions.zig");
// VLD-01/02/03 (WF02-vld01-03-20260816): POST /api/v1/definitions/:id/validate
// semantic-validation handler. Exposes `handleValidate` for router
// registration (see src/api/router.zig where the route is mounted).
pub const validation_routes = @import("api/routes/validation.zig");
pub const engine_instance = @import("engine/instance.zig");
pub const engine_reconstruction = @import("engine/reconstruction.zig"); // EE-11
pub const instance_routes = @import("api/routes/instances.zig");
// API-03 new handlers exported for router registration:
//   GET /api/v1/instances         → instance_routes.handleList
//   GET /api/v1/instances/:id     → instance_routes.handleGetById
// Register GET /instances (list) BEFORE GET /instances/:id so that the literal
// path segment "instances" is not consumed as a UUID path parameter.
// API-05 history endpoint:
//   GET /api/v1/instances/:id/history → instance_routes.handleHistory
// Register this BEFORE the generic /:id route so "history" is not parsed as UUID.
pub const task_store = @import("tasks/store.zig");
pub const scheduler_poller = @import("scheduler/scheduler.zig"); // SCH-02
pub const task_routes = @import("api/routes/tasks.zig");
// EE-09 / ES-05 schema validator (pure). Imported as a NAMED module, not by
// relative path: src/event_store/registry.zig (ISS-0155) needs it too, and that
// file lives under the `event_store` module whose root is store.zig, so it can
// only reach the validator as a named module. A file may belong to exactly one
// module, so every importer must use the same named form.
pub const json_schema_mod = @import("json_schema");
pub const api_errors = @import("api/errors.zig"); // API-01 RFC 9457 Problem Details
pub const api_response = @import("api/response.zig"); // API-01 response builder
pub const api_content_type = @import("api/middleware/content_type.zig"); // API-01 Content-Type enforcement
pub const api_trace_context = @import("api/trace_context.zig"); // API-09 trace context
pub const api_tenant_context = @import("tenant_context"); // ADP-03 request tenant context
pub const api_pipeline_context = @import("pipeline_context"); // ADP-06 request pipeline context
pub const api_trace = @import("api/middleware/trace.zig"); // API-09 trace middleware
pub const api_rate_limit = @import("api/middleware/rate_limit.zig"); // API-10 rate limiting
pub const api_quota_enforcement = @import("api/middleware/quota_enforcement.zig"); // EXP-601 centralized quota enforcement
pub const api_openapi = @import("api/openapi/mod.zig"); // API-11 OpenAPI builder/serializer
pub const openapi_routes = @import("api/routes/openapi.zig"); // API-11 public /openapi.json route handler
pub const health_routes = @import("api/routes/health.zig"); // API-12 public /health/live and /health/ready handlers
pub const metrics_routes = @import("api/routes/metrics.zig"); // OBS-02 public /metrics route handler
pub const tenant_config_routes = @import("api/routes/tenant_config.zig"); // OIDC-F-05 public /api/tenant-config route handler
pub const audit_routes = @import("api/routes/audit.zig"); // OBS-03 GET /audit route handler
pub const dlq_store = @import("dlq/store.zig"); // OBS-05 dead-letter persistence
pub const dlq_routes = @import("api/routes/dlq.zig"); // OBS-05 DLQ API handlers
pub const webhooks_routes = @import("api/routes/webhooks.zig"); // EXT-02 webhook subscription API handlers
pub const simulation_test_routes = @import("api/routes/simulation_test.zig"); // SIM-05..SIM-08 test runner API handlers
pub const entity_routes = @import("api/routes/entities.zig"); // EXP-201/EXP-202 entity definition + record API handlers
pub const api_health_readiness = @import("api/health/readiness.zig"); // API-12 readiness evaluation
pub const api_health_subsystems = @import("api/health/subsystems.zig"); // API-12 critical subsystem checks
pub const obs_logger = @import("obs/logger.zig"); // OBS-01 structured logger
pub const obs_metrics = @import("obs_metrics"); // OBS-02 Prometheus metrics
pub const obs_audit = @import("obs/audit.zig"); // OBS-03 audit query service
pub const obs_alerts = @import("obs/alerts.zig"); // OBS-06 alerting hooks
pub const startup_assertions = @import("operations/startup_assertions.zig"); // PI-09 fail-fast startup assertion
pub const pending_migration_gate = @import("operations/pending_migration_gate.zig"); // MIG-06 AC5 fail-fast startup assertion
pub const migration_fanout = @import("platform/migration_fanout.zig"); // MIG-02..05 platform migration fanout/resume
pub const platform_migrations_routes = @import("api/routes/platform_migrations.zig"); // MIG-06 admin surface
pub const webhook_subscription_store = @import("webhook/subscription_store.zig"); // EXT-02 subscription storage
pub const webhook_dispatcher = @import("webhook/dispatcher.zig"); // EXT-02 webhook delivery dispatcher
pub const identity_registry = @import("identity/registry.zig"); // IDN-01 user registry persistence
pub const identity_service = @import("identity/service.zig"); // IDN-01 user registry service
pub const identity_routes = @import("api/routes/identity.zig"); // IDN-01 user registry HTTP handlers
pub const role_registry_mod = @import("identity/role_registry.zig"); // IDN-05 named-role registry
pub const bootstrap_audit = @import("bootstrap/audit.zig"); // TNT-04 public schema startup audit
pub const onboarding_mod = @import("identity/onboarding.zig"); // OIDC-35 onboarding orchestration
pub const onboarding_routes = @import("api/routes/onboarding.zig"); // OIDC-35 onboarding HTTP handlers
pub const identity_provider = @import("identity_provider"); // OIDC provider contract and bootstrap wiring
pub const oidc_agent_lifecycle = @import("oidc/agent_lifecycle.zig"); // OIDC-16..26 lifecycle/idempotency/audit/metrics helpers
pub const oidc_verification_benchmark = @import("oidc/verification_benchmark.zig"); // OIDC-27 benchmark envelope helpers
pub const oidc_realm_seed = @import("oidc/realm_seed.zig"); // OIDC-29 realm seed validation and drift checks
pub const oidc_test_token_helper = @import("oidc/test_token_helper.zig"); // OIDC-30 test-only token helper
pub const oidc_coexistence_auth = @import("oidc/coexistence_auth.zig"); // OIDC-33 coexistence context equivalence checks
pub const oidc_migration_helper = @import("oidc/migration_helper.zig"); // OIDC-34 migration helper service
pub const api_auth = @import("api/middleware/auth.zig"); // API-08 auth middleware provider-manager configuration
pub const tenant_migration_admin = @import("admin/tenant_migration.zig"); // TNT-06 export/import admin handlers
pub const tenant_lifecycle_admin = @import("admin/tenant_lifecycle.zig"); // ENV-05 reset/delete lifecycle handlers
pub const promotion_routes = @import("api/routes/promotion.zig"); // ENV-03 definition promotion handler
pub const promotions_routes = @import("api/routes/promotions.zig"); // PRM-01 promotion plan endpoint
pub const pin_rebind_mod = @import("engine/pin_rebind.zig"); // PIN-05 explicit instance pin rebind
pub const pin_rebind_routes = @import("api/routes/pin_rebind.zig"); // PIN-05 rebind-pins HTTP handler
pub const tenant_status_middleware = @import("api/middleware/tenant_status.zig"); // TNT-06 MIGRATING status middleware
pub const service_catalog_repo = @import("repository/service_catalog.zig"); // SVC-01/SVC-04 service catalog store
pub const services_routes = @import("api/routes/services.zig"); // SVC-04 service catalog HTTP handlers
pub const process_module_catalog_repo = @import("repository/process_module_catalog.zig"); // PLC-01
pub const process_modules_routes = @import("api/routes/process_modules.zig"); // PLC-01 HTTP handlers
pub const solution_pack_store = @import("solution/store.zig"); // SOL-01/02/03
pub const solution_pack_routes = @import("api/routes/solution_packs.zig"); // SOL-01/02 HTTP handlers
pub const entity_query_types = @import("entities/query/types.zig"); // QRY-01..04 entity query DSL types
pub const entity_query_allowlist = @import("entities/query/allowlist.zig"); // QRY-02 allowlist loader
pub const entity_query_compiler = @import("entities/query/compiler.zig"); // QRY-01..03 SQL compiler
pub const entity_query_cursor = @import("entities/query/cursor.zig"); // QRY-03 keyset cursor
pub const entity_query_routes = @import("api/routes/entity_query.zig"); // QRY-01..04 POST /api/v1/entities/{key}/query
pub const entity_field_grants = @import("entities/query/field_grants.zig"); // QRY-05 field grant loader
pub const agent_auth_middleware = @import("api/middleware/agent_auth.zig"); // SBX-01/02/03 agent role gates
pub const agent_task_specs_routes = @import("api/routes/agent_task_specs.zig"); // SBX-01/02 POST /api/v1/agent/task-specs
pub const agent_sandboxes_routes = @import("api/routes/agent_sandboxes.zig"); // SBX-03 agent sandbox routes
pub const agent_artifacts_routes = @import("api/routes/agent_artifacts.zig"); // AGT-01..04 artifact submission pipeline
pub const canonical_json_mod = @import("crypto/canonical_json.zig"); // RFC 8785 canonical JSON

const placeholder_health_live = "{\"status\":\"live\"}";
const placeholder_health_ready = "{\"status\":\"ready\",\"api\":\"placeholder\"}";
const placeholder_not_implemented =
    "{\"type\":\"https://bpm.local/problems/not-implemented\",\"title\":\"Not Implemented\",\"status\":501,\"detail\":\"Runtime placeholder server is active; API routes are not wired yet.\"}";

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var io_threaded = std.Io.Threaded.init(allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const config = try config_mod.load(allocator);
    try obs_logger.init(.{ .level = config.log_level, .component = "main" });

    var idp_boot = identity_provider.bootstrap.initializeActiveProviderFromEnv(allocator, config.env) catch |err| {
        try logIdentityProviderConfigError(allocator, err);
        return err;
    };
    defer idp_boot.active.deinit();
    // Establish stable provider pointer now that idp_boot is at its final location.
    idp_boot.active.finalizeLinks();

    api_auth.configureIdentityProviderManager(idp_boot.active.manager);
    try api_auth.init(allocator, config.bootstrap_token);
    defer api_auth.deinit();

    try api_quota_enforcement.init(allocator);
    defer api_quota_enforcement.deinit();

    const fields = [_]obs_logger.LogField{
        .{ .key = "port", .value = .{ .integer = config.port } },
        .{ .key = "environment", .value = .{ .string = config.env } },
        .{ .key = "idp_provider_type", .value = .{ .string = @tagName(idp_boot.provider_type) } },
    };
    obs_logger.log(allocator, .INFO, "main", "startup configuration validated", &fields) catch {};

    try runApiServer(io, allocator, config);
}

fn logIdentityProviderConfigError(allocator: std.mem.Allocator, err: anyerror) !void {
    const detail = identity_provider.bootstrap.describeConfigError(err);
    const error_code = if (detail) |d| d.error_code else "adapter_bootstrap_failed";
    const field = if (detail) |d| d.field else "BPM_IDP_ADMIN_CREDENTIALS_REF";

    const fields = [_]obs_logger.LogField{
        .{ .key = "error_code", .value = .{ .string = error_code } },
        .{ .key = "field", .value = .{ .string = field } },
        .{ .key = "detail", .value = .{ .string = @errorName(err) } },
    };
    _ = obs_logger.log(allocator, .ERROR, "startup.identity_provider", "identity provider configuration invalid", &fields) catch {};
}

fn runApiServer(io: std.Io, allocator: std.mem.Allocator, config: config_mod.Config) !void {
    // Initialise pool and all stores once, before accepting any connections.
    var pool = try db_pool.Pool.init(io, allocator, .{ .url = config.db_url, .pool_size = 10 });
    defer pool.deinit();

    // PI-09: Fail-fast database configuration assertion (FATAL GATE)
    // This MUST run immediately after Pool.init and before any schema provisioning.
    // On failure: emits FATAL log line and exits with EX_CONFIG (78).
    startup_assertions.assertDatabaseConfiguration(allocator, &pool) catch |err| {
        const startup_fields = [_]obs_logger.LogField{
            .{ .key = "error", .value = .{ .string = @errorName(err) } },
        };
        obs_logger.log(allocator, .ERROR, "main", "database configuration assertion failed", &startup_fields) catch {};
        const EX_CONFIG = 78;
        std.process.exit(EX_CONFIG);
    };

    // MIG-06 AC5: refuse to serve traffic while any platform migration has
    // outstanding 'pending' rows. Second fail-fast gate in the same sequence
    // as assertDatabaseConfiguration above, run immediately after it and
    // before any schema provisioning.
    pending_migration_gate.assertNoOutstandingMigrations(allocator, &pool) catch |err| {
        const pending_fields = [_]obs_logger.LogField{
            .{ .key = "error", .value = .{ .string = @errorName(err) } },
        };
        obs_logger.log(allocator, .ERROR, "main", "outstanding platform migration assertion failed", &pending_fields) catch {};
        const EX_CONFIG = 78;
        std.process.exit(EX_CONFIG);
    };

    const default_tenant_id = "00000000-0000-0000-0000-000000000000";
    db_provisioning.provisionTenantSchema(allocator, &pool, default_tenant_id, build_options.migrations_dir) catch |err| {
        const provision_fields = [_]obs_logger.LogField{
            .{ .key = "error", .value = .{ .string = @errorName(err) } },
            .{ .key = "tenant_id", .value = .{ .string = default_tenant_id } },
        };
        obs_logger.log(allocator, .WARN, "main", "default tenant schema provisioning failed", &provision_fields) catch {};
    };

    // TNT-04: Startup public schema audit.
    // Runs after Pool.init and provisionTenantSchema (migrations applied).
    // Non-fatal: errors are caught and logged at WARN; server continues regardless.
    bootstrap_audit.auditPublicSchema(allocator, &pool) catch |audit_err| {
        const audit_fields = [_]obs_logger.LogField{
            .{ .key = "error", .value = .{ .string = @errorName(audit_err) } },
        };
        obs_logger.log(allocator, .WARN, "bootstrap.audit", "public schema audit could not complete", &audit_fields) catch {};
    };

    var def_store = definition_store.Store.init(allocator, &pool);
    defer def_store.deinit();

    var snapshot_store = definition_snapshot.SnapshotStore.init(&pool);

    var inst_store = engine_instance.InstanceStore.init(&pool, &snapshot_store);

    var task_store_inst = task_store.TaskStore.init(&pool);

    var export_import_store = definition_export_import.ExportImportStore{ .pool = &pool };

    var ev_registry = event_registry.Registry.init(allocator, &pool);
    var ev_store = event_store.Store.init(allocator, &pool, &ev_registry);

    var id_registry = identity_registry.Registry.init(&pool);
    var id_svc = identity_service.Service.init(&id_registry);
    var role_store = role_registry_mod.TenantRoleStore.init(&pool);

    var readiness_svc = api_health_readiness.ReadinessService.init(allocator, &pool, &.{});

    const listen_address = try std.Io.net.IpAddress.parse("0.0.0.0", config.port);
    var server = try listen_address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    const listening_fields = [_]obs_logger.LogField{
        .{ .key = "port", .value = .{ .integer = config.port } },
    };
    obs_logger.log(allocator, .INFO, "main", "API server listening", &listening_fields) catch {};

    while (true) {
        var stream = try server.accept(io);
        defer stream.close(io);
        serveRequest(
            io,
            allocator,
            stream,
            &pool,
            &def_store,
            &inst_store,
            &task_store_inst,
            &export_import_store,
            &ev_store,
            &readiness_svc,
            &id_svc,
            &role_store,
            std.ascii.eqlIgnoreCase(config.env, "production"),
        ) catch |err| {
            const err_fields = [_]obs_logger.LogField{
                .{ .key = "error", .value = .{ .string = @errorName(err) } },
            };
            obs_logger.log(allocator, .ERROR, "main", "request handler error", &err_fields) catch {};
        };
    }
}

fn serveRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    pool: *db_pool.Pool,
    def_store: *definition_store.Store,
    inst_store: *engine_instance.InstanceStore,
    task_store_inst: *task_store.TaskStore,
    export_import_inst: *definition_export_import.ExportImportStore,
    ev_store: *event_store.Store,
    readiness: *api_health_readiness.ReadinessService,
    id_svc: *identity_service.Service,
    role_store: *role_registry_mod.TenantRoleStore,
    production_mode: bool,
) !void {
    var recv_buffer: [8192]u8 = undefined;
    var send_buffer: [8192]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buffer);
    var conn_writer = stream.writer(io, &send_buffer);
    var http_server: std.http.Server = .init(&conn_reader.interface, &conn_writer.interface);

    var request = http_server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => return err,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const req_alloc = arena.allocator();

    // Extract caller metadata from request headers.
    const user_id = blk: {
        var hdr_it = request.iterateHeaders();
        while (hdr_it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "x-bpm-user-id")) break :blk h.value;
        }
        break :blk "00000000-0000-0000-0000-000000000000";
    };

    const authorization_header = blk: {
        var hdr_it = request.iterateHeaders();
        while (hdr_it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) break :blk h.value;
        }
        break :blk null;
    };

    const tenant_header = blk: {
        var hdr_it = request.iterateHeaders();
        while (hdr_it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "x-bpm-tenant-id")) break :blk h.value;
        }
        break :blk null;
    };

    const permissions_header = blk: {
        var hdr_it = request.iterateHeaders();
        while (hdr_it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "x-bpm-permissions")) break :blk h.value;
        }
        break :blk null;
    };

    // ── API-09 trace middleware ────────────────────────────────────────────────
    // Must run first (before auth) so that even auth failures are traceable.
    const x_trace_id_req_header: ?[]const u8 = blk: {
        var hdr_it = request.iterateHeaders();
        while (hdr_it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "x-trace-id")) break :blk h.value;
        }
        break :blk null;
    };
    const trace_result = try api_trace.extractOrGenerate(req_alloc, x_trace_id_req_header);
    api_trace_context.set(trace_result.trace_id);
    defer api_trace_context.clear();

    // Extract Idempotency-Key before body reading (iterateHeaders asserts received_head state).
    const idempotency_key_hdr: []const u8 = blk: {
        var hdr_it = request.iterateHeaders();
        while (hdr_it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "idempotency-key")) break :blk h.value;
        }
        break :blk "";
    };

    // Split path from query string.
    const target = request.head.target;
    const q_start = std.mem.indexOf(u8, target, "?");
    const path = if (q_start) |qi| target[0..qi] else target;
    const query_str = if (q_start) |qi| target[qi + 1 ..] else "";

    // Read request body only after copying request metadata that borrows from
    // the receive buffer. Consuming the body can invalidate request.head.target.
    // Some clients (including Playwright APIRequestContext) send
    // `Expect: 100-continue` for POST bodies, so acknowledge it before reading.
    var body_transfer_buf: [8192]u8 = undefined;
    request.writeExpectContinue() catch |err| switch (err) {
        error.HttpExpectationFailed => {
            const ct_hdr = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};
            try request.respond("{\"type\":\"expectation_failed\",\"status\":417}", .{
                .status = @enumFromInt(417),
                .keep_alive = false,
                .extra_headers = &ct_hdr,
            });
            return;
        },
        error.WriteFailed => return err,
    };
    var body_reader = request.readerExpectNone(&body_transfer_buf);
    const body = body_reader.allocRemaining(req_alloc, std.Io.Limit.limited(1 * 1024 * 1024)) catch &.{};

    // Get a query parameter by key (case-insensitive key match, URL-encoded values not decoded).
    const QS = struct {
        fn get(qs: []const u8, key: []const u8) ?[]const u8 {
            var it = std.mem.splitScalar(u8, qs, '&');
            while (it.next()) |pair| {
                const eq = std.mem.indexOf(u8, pair, "=") orelse continue;
                if (std.ascii.eqlIgnoreCase(pair[0..eq], key)) return pair[eq + 1 ..];
            }
            return null;
        }

        /// Like get() but percent-decodes the value: '+' → space, '%XX' → byte.
        /// Returns a slice allocated with `alloc`; null if the key is absent.
        fn getDecoded(qs: []const u8, key: []const u8, alloc: std.mem.Allocator) ?[]u8 {
            const raw = get(qs, key) orelse return null;
            var out = alloc.alloc(u8, raw.len) catch return null; // OOM: treat as absent
            var i: usize = 0;
            var j: usize = 0;
            while (i < raw.len) {
                if (raw[i] == '+') {
                    out[j] = ' ';
                    i += 1;
                    j += 1;
                } else if (raw[i] == '%' and i + 2 < raw.len) {
                    const byte = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch {
                        out[j] = raw[i];
                        i += 1;
                        j += 1;
                        continue;
                    };
                    out[j] = byte;
                    i += 3;
                    j += 1;
                } else {
                    out[j] = raw[i];
                    i += 1;
                    j += 1;
                }
            }
            return out[0..j];
        }
    };

    const method = request.head.method;

    // DEBUG: log path and method to diagnose routing failures
    {
        const dbg_fields = [_]obs_logger.LogField{
            .{ .key = "debug_path", .value = .{ .string = path } },
            .{ .key = "debug_method", .value = .{ .string = @tagName(method) } },
            .{ .key = "debug_path_len", .value = .{ .integer = @as(i64, @intCast(path.len)) } },
        };
        obs_logger.log(allocator, .INFO, "debug.routing", "routing check", &dbg_fields) catch {};
    }

    var resp_status: u16 = 200;
    var resp_body: []const u8 = "{}";
    var resp_content_type: []const u8 = "application/json";

    // ── /health/live ─────────────────────────────────────────────────────────
    if (std.mem.eql(u8, path, "/health/live")) {
        const r = health_routes.handleLive(req_alloc);
        resp_status = r.status_code;
        resp_body = r.body;
        resp_content_type = r.content_type;
    }
    // ── /health/ready ────────────────────────────────────────────────────────
    else if (std.mem.eql(u8, path, "/health/ready")) {
        const r = health_routes.handleReady(req_alloc, pool, readiness);
        resp_status = r.status_code;
        resp_body = r.body;
        resp_content_type = r.content_type;
    }
    // ── /metrics ─────────────────────────────────────────────────────────────
    else if (std.mem.eql(u8, path, "/metrics")) {
        const r = metrics_routes.handleMetrics(req_alloc);
        resp_status = r.status_code;
        resp_body = r.body;
        resp_content_type = r.content_type;
    }
    // ── GET /api/tenant-config  (public — no auth required) ──────────────────
    else if (std.mem.eql(u8, path, "/api/tenant-config") and method == .GET) {
        const r = tenant_config_routes.handleTenantConfig(req_alloc, pool, query_str);
        resp_status = r.status_code;
        resp_body = r.body;
        resp_content_type = r.content_type;
    }
    // ── /test/... (SIM-05..SIM-08) ───────────────────────────────────────────
    else if (std.mem.eql(u8, path, "/test/run") and method == .POST) {
        const r = simulation_test_routes.handleRunScenario(
            req_alloc,
            authorization_header,
            user_id,
            tenant_header,
            permissions_header,
            body,
        );
        resp_status = r.status_code;
        resp_body = r.body;
        resp_content_type = r.content_type;
    } else if (std.mem.eql(u8, path, "/test/run-batch") and method == .POST) {
        const r = simulation_test_routes.handleRunBatch(
            req_alloc,
            authorization_header,
            user_id,
            tenant_header,
            permissions_header,
            body,
        );
        resp_status = r.status_code;
        resp_body = r.body;
        resp_content_type = r.content_type;
    } else if (std.mem.eql(u8, path, "/test/scenarios/validate") and method == .POST) {
        const r = simulation_test_routes.handleValidateScenario(
            req_alloc,
            authorization_header,
            user_id,
            tenant_header,
            permissions_header,
            body,
        );
        resp_status = r.status_code;
        resp_body = r.body;
        resp_content_type = r.content_type;
    } else if (std.mem.startsWith(u8, path, "/test/scenarios/schema/") and method == .GET) {
        var segs: [8][]const u8 = @splat(@as([]const u8, ""));
        var seg_count: usize = 0;
        var seg_it = std.mem.splitScalar(u8, path, '/');
        while (seg_it.next()) |s| {
            if (seg_count >= 8) break;
            segs[seg_count] = s;
            seg_count += 1;
        }
        if (seg_count > 5 and std.mem.eql(u8, segs[1], "test") and std.mem.eql(u8, segs[2], "scenarios") and std.mem.eql(u8, segs[3], "schema")) {
            const schema_name = segs[4];
            const schema_version = segs[5];
            const r = simulation_test_routes.handleGetSchema(
                req_alloc,
                authorization_header,
                user_id,
                tenant_header,
                permissions_header,
                schema_name,
                schema_version,
            );
            resp_status = r.status_code;
            resp_body = r.body;
            resp_content_type = r.content_type;
        } else {
            resp_status = 404;
            resp_body = "{\"type\":\"not_found\",\"status\":404}";
        }
    }
    // ── /api/v1/... (+ legacy /dlq compatibility) ───────────────────────────
    else if (std.mem.startsWith(u8, path, "/api/v1/") or std.mem.eql(u8, path, "/dlq") or std.mem.startsWith(u8, path, "/dlq/")) {
        // ── API-08/API-09 auth gate ───────────────────────────────────────────
        // Every /api/v1/... request must be authenticated.  Return 401/403
        // immediately and include X-Trace-Id so the caller can correlate.
        // The authenticated AuthContext is stored for use by tenant-aware routes (SVC-01).
        var authenticated_ctx: ?api_auth.AuthContext = null;
        {
            const auth_gate_result = api_auth.authenticate(req_alloc, authorization_header, pool);
            switch (auth_gate_result) {
                .unauthenticated => |hr| {
                    const tid = api_trace_context.get();
                    const auth_hdrs = [_]std.http.Header{
                        .{ .name = "content-type", .value = "application/json" },
                        .{ .name = "X-Trace-Id", .value = tid },
                    };
                    try request.respond(hr.body, .{ .status = @enumFromInt(hr.status_code), .keep_alive = false, .extra_headers = &auth_hdrs });
                    return;
                },
                .forbidden => |hr| {
                    const tid = api_trace_context.get();
                    const auth_hdrs = [_]std.http.Header{
                        .{ .name = "content-type", .value = "application/json" },
                        .{ .name = "X-Trace-Id", .value = tid },
                    };
                    try request.respond(hr.body, .{ .status = @enumFromInt(hr.status_code), .keep_alive = false, .extra_headers = &auth_hdrs });
                    return;
                },
                .authenticated => |ctx| {
                    authenticated_ctx = ctx;
                },
            }
        }

        // EXP-601: central quota guard at the kernel middleware boundary.
        if (authenticated_ctx) |ctx| {
            if (api_quota_enforcement.classifyTarget(path, method)) |quota_target| {
                const quota_check = api_quota_enforcement.check(
                    req_alloc,
                    pool,
                    .{
                        .tenant_id = ctx.tenant_id[0..],
                        .target = quota_target,
                        .requested_delta = 1,
                        .request_path = path,
                        .request_method = method,
                    },
                ) catch |err| switch (err) {
                    api_quota_enforcement.QuotaMiddlewareError.NotInitialized,
                    api_quota_enforcement.QuotaMiddlewareError.QuotaPolicyInvalid,
                    api_quota_enforcement.QuotaMiddlewareError.QuotaPolicyNotConfigured,
                    api_quota_enforcement.QuotaMiddlewareError.QuotaUsageReadFailed,
                    api_quota_enforcement.QuotaMiddlewareError.QuotaDimensionUnsupported,
                    => {
                        const pd = api_errors.problemServiceUnavailable("quota policy unavailable");
                        const err_body = api_errors.serialise(req_alloc, pd) catch "{\"type\":\"https://bpm.example.com/problems/service-unavailable\",\"title\":\"Service Unavailable\",\"status\":503,\"detail\":\"quota policy unavailable\"}";
                        const tid = api_trace_context.get();
                        const hdrs = [_]std.http.Header{
                            .{ .name = "content-type", .value = "application/json" },
                            .{ .name = "X-Trace-Id", .value = tid },
                        };
                        try request.respond(err_body, .{ .status = @enumFromInt(503), .keep_alive = false, .extra_headers = &hdrs });
                        return;
                    },
                    api_quota_enforcement.QuotaMiddlewareError.OutOfMemory,
                    api_quota_enforcement.QuotaMiddlewareError.PoolExhausted,
                    => {
                        const pd = api_errors.problemServiceUnavailable("quota check unavailable");
                        const err_body = api_errors.serialise(req_alloc, pd) catch "{\"type\":\"https://bpm.example.com/problems/service-unavailable\",\"title\":\"Service Unavailable\",\"status\":503,\"detail\":\"quota check unavailable\"}";
                        const tid = api_trace_context.get();
                        const hdrs = [_]std.http.Header{
                            .{ .name = "content-type", .value = "application/json" },
                            .{ .name = "X-Trace-Id", .value = tid },
                        };
                        try request.respond(err_body, .{ .status = @enumFromInt(503), .keep_alive = false, .extra_headers = &hdrs });
                        return;
                    },
                };

                switch (quota_check) {
                    .allowed => {},
                    .rejected => |reject| {
                        const tid = api_trace_context.get();
                        const hdrs = [_]std.http.Header{
                            .{ .name = "content-type", .value = "application/json" },
                            .{ .name = "X-Trace-Id", .value = tid },
                        };
                        try request.respond(reject.body, .{ .status = @enumFromInt(reject.status_code), .keep_alive = false, .extra_headers = &hdrs });
                        return;
                    },
                }
            }
        }

        const route_path = if (std.mem.eql(u8, path, "/dlq") or std.mem.startsWith(u8, path, "/dlq/"))
            (std.fmt.allocPrint(req_alloc, "/api/v1{s}", .{path}) catch path)
        else
            path;

        // Split path into up to 8 segments.
        // e.g. "/api/v1/definitions/abc/activate"
        //       [0]="" [1]="api" [2]="v1" [3]="definitions" [4]="abc" [5]="activate"
        var segs: [8][]const u8 = @splat(@as([]const u8, ""));
        var seg_count: usize = 0;
        var seg_it = std.mem.splitScalar(u8, route_path, '/');
        while (seg_it.next()) |s| {
            if (seg_count >= 8) break;
            segs[seg_count] = s;
            seg_count += 1;
        }
        const resource = if (seg_count > 3) segs[3] else "";
        const seg4 = if (seg_count > 4) segs[4] else "";
        const seg5 = if (seg_count > 5) segs[5] else "";
        const seg6 = if (seg_count > 6) segs[6] else "";

        if (std.mem.eql(u8, resource, "definitions")) {
            // Actor UUID for definition writes (created_by).
            const actor_uuid: definition_store.Uuid = task_store.parseUuid(user_id) catch
                std.mem.zeroes(definition_store.Uuid);

            if (seg4.len == 0) {
                // GET /api/v1/definitions  or  POST /api/v1/definitions
                if (method == .GET) {
                    const params = definition_routes.ListQueryParams{
                        .name = QS.getDecoded(query_str, "name", req_alloc),
                        .status = QS.get(query_str, "status"),
                        .stage = QS.get(query_str, "stage"),
                        .cursor = QS.get(query_str, "cursor"),
                        .page_size = if (QS.get(query_str, "page_size")) |ps| std.fmt.parseInt(u16, ps, 10) catch null else null,
                    };
                    const r = definition_routes.handleList(def_store, req_alloc, params);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (method == .POST) {
                    const parsed = std.json.parseFromSlice(
                        definition_routes.CreateDefinitionBody,
                        req_alloc,
                        body,
                        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
                    ) catch {
                        resp_status = 400;
                        resp_body = "{\"type\":\"malformed_json\",\"status\":400,\"title\":\"Bad Request\"}";
                        const ct_hdr = [_]std.http.Header{.{ .name = "content-type", .value = resp_content_type }};
                        try request.respond(resp_body, .{ .status = @enumFromInt(resp_status), .keep_alive = false, .extra_headers = &ct_hdr });
                        return;
                    };

                    const r = definition_routes.handleCreate(def_store, req_alloc, parsed.value, actor_uuid);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else if (std.mem.eql(u8, seg4, "search") and method == .GET) {
                // GET /api/v1/definitions/search
                const params = definition_routes.SearchQueryParams{
                    .q = QS.getDecoded(query_str, "q", req_alloc),
                    .limit = if (QS.get(query_str, "limit")) |l| std.fmt.parseInt(u32, l, 10) catch null else null,
                    .offset = if (QS.get(query_str, "offset")) |o| std.fmt.parseInt(u32, o, 10) catch null else null,
                };
                const r = definition_routes.handleSearch(def_store, req_alloc, params);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (std.mem.eql(u8, seg4, "import") and method == .POST) {
                // POST /api/v1/definitions/import
                const r = definition_routes.handleImport(req_alloc, export_import_inst, body);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (std.mem.eql(u8, seg4, "active") and seg5.len > 0 and method == .GET) {
                // GET /api/v1/definitions/active/:name
                const r = definition_routes.handleGetActiveByName(def_store, req_alloc, seg5);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (seg5.len == 0) {
                // Routes with /:id and no further segment
                if (method == .GET) {
                    const r = definition_routes.handleGetById(def_store, req_alloc, seg4);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (method == .PATCH) {
                    const parsed = std.json.parseFromSlice(
                        definition_routes.PatchDefinitionBody,
                        req_alloc,
                        body,
                        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
                    ) catch {
                        resp_status = 400;
                        resp_body = "{\"type\":\"malformed_json\",\"status\":400,\"title\":\"Bad Request\"}";
                        const ct_hdr = [_]std.http.Header{.{ .name = "content-type", .value = resp_content_type }};
                        try request.respond(resp_body, .{ .status = @enumFromInt(resp_status), .keep_alive = false, .extra_headers = &ct_hdr });
                        return;
                    };

                    const r = definition_routes.handlePatch(def_store, req_alloc, seg4, parsed.value);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (method == .DELETE) {
                    const r = definition_routes.handleDelete(def_store, req_alloc, seg4);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else if (method == .POST and std.mem.eql(u8, seg5, "activate")) {
                // SOL-03: role-mapping gate check before activation.
                // Fail-open: gate errors do not block activation (logged implicitly).
                var sol_store = solution_pack_store.SolutionPackStore.init(pool);
                const gate = sol_store.checkRoleGate(req_alloc, seg4) catch
                    solution_pack_store.RoleGateResult{ .allowed = true, .unbound_roles = &.{} };
                if (!gate.allowed) {
                    var gate_buf: std.ArrayList(u8) = .empty;
                    gate_buf.appendSlice(req_alloc, "{\"error\":\"UNBOUND_ROLES\",\"unbound_roles\":[") catch {};
                    for (gate.unbound_roles, 0..) |rname, ri| {
                        if (ri > 0) gate_buf.append(req_alloc, ',') catch {};
                        gate_buf.append(req_alloc, '"') catch {};
                        gate_buf.appendSlice(req_alloc, rname) catch {};
                        gate_buf.append(req_alloc, '"') catch {};
                    }
                    gate_buf.appendSlice(req_alloc, "]}") catch {};
                    resp_status = 422;
                    resp_body = gate_buf.toOwnedSlice(req_alloc) catch "{\"error\":\"UNBOUND_ROLES\"}";
                } else {
                    const r = definition_routes.handleActivate(def_store, req_alloc, seg4);
                    resp_status = r.status_code;
                    resp_body = r.body;
                }
            } else if (method == .POST and std.mem.eql(u8, seg5, "deprecate")) {
                const r = definition_routes.handleDeprecate(def_store, req_alloc, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (method == .POST and std.mem.eql(u8, seg5, "archive")) {
                const r = definition_routes.handleArchive(def_store, req_alloc, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (method == .GET and std.mem.eql(u8, seg5, "export")) {
                const r = definition_routes.handleExport(req_alloc, export_import_inst, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (method == .POST and std.mem.eql(u8, seg5, "validate")) {
                // VLD-01/02/03 (WF02-vld01-03-20260816):
                // POST /api/v1/definitions/:id/validate
                // Run semantic validation against the stored definition's
                // graph. tenant_id from the authenticated AuthContext is
                // threaded into the handler so the RLS policy on
                // process_definitions cannot return a row owned by another
                // tenant. Falls through to 404 on cross-tenant reads.
                const validate_tenant = if (authenticated_ctx) |ctx| ctx.tenant_id else api_auth.DEFAULT_TENANT_ID.*;
                const r = validation_routes.handleValidate(def_store, req_alloc, validate_tenant, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "instances")) {
            if (seg4.len == 0) {
                // GET /api/v1/instances  or  POST /api/v1/instances
                if (method == .GET) {
                    const params = instance_routes.ListInstancesParams{
                        .status = QS.get(query_str, "status"),
                        .definition_id = QS.get(query_str, "definition_id"),
                        .cursor = QS.get(query_str, "cursor"),
                        .page_size = std.fmt.parseInt(u16, QS.get(query_str, "page_size") orelse "50", 10) catch 50,
                    };
                    const r = instance_routes.handleList(inst_store, req_alloc, params);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (method == .POST) {
                    const r = instance_routes.handleCreate(inst_store, req_alloc, body);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else if (std.mem.eql(u8, seg5, "history") and method == .GET) {
                // GET /api/v1/instances/:id/history — must precede plain /:id
                const params = instance_routes.HistoryParams{
                    .event_type = QS.get(query_str, "event_type"),
                    .from = QS.get(query_str, "from"),
                    .to = QS.get(query_str, "to"),
                    .pipeline_run_id = QS.get(query_str, "pipeline_run_id"),
                    .cursor = QS.get(query_str, "cursor"),
                    .page_size = std.fmt.parseInt(u16, QS.get(query_str, "page_size") orelse "50", 10) catch 50,
                };
                const r = instance_routes.handleHistory(ev_store, req_alloc, seg4, params);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (std.mem.eql(u8, seg5, "timeline") and method == .GET) {
                // GET /api/v1/instances/:id/timeline — must precede plain /:id
                const params = instance_routes.TimelineParams{
                    .cursor = QS.get(query_str, "cursor"),
                    .page_size = std.fmt.parseInt(u16, QS.get(query_str, "page_size") orelse "50", 10) catch 50,
                };
                const r = instance_routes.handleTimeline(ev_store, req_alloc, seg4, params);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (std.mem.eql(u8, seg5, "reconstruct") and method == .GET) {
                const r = instance_routes.handleReconstruct(inst_store, req_alloc, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (std.mem.eql(u8, seg5, "cancel") and method == .POST) {
                const r = instance_routes.handleCancel(inst_store, task_store_inst, req_alloc, seg4, user_id);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (std.mem.eql(u8, seg5, "pins") and method == .GET) {
                // PIN-04 AC4: GET /api/v1/instances/:id/pins — must precede plain /:id
                const r = instance_routes.handleGetPins(inst_store, req_alloc, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (std.mem.eql(u8, seg5, "rebind-pins") and method == .POST) {
                // PIN-05: POST /api/v1/instances/:id/rebind-pins — must precede plain /:id
                const r = pin_rebind_routes.handleRebindPins(inst_store.pool, req_alloc, user_id, seg4, body);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (seg5.len == 0 and method == .GET) {
                // GET /api/v1/instances/:id
                const r = instance_routes.handleGetById(inst_store, req_alloc, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "tasks")) {
            // Build actor for task handlers.
            const actor = task_routes.Actor{
                .user_id = user_id,
                .is_operator_or_above = true,
                .is_platform_admin = false,
            };

            if (seg4.len == 0) {
                // GET /api/v1/tasks
                if (method == .GET) {
                    const instance_id_opt: ?task_store.Uuid = if (QS.get(query_str, "instance_id")) |s|
                        task_store.parseUuid(s) catch null
                    else
                        null;
                    const params = task_routes.ListTasksParams{
                        .assignee_id = QS.get(query_str, "assignee_id"),
                        .status = if (QS.get(query_str, "status")) |s|
                            std.meta.stringToEnum(task_store.TaskStatus, s) orelse null
                        else
                            null,
                        .instance_id = instance_id_opt,
                        .cursor = QS.get(query_str, "cursor"),
                        .page_size = std.fmt.parseInt(u16, QS.get(query_str, "page_size") orelse "50", 10) catch 50,
                    };
                    const r = task_routes.handleList(task_store_inst, req_alloc, actor, params);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else if (std.mem.eql(u8, seg4, "inbox") and seg5.len == 0) {
                // GET /api/v1/tasks/inbox
                if (method == .GET) {
                    const page_size = std.fmt.parseInt(u16, QS.get(query_str, "page_size") orelse "50", 10) catch 50;
                    const r = task_routes.handleInbox(task_store_inst, req_alloc, actor, QS.get(query_str, "cursor"), page_size);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else if (seg5.len == 0 and method == .GET) {
                // GET /api/v1/tasks/:id
                const r = task_routes.handleGetById(task_store_inst, req_alloc, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (method == .POST and std.mem.eql(u8, seg5, "complete")) {
                const r = task_routes.handleComplete(task_store_inst, inst_store, id_svc, req_alloc, actor, seg4, body);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (method == .POST and std.mem.eql(u8, seg5, "claim")) {
                const r = task_routes.handleClaim(task_store_inst, req_alloc, actor, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (method == .POST and std.mem.eql(u8, seg5, "assign")) {
                const r = task_routes.handleAssign(task_store_inst, req_alloc, actor, seg4, body);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (method == .POST and std.mem.eql(u8, seg5, "reassign")) {
                const r = task_routes.handleReassign(task_store_inst, req_alloc, actor, seg4, body);
                resp_status = r.status_code;
                resp_body = r.body;
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "dlq")) {
            const actor = dlq_routes.Actor{
                .user_id = user_id,
                .roles = null,
                .is_operator_or_above = true,
                .is_platform_admin = false,
            };

            if (seg4.len == 0) {
                if (method == .GET) {
                    const item_type_filter = blk: {
                        const source_type = QS.get(query_str, "source_type");
                        if (source_type) |raw_source| {
                            if (std.ascii.eqlIgnoreCase(raw_source, "service_task")) break :blk dlq_store.DlqItemType.SERVICE_TASK;
                            if (std.ascii.eqlIgnoreCase(raw_source, "webhook")) break :blk dlq_store.DlqItemType.WEBHOOK;
                            if (std.ascii.eqlIgnoreCase(raw_source, "timer")) break :blk dlq_store.DlqItemType.TIMER;
                            resp_status = 422;
                            resp_body = "{\"type\":\"invalid_filter\",\"status\":422,\"detail\":\"source_type must be service_task, webhook, or timer\"}";
                            break :blk null;
                        }

                        const item_type = QS.get(query_str, "item_type");
                        if (item_type) |raw_type| {
                            if (std.ascii.eqlIgnoreCase(raw_type, "service_task") or std.mem.eql(u8, raw_type, "SERVICE_TASK")) break :blk dlq_store.DlqItemType.SERVICE_TASK;
                            if (std.ascii.eqlIgnoreCase(raw_type, "webhook") or std.mem.eql(u8, raw_type, "WEBHOOK")) break :blk dlq_store.DlqItemType.WEBHOOK;
                            if (std.ascii.eqlIgnoreCase(raw_type, "timer") or std.mem.eql(u8, raw_type, "TIMER")) break :blk dlq_store.DlqItemType.TIMER;
                            resp_status = 422;
                            resp_body = "{\"type\":\"invalid_filter\",\"status\":422,\"detail\":\"item_type must be SERVICE_TASK, WEBHOOK, or TIMER\"}";
                            break :blk null;
                        }

                        break :blk null;
                    };

                    if (resp_status == 422) {
                        // Filter validation failed above.
                    } else {
                        const r = dlq_routes.handleList(pool, req_alloc, actor, .{
                            .cursor = QS.get(query_str, "cursor"),
                            .page_size = if (QS.get(query_str, "page_size")) |ps| std.fmt.parseInt(u16, ps, 10) catch null else null,
                            .instance_id = QS.get(query_str, "instance_id"),
                            .item_type = item_type_filter,
                        });
                        resp_status = r.status_code;
                        resp_body = r.body;
                    }
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else if (method == .POST and std.mem.eql(u8, seg5, "retry")) {
                const r = dlq_routes.handleRetry(pool, req_alloc, actor, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (method == .POST and std.mem.eql(u8, seg5, "discard")) {
                var discard_reason: ?[]const u8 = null;
                if (body.len > 0) {
                    const parsed = std.json.parseFromSlice(std.json.Value, req_alloc, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
                        resp_status = 400;
                        resp_body = "{\"type\":\"malformed_json\",\"status\":400,\"title\":\"Bad Request\"}";
                        const ct_hdr = [_]std.http.Header{.{ .name = "content-type", .value = resp_content_type }};
                        try request.respond(resp_body, .{ .status = @enumFromInt(resp_status), .keep_alive = false, .extra_headers = &ct_hdr });
                        return;
                    };
                    defer parsed.deinit();
                    if (parsed.value == .object) {
                        if (parsed.value.object.get("reason")) |raw_reason| {
                            switch (raw_reason) {
                                .null => discard_reason = null,
                                .string => |s| discard_reason = if (s.len == 0) null else s,
                                else => {
                                    resp_status = 422;
                                    resp_body = "{\"type\":\"invalid_body\",\"status\":422,\"detail\":\"reason must be a string when provided\"}";
                                },
                            }
                        }
                    }
                }

                if (resp_status == 422) {
                    // Body validation failed above.
                } else {
                    const r = dlq_routes.handleDiscard(pool, req_alloc, actor, seg4, discard_reason);
                    resp_status = r.status_code;
                    resp_body = r.body;
                }
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "services")) {
            // GET /api/v1/services  (SVC-01, SVC-04) — tenant-scoped listing
            var svc_cat = service_catalog_repo.ServiceCatalog.init(req_alloc, pool);
            defer svc_cat.deinit();

            const actor_svc: api_auth.AuthContext = authenticated_ctx orelse .{
                .user_id = user_id,
                .role = .PLATFORM_ADMIN,
                .is_bootstrap = false,
                .token_id = user_id,
                .principal = user_id,
            };

            if (method == .GET) {
                const after_id = QS.get(query_str, "after_id");
                const limit_opt: ?u32 = if (QS.get(query_str, "limit")) |ls|
                    std.fmt.parseInt(u32, ls, 10) catch null
                else
                    null;
                const r = services_routes.handleListServices(req_alloc, &svc_cat, actor_svc, after_id, limit_opt);
                resp_status = r.status_code;
                resp_body = r.body;
            } else {
                resp_status = 405;
                resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
            }
        } else if (std.mem.eql(u8, resource, "process-modules")) {
            // PLC-01: process module catalog
            var pmc_cat = process_module_catalog_repo.ProcessModuleCatalog.init(req_alloc, pool);
            defer pmc_cat.deinit();

            const actor_pm: api_auth.AuthContext = authenticated_ctx orelse .{
                .user_id = user_id,
                .role = .PLATFORM_ADMIN,
                .is_bootstrap = false,
                .token_id = user_id,
                .principal = user_id,
            };

            if (seg5.len > 0 and std.mem.eql(u8, seg5, "versions") and seg6.len > 0) {
                // GET /api/v1/process-modules/:id/versions/:v
                if (method == .GET) {
                    const r = process_modules_routes.handleGetModuleVersion(req_alloc, &pmc_cat, actor_pm, seg4, seg6);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else if (seg5.len > 0 and std.mem.eql(u8, seg5, "publish")) {
                // POST /api/v1/process-modules/:id/publish
                if (method == .POST) {
                    const r = process_modules_routes.handlePublishModule(req_alloc, &pmc_cat, actor_pm, seg4, seg6);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else if (method == .GET) {
                // GET /api/v1/process-modules
                const after_cv = QS.get(query_str, "after_module_version");
                const limit_opt: ?u32 = if (QS.get(query_str, "limit")) |ls|
                    std.fmt.parseInt(u32, ls, 10) catch null
                else
                    null;
                const r = process_modules_routes.handleListModules(req_alloc, &pmc_cat, actor_pm, after_cv, limit_opt);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (method == .POST) {
                // POST /api/v1/process-modules
                const r = process_modules_routes.handleRegisterModule(req_alloc, &pmc_cat, actor_pm, body);
                resp_status = r.status_code;
                resp_body = r.body;
            } else {
                resp_status = 405;
                resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
            }
        } else if (std.mem.eql(u8, resource, "admin") and seg4.len > 0) {
            // PLC-01/PLC-04 admin routes
            var pmc_admin = process_module_catalog_repo.ProcessModuleCatalog.init(req_alloc, pool);
            defer pmc_admin.deinit();

            const actor_admin: api_auth.AuthContext = authenticated_ctx orelse .{
                .user_id = user_id,
                .role = .PLATFORM_ADMIN,
                .is_bootstrap = false,
                .token_id = user_id,
                .principal = user_id,
            };

            if (std.mem.eql(u8, seg4, "module-shares")) {
                if (seg5.len == 0) {
                    // POST /api/v1/admin/module-shares
                    if (method == .POST) {
                        const r = process_modules_routes.handleGrantShare(req_alloc, &pmc_admin, actor_admin, body);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else {
                        resp_status = 405;
                        resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                    }
                } else {
                    // DELETE /api/v1/admin/module-shares/:grant_id
                    if (method == .DELETE) {
                        const r = process_modules_routes.handleRevokeShare(req_alloc, &pmc_admin, actor_admin, seg5);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else {
                        resp_status = 405;
                        resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                    }
                }
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "webhooks")) {
            const actor = api_auth.AuthContext{
                .user_id = user_id,
                .role = .PLATFORM_ADMIN,
                .is_bootstrap = false,
                .token_id = user_id,
                .principal = user_id,
            };

            if (std.mem.eql(u8, seg4, "subscriptions")) {
                if (seg5.len == 0) {
                    if (method == .GET) {
                        const r = webhooks_routes.handleListSubscriptions(req_alloc, pool, actor);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else if (method == .POST) {
                        const r = webhooks_routes.handleCreateSubscription(req_alloc, pool, actor, body, production_mode);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else {
                        resp_status = 405;
                        resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                    }
                } else if (seg6.len == 0) {
                    if (method == .PATCH) {
                        const r = webhooks_routes.handleUpdateSubscription(req_alloc, pool, actor, seg5, body);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else if (method == .DELETE) {
                        const r = webhooks_routes.handleDeleteSubscription(req_alloc, pool, actor, seg5);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else {
                        resp_status = 405;
                        resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                    }
                } else if (std.mem.eql(u8, seg6, "deliveries")) {
                    if (method == .GET) {
                        const r = webhooks_routes.handleListDeliveries(req_alloc, pool, actor, seg5, QS.get(query_str, "limit"));
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else {
                        resp_status = 405;
                        resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                    }
                } else {
                    resp_status = 404;
                    resp_body = "{\"type\":\"not_found\",\"status\":404}";
                }
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "audit")) {
            const actor = api_auth.AuthContext{
                .user_id = user_id,
                .role = .PLATFORM_ADMIN,
                .is_bootstrap = false,
                .token_id = user_id,
                .principal = user_id,
            };

            if (actor.role != .PLATFORM_ADMIN) {
                resp_status = 403;
                resp_body = "{\"error\":\"forbidden\"}";
            } else if (seg4.len == 0 and method == .GET) {
                const params = audit_routes.ListAuditParams{
                    .actor_id = QS.get(query_str, "actor_id"),
                    .resource_type = QS.get(query_str, "resource_type"),
                    .resource_id = QS.get(query_str, "resource_id"),
                    .pipeline_run_id = QS.get(query_str, "pipeline_run_id"),
                    .from = QS.get(query_str, "from"),
                    .to = QS.get(query_str, "to"),
                    .cursor = QS.get(query_str, "cursor"),
                    .page_size = if (QS.get(query_str, "page_size")) |ps| std.fmt.parseInt(u16, ps, 10) catch null else null,
                };
                const r = audit_routes.handleList(pool, req_alloc, params);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (seg4.len == 0) {
                resp_status = 405;
                resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "auth")) {
            const actor = api_auth.AuthContext{
                .user_id = user_id,
                .role = .PLATFORM_ADMIN,
                .is_bootstrap = false,
                .token_id = user_id,
                .principal = user_id,
            };

            if (std.mem.eql(u8, seg4, "tokens")) {
                if (seg5.len == 0) {
                    if (method == .GET) {
                        const r = identity_routes.handleListTokens(id_svc, req_alloc, actor);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else if (method == .POST) {
                        const r = identity_routes.handleCreateToken(id_svc, req_alloc, actor, body);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else {
                        resp_status = 405;
                        resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                    }
                } else if (seg6.len == 0 and method == .DELETE) {
                    const r = identity_routes.handleRevokeToken(id_svc, req_alloc, actor, seg5);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 404;
                    resp_body = "{\"type\":\"not_found\",\"status\":404}";
                }
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "admin")) {
            const actor = api_auth.AuthContext{
                .user_id = user_id,
                .role = .PLATFORM_ADMIN,
                .is_bootstrap = false,
                .token_id = user_id,
                .principal = user_id,
            };
            if (std.mem.eql(u8, seg4, "services")) {
                // GET  /api/v1/admin/services           → handleAdminListServices (SVC-04)
                // POST /api/v1/admin/services           → handleAdminRegisterService (SVC-04)
                // PATCH /api/v1/admin/services/:id      → handleAdminUpdateService (SVC-04)
                // DELETE /api/v1/admin/services/:id     → handleAdminDeleteService (SVC-04)
                var svc_cat_admin = service_catalog_repo.ServiceCatalog.init(req_alloc, pool);
                defer svc_cat_admin.deinit();

                if (seg5.len == 0) {
                    if (method == .GET) {
                        const after_id = QS.get(query_str, "after_id");
                        const limit_opt: ?u32 = if (QS.get(query_str, "limit")) |ls|
                            std.fmt.parseInt(u32, ls, 10) catch null
                        else
                            null;
                        const r = services_routes.handleAdminListServices(req_alloc, &svc_cat_admin, actor, after_id, limit_opt);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else if (method == .POST) {
                        const r = services_routes.handleAdminRegisterService(req_alloc, &svc_cat_admin, actor, body);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else {
                        resp_status = 405;
                        resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                    }
                } else {
                    // /api/v1/admin/services/:service_id
                    if (method == .PATCH) {
                        const r = services_routes.handleAdminUpdateService(req_alloc, &svc_cat_admin, actor, seg5, body);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else if (method == .DELETE) {
                        const r = services_routes.handleAdminDeleteService(req_alloc, &svc_cat_admin, actor, seg5);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else {
                        resp_status = 405;
                        resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                    }
                }
            } else if (std.mem.eql(u8, seg4, "migrations")) {
                // MIG-06: migration admin surface.
                // POST /api/v1/admin/migrations/run
                // GET  /api/v1/admin/migrations/{migration_id}/status
                // POST /api/v1/admin/migrations/{migration_id}/resume
                //
                // No-op DdlStep: no real DDL step registry exists yet for the
                // platform.platform_migrations fanout system (see the design
                // doc's Open Questions §2 — the same gap that motivates the
                // caller-supplied known_migration_ids parameter below). A
                // future wiring task supplies real DdlStep implementations
                // once DDL-01/MIG-01's migration-plan CLI exists; until then
                // this satisfies the route contract (run/status/resume
                // reachable, gated, correctly shaped responses) without
                // executing arbitrary DDL.
                const noOpStep = struct {
                    fn step(conn: *db_pool.Conn, schema_name: []const u8) anyerror!void {
                        _ = schema_name;
                        try conn.exec("SELECT 1", &.{});
                    }
                }.step;
                // No migration registry exists yet (see handler doc comment)
                // so the known set is empty — every run request 404s as
                // UnknownMigration until a real registry is wired in, which
                // is the conservative, non-destructive interim behavior.
                const known_migration_ids: []const []const u8 = &.{};

                if (seg5.len == 0 and method == .POST) {
                    const r = platform_migrations_routes.handleRunMigration(pool, req_alloc, actor, body, known_migration_ids, noOpStep);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (seg5.len > 0 and std.mem.eql(u8, seg6, "status") and method == .GET) {
                    const r = platform_migrations_routes.handleMigrationStatus(pool, req_alloc, actor, seg5);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (seg5.len > 0 and std.mem.eql(u8, seg6, "resume") and method == .POST) {
                    const r = platform_migrations_routes.handleResumeMigration(pool, req_alloc, actor, seg5, noOpStep);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 404;
                    resp_body = "{\"type\":\"not_found\",\"status\":404}";
                }
            } else if (std.mem.eql(u8, seg4, "tenants") and seg5.len > 0) {
                // POST /api/v1/admin/tenants/{tenant_id}/export    (TNT-06)
                // POST /api/v1/admin/tenants/{tenant_id}/import    (TNT-06)
                // POST /api/v1/admin/tenants/{tenant_id}/reset     (ENV-05)
                // DELETE /api/v1/admin/tenants/{tenant_id}         (ENV-05)
                if (method == .POST and std.mem.eql(u8, seg6, "export")) {
                    const r = tenant_migration_admin.handleExportTenant(pool, req_alloc, seg5, body);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (method == .POST and std.mem.eql(u8, seg6, "import")) {
                    const r = tenant_migration_admin.handleImportTenant(pool, req_alloc, seg5, body);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (method == .POST and std.mem.eql(u8, seg6, "reset") and seg5.len > 0) {
                    // ENV-05: POST /api/v1/admin/tenants/:id/reset
                    const r = tenant_lifecycle_admin.handleReset(pool, req_alloc, seg5);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (method == .DELETE and seg6.len == 0 and seg5.len > 0) {
                    // ENV-05: DELETE /api/v1/admin/tenants/:id
                    const idp_mgr = api_auth.getIdentityProviderManager();
                    const r = tenant_lifecycle_admin.handleDelete(pool, req_alloc, idp_mgr, seg5);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 404;
                    resp_body = "{\"type\":\"not_found\",\"status\":404}";
                }
            } else if (std.mem.eql(u8, seg4, "groups")) {
                if (seg5.len == 0) {
                    if (method == .GET) {
                        const r = identity_routes.handleListGroups(id_svc, req_alloc, actor);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else if (method == .POST) {
                        const r = identity_routes.handleCreateGroup(id_svc, req_alloc, actor, body);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else {
                        resp_status = 405;
                        resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                    }
                } else if (std.mem.eql(u8, seg6, "members")) {
                    if (method == .GET) {
                        const r = identity_routes.handleListGroupMembersArray(id_svc, req_alloc, actor, seg5);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else if (method == .POST) {
                        const r = identity_routes.handleAddGroupMember(id_svc, req_alloc, actor, seg5, body);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else if (method == .DELETE) {
                        const maybe_page = id_svc.listGroupMembers(req_alloc, actor, seg5, .{ .cursor = null, .page_size = 200 }) catch |err| switch (err) {
                            identity_service.GroupError.GroupNotFound => blk: {
                                resp_status = 404;
                                resp_body = "{\"error\":\"group_not_found\"}";
                                break :blk null;
                            },
                            identity_service.GroupError.ValidationFailed => blk: {
                                resp_status = 422;
                                resp_body = "{\"error\":\"validation_failed\"}";
                                break :blk null;
                            },
                            identity_service.GroupError.Forbidden => blk: {
                                resp_status = 403;
                                resp_body = "{\"error\":\"forbidden\"}";
                                break :blk null;
                            },
                            else => blk: {
                                resp_status = 500;
                                resp_body = "{\"error\":\"internal_error\"}";
                                break :blk null;
                            },
                        };
                        if (maybe_page) |page| {
                            defer page.deinit(req_alloc);
                            for (page.items) |member| {
                                id_svc.removeGroupMember(req_alloc, actor, .{ .group_id = seg5, .user_id = member.user_id }) catch {};
                            }
                            resp_status = 204;
                            resp_body = "";
                        }
                    } else {
                        resp_status = 405;
                        resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                    }
                } else if (seg6.len == 0 and method == .DELETE) {
                    const r = identity_routes.handleDeleteGroup(id_svc, req_alloc, actor, seg5);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 404;
                    resp_body = "{\"type\":\"not_found\",\"status\":404}";
                }
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "users")) {
            const actor = api_auth.AuthContext{
                .user_id = user_id,
                .role = .PLATFORM_ADMIN,
                .is_bootstrap = false,
                .token_id = user_id,
                .principal = user_id,
            };

            if (seg4.len == 0) {
                if (method == .GET) {
                    const params = identity_routes.ListUsersQueryParams{
                        .search = QS.getDecoded(query_str, "search", req_alloc),
                        .status = QS.get(query_str, "status"),
                        .page = std.fmt.parseInt(u32, QS.get(query_str, "page") orelse "1", 10) catch 1,
                        .page_size = std.fmt.parseInt(u16, QS.get(query_str, "page_size") orelse "25", 10) catch 25,
                    };
                    const r = identity_routes.handleListUsers(id_svc, req_alloc, actor, params);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (method == .POST) {
                    const r = identity_routes.handleCreateUser(id_svc, req_alloc, actor, body);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else if (seg5.len == 0) {
                if (method == .GET) {
                    const r = identity_routes.handleGetUser(id_svc, req_alloc, actor, seg4);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (method == .PATCH) {
                    const r = identity_routes.handlePatchUser(id_svc, req_alloc, actor, seg4, body);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "tenants")) {
            // GET /api/v1/tenants       — PLATFORM_ADMIN list
            // GET /api/v1/tenants/:slug — PLATFORM_ADMIN read
            // PATCH /api/v1/tenants/:slug — PLATFORM_ADMIN update
            const actor = api_auth.AuthContext{
                .user_id = user_id,
                .role = .PLATFORM_ADMIN,
                .is_bootstrap = false,
                .token_id = user_id,
                .principal = user_id,
            };

            if (seg4.len == 0) {
                if (method == .GET) {
                    const limit_raw = std.fmt.parseInt(u16, QS.get(query_str, "limit") orelse "20", 10) catch 20;
                    const offset_raw = std.fmt.parseInt(u32, QS.get(query_str, "offset") orelse "0", 10) catch 0;
                    const params = identity_routes.ListTenantsQueryParams{
                        .search = QS.getDecoded(query_str, "search", req_alloc),
                        .limit = if (limit_raw > 100) 100 else limit_raw,
                        .offset = offset_raw,
                    };
                    const r = identity_routes.handleListTenants(id_svc, req_alloc, actor, params);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else if (seg5.len == 0) {
                if (method == .GET) {
                    const r = identity_routes.handleGetTenant(id_svc, req_alloc, actor, seg4);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (method == .PATCH) {
                    const r = identity_routes.handlePatchTenant(id_svc, req_alloc, actor, seg4, body);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else if (method == .POST and seg6.len == 0 and std.mem.eql(u8, seg5, "deactivate")) {
                const r = identity_routes.handleDeactivateTenant(id_svc, req_alloc, actor, seg4, body);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (method == .POST and seg6.len == 0 and std.mem.eql(u8, seg5, "reactivate")) {
                const r = identity_routes.handleReactivateTenant(id_svc, req_alloc, actor, seg4, body);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (method == .POST and std.mem.eql(u8, seg5, "solution-packs") and
                (std.mem.eql(u8, seg6, "export") or std.mem.eql(u8, seg6, "install")))
            {
                // SOL-01: POST /api/v1/tenants/{tenant_id}/solution-packs/export
                // SOL-02: POST /api/v1/tenants/{tenant_id}/solution-packs/install
                if (std.mem.eql(u8, seg6, "export")) {
                    const r = solution_pack_routes.handleExport(pool, req_alloc, body);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    const r = solution_pack_routes.handleInstall(pool, req_alloc, user_id, body);
                    resp_status = r.status_code;
                    resp_body = r.body;
                }
            } else if (method == .POST and std.mem.eql(u8, seg5, "promote") and seg6.len > 0) {
                // ENV-03: POST /api/v1/tenants/:test_tenant_id/promote/:definition_name
                const r = promotion_routes.handlePromotion(pool, req_alloc, actor, seg4, seg6);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (method == .POST and seg6.len == 0) {
                resp_status = 400;
                resp_body = "{\"error\":\"invalid_lifecycle_action\"}";
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "promotions")) {
            // PRM-01: POST /api/v1/promotions
            const actor = api_auth.AuthContext{
                .user_id = user_id,
                .role = .PLATFORM_ADMIN,
                .is_bootstrap = false,
                .token_id = user_id,
                .principal = user_id,
            };
            if (seg4.len == 0 and method == .POST) {
                const r = promotions_routes.handleCreatePromotionPlan(pool, req_alloc, actor, body);
                resp_status = r.status_code;
                resp_body = r.body;
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "onboarding")) {
            // ── /api/v1/onboarding — OIDC-35 ─────────────────────────────────
            const actor = api_auth.AuthContext{
                .user_id = user_id,
                .role = .PLATFORM_ADMIN,
                .is_bootstrap = false,
                .token_id = user_id,
                .principal = user_id,
            };

            if (seg4.len == 0 and method == .POST) {
                // POST /api/v1/onboarding
                const r = onboarding_routes.handleOnboarding(id_svc, req_alloc, actor, body, idempotency_key_hdr);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (seg4.len > 0 and seg5.len == 0 and method == .GET) {
                // GET /api/v1/onboarding/:onboarding_id
                const r = onboarding_routes.handleGetOnboarding(id_svc, api_auth.getIdentityProviderManager(), req_alloc, actor, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (seg4.len == 0 and method == .GET) {
                // GET /api/v1/onboarding?hostname=...
                const hostname = QS.get(query_str, "hostname") orelse "";
                const r = onboarding_routes.handleGetOnboardingByHostname(id_svc, req_alloc, actor, hostname);
                resp_status = r.status_code;
                resp_body = r.body;
            } else {
                resp_status = 405;
                resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
            }
        } else if (std.mem.eql(u8, resource, "entity-definitions")) {
            // ── /api/v1/entity-definitions — EXP-201 ─────────────────────────
            if (seg4.len == 0) {
                // GET /api/v1/entity-definitions  or  POST /api/v1/entity-definitions
                if (method == .GET) {
                    const r = entity_routes.handleListDefinitions(req_alloc, pool, user_id, query_str);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (method == .POST) {
                    const r = entity_routes.handleCreateDefinition(req_alloc, pool, body, user_id, user_id);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else if (std.mem.eql(u8, seg5, "activate") and method == .POST) {
                // POST /api/v1/entity-definitions/:id/activate
                const r = entity_routes.handleActivateDefinition(req_alloc, pool, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (seg5.len == 0) {
                // GET /api/v1/entity-definitions/:id  (future)
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "entities")) {
            // ── /api/v1/entities/:type — EXP-202 ─────────────────────────────
            if (seg4.len > 0) {
                if (std.mem.eql(u8, seg5, "query") and method == .POST) {
                    // POST /api/v1/entities/:entity_key/query — QRY-01..04
                    const actor = authenticated_ctx orelse api_auth.AuthContext{
                        .user_id = user_id,
                        .role = .TASK_WORKER,
                        .is_bootstrap = false,
                        .token_id = user_id,
                        .principal = user_id,
                    };
                    const r = entity_query_routes.handleEntityQuery(req_alloc, pool, actor, seg4, body);
                    resp_status = r.status_code;
                    resp_body = r.body;
                    resp_content_type = r.content_type;
                } else if (seg5.len == 0) {
                    // POST /api/v1/entities/:type  or  GET /api/v1/entities/:type
                    if (method == .POST) {
                        const r = entity_routes.handleCreateRecord(req_alloc, pool, ev_store, seg4, body, user_id, user_id);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else if (method == .GET) {
                        const r = entity_routes.handleListRecords(req_alloc, pool, seg4, user_id);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else {
                        resp_status = 405;
                        resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                    }
                } else {
                    // GET/PATCH/DELETE /api/v1/entities/:type/:id
                    if (method == .GET) {
                        const r = entity_routes.handleGetRecord(req_alloc, pool, seg4, seg5, user_id);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else if (method == .PATCH) {
                        const r = entity_routes.handleUpdateRecord(req_alloc, pool, ev_store, seg4, seg5, body, user_id, user_id);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else if (method == .DELETE) {
                        const r = entity_routes.handleDeleteRecord(req_alloc, pool, ev_store, seg4, seg5, user_id, user_id);
                        resp_status = r.status_code;
                        resp_body = r.body;
                    } else {
                        resp_status = 405;
                        resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                    }
                }
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "roles")) {
            // ── /api/v1/roles — IDN-05 named-role registry ────────────────────
            const actor = authenticated_ctx orelse api_auth.AuthContext{
                .user_id = user_id,
                .role = .TASK_WORKER,
                .is_bootstrap = false,
                .token_id = user_id,
                .principal = user_id,
            };

            if (seg4.len == 0) {
                if (method == .GET) {
                    const r = identity_routes.handleListRoles(role_store, req_alloc, actor);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else if (method == .POST) {
                    const r = identity_routes.handleUpsertRole(role_store, req_alloc, actor, body);
                    resp_status = r.status_code;
                    resp_body = r.body;
                } else {
                    resp_status = 405;
                    resp_body = "{\"type\":\"method_not_allowed\",\"status\":405}";
                }
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else if (std.mem.eql(u8, resource, "agent")) {
            // ── /api/v1/agent — SBX-01/02/03 ─────────────────────────────────
            // POST /api/v1/agent/task-specs       → handleSubmitTaskSpec (SBX-01/02)
            // GET  /api/v1/agent/sandboxes         → handleListSandboxes (SBX-03)
            // POST /api/v1/agent/sandboxes/:id/claim → handleClaimSandbox (SBX-03)
            const actor_agent = authenticated_ctx orelse api_auth.AuthContext{
                .user_id = user_id,
                .role = .AGENT_RUNNER,
                .is_bootstrap = false,
                .token_id = user_id,
                .principal = user_id,
            };
            if (std.mem.eql(u8, seg4, "artifacts") and seg5.len == 0 and method == .POST) {
                // AGT-01..04: POST /api/v1/agent/artifacts
                const r = agent_artifacts_routes.handleArtifactSubmit(req_alloc, pool, actor_agent, body, production_mode);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (std.mem.eql(u8, seg4, "artifacts") and std.mem.eql(u8, seg5, "schemas") and method == .GET) {
                // AGT-01: GET /api/v1/agent/artifacts/schemas
                const r = agent_artifacts_routes.handleSchemaCatalog(req_alloc);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (std.mem.eql(u8, seg4, "task-specs") and seg5.len == 0 and method == .POST) {
                const r = agent_task_specs_routes.handleSubmitTaskSpec(req_alloc, pool, actor_agent, body);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (std.mem.eql(u8, seg4, "sandboxes") and seg5.len == 0 and method == .GET) {
                const cursor = QS.get(query_str, "cursor");
                const page_size_opt: ?u16 = if (QS.get(query_str, "page_size")) |ps|
                    std.fmt.parseInt(u16, ps, 10) catch null
                else
                    null;
                const r = agent_sandboxes_routes.handleListSandboxes(req_alloc, pool, actor_agent, cursor, page_size_opt);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (std.mem.eql(u8, seg4, "sandboxes") and seg5.len > 0 and std.mem.eql(u8, seg6, "claim") and method == .POST) {
                const r = agent_sandboxes_routes.handleClaimSandbox(req_alloc, pool, actor_agent, seg5, body);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (std.mem.eql(u8, seg4, "sandboxes") and seg5.len > 0 and std.mem.eql(u8, seg6, "claim") and method == .DELETE) {
                const r = agent_sandboxes_routes.handleReleaseSandbox(req_alloc, pool, actor_agent, seg5);
                resp_status = r.status_code;
                resp_body = r.body;
            } else {
                resp_status = 404;
                resp_body = "{\"type\":\"not_found\",\"status\":404}";
            }
        } else {
            resp_status = 404;
            resp_body = "{\"type\":\"not_found\",\"status\":404}";
        }
        {
            const req_log_fields = [_]obs_logger.LogField{
                .{ .key = "method", .value = .{ .string = @tagName(method) } },
                .{ .key = "path", .value = .{ .string = path } },
                .{ .key = "status_code", .value = .{ .integer = @as(i64, resp_status) } },
            };
            obs_logger.log(req_alloc, .INFO, "api.request", "request completed", &req_log_fields) catch {};
        }
    } else {
        resp_status = 404;
        resp_body = "{\"type\":\"not_found\",\"status\":404}";
    }

    // API-09: inject trace_id into 4xx/5xx JSON error bodies.
    const trace_id_final = api_trace_context.get();
    var final_resp_body = resp_body;
    if (resp_status >= 400 and trace_id_final.len > 0 and
        resp_body.len > 1 and resp_body[0] == '{' and resp_body[resp_body.len - 1] == '}')
    {
        final_resp_body = std.fmt.allocPrint(
            req_alloc,
            "{s},\"trace_id\":\"{s}\"}}",
            .{ resp_body[0 .. resp_body.len - 1], trace_id_final },
        ) catch resp_body;
    }

    const resp_hdrs = [_]std.http.Header{
        .{ .name = "content-type", .value = resp_content_type },
        .{ .name = "X-Trace-Id", .value = trace_id_final },
    };
    try request.respond(final_resp_body, .{
        .status = @enumFromInt(resp_status),
        .keep_alive = false,
        .extra_headers = &resp_hdrs,
    });
}
pub const engine_transition = @import("engine/transition.zig");
