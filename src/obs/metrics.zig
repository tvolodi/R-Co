const std = @import("std");

pub const PROMETHEUS_CONTENT_TYPE = "text/plain; version=0.0.4";

pub const QueryType = enum {
    select,
    insert,
    update,
    delete,
    begin,
    commit,
    rollback,
    migration,
    other,

    pub fn asString(self: QueryType) []const u8 {
        return switch (self) {
            .select => "select",
            .insert => "insert",
            .update => "update",
            .delete => "delete",
            .begin => "begin",
            .commit => "commit",
            .rollback => "rollback",
            .migration => "migration",
            .other => "other",
        };
    }
};

const Histogram = struct {
    const finite_buckets = [_]f64{ 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0 };

    bucket_counts: [finite_buckets.len]u64 = std.mem.zeroes([finite_buckets.len]u64),
    count: u64 = 0,
    sum: f64 = 0.0,

    fn observe(self: *Histogram, value_seconds: f64) void {
        var value = value_seconds;
        if (value < 0) value = 0;

        self.count += 1;
        self.sum += value;

        for (finite_buckets, 0..) |le, idx| {
            if (value <= le) {
                self.bucket_counts[idx] += 1;
            }
        }
    }
};

pub const MetricsRegistry = struct {
    allocator: std.mem.Allocator,

    active_instances_total: u64 = 0,
    active_instances_stale: bool = false,

    event_append_duration: Histogram = .{},

    task_completions: std.StringHashMap(u64),

    db_query_duration: std.StringHashMap(Histogram),

    http_requests: std.StringHashMap(u64),

    http_errors: std.StringHashMap(u64),

    idp_token_verification_total: std.StringHashMap(u64),
    idp_token_verification_duration: std.StringHashMap(Histogram),
    idp_jwks_cache_access_total: std.StringHashMap(u64),
    idp_adapter_call_total: std.StringHashMap(u64),
    idp_adapter_call_duration: std.StringHashMap(Histogram),
    idp_adapter_error_total: std.StringHashMap(u64),
    idp_readiness_probe_total: std.StringHashMap(u64),
    idp_readiness_probe_duration: Histogram = .{},

    pub fn init(allocator: std.mem.Allocator) MetricsRegistry {
        return .{
            .allocator = allocator,
            .task_completions = std.StringHashMap(u64).init(allocator),
            .db_query_duration = std.StringHashMap(Histogram).init(allocator),
            .http_requests = std.StringHashMap(u64).init(allocator),
            .http_errors = std.StringHashMap(u64).init(allocator),
            .idp_token_verification_total = std.StringHashMap(u64).init(allocator),
            .idp_token_verification_duration = std.StringHashMap(Histogram).init(allocator),
            .idp_jwks_cache_access_total = std.StringHashMap(u64).init(allocator),
            .idp_adapter_call_total = std.StringHashMap(u64).init(allocator),
            .idp_adapter_call_duration = std.StringHashMap(Histogram).init(allocator),
            .idp_adapter_error_total = std.StringHashMap(u64).init(allocator),
            .idp_readiness_probe_total = std.StringHashMap(u64).init(allocator),
        };
    }

    pub fn deinit(self: *MetricsRegistry) void {
        freeKeys(u64, self.allocator, &self.task_completions);
        freeKeys(Histogram, self.allocator, &self.db_query_duration);
        freeKeys(u64, self.allocator, &self.http_requests);
        freeKeys(u64, self.allocator, &self.http_errors);
        freeKeys(u64, self.allocator, &self.idp_token_verification_total);
        freeKeys(Histogram, self.allocator, &self.idp_token_verification_duration);
        freeKeys(u64, self.allocator, &self.idp_jwks_cache_access_total);
        freeKeys(u64, self.allocator, &self.idp_adapter_call_total);
        freeKeys(Histogram, self.allocator, &self.idp_adapter_call_duration);
        freeKeys(u64, self.allocator, &self.idp_adapter_error_total);
        freeKeys(u64, self.allocator, &self.idp_readiness_probe_total);
    }

    pub fn incIdpTokenVerification(self: *MetricsRegistry, realm_id: []const u8, method: []const u8, outcome: []const u8) void {
        const key = std.fmt.allocPrint(self.allocator, "{s}|{s}|{s}", .{ realm_id, method, outcome }) catch return;
        defer self.allocator.free(key);
        const gop = self.idp_token_verification_total.getOrPut(key) catch return;
        if (!gop.found_existing) {
            const key_copy = self.allocator.dupe(u8, key) catch {
                _ = self.idp_token_verification_total.remove(key);
                return;
            };
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }

    pub fn observeIdpTokenVerificationDuration(self: *MetricsRegistry, realm_id: []const u8, method: []const u8, duration_seconds: f64) void {
        const key = std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ realm_id, method }) catch return;
        defer self.allocator.free(key);
        const gop = self.idp_token_verification_duration.getOrPut(key) catch return;
        if (!gop.found_existing) {
            const key_copy = self.allocator.dupe(u8, key) catch {
                _ = self.idp_token_verification_duration.remove(key);
                return;
            };
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = Histogram{};
        }
        gop.value_ptr.observe(duration_seconds);
    }

    pub fn incIdpJwksCacheAccess(self: *MetricsRegistry, realm_id: []const u8, outcome: []const u8) void {
        const key = std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ realm_id, outcome }) catch return;
        defer self.allocator.free(key);
        const gop = self.idp_jwks_cache_access_total.getOrPut(key) catch return;
        if (!gop.found_existing) {
            const key_copy = self.allocator.dupe(u8, key) catch {
                _ = self.idp_jwks_cache_access_total.remove(key);
                return;
            };
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }

    pub fn incIdpAdapterCall(self: *MetricsRegistry, realm_id: []const u8, method: []const u8, status_class: []const u8) void {
        const key = std.fmt.allocPrint(self.allocator, "{s}|{s}|{s}", .{ realm_id, method, status_class }) catch return;
        defer self.allocator.free(key);
        const gop = self.idp_adapter_call_total.getOrPut(key) catch return;
        if (!gop.found_existing) {
            const key_copy = self.allocator.dupe(u8, key) catch {
                _ = self.idp_adapter_call_total.remove(key);
                return;
            };
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }

    pub fn observeIdpAdapterCallDuration(self: *MetricsRegistry, realm_id: []const u8, method: []const u8, duration_seconds: f64) void {
        const key = std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ realm_id, method }) catch return;
        defer self.allocator.free(key);
        const gop = self.idp_adapter_call_duration.getOrPut(key) catch return;
        if (!gop.found_existing) {
            const key_copy = self.allocator.dupe(u8, key) catch {
                _ = self.idp_adapter_call_duration.remove(key);
                return;
            };
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = Histogram{};
        }
        gop.value_ptr.observe(duration_seconds);
    }

    pub fn incIdpAdapterError(self: *MetricsRegistry, realm_id: []const u8, method: []const u8, error_code: []const u8) void {
        const key = std.fmt.allocPrint(self.allocator, "{s}|{s}|{s}", .{ realm_id, method, error_code }) catch return;
        defer self.allocator.free(key);
        const gop = self.idp_adapter_error_total.getOrPut(key) catch return;
        if (!gop.found_existing) {
            const key_copy = self.allocator.dupe(u8, key) catch {
                _ = self.idp_adapter_error_total.remove(key);
                return;
            };
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }

    pub fn incIdpReadinessProbe(self: *MetricsRegistry, outcome: []const u8) void {
        const gop = self.idp_readiness_probe_total.getOrPut(outcome) catch return;
        if (!gop.found_existing) {
            const key_copy = self.allocator.dupe(u8, outcome) catch {
                _ = self.idp_readiness_probe_total.remove(outcome);
                return;
            };
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }

    pub fn observeIdpReadinessProbeDuration(self: *MetricsRegistry, duration_seconds: f64) void {
        self.idp_readiness_probe_duration.observe(duration_seconds);
    }

    pub fn observeEventAppendDurationSeconds(self: *MetricsRegistry, duration_seconds: f64) void {
        self.event_append_duration.observe(duration_seconds);
    }

    pub fn observeDbQueryDurationSeconds(self: *MetricsRegistry, query_type: QueryType, duration_seconds: f64) void {
        const key = query_type.asString();
        const gop = self.db_query_duration.getOrPut(key) catch return;
        if (!gop.found_existing) {
            const key_copy = self.allocator.dupe(u8, key) catch {
                _ = self.db_query_duration.remove(key);
                return;
            };
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = Histogram{};
        }
        gop.value_ptr.observe(duration_seconds);
    }

    pub fn incTaskCompletions(self: *MetricsRegistry, definition_id: []const u8) void {
        const label = normalizeDefinitionId(definition_id);

        const gop = self.task_completions.getOrPut(label) catch return;
        if (!gop.found_existing) {
            const key_copy = self.allocator.dupe(u8, label) catch {
                _ = self.task_completions.remove(label);
                return;
            };
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }

    pub fn incHttpRequest(self: *MetricsRegistry, method: []const u8, path: []const u8, status: u16) void {
        const key = std.fmt.allocPrint(self.allocator, "{s}|{s}|{d}", .{ method, path, status }) catch return;
        defer self.allocator.free(key);

        const gop = self.http_requests.getOrPut(key) catch return;
        if (!gop.found_existing) {
            const key_copy = self.allocator.dupe(u8, key) catch {
                _ = self.http_requests.remove(key);
                return;
            };
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }

    pub fn incHttpError5xx(self: *MetricsRegistry, path: []const u8) void {
        const gop = self.http_errors.getOrPut(path) catch return;
        if (!gop.found_existing) {
            const key_copy = self.allocator.dupe(u8, path) catch {
                _ = self.http_errors.remove(path);
                return;
            };
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }

    pub fn setActiveInstances(self: *MetricsRegistry, count: u64) void {
        self.active_instances_total = count;
        self.active_instances_stale = false;
    }

    pub fn markActiveInstancesStale(self: *MetricsRegistry) void {
        self.active_instances_stale = true;
    }

    pub fn collectPrometheusText(self: *MetricsRegistry, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);

        try out.appendSlice(allocator, "# HELP bpm_active_instances_total Current count of ACTIVE instances.\n");
        try out.appendSlice(allocator, "# TYPE bpm_active_instances_total gauge\n");
        try appendFmt(allocator, &out, "bpm_active_instances_total {d}\n", .{self.active_instances_total});

        try out.appendSlice(allocator, "# HELP bpm_task_completions_total Total task completions since startup.\n");
        try out.appendSlice(allocator, "# TYPE bpm_task_completions_total counter\n");
        {
            var it = self.task_completions.iterator();
            while (it.next()) |entry| {
                const escaped = try escapePromLabel(allocator, entry.key_ptr.*);
                defer allocator.free(escaped);
                try appendFmt(
                    allocator,
                    &out,
                    "bpm_task_completions_total{{definition_id=\"{s}\"}} {d}\n",
                    .{ escaped, entry.value_ptr.* },
                );
            }
        }

        try out.appendSlice(allocator, "# HELP bpm_event_append_duration_seconds Event append latency in seconds.\n");
        try out.appendSlice(allocator, "# TYPE bpm_event_append_duration_seconds histogram\n");
        try renderHistogram(allocator, &out, "bpm_event_append_duration_seconds", null, self.event_append_duration);

        try out.appendSlice(allocator, "# HELP bpm_db_query_duration_seconds DB query latency in seconds.\n");
        try out.appendSlice(allocator, "# TYPE bpm_db_query_duration_seconds histogram\n");
        {
            var it = self.db_query_duration.iterator();
            while (it.next()) |entry| {
                try renderHistogram(allocator, &out, "bpm_db_query_duration_seconds", entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        try out.appendSlice(allocator, "# HELP bpm_http_requests_total HTTP requests by method/path/status.\n");
        try out.appendSlice(allocator, "# TYPE bpm_http_requests_total counter\n");
        {
            var it = self.http_requests.iterator();
            while (it.next()) |entry| {
                var parts = std.mem.splitScalar(u8, entry.key_ptr.*, '|');
                const method = parts.next() orelse "";
                const path = parts.next() orelse "";
                const status = parts.next() orelse "0";

                const escaped_method = try escapePromLabel(allocator, method);
                defer allocator.free(escaped_method);
                const escaped_path = try escapePromLabel(allocator, path);
                defer allocator.free(escaped_path);

                try appendFmt(
                    allocator,
                    &out,
                    "bpm_http_requests_total{{method=\"{s}\",path=\"{s}\",status=\"{s}\"}} {d}\n",
                    .{ escaped_method, escaped_path, status, entry.value_ptr.* },
                );
            }
        }

        try out.appendSlice(allocator, "# HELP bpm_http_errors_total HTTP 5xx responses by path.\n");
        try out.appendSlice(allocator, "# TYPE bpm_http_errors_total counter\n");
        {
            var it = self.http_errors.iterator();
            while (it.next()) |entry| {
                const escaped_path = try escapePromLabel(allocator, entry.key_ptr.*);
                defer allocator.free(escaped_path);
                try appendFmt(
                    allocator,
                    &out,
                    "bpm_http_errors_total{{path=\"{s}\"}} {d}\n",
                    .{ escaped_path, entry.value_ptr.* },
                );
            }
        }

        try out.appendSlice(allocator, "# HELP idp_token_verification_total Identity-provider token verification attempts by outcome.\n");
        try out.appendSlice(allocator, "# TYPE idp_token_verification_total counter\n");
        {
            var it = self.idp_token_verification_total.iterator();
            while (it.next()) |entry| {
                var parts = std.mem.splitScalar(u8, entry.key_ptr.*, '|');
                const realm_id = parts.next() orelse "";
                const method = parts.next() orelse "";
                const outcome = parts.next() orelse "unknown";
                try appendFmt(
                    allocator,
                    &out,
                    "idp_token_verification_total{{realm_id=\"{s}\",method=\"{s}\",outcome=\"{s}\"}} {d}\n",
                    .{ realm_id, method, outcome, entry.value_ptr.* },
                );
            }
        }

        try out.appendSlice(allocator, "# HELP idp_token_verification_duration_seconds Identity-provider token verification latency in seconds.\n");
        try out.appendSlice(allocator, "# TYPE idp_token_verification_duration_seconds histogram\n");
        {
            var it = self.idp_token_verification_duration.iterator();
            while (it.next()) |entry| {
                var parts = std.mem.splitScalar(u8, entry.key_ptr.*, '|');
                const realm_id = parts.next() orelse "";
                const method = parts.next() orelse "";
                const label = std.fmt.allocPrint(allocator, "realm_id=\"{s}\",method=\"{s}\"", .{ realm_id, method }) catch return error.OutOfMemory;
                defer allocator.free(label);
                try renderHistogram(allocator, &out, "idp_token_verification_duration_seconds", label, entry.value_ptr.*);
            }
        }

        try out.appendSlice(allocator, "# HELP idp_jwks_cache_access_total JWKS cache accesses by realm and outcome.\n");
        try out.appendSlice(allocator, "# TYPE idp_jwks_cache_access_total counter\n");
        {
            var it = self.idp_jwks_cache_access_total.iterator();
            while (it.next()) |entry| {
                var parts = std.mem.splitScalar(u8, entry.key_ptr.*, '|');
                const realm_id = parts.next() orelse "";
                const outcome = parts.next() orelse "unknown";
                try appendFmt(
                    allocator,
                    &out,
                    "idp_jwks_cache_access_total{{realm_id=\"{s}\",outcome=\"{s}\"}} {d}\n",
                    .{ realm_id, outcome, entry.value_ptr.* },
                );
            }
        }

        try out.appendSlice(allocator, "# HELP idp_adapter_call_total Identity-provider adapter calls by method and status class.\n");
        try out.appendSlice(allocator, "# TYPE idp_adapter_call_total counter\n");
        {
            var it = self.idp_adapter_call_total.iterator();
            while (it.next()) |entry| {
                var parts = std.mem.splitScalar(u8, entry.key_ptr.*, '|');
                const realm_id = parts.next() orelse "";
                const method = parts.next() orelse "";
                const status_class = parts.next() orelse "unknown";
                try appendFmt(
                    allocator,
                    &out,
                    "idp_adapter_call_total{{realm_id=\"{s}\",method=\"{s}\",status_class=\"{s}\"}} {d}\n",
                    .{ realm_id, method, status_class, entry.value_ptr.* },
                );
            }
        }

        try out.appendSlice(allocator, "# HELP idp_adapter_call_duration_seconds Identity-provider adapter call latency in seconds.\n");
        try out.appendSlice(allocator, "# TYPE idp_adapter_call_duration_seconds histogram\n");
        {
            var it = self.idp_adapter_call_duration.iterator();
            while (it.next()) |entry| {
                var parts = std.mem.splitScalar(u8, entry.key_ptr.*, '|');
                const realm_id = parts.next() orelse "";
                const method = parts.next() orelse "";
                const label = std.fmt.allocPrint(allocator, "realm_id=\"{s}\",method=\"{s}\"", .{ realm_id, method }) catch return error.OutOfMemory;
                defer allocator.free(label);
                try renderHistogram(allocator, &out, "idp_adapter_call_duration_seconds", label, entry.value_ptr.*);
            }
        }

        try out.appendSlice(allocator, "# HELP idp_adapter_error_total Identity-provider adapter errors by method and code.\n");
        try out.appendSlice(allocator, "# TYPE idp_adapter_error_total counter\n");
        {
            var it = self.idp_adapter_error_total.iterator();
            while (it.next()) |entry| {
                var parts = std.mem.splitScalar(u8, entry.key_ptr.*, '|');
                const realm_id = parts.next() orelse "";
                const method = parts.next() orelse "";
                const error_code = parts.next() orelse "unknown";
                try appendFmt(
                    allocator,
                    &out,
                    "idp_adapter_error_total{{realm_id=\"{s}\",method=\"{s}\",error_code=\"{s}\"}} {d}\n",
                    .{ realm_id, method, error_code, entry.value_ptr.* },
                );
            }
        }

        try out.appendSlice(allocator, "# HELP idp_readiness_probe_total Identity-provider readiness probe outcomes.\n");
        try out.appendSlice(allocator, "# TYPE idp_readiness_probe_total counter\n");
        {
            var it = self.idp_readiness_probe_total.iterator();
            while (it.next()) |entry| {
                try appendFmt(
                    allocator,
                    &out,
                    "idp_readiness_probe_total{{outcome=\"{s}\"}} {d}\n",
                    .{ entry.key_ptr.*, entry.value_ptr.* },
                );
            }
        }

        try out.appendSlice(allocator, "# HELP idp_readiness_probe_duration_seconds Identity-provider readiness probe latency in seconds.\n");
        try out.appendSlice(allocator, "# TYPE idp_readiness_probe_duration_seconds histogram\n");
        try renderHistogram(allocator, &out, "idp_readiness_probe_duration_seconds", null, self.idp_readiness_probe_duration);

        return out.toOwnedSlice(allocator);
    }
};

var global_registry: ?*MetricsRegistry = null;

pub fn installGlobal(registry: *MetricsRegistry) void {
    global_registry = registry;
}

pub fn clearGlobal() void {
    global_registry = null;
}

pub fn recordEventAppendDurationSeconds(duration_seconds: f64) void {
    withGlobal(struct {
        fn call(registry: *MetricsRegistry, dur: f64) void {
            registry.observeEventAppendDurationSeconds(dur);
        }
    }.call, duration_seconds);
}

pub fn recordDbQueryDurationSeconds(query_type: QueryType, duration_seconds: f64) void {
    withGlobal(struct {
        fn call(registry: *MetricsRegistry, args: struct { QueryType, f64 }) void {
            registry.observeDbQueryDurationSeconds(args[0], args[1]);
        }
    }.call, .{ query_type, duration_seconds });
}

pub fn recordTaskCompletion(definition_id: []const u8) void {
    withGlobal(struct {
        fn call(registry: *MetricsRegistry, value: []const u8) void {
            registry.incTaskCompletions(value);
        }
    }.call, definition_id);
}

pub fn recordHttpRequest(method: []const u8, path: []const u8, status: u16) void {
    withGlobal(struct {
        fn call(registry: *MetricsRegistry, args: struct { []const u8, []const u8, u16 }) void {
            registry.incHttpRequest(args[0], args[1], args[2]);
        }
    }.call, .{ method, path, status });
}

pub fn recordHttpError5xx(path: []const u8) void {
    withGlobal(struct {
        fn call(registry: *MetricsRegistry, value: []const u8) void {
            registry.incHttpError5xx(value);
        }
    }.call, path);
}

pub fn recordIdpTokenVerification(realm_id: []const u8, method: []const u8, success: bool, duration_seconds: f64) void {
    const outcome = if (success) "success" else "failure";
    withGlobal(struct {
        fn call(registry: *MetricsRegistry, args: struct { []const u8, []const u8, []const u8, f64 }) void {
            registry.incIdpTokenVerification(args[0], args[1], args[2]);
            registry.observeIdpTokenVerificationDuration(args[0], args[1], args[3]);
        }
    }.call, .{ realm_id, method, outcome, duration_seconds });
}

pub fn recordIdpJwksCacheAccess(realm_id: []const u8, hit: bool) void {
    const outcome = if (hit) "hit" else "miss";
    withGlobal(struct {
        fn call(registry: *MetricsRegistry, args: struct { []const u8, []const u8 }) void {
            registry.incIdpJwksCacheAccess(args[0], args[1]);
        }
    }.call, .{ realm_id, outcome });
}

pub fn recordIdpAdapterCall(realm_id: []const u8, method: []const u8, status_class: []const u8, duration_seconds: f64) void {
    withGlobal(struct {
        fn call(registry: *MetricsRegistry, args: struct { []const u8, []const u8, []const u8, f64 }) void {
            registry.incIdpAdapterCall(args[0], args[1], args[2]);
            registry.observeIdpAdapterCallDuration(args[0], args[1], args[3]);
        }
    }.call, .{ realm_id, method, status_class, duration_seconds });
}

pub fn recordIdpAdapterError(realm_id: []const u8, method: []const u8, error_code: []const u8) void {
    withGlobal(struct {
        fn call(registry: *MetricsRegistry, args: struct { []const u8, []const u8, []const u8 }) void {
            registry.incIdpAdapterError(args[0], args[1], args[2]);
        }
    }.call, .{ realm_id, method, error_code });
}

pub fn recordIdpReadinessProbe(outcome: []const u8, duration_seconds: f64) void {
    withGlobal(struct {
        fn call(registry: *MetricsRegistry, args: struct { []const u8, f64 }) void {
            registry.incIdpReadinessProbe(args[0]);
            registry.observeIdpReadinessProbeDuration(args[1]);
        }
    }.call, .{ outcome, duration_seconds });
}

pub fn setActiveInstances(count: u64) void {
    withGlobal(struct {
        fn call(registry: *MetricsRegistry, value: u64) void {
            registry.setActiveInstances(value);
        }
    }.call, count);
}

pub fn markActiveInstancesStale() void {
    withGlobal(struct {
        fn call(registry: *MetricsRegistry, _: void) void {
            registry.markActiveInstancesStale();
        }
    }.call, {});
}

pub fn collectGlobalPrometheusText(allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    const reg = global_registry;

    if (reg) |registry| {
        return registry.collectPrometheusText(allocator);
    }

    var transient = MetricsRegistry.init(allocator);
    defer transient.deinit();
    return transient.collectPrometheusText(allocator);
}

pub fn classifyQueryType(sql: []const u8) QueryType {
    const trimmed = std.mem.trimStart(u8, sql, " \t\r\n");
    if (trimmed.len == 0) return .other;

    const token = firstToken(trimmed);
    if (std.ascii.eqlIgnoreCase(token, "SELECT")) return .select;
    if (std.ascii.eqlIgnoreCase(token, "INSERT")) return .insert;
    if (std.ascii.eqlIgnoreCase(token, "UPDATE")) return .update;
    if (std.ascii.eqlIgnoreCase(token, "DELETE")) return .delete;
    if (std.ascii.eqlIgnoreCase(token, "BEGIN")) return .begin;
    if (std.ascii.eqlIgnoreCase(token, "COMMIT")) return .commit;
    if (std.ascii.eqlIgnoreCase(token, "ROLLBACK")) return .rollback;
    if (std.ascii.eqlIgnoreCase(token, "CREATE") or
        std.ascii.eqlIgnoreCase(token, "ALTER") or
        std.ascii.eqlIgnoreCase(token, "DROP"))
    {
        return .migration;
    }

    return .other;
}

fn withGlobal(comptime Func: anytype, arg: anytype) void {
    const reg = global_registry;

    if (reg) |registry| {
        Func(registry, arg);
    }
}

fn firstToken(input: []const u8) []const u8 {
    var idx: usize = 0;
    while (idx < input.len) : (idx += 1) {
        const c = input[idx];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
    }
    return input[0..idx];
}

fn normalizeDefinitionId(definition_id: []const u8) []const u8 {
    if (definition_id.len == 0) return "_unknown";
    if (definition_id.len > 128) return definition_id[0..128];
    return definition_id;
}

fn appendFmt(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    const rendered = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(rendered);
    try out.appendSlice(allocator, rendered);
}

fn renderHistogram(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    metric_name: []const u8,
    query_type: ?[]const u8,
    hist: Histogram,
) error{OutOfMemory}!void {
    const has_eq = if (query_type) |qt| (std.mem.indexOfScalar(u8, qt, '=') != null) else false;
    var cumulative: u64 = 0;
    for (Histogram.finite_buckets, 0..) |le, idx| {
        cumulative += hist.bucket_counts[idx];
        if (query_type) |qt| {
            if (has_eq) {
                try appendFmt(
                    allocator,
                    out,
                    "{s}_bucket{{{s},le=\"{d:.4}\"}} {d}\n",
                    .{ metric_name, qt, le, cumulative },
                );
            } else {
                try appendFmt(
                    allocator,
                    out,
                    "{s}_bucket{{query_type=\"{s}\",le=\"{d:.4}\"}} {d}\n",
                    .{ metric_name, qt, le, cumulative },
                );
            }
        } else {
            try appendFmt(
                allocator,
                out,
                "{s}_bucket{{le=\"{d:.4}\"}} {d}\n",
                .{ metric_name, le, cumulative },
            );
        }
    }

    if (query_type) |qt| {
        if (has_eq) {
            try appendFmt(allocator, out, "{s}_bucket{{{s},le=\"+Inf\"}} {d}\n", .{ metric_name, qt, hist.count });
            try appendFmt(allocator, out, "{s}_sum{{{s}}} {d:.6}\n", .{ metric_name, qt, hist.sum });
            try appendFmt(allocator, out, "{s}_count{{{s}}} {d}\n", .{ metric_name, qt, hist.count });
        } else {
            try appendFmt(allocator, out, "{s}_bucket{{query_type=\"{s}\",le=\"+Inf\"}} {d}\n", .{ metric_name, qt, hist.count });
            try appendFmt(allocator, out, "{s}_sum{{query_type=\"{s}\"}} {d:.6}\n", .{ metric_name, qt, hist.sum });
            try appendFmt(allocator, out, "{s}_count{{query_type=\"{s}\"}} {d}\n", .{ metric_name, qt, hist.count });
        }
    } else {
        try appendFmt(allocator, out, "{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ metric_name, hist.count });
        try appendFmt(allocator, out, "{s}_sum {d:.6}\n", .{ metric_name, hist.sum });
        try appendFmt(allocator, out, "{s}_count {d}\n", .{ metric_name, hist.count });
    }
}

fn escapePromLabel(allocator: std.mem.Allocator, value: []const u8) error{OutOfMemory}![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    for (value) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            else => try out.append(allocator, c),
        }
    }

    return out.toOwnedSlice(allocator);
}

fn freeKeys(comptime V: type, allocator: std.mem.Allocator, map: *std.StringHashMap(V)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    map.deinit();
}

test "TC-OBS-02-01: collectPrometheusText emits required metric families" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    registry.setActiveInstances(3);
    registry.incTaskCompletions("def-a");
    registry.observeEventAppendDurationSeconds(0.014);
    registry.observeDbQueryDurationSeconds(.select, 0.002);
    registry.incHttpRequest("GET", "/tasks", 200);
    registry.incHttpError5xx("/tasks/:id");

    const body = try registry.collectPrometheusText(std.testing.allocator);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_active_instances_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_task_completions_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_event_append_duration_seconds_bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_db_query_duration_seconds_bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_http_requests_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_http_errors_total") != null);
}

test "TC-OBS-02-02: classifyQueryType detects common verbs" {
    try std.testing.expectEqual(QueryType.select, classifyQueryType("SELECT * FROM tasks"));
    try std.testing.expectEqual(QueryType.insert, classifyQueryType("insert into tasks values ($1)"));
    try std.testing.expectEqual(QueryType.begin, classifyQueryType("BEGIN"));
    try std.testing.expectEqual(QueryType.migration, classifyQueryType("CREATE TABLE x(y int)"));
}

test "TC-OBS-02-04: collectPrometheusText emits required labels and histogram contract" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    registry.setActiveInstances(7);
    registry.incTaskCompletions("def-obs-02");
    registry.observeEventAppendDurationSeconds(0.014);
    registry.observeDbQueryDurationSeconds(.select, 0.002);
    registry.incHttpRequest("GET", "/metrics", 200);
    registry.incHttpError5xx("/metrics");

    const body = try registry.collectPrometheusText(std.testing.allocator);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_task_completions_total{definition_id=\"def-obs-02\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_db_query_duration_seconds_bucket{query_type=\"select\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_db_query_duration_seconds_bucket{query_type=\"select\",le=\"+Inf\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_db_query_duration_seconds_sum{query_type=\"select\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_db_query_duration_seconds_count{query_type=\"select\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_event_append_duration_seconds_bucket{le=\"+Inf\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_event_append_duration_seconds_sum") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_event_append_duration_seconds_count") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_http_requests_total{method=\"GET\",path=\"/metrics\",status=\"200\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_http_errors_total{path=\"/metrics\"}") != null);
}

test "TC-OBS-02-05: scrape rendering is read-only across repeated collections" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    registry.incHttpRequest("GET", "/health/live", 200);

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const body = try registry.collectPrometheusText(std.testing.allocator);
        std.testing.allocator.free(body);
    }

    const final_body = try registry.collectPrometheusText(std.testing.allocator);
    defer std.testing.allocator.free(final_body);

    try std.testing.expect(std.mem.indexOf(u8, final_body, "bpm_http_requests_total{method=\"GET\",path=\"/health/live\",status=\"200\"} 1") != null);
}

test "TC-OBS-02-06: stale active instance gauge retains last in-memory value" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    registry.setActiveInstances(13);
    registry.markActiveInstancesStale();

    const body = try registry.collectPrometheusText(std.testing.allocator);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "bpm_active_instances_total 13") != null);
}

test "OIDC-26 metrics families are rendered" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    registry.incIdpTokenVerification("tenant-a", "bearer", "success");
    registry.observeIdpTokenVerificationDuration("tenant-a", "bearer", 0.001);
    registry.incIdpJwksCacheAccess("tenant-a", "hit");
    registry.incIdpAdapterCall("tenant-a", "provisionRealm", "2xx");
    registry.observeIdpAdapterCallDuration("tenant-a", "provisionRealm", 0.02);
    registry.incIdpAdapterError("tenant-a", "provisionRealm", "UpstreamTimeout");
    registry.incIdpReadinessProbe("ok");
    registry.observeIdpReadinessProbeDuration(0.005);

    const body = try registry.collectPrometheusText(std.testing.allocator);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "idp_token_verification_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "idp_jwks_cache_access_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "idp_adapter_call_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "idp_adapter_error_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "idp_readiness_probe_total") != null);
}
