const std = @import("std");

pub const RegressionCase = struct {
    case_id: []const u8,
    stage: u8,
    requirement_refs: []const []const u8,
    route: []const u8,
    method: []const u8,
    setup_fixture: []const u8,
    request_builder_id: []const u8,
    expected_status: u16,
};

const refs_adp12 = [_][]const u8{"ADP-12"};

const matrix_static = [_]RegressionCase{
    .{ .case_id = "S1-ES01-append", .stage = 1, .requirement_refs = refs_adp12[0..], .route = "/events", .method = "POST", .setup_fixture = "stage1", .request_builder_id = "rb-es01", .expected_status = 200 },
    .{ .case_id = "S1-ES02-read-ordered", .stage = 1, .requirement_refs = refs_adp12[0..], .route = "/instances/{id}/events", .method = "GET", .setup_fixture = "stage1", .request_builder_id = "rb-es02", .expected_status = 200 },
    .{ .case_id = "S1-ES03-idempotency", .stage = 1, .requirement_refs = refs_adp12[0..], .route = "/events", .method = "POST", .setup_fixture = "stage1", .request_builder_id = "rb-es03", .expected_status = 200 },
    .{ .case_id = "S1-ES04-global", .stage = 1, .requirement_refs = refs_adp12[0..], .route = "/events/global", .method = "GET", .setup_fixture = "stage1", .request_builder_id = "rb-es04", .expected_status = 200 },
    .{ .case_id = "S1-ES05-registry-upsert", .stage = 1, .requirement_refs = refs_adp12[0..], .route = "/event-types", .method = "POST", .setup_fixture = "stage1", .request_builder_id = "rb-es05-upsert", .expected_status = 200 },
    .{ .case_id = "S1-ES05-registry-validate", .stage = 1, .requirement_refs = refs_adp12[0..], .route = "/events", .method = "POST", .setup_fixture = "stage1", .request_builder_id = "rb-es05-validate", .expected_status = 422 },
    .{ .case_id = "S1-ES06-point-in-time", .stage = 1, .requirement_refs = refs_adp12[0..], .route = "/instances/{id}/events?up_to_sequence=K", .method = "GET", .setup_fixture = "stage1", .request_builder_id = "rb-es06", .expected_status = 200 },
    .{ .case_id = "S1-ES07-archive-read", .stage = 1, .requirement_refs = refs_adp12[0..], .route = "/archive/events", .method = "GET", .setup_fixture = "stage1", .request_builder_id = "rb-es07", .expected_status = 200 },

    .{ .case_id = "S2-PD01-create", .stage = 2, .requirement_refs = refs_adp12[0..], .route = "/definitions", .method = "POST", .setup_fixture = "stage2", .request_builder_id = "rb-pd01", .expected_status = 201 },
    .{ .case_id = "S2-PD02-validate", .stage = 2, .requirement_refs = refs_adp12[0..], .route = "/definitions/validate", .method = "POST", .setup_fixture = "stage2", .request_builder_id = "rb-pd02", .expected_status = 200 },
    .{ .case_id = "S2-PD03-version", .stage = 2, .requirement_refs = refs_adp12[0..], .route = "/definitions/{name}/versions", .method = "POST", .setup_fixture = "stage2", .request_builder_id = "rb-pd03", .expected_status = 201 },
    .{ .case_id = "S2-PD04-lifecycle", .stage = 2, .requirement_refs = refs_adp12[0..], .route = "/definitions/{id}/lifecycle", .method = "POST", .setup_fixture = "stage2", .request_builder_id = "rb-pd04", .expected_status = 200 },
    .{ .case_id = "S2-PD07-get", .stage = 2, .requirement_refs = refs_adp12[0..], .route = "/definitions/{id}", .method = "GET", .setup_fixture = "stage2", .request_builder_id = "rb-pd07", .expected_status = 200 },
    .{ .case_id = "S2-PD09-export", .stage = 2, .requirement_refs = refs_adp12[0..], .route = "/definitions/{id}/export", .method = "GET", .setup_fixture = "stage2", .request_builder_id = "rb-pd09", .expected_status = 200 },

    .{ .case_id = "S3-EE01-start", .stage = 3, .requirement_refs = refs_adp12[0..], .route = "/instances", .method = "POST", .setup_fixture = "stage3", .request_builder_id = "rb-ee01", .expected_status = 201 },
    .{ .case_id = "S3-EE03-task-activate", .stage = 3, .requirement_refs = refs_adp12[0..], .route = "/instances/{id}", .method = "GET", .setup_fixture = "stage3", .request_builder_id = "rb-ee03", .expected_status = 200 },
    .{ .case_id = "S3-EE04-complete-task", .stage = 3, .requirement_refs = refs_adp12[0..], .route = "/tasks/{id}/complete", .method = "POST", .setup_fixture = "stage3", .request_builder_id = "rb-ee04", .expected_status = 200 },
    .{ .case_id = "S3-EE05-exclusive", .stage = 3, .requirement_refs = refs_adp12[0..], .route = "/tasks/{id}/complete", .method = "POST", .setup_fixture = "stage3", .request_builder_id = "rb-ee05", .expected_status = 200 },
    .{ .case_id = "S3-EE06-07-parallel", .stage = 3, .requirement_refs = refs_adp12[0..], .route = "/tasks/{id}/complete", .method = "POST", .setup_fixture = "stage3", .request_builder_id = "rb-ee06-07", .expected_status = 200 },
    .{ .case_id = "S3-EE08-cancel", .stage = 3, .requirement_refs = refs_adp12[0..], .route = "/instances/{id}/cancel", .method = "POST", .setup_fixture = "stage3", .request_builder_id = "rb-ee08", .expected_status = 200 },
    .{ .case_id = "S3-EE09-vars", .stage = 3, .requirement_refs = refs_adp12[0..], .route = "/instances/{id}", .method = "GET", .setup_fixture = "stage3", .request_builder_id = "rb-ee09", .expected_status = 200 },
    .{ .case_id = "S3-EE11-reconstruct", .stage = 3, .requirement_refs = refs_adp12[0..], .route = "/instances/{id}/history", .method = "GET", .setup_fixture = "stage3", .request_builder_id = "rb-ee11", .expected_status = 200 },

    .{ .case_id = "S4-API02-def-crud", .stage = 4, .requirement_refs = refs_adp12[0..], .route = "/definitions", .method = "GET", .setup_fixture = "stage4", .request_builder_id = "rb-api02", .expected_status = 200 },
    .{ .case_id = "S4-API03-instance-mgmt", .stage = 4, .requirement_refs = refs_adp12[0..], .route = "/instances", .method = "GET", .setup_fixture = "stage4", .request_builder_id = "rb-api03", .expected_status = 200 },
    .{ .case_id = "S4-API04-task-ops", .stage = 4, .requirement_refs = refs_adp12[0..], .route = "/tasks", .method = "GET", .setup_fixture = "stage4", .request_builder_id = "rb-api04", .expected_status = 200 },
    .{ .case_id = "S4-API05-history", .stage = 4, .requirement_refs = refs_adp12[0..], .route = "/instances/{id}/history", .method = "GET", .setup_fixture = "stage4", .request_builder_id = "rb-api05", .expected_status = 200 },
    .{ .case_id = "S4-API06-pagination", .stage = 4, .requirement_refs = refs_adp12[0..], .route = "/instances?cursor=...", .method = "GET", .setup_fixture = "stage4", .request_builder_id = "rb-api06", .expected_status = 200 },
    .{ .case_id = "S4-API07-validation", .stage = 4, .requirement_refs = refs_adp12[0..], .route = "/instances", .method = "POST", .setup_fixture = "stage4", .request_builder_id = "rb-api07", .expected_status = 422 },
    .{ .case_id = "S4-API08-auth", .stage = 4, .requirement_refs = refs_adp12[0..], .route = "/instances", .method = "GET", .setup_fixture = "stage4", .request_builder_id = "rb-api08", .expected_status = 401 },
    .{ .case_id = "S4-API09-tracing", .stage = 4, .requirement_refs = refs_adp12[0..], .route = "/health/live", .method = "GET", .setup_fixture = "stage4", .request_builder_id = "rb-api09", .expected_status = 200 },
    .{ .case_id = "S4-API12-health", .stage = 4, .requirement_refs = refs_adp12[0..], .route = "/health/ready", .method = "GET", .setup_fixture = "stage4", .request_builder_id = "rb-api12", .expected_status = 200 },

    .{ .case_id = "S5-SCH01-create-timer", .stage = 5, .requirement_refs = refs_adp12[0..], .route = "/tasks/{id}/complete", .method = "POST", .setup_fixture = "stage5", .request_builder_id = "rb-sch01", .expected_status = 200 },
    .{ .case_id = "S5-SCH02-fire-observable", .stage = 5, .requirement_refs = refs_adp12[0..], .route = "/instances/{id}/history", .method = "GET", .setup_fixture = "stage5", .request_builder_id = "rb-sch02", .expected_status = 200 },
    .{ .case_id = "S5-SCH03-cancel-timer", .stage = 5, .requirement_refs = refs_adp12[0..], .route = "/instances/{id}/cancel", .method = "POST", .setup_fixture = "stage5", .request_builder_id = "rb-sch03", .expected_status = 200 },
    .{ .case_id = "S5-IDN01-users", .stage = 5, .requirement_refs = refs_adp12[0..], .route = "/users", .method = "GET", .setup_fixture = "stage5", .request_builder_id = "rb-idn01", .expected_status = 200 },
    .{ .case_id = "S5-IDN02-groups", .stage = 5, .requirement_refs = refs_adp12[0..], .route = "/groups", .method = "GET", .setup_fixture = "stage5", .request_builder_id = "rb-idn02", .expected_status = 200 },
    .{ .case_id = "S5-IDN03-rbac", .stage = 5, .requirement_refs = refs_adp12[0..], .route = "/admin/audit", .method = "GET", .setup_fixture = "stage5", .request_builder_id = "rb-idn03", .expected_status = 403 },
    .{ .case_id = "S5-IDN04-tokens", .stage = 5, .requirement_refs = refs_adp12[0..], .route = "/tokens", .method = "POST", .setup_fixture = "stage5", .request_builder_id = "rb-idn04", .expected_status = 201 },

    .{ .case_id = "S6-OBS01-logging-proxy", .stage = 6, .requirement_refs = refs_adp12[0..], .route = "/health/live", .method = "GET", .setup_fixture = "stage6", .request_builder_id = "rb-obs01", .expected_status = 200 },
    .{ .case_id = "S6-OBS02-metrics", .stage = 6, .requirement_refs = refs_adp12[0..], .route = "/metrics", .method = "GET", .setup_fixture = "stage6", .request_builder_id = "rb-obs02", .expected_status = 200 },
    .{ .case_id = "S6-OBS03-audit", .stage = 6, .requirement_refs = refs_adp12[0..], .route = "/admin/audit", .method = "GET", .setup_fixture = "stage6", .request_builder_id = "rb-obs03", .expected_status = 200 },
    .{ .case_id = "S6-OBS04-timeline", .stage = 6, .requirement_refs = refs_adp12[0..], .route = "/instances/{id}/timeline", .method = "GET", .setup_fixture = "stage6", .request_builder_id = "rb-obs04", .expected_status = 200 },
    .{ .case_id = "S6-OBS05-dlq-list", .stage = 6, .requirement_refs = refs_adp12[0..], .route = "/dlq", .method = "GET", .setup_fixture = "stage6", .request_builder_id = "rb-obs05", .expected_status = 200 },
    .{ .case_id = "S6-EXT01-service-task", .stage = 6, .requirement_refs = refs_adp12[0..], .route = "/tasks/{id}/complete", .method = "POST", .setup_fixture = "stage6", .request_builder_id = "rb-ext01", .expected_status = 200 },
    .{ .case_id = "S6-EXT02-webhook-subscribe", .stage = 6, .requirement_refs = refs_adp12[0..], .route = "/webhooks/subscriptions", .method = "POST", .setup_fixture = "stage6", .request_builder_id = "rb-ext02-sub", .expected_status = 201 },
    .{ .case_id = "S6-EXT02-webhook-list", .stage = 6, .requirement_refs = refs_adp12[0..], .route = "/webhooks/subscriptions", .method = "GET", .setup_fixture = "stage6", .request_builder_id = "rb-ext02-list", .expected_status = 200 },
};

pub fn loadStageCoverageMatrix(allocator: std.mem.Allocator) ![]RegressionCase {
    const out = try allocator.alloc(RegressionCase, matrix_static.len);
    @memcpy(out, matrix_static[0..]);
    return out;
}
