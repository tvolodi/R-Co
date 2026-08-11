//! Pure platform DDL validator — DDL-01
//!
//! Design artefact: src/design/ddl-01-validate-platform-ddl.md
//! Depends on: DDL-05 (src/platform/ddl_namespace.zig), composed as one of
//! three checks this module aggregates.
//!
//! `validatePlatformDDL` decides, for an entire migration file's parsed
//! statement list, whether every statement is safe to run against a live
//! tenant schema without holding an ACCESS EXCLUSIVE lock for a duration
//! proportional to table size, and whether every object name in the file
//! respects the `plat_` reserved-namespace rule (DDL-05, composed here, not
//! re-derived). This is the pre-flight gate MIG-01's fanout (`runFanout` in
//! src/platform/migration_fanout.zig) must pass through before opening a
//! connection to any tenant schema.
//!
//! Three independent checks run per statement, in a fixed tie-break order
//! (lock-class, then index-concurrency, then namespace — see the design
//! doc's "Within-statement check order" section), aggregated into ONE
//! verdict naming the FIRST failing statement in `order` (DDL-01 AC5):
//!   - Lock-class check (new): reject drop_column, cluster, vacuum_full,
//!     reindex_non_concurrent, alter_column_set_data_type.
//!   - Concurrent-index check (new): reject create_index_non_concurrent,
//!     drop_index_non_concurrent.
//!   - Namespace check (composed from DDL-05): delegate to
//!     ddl_namespace.checkNamespace for every statement.
//!
//! Pure: no allocator, no database handle, no connection, no clock, no
//! environment variable (DDL-01 AC4) — matching ddl_namespace.zig's own
//! purity contract exactly. Every outcome, including all rejection cases, is
//! a normal return value (ValidationVerdict), never a thrown error: this
//! module raises no Zig error{...} set.
//!
//! Must NOT depend on: src/db/pool.zig, src/db/provisioning.zig,
//! src/db/migrations.zig, src/platform/migration_fanout.zig, std.time, or
//! any clock — see the design doc's Dependencies section.
const std = @import("std");
const ddl_namespace = @import("ddl_namespace.zig");

/// Statement classification the lock-class / index-concurrency checks switch
/// on. Distinct from ddl_namespace.StatementKind (create/rename_to/alter),
/// which is about *namespace* ownership, not *lock* behavior.
pub const StatementClass = enum {
    drop_column,
    cluster,
    vacuum_full,
    reindex_concurrent,
    reindex_non_concurrent,
    alter_column_set_data_type,
    create_index_concurrent,
    create_index_non_concurrent,
    drop_index_concurrent,
    drop_index_non_concurrent,
    other,
};

/// The full statement descriptor validatePlatformDDL operates over. A
/// superset of ddl_namespace.StatementDescriptor's shape (kind, object_name,
/// previous_object_name) plus the fields the lock-class / index checks need.
pub const StatementDescriptor = struct {
    /// Namespace-check shape, reused verbatim so checkNamespace can be
    /// called with zero field-by-field translation.
    kind: ddl_namespace.StatementKind,
    object_name: []const u8,
    previous_object_name: ?[]const u8 = null,

    /// Lock-class / index-concurrency shape, read only by this module's own
    /// checks, never by ddl_namespace.checkNamespace.
    class: StatementClass,

    /// 1-based position of this statement within its file's statement list —
    /// AC5's "first failure in statement order" needs a stable order key.
    /// Set by the (out-of-scope) parser.
    order: u32,

    /// Raw statement text, exactly as written, for the failure detail.
    text: []const u8,
};

pub const FileSet = struct {
    /// Statements across the whole file (or file set) being validated, in
    /// declaration order. This module does not itself sort by `order` — the
    /// caller is expected to supply the slice already in file order.
    statements: []const StatementDescriptor,
    actor: ddl_namespace.Actor,
};

pub const UnboundedExclusiveLockDetail = struct {
    statement_order: u32,
    statement_text: []const u8,
    class: StatementClass,
};

pub const NonConcurrentIndexBuildDetail = struct {
    statement_order: u32,
    statement_text: []const u8,
};

/// Re-exports of ddl_namespace's detail shapes plus the failing statement's
/// order/text, since ddl_namespace.NamespaceVerdict alone carries only
/// object_name.
pub const ReservedNamespaceDetail = struct {
    statement_order: u32,
    statement_text: []const u8,
    object_name: []const u8,
};

pub const UnreservedPlatformObjectDetail = struct {
    statement_order: u32,
    statement_text: []const u8,
    object_name: []const u8,
};

pub const ValidationVerdict = union(enum) {
    accept,
    unbounded_exclusive_lock: UnboundedExclusiveLockDetail,
    non_concurrent_index_build: NonConcurrentIndexBuildDetail,
    reserved_namespace: ReservedNamespaceDetail,
    unreserved_platform_object: UnreservedPlatformObjectDetail,
};

/// Lock-class check: is this statement's class one that holds ACCESS
/// EXCLUSIVE for a duration proportional to table size?
fn isUnboundedExclusiveLockClass(class: StatementClass) bool {
    return switch (class) {
        .drop_column,
        .cluster,
        .vacuum_full,
        .reindex_non_concurrent,
        .alter_column_set_data_type,
        => true,
        else => false,
    };
}

/// Index-concurrency check: is this statement a CREATE/DROP INDEX written
/// without CONCURRENTLY?
fn isNonConcurrentIndexClass(class: StatementClass) bool {
    return switch (class) {
        .create_index_non_concurrent, .drop_index_non_concurrent => true,
        else => false,
    };
}

/// Validates every statement in `file_set.statements`, in `order`, against
/// three checks (lock-class, index-concurrency, namespace) and returns the
/// FIRST failing verdict in statement order (AC5), or .accept if every
/// statement passes every check. Pure: no allocator, no I/O, no clock, no
/// env var — DDL-01's stated purity constraint, and AC4's testable
/// consequence of it.
///
/// Within a single statement, if more than one check would fail
/// simultaneously, the fixed tie-break order is lock-class, then
/// index-concurrency, then namespace (see the design doc's "Within-statement
/// check order" section) — this makes the verdict deterministic (AC4)
/// regardless of which checks a given statement happens to trip.
///
/// The caller is expected to supply `file_set.statements` already sorted by
/// `order`; this function does not itself sort, but iterates in the order
/// the slice is given and reports the first (in that iteration order)
/// non-accept verdict. Callers that cannot guarantee pre-sorted input should
/// sort by `order` before calling.
pub fn validatePlatformDDL(file_set: FileSet) ValidationVerdict {
    for (file_set.statements) |stmt| {
        if (isUnboundedExclusiveLockClass(stmt.class)) {
            return .{ .unbounded_exclusive_lock = .{
                .statement_order = stmt.order,
                .statement_text = stmt.text,
                .class = stmt.class,
            } };
        }

        if (isNonConcurrentIndexClass(stmt.class)) {
            return .{ .non_concurrent_index_build = .{
                .statement_order = stmt.order,
                .statement_text = stmt.text,
            } };
        }

        const ns_verdict = ddl_namespace.checkNamespace(file_set.actor, .{
            .kind = stmt.kind,
            .object_name = stmt.object_name,
            .previous_object_name = stmt.previous_object_name,
        });
        switch (ns_verdict) {
            .accept => {},
            .reserved_namespace => |detail| return .{ .reserved_namespace = .{
                .statement_order = stmt.order,
                .statement_text = stmt.text,
                .object_name = detail.object_name,
            } },
            .unreserved_platform_object => |detail| return .{ .unreserved_platform_object = .{
                .statement_order = stmt.order,
                .statement_text = stmt.text,
                .object_name = detail.object_name,
            } },
        }
    }

    return .accept;
}

// ---------------------------------------------------------------------------
// Unit tests — DDL-01 acceptance criteria
// ---------------------------------------------------------------------------

const testing = std.testing;

// DDL-01 AC1: GIVEN a file set containing `ALTER TABLE events DROP COLUMN
// legacy_flag`, WHEN the migration plan runs, THEN ValidatePlatformDDL
// returns UnboundedExclusiveLock naming that statement.
test "TC-DDL-01-AC1: DROP COLUMN statement is refused as UnboundedExclusiveLock" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .alter,
            .object_name = "events",
            .class = .drop_column,
            .order = 1,
            .text = "ALTER TABLE events DROP COLUMN legacy_flag",
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .platform });
    switch (verdict) {
        .unbounded_exclusive_lock => |detail| {
            try testing.expectEqual(@as(u32, 1), detail.statement_order);
            try testing.expectEqualStrings("ALTER TABLE events DROP COLUMN legacy_flag", detail.statement_text);
            try testing.expectEqual(StatementClass.drop_column, detail.class);
        },
        else => return error.TestExpectedUnboundedExclusiveLock,
    }
}

// DDL-01 AC2: GIVEN a file set containing `CREATE INDEX idx_events_actor ON
// events (actor_id)` without CONCURRENTLY, WHEN validated, THEN
// NonConcurrentIndexBuild is returned.
test "TC-DDL-01-AC2: CREATE INDEX without CONCURRENTLY is refused as NonConcurrentIndexBuild" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .create,
            .object_name = "idx_events_actor",
            .class = .create_index_non_concurrent,
            .order = 1,
            .text = "CREATE INDEX idx_events_actor ON events (actor_id)",
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .platform });
    switch (verdict) {
        .non_concurrent_index_build => |detail| {
            try testing.expectEqual(@as(u32, 1), detail.statement_order);
            try testing.expectEqualStrings("CREATE INDEX idx_events_actor ON events (actor_id)", detail.statement_text);
        },
        else => return error.TestExpectedNonConcurrentIndexBuild,
    }
}

// DDL-01 AC3: GIVEN a file set containing `ALTER TABLE events ALTER COLUMN
// payload SET DATA TYPE JSONB`, WHEN validated, THEN UnboundedExclusiveLock
// is returned.
test "TC-DDL-01-AC3: ALTER COLUMN SET DATA TYPE is refused as UnboundedExclusiveLock" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .alter,
            .object_name = "events",
            .class = .alter_column_set_data_type,
            .order = 1,
            .text = "ALTER TABLE events ALTER COLUMN payload SET DATA TYPE JSONB",
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .platform });
    switch (verdict) {
        .unbounded_exclusive_lock => |detail| {
            try testing.expectEqual(StatementClass.alter_column_set_data_type, detail.class);
        },
        else => return error.TestExpectedUnboundedExclusiveLock,
    }
}

// DDL-01 AC4: GIVEN one descriptor list, WHEN ValidatePlatformDDL is called
// from a unit test with no database reachable and no BPM_DB_URL set, THEN
// the call succeeds and returns the same verdict as any other call — proven
// by this being a plain unit test with no DB setup at all, and by calling
// twice with identical input and asserting identical output (determinism).
test "TC-DDL-01-AC4: validatePlatformDDL is deterministic and requires no database" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .create,
            .object_name = "orders",
            .class = .other,
            .order = 1,
            .text = "CREATE TABLE orders (id uuid PRIMARY KEY)",
        },
    };
    const file_set = FileSet{ .statements = &stmts, .actor = .tenant };
    const verdict1 = validatePlatformDDL(file_set);
    const verdict2 = validatePlatformDDL(file_set);
    try testing.expectEqual(ValidationVerdict.accept, verdict1);
    try testing.expectEqual(ValidationVerdict.accept, verdict2);
}

// DDL-01: first failure in statement order is reported — a file set with
// a passing statement first and a failing statement second must report the
// SECOND statement (order=2), not silently accept because the first passed.
// Named "order" (not "AC5") to avoid colliding with the genuine AC5
// (docs/requirements.yaml's 200-statement/100ms performance criterion,
// tested separately below as TC-DDL-01-AC5) — this test instead supports
// AC1/AC2/AC3's "naming that statement" wording for a multi-statement file
// set; see tests/specs/DDL-01.md's naming-disambiguation note.
test "TC-DDL-01-order: first failing statement in order is reported, earlier accepts are skipped" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .create,
            .object_name = "orders",
            .class = .other,
            .order = 1,
            .text = "CREATE TABLE orders (id uuid PRIMARY KEY)",
        },
        .{
            .kind = .alter,
            .object_name = "orders",
            .class = .drop_column,
            .order = 2,
            .text = "ALTER TABLE orders DROP COLUMN stale",
        },
        .{
            .kind = .create,
            .object_name = "idx_orders_bad",
            .class = .create_index_non_concurrent,
            .order = 3,
            .text = "CREATE INDEX idx_orders_bad ON orders (id)",
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    switch (verdict) {
        .unbounded_exclusive_lock => |detail| {
            try testing.expectEqual(@as(u32, 2), detail.statement_order);
        },
        else => return error.TestExpectedUnboundedExclusiveLock,
    }
}

// DDL-01 ordering companion: no later statement is even inspected once an
// earlier one fails — verified here by having statement 1 fail the
// lock-class check and statement 2 carry an otherwise-detectable namespace
// violation; the verdict must name statement 1, proving statement 2 was
// never reached. See TC-DDL-01-order above for the naming-disambiguation
// note (this is "order-b", not "AC5b" — no collision with the AC5
// performance test below).
test "TC-DDL-01-order-b: a later statement's violation is never reported once an earlier one fails" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .alter,
            .object_name = "orders",
            .class = .vacuum_full,
            .order = 1,
            .text = "VACUUM FULL orders",
        },
        .{
            .kind = .create,
            .object_name = "plat_hijacked",
            .class = .other,
            .order = 2,
            .text = "CREATE TABLE plat_hijacked (id uuid PRIMARY KEY)",
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    switch (verdict) {
        .unbounded_exclusive_lock => |detail| {
            try testing.expectEqual(@as(u32, 1), detail.statement_order);
        },
        else => return error.TestExpectedUnboundedExclusiveLock,
    }
}

// Composition proof: the namespace check (DDL-05, composed via
// ddl_namespace.checkNamespace) fires through this module's own pipeline
// when no lock-class/index-concurrency violation precedes it.
test "TC-DDL-01-composition: tenant CREATE TABLE plat_outbox is refused as ReservedNamespace via composed checkNamespace" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .create,
            .object_name = "plat_outbox",
            .class = .other,
            .order = 1,
            .text = "CREATE TABLE plat_outbox (id uuid PRIMARY KEY)",
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    switch (verdict) {
        .reserved_namespace => |detail| {
            try testing.expectEqual(@as(u32, 1), detail.statement_order);
            try testing.expectEqualStrings("plat_outbox", detail.object_name);
        },
        else => return error.TestExpectedReservedNamespace,
    }
}

// Composition proof (platform side): a platform-authored CREATE without the
// plat_ prefix is refused as UnreservedPlatformObject via the composed check.
test "TC-DDL-01-composition-b: platform CREATE without plat_ prefix is refused as UnreservedPlatformObject" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .create,
            .object_name = "correlation_cursor",
            .class = .other,
            .order = 1,
            .text = "CREATE TABLE correlation_cursor (id uuid PRIMARY KEY)",
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .platform });
    switch (verdict) {
        .unreserved_platform_object => |detail| {
            try testing.expectEqualStrings("correlation_cursor", detail.object_name);
        },
        else => return error.TestExpectedUnreservedPlatformObject,
    }
}

/// Wall-clock nanosecond timer for TC-DDL-01-AC5's timing assertion only.
/// Zig 0.16 removed std.time.Timer / nanoTimestamp() from the public API
/// (see src/api/routes/instances.zig's currentMicrosecondTimestamp and
/// src/expr/benchmark.zig's getTimeNanos for the two other places this
/// codebase already reimplements the same platform primitives); this test
/// file needs its own copy purely to measure elapsed wall-clock time around
/// the call below. The module under test (validatePlatformDDL) itself takes
/// no clock dependency anywhere -- this timer lives ONLY in the test, never
/// in src/platform/ddl_validate.zig, so the module's own DDL-01 AC4 purity
/// contract ("no clock") is untouched.
fn testTimeNanos() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return unix_100ns * 100;
    } else {
        const posix = std.posix;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.MONOTONIC, &ts);
        return ts.sec * 1_000_000_000 + ts.nsec;
    }
}

// DDL-01 AC5: GIVEN a file set of 200 accepted statements, WHEN validated,
// THEN the verdict is returned in under 100 ms. Deterministic in outcome
// (all 200 statements are `other`-classed CREATE TABLE statements that
// unconditionally ACCEPT, so the verdict itself never varies), only the
// wall-clock budget is environment-dependent -- this is DDL-01's own stated
// acceptance criterion, not an NFR benchmark, so it belongs in this unit
// test file rather than tests/bench. A 100ms budget against a pure,
// allocation-free, O(n) loop over 200 elements has enormous headroom; this
// is not a tight timing assertion prone to environment flakiness.
test "TC-DDL-01-AC5: 200 accepted statements validate in under 100ms" {
    var stmts: [200]StatementDescriptor = undefined;
    for (&stmts, 0..) |*stmt, i| {
        stmt.* = .{
            .kind = .create,
            .object_name = "orders",
            .class = .other,
            .order = @intCast(i + 1),
            .text = "CREATE TABLE orders (id uuid PRIMARY KEY)",
        };
    }

    const start_ns = testTimeNanos();
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    const elapsed_ns = testTimeNanos() - start_ns;

    try testing.expectEqual(ValidationVerdict.accept, verdict);
    try testing.expect(elapsed_ns < 100 * std.time.ns_per_ms);
}

// Empty file set trivially accepts.
test "TC-DDL-01-empty: empty statement list is ACCEPT" {
    const stmts = [_]StatementDescriptor{};
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .platform });
    try testing.expectEqual(ValidationVerdict.accept, verdict);
}

// A statement using CONCURRENTLY for both index build and REINDEX is
// accepted (positive mirror of AC2's rejection cases) — proves the checks do
// not over-trigger on the safe/concurrent classes.
test "TC-DDL-01-positive: CONCURRENTLY index and reindex classes are ACCEPT" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .create,
            .object_name = "idx_events_actor",
            .class = .create_index_concurrent,
            .order = 1,
            .text = "CREATE INDEX CONCURRENTLY idx_events_actor ON events (actor_id)",
        },
        .{
            .kind = .alter,
            .object_name = "events",
            .class = .reindex_concurrent,
            .order = 2,
            .text = "REINDEX INDEX CONCURRENTLY idx_events_actor",
        },
        .{
            .kind = .alter,
            .object_name = "events",
            .class = .drop_index_concurrent,
            .order = 3,
            .text = "DROP INDEX CONCURRENTLY idx_events_actor",
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    try testing.expectEqual(ValidationVerdict.accept, verdict);
}
