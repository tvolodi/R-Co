const std = @import("std");

// Module references — imported here so that `zig build` and `zig build test`
// compile and validate all Stage 1 modules.
pub const db_pool = @import("pool");
pub const db_migrations = @import("db/migrations.zig");
pub const config_mod = @import("config.zig");
pub const event_store = @import("event_store/store.zig");
pub const event_registry = @import("event_store/registry.zig");
pub const definition_graph = @import("definition/graph.zig");
pub const definition_store = @import("definition/store.zig");
pub const definition_snapshot = @import("definition/snapshot.zig");
pub const definition_export_import = @import("definition/export_import.zig"); // PD-09
pub const definition_routes = @import("api/routes/definitions.zig");
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
pub const json_schema_mod = @import("tools/json_schema.zig"); // EE-09 schema validator (pure)
pub const api_errors = @import("api/errors.zig"); // API-01 RFC 9457 Problem Details
pub const api_response = @import("api/response.zig"); // API-01 response builder
pub const api_content_type = @import("api/middleware/content_type.zig"); // API-01 Content-Type enforcement
pub const api_trace_context = @import("api/trace_context.zig"); // API-09 trace context
pub const api_tenant_context = @import("api/tenant_context.zig"); // ADP-03 request tenant context
pub const api_pipeline_context = @import("api/pipeline_context.zig"); // ADP-06 request pipeline context
pub const api_trace = @import("api/middleware/trace.zig"); // API-09 trace middleware
pub const api_rate_limit = @import("api/middleware/rate_limit.zig"); // API-10 rate limiting
pub const api_openapi = @import("api/openapi/mod.zig"); // API-11 OpenAPI builder/serializer
pub const openapi_routes = @import("api/routes/openapi.zig"); // API-11 public /openapi.json route handler
pub const health_routes = @import("api/routes/health.zig"); // API-12 public /health/live and /health/ready handlers
pub const metrics_routes = @import("api/routes/metrics.zig"); // OBS-02 public /metrics route handler
pub const audit_routes = @import("api/routes/audit.zig"); // OBS-03 GET /audit route handler
pub const dlq_store = @import("dlq/store.zig"); // OBS-05 dead-letter persistence
pub const dlq_routes = @import("api/routes/dlq.zig"); // OBS-05 DLQ API handlers
pub const webhooks_routes = @import("api/routes/webhooks.zig"); // EXT-02 webhook subscription API handlers
pub const api_health_readiness = @import("api/health/readiness.zig"); // API-12 readiness evaluation
pub const api_health_subsystems = @import("api/health/subsystems.zig"); // API-12 critical subsystem checks
pub const obs_logger = @import("obs/logger.zig"); // OBS-01 structured logger
pub const obs_metrics = @import("obs/metrics.zig"); // OBS-02 Prometheus metrics
pub const obs_audit = @import("obs/audit.zig"); // OBS-03 audit query service
pub const obs_alerts = @import("obs/alerts.zig"); // OBS-06 alerting hooks
pub const webhook_subscription_store = @import("webhook/subscription_store.zig"); // EXT-02 subscription storage
pub const webhook_dispatcher = @import("webhook/dispatcher.zig"); // EXT-02 webhook delivery dispatcher
pub const identity_registry = @import("identity/registry.zig"); // IDN-01 user registry persistence
pub const identity_service = @import("identity/service.zig"); // IDN-01 user registry service
pub const identity_routes = @import("api/routes/identity.zig"); // IDN-01 user registry HTTP handlers
pub const identity_provider = @import("identity_provider"); // OIDC provider contract and bootstrap wiring
pub const oidc_agent_lifecycle = @import("oidc/agent_lifecycle.zig"); // OIDC-16..26 lifecycle/idempotency/audit/metrics helpers
pub const api_auth = @import("api/middleware/auth.zig"); // API-08 auth middleware provider-manager configuration

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

    api_auth.configureIdentityProviderManager(idp_boot.active.manager);

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

    // Read request body (up to 1 MiB).
    var body_transfer_buf: [8192]u8 = undefined;
    var body_reader = request.readerExpectNone(&body_transfer_buf);
    const body = body_reader.allocRemaining(req_alloc, std.Io.Limit.limited(1 * 1024 * 1024)) catch &.{};

    // Extract user identity from request header.
    const user_id = blk: {
        var hdr_it = request.iterateHeaders();
        while (hdr_it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "x-bpm-user-id")) break :blk h.value;
        }
        break :blk "00000000-0000-0000-0000-000000000000";
    };

    // Split path from query string.
    const target = request.head.target;
    const q_start = std.mem.indexOf(u8, target, "?");
    const path = if (q_start) |qi| target[0..qi] else target;
    const query_str = if (q_start) |qi| target[qi + 1 ..] else "";

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
    };

    const method = request.head.method;

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
    // ── /api/v1/... ──────────────────────────────────────────────────────────
    else if (std.mem.startsWith(u8, path, "/api/v1/")) {
        // Split path into up to 8 segments.
        // e.g. "/api/v1/definitions/abc/activate"
        //       [0]="" [1]="api" [2]="v1" [3]="definitions" [4]="abc" [5]="activate"
        var segs: [8][]const u8 = @splat(@as([]const u8, ""));
        var seg_count: usize = 0;
        var seg_it = std.mem.splitScalar(u8, path, '/');
        while (seg_it.next()) |s| {
            if (seg_count >= 8) break;
            segs[seg_count] = s;
            seg_count += 1;
        }
        const resource = if (seg_count > 3) segs[3] else "";
        const seg4 = if (seg_count > 4) segs[4] else "";
        const seg5 = if (seg_count > 5) segs[5] else "";

        if (std.mem.eql(u8, resource, "definitions")) {
            // Actor UUID for definition writes (created_by).
            const actor_uuid: definition_store.Uuid = task_store.parseUuid(user_id) catch
                std.mem.zeroes(definition_store.Uuid);

            if (seg4.len == 0) {
                // GET /api/v1/definitions  or  POST /api/v1/definitions
                if (method == .GET) {
                    const params = definition_routes.ListQueryParams{
                        .name = QS.get(query_str, "name"),
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
                    defer parsed.deinit();
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
                    .q = QS.get(query_str, "q"),
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
                    defer parsed.deinit();
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
                const r = definition_routes.handleActivate(def_store, req_alloc, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
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
            } else if (std.mem.eql(u8, seg5, "reconstruct") and method == .GET) {
                const r = instance_routes.handleReconstruct(inst_store, req_alloc, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (std.mem.eql(u8, seg5, "cancel") and method == .POST) {
                const r = instance_routes.handleCancel(inst_store, task_store_inst, req_alloc, seg4, user_id);
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
            } else if (seg5.len == 0 and method == .GET) {
                // GET /api/v1/tasks/:id
                const r = task_routes.handleGetById(task_store_inst, req_alloc, seg4);
                resp_status = r.status_code;
                resp_body = r.body;
            } else if (method == .POST and std.mem.eql(u8, seg5, "complete")) {
                const r = task_routes.handleComplete(task_store_inst, inst_store, id_svc, req_alloc, actor, seg4, body);
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
        } else {
            resp_status = 404;
            resp_body = "{\"type\":\"not_found\",\"status\":404}";
        }
    } else {
        resp_status = 404;
        resp_body = "{\"type\":\"not_found\",\"status\":404}";
    }

    const ct_hdr = [_]std.http.Header{.{ .name = "content-type", .value = resp_content_type }};
    try request.respond(resp_body, .{
        .status = @enumFromInt(resp_status),
        .keep_alive = false,
        .extra_headers = &ct_hdr,
    });
}
pub const engine_transition = @import("engine/transition.zig");
