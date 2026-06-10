//! Service scope validator — SVC-03
//!
//! Validates that every SERVICE_TASK node in a process definition graph
//! references a service/plugin that is accessible to the activating tenant.
//! Called inside definition/store.zig activate() before the SQL transaction.
//!
//! Design artefact: src/design/svc-01-04-service-scope.md §2.5

const std = @import("std");
const graph_mod = @import("graph.zig");
const catalog_mod = @import("../repository/service_catalog.zig");
const plugin_registry = @import("../engine/plugin_registry.zig");

pub const ServiceScopeError = error{
    ServiceNotRegistered, // HTTP 422: service_id has no catalog entry
    ServiceNotAvailableToTenant, // HTTP 422: tenant-scoped service owned by other tenant
    PluginNotAvailableToTenant, // HTTP 422: tenant-scoped plugin owned by other tenant
    OutOfMemory,
    PoolExhausted,
    TransactionFailed,
};

/// Violation detail returned when validation fails.
pub const ScopeViolation = struct {
    node_id: []const u8,
    kind: enum { service, plugin },
    ref_id: []const u8,
    reason: []const u8,
};

pub const ServiceScopeValidator = struct {
    allocator: std.mem.Allocator,
    catalog: *catalog_mod.ServiceCatalog,
    plugin_reg: *const plugin_registry.PluginRegistry,

    _last_violation: ?ScopeViolation = null,
    _violation_buf: [512]u8 = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        catalog: *catalog_mod.ServiceCatalog,
        plugin_reg: *const plugin_registry.PluginRegistry,
    ) ServiceScopeValidator {
        return .{
            .allocator = allocator,
            .catalog = catalog,
            .plugin_reg = plugin_reg,
        };
    }

    /// Walk every SERVICE_TASK node in graph. Check scope for each
    /// service_id / plugin_handler reference against the activating tenant.
    /// Returns void on full pass. Returns error on the first violation.
    pub fn validateServiceTaskReferences(
        self: *ServiceScopeValidator,
        graph: graph_mod.DefinitionGraph,
        tenant_id: [16]u8,
    ) ServiceScopeError!void {
        self._last_violation = null;

        for (graph.nodes) |node| {
            if (node.node_type != .SERVICE_TASK) continue;

            // Parse attributes JSON to extract service_id and plugin_handler.
            const attrs_json = node.attributes orelse continue;

            var parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                attrs_json,
                .{ .allocate = .alloc_if_needed },
            ) catch continue;
            defer parsed.deinit();

            const obj = switch (parsed.value) {
                .object => |o| o,
                else => continue,
            };

            // Check service_id.
            if (obj.get("service_id")) |sid_val| {
                const sid = switch (sid_val) {
                    .string => |s| s,
                    else => continue,
                };
                if (sid.len > 0) {
                    try self.checkServiceId(node.id, sid, tenant_id);
                }
            }

            // Check plugin_handler.
            if (obj.get("plugin_handler")) |ph_val| {
                const ph = switch (ph_val) {
                    .string => |s| s,
                    else => continue,
                };
                if (ph.len > 0) {
                    try self.checkPluginHandler(node.id, ph, tenant_id);
                }
            }
        }
    }

    /// Returns the violation from the most recent failing call.
    pub fn lastViolation(self: *const ServiceScopeValidator) ?ScopeViolation {
        return self._last_violation;
    }

    fn checkServiceId(
        self: *ServiceScopeValidator,
        node_id: []const u8,
        service_id: []const u8,
        tenant_id: [16]u8,
    ) ServiceScopeError!void {
        // Fetch without scope filter to distinguish "not found" vs "wrong tenant".
        const rec = self.catalog.getService(self.allocator, service_id) catch |err| switch (err) {
            catalog_mod.CatalogError.ServiceNotFound => {
                const reason = std.fmt.bufPrint(
                    &self._violation_buf,
                    "service {s} is not registered",
                    .{service_id},
                ) catch "service is not registered";
                self._last_violation = .{
                    .node_id = node_id,
                    .kind = .service,
                    .ref_id = service_id,
                    .reason = reason,
                };
                return ServiceScopeError.ServiceNotRegistered;
            },
            catalog_mod.CatalogError.PoolExhausted => return ServiceScopeError.PoolExhausted,
            else => return ServiceScopeError.TransactionFailed,
        };
        // Free the record strings; we only needed scope / owner.
        self.allocator.free(rec.service_id);
        self.allocator.free(rec.endpoint_url);
        self.allocator.free(rec.request_schema);
        self.allocator.free(rec.response_schema);
        self.allocator.free(rec.retry_policy);

        if (rec.scope == .tenant) {
            const owner = rec.owner_tenant_id orelse {
                // Malformed DB row — treat as unavailable.
                self._last_violation = .{
                    .node_id = node_id,
                    .kind = .service,
                    .ref_id = service_id,
                    .reason = "service scope data is inconsistent",
                };
                return ServiceScopeError.ServiceNotAvailableToTenant;
            };
            if (!std.mem.eql(u8, &owner, &tenant_id)) {
                const reason = std.fmt.bufPrint(
                    &self._violation_buf,
                    "service {s} is not available to this tenant",
                    .{service_id},
                ) catch "service is not available to this tenant";
                self._last_violation = .{
                    .node_id = node_id,
                    .kind = .service,
                    .ref_id = service_id,
                    .reason = reason,
                };
                return ServiceScopeError.ServiceNotAvailableToTenant;
            }
        }
    }

    fn checkPluginHandler(
        self: *ServiceScopeValidator,
        node_id: []const u8,
        plugin_handler: []const u8,
        tenant_id: [16]u8,
    ) ServiceScopeError!void {
        // Look up in tenant-aware manner.
        // If a tenant-scoped plugin exists for this handler name and belongs to a
        // different tenant, that is a violation. If no plugin is found at all,
        // PD-05 already validates handler existence — skip here.
        const resolved = plugin_registry.resolvePluginHandlerForTenant(
            self.plugin_reg,
            plugin_handler,
            tenant_id,
        );

        if (resolved) |reg| {
            if (reg.scope == .tenant) {
                const owner = reg.owner_tenant_id orelse return;
                if (!std.mem.eql(u8, &owner, &tenant_id)) {
                    const reason = std.fmt.bufPrint(
                        &self._violation_buf,
                        "plugin {s} is not available to this tenant",
                        .{plugin_handler},
                    ) catch "plugin is not available to this tenant";
                    self._last_violation = .{
                        .node_id = node_id,
                        .kind = .plugin,
                        .ref_id = plugin_handler,
                        .reason = reason,
                    };
                    return ServiceScopeError.PluginNotAvailableToTenant;
                }
            }
        } else {
            // No handler found for this tenant. If a tenant-scoped entry exists
            // for any other tenant, the caller does not own it — deny.
            for (self.plugin_reg.tenant_entries.items) |reg| {
                if (!std.mem.eql(u8, reg.node_type, plugin_handler)) continue;
                const reason = std.fmt.bufPrint(
                    &self._violation_buf,
                    "plugin {s} is not available to this tenant",
                    .{plugin_handler},
                ) catch "plugin is not available to this tenant";
                self._last_violation = .{
                    .node_id = node_id,
                    .kind = .plugin,
                    .ref_id = plugin_handler,
                    .reason = reason,
                };
                return ServiceScopeError.PluginNotAvailableToTenant;
            }
            // No tenant-scoped entry at all: PD-05 already validates; skip.
        }
    }
};
