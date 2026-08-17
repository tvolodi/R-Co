//! DDL-03 — Pure three-phase DDL generator for NOT NULL column additions.
//!
//! Design artefact: src/design/ddl-03-phased-ddl-generation.md
//! Authoritative process: docs/processes/system/platform-ddl-safety.md
//! (sys-platform-ddl-safety, PW-05).
//!
//! Given a ColumnAdditionSpec (column + NOT NULL constraint), generates:
//!   Phase 1 (expand):    ADD COLUMN NULL + ADD CONSTRAINT NOT VALID
//!   Phase 2 (backfill):  GeneratedBackfill UPDATE statement (consumed by DDL-04)
//!   Phase 3 (constrain): VALIDATE CONSTRAINT + SET NOT NULL
//!
//! Pure: no allocator, no DB handle, no clock, no environment read. All
//! returned strings are slices into constant string literals (or fmt-formatted
//! into caller-supplied buffers — but since we return fixed-template strings
//! we embed them as string literals built from spec fields at generation time).
//!
//! IMPORTANT: this file uses fixed-size stack buffers. The total length of any
//! single statement is bounded by MAX_STMT_LEN (2048 bytes). Migration authors
//! MUST NOT use table or column names that, combined, exceed that budget.
//!
//! Security: identifier safety (no whitespace, semicolons, or SQL meta-chars)
//! is enforced by validateSpec before any string is formatted. The generator
//! does not execute SQL; it produces text for the caller to execute.
const std = @import("std");
const backfill = @import("backfill.zig");

// Maximum single-statement string length (stack-allocated).
const MAX_STMT_LEN: usize = 2048;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Only NOT NULL is supported in this generator.
pub const ColumnConstraintKind = enum {
    not_null,
};

/// Describes the column being added.
pub const ColumnAdditionSpec = struct {
    migration_id: []const u8,
    table: []const u8,
    column: []const u8,
    column_type: []const u8,
    backfill_expr: []const u8,
    constraint: ColumnConstraintKind,
    order: u32,
};

/// Phase 1 (expand) statements.
pub const Phase1Statements = struct {
    set_lock_timeout: []const u8,
    set_statement_timeout: []const u8,
    add_column_null: []const u8,
    add_constraint_not_valid: []const u8,
};

/// Phase 3 (constrain) statements.
pub const Phase3Statements = struct {
    set_lock_timeout: []const u8,
    set_statement_timeout: []const u8,
    validate_constraint: []const u8,
    set_not_null: []const u8,
};

/// The three-phase output for one column addition.
pub const PhasedDDL = struct {
    migration_id: []const u8,
    table: []const u8,
    column: []const u8,
    constraint_name: []const u8,

    // Phase 1 and Phase 3 strings are stored in these fixed buffers.
    _p1_add_column_buf: [MAX_STMT_LEN]u8,
    _p1_add_constraint_buf: [MAX_STMT_LEN]u8,
    _p3_validate_buf: [MAX_STMT_LEN]u8,
    _p3_set_not_null_buf: [MAX_STMT_LEN]u8,
    _constraint_name_buf: [256]u8,
    _p2_sql_buf: [MAX_STMT_LEN]u8,

    phase1: Phase1Statements,
    phase2: backfill.GeneratedBackfill,
    phase3: Phase3Statements,
};

/// Reason a generation failed.
pub const FailureReason = enum {
    empty_backfill_expr,
    unsupported_constraint_type,
    unsafe_identifier,
    empty_column_type,
};

pub const PhaseGenerationFailed = struct {
    spec: ColumnAdditionSpec,
    reason: FailureReason,
};

/// The result of one generatePhases call (tagged union, no Zig error set).
pub const GenerationResult = union(enum) {
    accept: PhasedDDL,
    phase_generation_failed: PhaseGenerationFailed,
};

// ---------------------------------------------------------------------------
// validateSpec — exposed for pre-flight tests
// ---------------------------------------------------------------------------

/// Return the first FailureReason if the spec is unsafe, or null if safe.
pub fn validateSpec(spec: ColumnAdditionSpec) ?FailureReason {
    if (spec.backfill_expr.len == 0) return .empty_backfill_expr;
    if (spec.column_type.len == 0) return .empty_column_type;
    if (!isSafeIdentifier(spec.table)) return .unsafe_identifier;
    if (!isSafeIdentifier(spec.column)) return .unsafe_identifier;
    if (spec.constraint != .not_null) return .unsupported_constraint_type;
    return null;
}

/// Strict identifier check: only letters, digits, and underscores, non-empty,
/// starts with a letter or underscore.
fn isSafeIdentifier(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id, 0..) |c, i| {
        if (i == 0 and !(std.ascii.isAlphabetic(c) or c == '_')) return false;
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// generatePhases — the pure three-phase generator
// ---------------------------------------------------------------------------

/// Generate the three-phase DDL for one ColumnAdditionSpec. Pure: no
/// allocator, no DB handle, no clock, no env read.
pub fn generatePhases(spec: ColumnAdditionSpec) GenerationResult {
    if (validateSpec(spec)) |reason| {
        return .{ .phase_generation_failed = .{ .spec = spec, .reason = reason } };
    }

    var result: PhasedDDL = undefined;
    result.migration_id = spec.migration_id;
    result.table = spec.table;
    result.column = spec.column;

    // Constraint name: "<table>_<column>_nn"
    const cname_len = std.fmt.bufPrint(&result._constraint_name_buf, "{s}_{s}_nn", .{ spec.table, spec.column }) catch {
        return .{ .phase_generation_failed = .{ .spec = spec, .reason = .unsafe_identifier } };
    };
    result.constraint_name = result._constraint_name_buf[0..cname_len.len];

    // Phase 1: ADD COLUMN NULL + ADD CONSTRAINT NOT VALID
    const p1_col = std.fmt.bufPrint(&result._p1_add_column_buf, "ALTER TABLE {s} ADD COLUMN {s} {s} NULL", .{
        spec.table, spec.column, spec.column_type,
    }) catch {
        return .{ .phase_generation_failed = .{ .spec = spec, .reason = .unsafe_identifier } };
    };
    const p1_con = std.fmt.bufPrint(&result._p1_add_constraint_buf, "ALTER TABLE {s} ADD CONSTRAINT {s}_{s}_nn CHECK ({s} IS NOT NULL) NOT VALID", .{
        spec.table, spec.table, spec.column, spec.column,
    }) catch {
        return .{ .phase_generation_failed = .{ .spec = spec, .reason = .unsafe_identifier } };
    };

    result.phase1 = Phase1Statements{
        .set_lock_timeout = "SET LOCAL lock_timeout = '3s'",
        .set_statement_timeout = "SET LOCAL statement_timeout = '60s'",
        .add_column_null = result._p1_add_column_buf[0..p1_col.len],
        .add_constraint_not_valid = result._p1_add_constraint_buf[0..p1_con.len],
    };

    // Phase 2: GeneratedBackfill UPDATE (consumed by DDL-04)
    const p2_sql = std.fmt.bufPrint(&result._p2_sql_buf, "UPDATE {s} SET {s} = {s} WHERE {s} IS NULL AND ctid = ANY (ARRAY(SELECT ctid FROM {s} WHERE {s} IS NULL LIMIT $1))", .{
        spec.table, spec.column, spec.backfill_expr, spec.column, spec.table, spec.column,
    }) catch {
        return .{ .phase_generation_failed = .{ .spec = spec, .reason = .unsafe_identifier } };
    };

    result.phase2 = backfill.GeneratedBackfill{
        .migration_id = spec.migration_id,
        .tenant_schema = "",
        .table = spec.table,
        .column = spec.column,
        .sql = result._p2_sql_buf[0..p2_sql.len],
        .order = spec.order,
    };

    // Phase 3: VALIDATE CONSTRAINT + SET NOT NULL
    const p3_val = std.fmt.bufPrint(&result._p3_validate_buf, "ALTER TABLE {s} VALIDATE CONSTRAINT {s}_{s}_nn", .{
        spec.table, spec.table, spec.column,
    }) catch {
        return .{ .phase_generation_failed = .{ .spec = spec, .reason = .unsafe_identifier } };
    };
    const p3_nn = std.fmt.bufPrint(&result._p3_set_not_null_buf, "ALTER TABLE {s} ALTER COLUMN {s} SET NOT NULL", .{
        spec.table, spec.column,
    }) catch {
        return .{ .phase_generation_failed = .{ .spec = spec, .reason = .unsafe_identifier } };
    };

    result.phase3 = Phase3Statements{
        .set_lock_timeout = "SET LOCAL lock_timeout = '3s'",
        .set_statement_timeout = "SET LOCAL statement_timeout = '60s'",
        .validate_constraint = result._p3_validate_buf[0..p3_val.len],
        .set_not_null = result._p3_set_not_null_buf[0..p3_nn.len],
    };

    return .{ .accept = result };
}

// ---------------------------------------------------------------------------
// Tests — pure (no DB)
// ---------------------------------------------------------------------------

test "ddl03: TC-DDL-03-AC1 — generates three phases with consistent constraint name" {
    const spec = ColumnAdditionSpec{
        .migration_id = "1168_test",
        .table = "tenant_data",
        .column = "updated_by",
        .column_type = "TEXT",
        .backfill_expr = "'system'",
        .constraint = .not_null,
        .order = 1,
    };
    const result = generatePhases(spec);
    switch (result) {
        .phase_generation_failed => |f| {
            std.debug.print("Failed: {any}\n", .{f.reason});
            return error.UnexpectedFailure;
        },
        .accept => |phased| {
            // Same constraint name in phase1 and phase3.
            try std.testing.expect(std.mem.containsAtLeast(u8, phased.phase1.add_constraint_not_valid, 1, "tenant_data_updated_by_nn"));
            try std.testing.expect(std.mem.containsAtLeast(u8, phased.phase3.validate_constraint, 1, "tenant_data_updated_by_nn"));
            try std.testing.expectEqualStrings("tenant_data_updated_by_nn", phased.constraint_name);
        },
    }
}

test "ddl03: TC-DDL-03-AC2 — phase1 uses NOT VALID form" {
    const spec = ColumnAdditionSpec{
        .migration_id = "1168_test",
        .table = "orders",
        .column = "processed_at",
        .column_type = "TIMESTAMPTZ",
        .backfill_expr = "now()",
        .constraint = .not_null,
        .order = 1,
    };
    const result = generatePhases(spec);
    switch (result) {
        .phase_generation_failed => return error.UnexpectedFailure,
        .accept => |phased| {
            try std.testing.expect(std.mem.containsAtLeast(u8, phased.phase1.add_constraint_not_valid, 1, "NOT VALID"));
        },
    }
}

test "ddl03: TC-DDL-03-AC3 — phase3 includes SET NOT NULL" {
    const spec = ColumnAdditionSpec{
        .migration_id = "1168_test",
        .table = "items",
        .column = "slug",
        .column_type = "TEXT",
        .backfill_expr = "'default'",
        .constraint = .not_null,
        .order = 1,
    };
    const result = generatePhases(spec);
    switch (result) {
        .phase_generation_failed => return error.UnexpectedFailure,
        .accept => |phased| {
            try std.testing.expect(std.mem.containsAtLeast(u8, phased.phase3.set_not_null, 1, "SET NOT NULL"));
        },
    }
}

test "ddl03: TC-DDL-03-AC4 — empty backfill_expr returns phase_generation_failed" {
    const spec = ColumnAdditionSpec{
        .migration_id = "1168_test",
        .table = "items",
        .column = "slug",
        .column_type = "TEXT",
        .backfill_expr = "",
        .constraint = .not_null,
        .order = 1,
    };
    const result = generatePhases(spec);
    switch (result) {
        .phase_generation_failed => |f| try std.testing.expectEqual(FailureReason.empty_backfill_expr, f.reason),
        .accept => return error.ExpectedFailure,
    }
}

test "ddl03: TC-DDL-03-AC4b — unsafe identifier (semicolon) returns phase_generation_failed" {
    const spec = ColumnAdditionSpec{
        .migration_id = "1168_test",
        .table = "it;ems",
        .column = "slug",
        .column_type = "TEXT",
        .backfill_expr = "'x'",
        .constraint = .not_null,
        .order = 1,
    };
    const result = generatePhases(spec);
    switch (result) {
        .phase_generation_failed => |f| try std.testing.expectEqual(FailureReason.unsafe_identifier, f.reason),
        .accept => return error.ExpectedFailure,
    }
}

test "ddl03: TC-DDL-03-AC6 — phase1 and phase3 contain SET LOCAL timeout guards" {
    const spec = ColumnAdditionSpec{
        .migration_id = "1168_test",
        .table = "jobs",
        .column = "status_v2",
        .column_type = "TEXT",
        .backfill_expr = "'pending'",
        .constraint = .not_null,
        .order = 2,
    };
    const result = generatePhases(spec);
    switch (result) {
        .phase_generation_failed => return error.UnexpectedFailure,
        .accept => |phased| {
            try std.testing.expectEqualStrings("SET LOCAL lock_timeout = '3s'", phased.phase1.set_lock_timeout);
            try std.testing.expectEqualStrings("SET LOCAL statement_timeout = '60s'", phased.phase1.set_statement_timeout);
            try std.testing.expectEqualStrings("SET LOCAL lock_timeout = '3s'", phased.phase3.set_lock_timeout);
            try std.testing.expectEqualStrings("SET LOCAL statement_timeout = '60s'", phased.phase3.set_statement_timeout);
        },
    }
}

test "ddl03: phase2 sql contains IS NULL and ctid = ANY (idempotent form)" {
    const spec = ColumnAdditionSpec{
        .migration_id = "1168_test",
        .table = "events",
        .column = "tenant_id",
        .column_type = "UUID",
        .backfill_expr = "gen_random_uuid()",
        .constraint = .not_null,
        .order = 1,
    };
    const result = generatePhases(spec);
    switch (result) {
        .phase_generation_failed => return error.UnexpectedFailure,
        .accept => |phased| {
            try std.testing.expect(std.mem.containsAtLeast(u8, phased.phase2.sql, 1, "IS NULL"));
            try std.testing.expect(std.mem.containsAtLeast(u8, phased.phase2.sql, 1, "ctid = ANY"));
        },
    }
}

test "ddl03: TC-DDL-03-AC4c — empty column_type returns phase_generation_failed" {
    // covers: DDL-03 AC4
    const spec = ColumnAdditionSpec{
        .migration_id = "1168_test",
        .table = "items",
        .column = "slug",
        .column_type = "",
        .backfill_expr = "'default'",
        .constraint = .not_null,
        .order = 1,
    };
    const result = generatePhases(spec);
    switch (result) {
        .phase_generation_failed => |f| try std.testing.expectEqual(FailureReason.empty_column_type, f.reason),
        .accept => return error.ExpectedFailure,
    }
}

test "TC-DDL-03-AC5-phase2-is-null-predicate: phase2 sql uses canonical IS NULL ctid-batched predicate" {
    // covers: DDL-03 AC5 — the IS NULL predicate is the idempotent resume guard;
    // re-running phase 2 skips already-backfilled rows.
    const spec = ColumnAdditionSpec{
        .migration_id = "1169_test",
        .table = "items",
        .column = "category",
        .column_type = "TEXT",
        .backfill_expr = "'general'",
        .constraint = .not_null,
        .order = 1,
    };
    const result = generatePhases(spec);
    switch (result) {
        .phase_generation_failed => return error.UnexpectedFailure,
        .accept => |phased| {
            try std.testing.expect(std.mem.containsAtLeast(u8, phased.phase2.sql, 1, "WHERE"));
            try std.testing.expect(std.mem.containsAtLeast(u8, phased.phase2.sql, 1, "IS NULL"));
            try std.testing.expect(std.mem.containsAtLeast(u8, phased.phase2.sql, 1, "LIMIT $1"));
        },
    }
}

test "TC-DDL-03-AC6-lock-and-statement-timeouts: phase1 and phase3 carry SET LOCAL 3s/60s guards" {
    // covers: DDL-03 AC6
    const spec = ColumnAdditionSpec{
        .migration_id = "1169_test",
        .table = "orders",
        .column = "dispatched_at",
        .column_type = "TIMESTAMPTZ",
        .backfill_expr = "now()",
        .constraint = .not_null,
        .order = 3,
    };
    const result = generatePhases(spec);
    switch (result) {
        .phase_generation_failed => return error.UnexpectedFailure,
        .accept => |phased| {
            try std.testing.expectEqualStrings("SET LOCAL lock_timeout = '3s'", phased.phase1.set_lock_timeout);
            try std.testing.expectEqualStrings("SET LOCAL statement_timeout = '60s'", phased.phase1.set_statement_timeout);
            try std.testing.expectEqualStrings("SET LOCAL lock_timeout = '3s'", phased.phase3.set_lock_timeout);
            try std.testing.expectEqualStrings("SET LOCAL statement_timeout = '60s'", phased.phase3.set_statement_timeout);
        },
    }
}
