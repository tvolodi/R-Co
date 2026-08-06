//! Unit test stubs for DB-01 through DB-04.
//!
//! Each test block corresponds to one test case in tests/specs/DB-01-04.md.
//! Stub blocks return error.SkipZigTest until the TEST-RUNNER implements them;
//! TC-DB-01-06 and the DB-02 bound checks are fully implemented.
//!
//! Requirement traceability:
//!   DB-01 → TC-DB-01-01 … TC-DB-01-06  (TC-DB-01-06: ISS-0603 / GH-467 ordering)
//!   DB-02 → TC-DB-02-01 … TC-DB-02-04
//!   DB-03 → TC-DB-03-01 … TC-DB-03-02  (integration layer; stubs here for catalog)
//!   DB-04 → TC-DB-04-01 … TC-DB-04-02
const std = @import("std");
const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const PoolError = bpm.pool.PoolError;

// ---------------------------------------------------------------------------
// DB-01: Schema initialisation
// ---------------------------------------------------------------------------

test "TC-DB-01-01: fresh migration applies all schemas" {
    return error.SkipZigTest;
}

test "TC-DB-01-02: re-applying migrations is idempotent" {
    return error.SkipZigTest;
}

test "TC-DB-01-03: out-of-order migration returns OutOfOrderMigration" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-DB-01-06 (ISS-0603 / GH-467): migration apply ordering
//
// Regression guard for the fresh-database bootstrap failure. The apply sort in
// src/db/migrations.zig used to be a raw lexicographic std.mem.lessThan on the
// filename. Because '1' (0x31) sorts before 'G' (0x47), EVERY GBL-* migration
// was applied after EVERY 1xxx_* migration. GBL-119_env01_tenant_type_field.sql
// adds public.tenant.tenant_type, which
// 1135_iss0114_backfill_public_tenant_storage_mode.sql writes to, so
// bootstrapping any brand-new database died with C42703
// 'column "tenant_type" of relation "tenant" does not exist'.
//
// The ordering authority is migrationOrder(): it strips the "GBL-" prefix and
// adds a 1000 offset, so GBL-119 -> 1119, correctly before 1135.
// ---------------------------------------------------------------------------

const migrationOrder = bpm.migrations.migrationOrder;

/// Mirrors the comparator used by the apply sort in runForSchema: order first,
/// filename as the deterministic tiebreak for equal orders.
fn migrationLessThan(a: []const u8, b: []const u8) bool {
    const oa = migrationOrder(a);
    const ob = migrationOrder(b);
    if (oa != ob) return oa < ob;
    return std.mem.lessThan(u8, a, b);
}

test "TC-DB-01-06: GBL-119 sorts before 1135 (ISS-0603 fresh-DB bootstrap)" {
    const gbl119 = "GBL-119_env01_tenant_type_field.sql";
    const m1135 = "1135_iss0114_backfill_public_tenant_storage_mode.sql";

    // The exact ordering the bug violated: the column-adding migration must be
    // applied before the migration that backfills that column.
    try std.testing.expect(migrationLessThan(gbl119, m1135));
    try std.testing.expect(!migrationLessThan(m1135, gbl119));

    // And the raw lexicographic comparison the old sort used gets it backwards —
    // this is what makes the assertion above a real regression guard rather than
    // a restatement of the default behaviour.
    try std.testing.expect(std.mem.lessThan(u8, m1135, gbl119));
}

test "TC-DB-01-06: migrationOrder maps GBL- prefix into the 1xxx band" {
    try std.testing.expectEqual(@as(u32, 1119), migrationOrder("GBL-119_env01_tenant_type_field.sql"));
    try std.testing.expectEqual(@as(u32, 1135), migrationOrder("1135_iss0114_backfill_public_tenant_storage_mode.sql"));
    try std.testing.expectEqual(@as(u32, 1112), migrationOrder("GBL-112_tnt01_drop_legacy_public_business_tables.sql"));
    try std.testing.expectEqual(@as(u32, 1133), migrationOrder("GBL-133_iss0112_schema_ledger_reconcile.sql"));
    try std.testing.expectEqual(@as(u32, 1), migrationOrder("001_event_store.sql"));
    try std.testing.expectEqual(@as(u32, 94), migrationOrder("094_entity_subsystem.sql"));
}

test "TC-DB-01-06: full GBL/numeric migration set sorts into interleaved order" {
    const alloc = std.testing.allocator;

    // Deliberately seeded in the WRONG (old lexicographic) order.
    var names = [_][]const u8{
        "1134_iss0112_add_secret_ref_to_tenant_schemas.sql",
        "1135_iss0114_backfill_public_tenant_storage_mode.sql",
        "GBL-112_tnt01_drop_legacy_public_business_tables.sql",
        "GBL-119_env01_tenant_type_field.sql",
        "GBL-133_iss0112_schema_ledger_reconcile.sql",
        "1111_iss0122_validator_pass_trace_id.sql",
        "094_entity_subsystem.sql",
    };

    const slice = try alloc.dupe([]const u8, &names);
    defer alloc.free(slice);

    std.sort.block([]const u8, slice, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return migrationLessThan(a, b);
        }
    }.lessThan);

    const expected = [_][]const u8{
        "094_entity_subsystem.sql",
        "1111_iss0122_validator_pass_trace_id.sql",
        "GBL-112_tnt01_drop_legacy_public_business_tables.sql",
        "GBL-119_env01_tenant_type_field.sql",
        "GBL-133_iss0112_schema_ledger_reconcile.sql",
        "1134_iss0112_add_secret_ref_to_tenant_schemas.sql",
        "1135_iss0114_backfill_public_tenant_storage_mode.sql",
    };

    for (expected, slice) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "TC-DB-01-06: equal-order migrations use filename as deterministic tiebreak" {
    // migrations/ genuinely contains duplicate-order pairs; the sort must be
    // stable and total, never dependent on directory iteration order.
    const a = "050_tenant_hostnames.sql";
    const b = "050_xc01_trace_id_audit.sql";
    try std.testing.expectEqual(migrationOrder(a), migrationOrder(b));
    try std.testing.expect(migrationLessThan(a, b));
    try std.testing.expect(!migrationLessThan(b, a));
}

test "TC-DB-01-04: failed migration SQL is fully rolled back" {
    return error.SkipZigTest;
}

test "TC-DB-01-05: PostgreSQL version below 15 returns UnsupportedPgVersion" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// DB-02: Connection pooling
// ---------------------------------------------------------------------------

test "TC-DB-02-01: pool_size below lower bound returns InvalidPoolSize" {
    const result = Pool.init(std.testing.io, std.testing.allocator, PoolConfig{
        .url = "postgres://fake:fake@localhost/fake",
        .pool_size = 1,
    });
    try std.testing.expectError(PoolError.InvalidPoolSize, result);
}

test "TC-DB-02-02: pool_size above upper bound returns InvalidPoolSize" {
    const result = Pool.init(std.testing.io, std.testing.allocator, PoolConfig{
        .url = "postgres://fake:fake@localhost/fake",
        .pool_size = 201,
    });
    try std.testing.expectError(PoolError.InvalidPoolSize, result);
}

test "TC-DB-02-03: fully exhausted pool returns ExhaustedPool immediately" {
    return error.SkipZigTest;
}

test "TC-DB-02-04: released connection is available for next acquire" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// DB-03: Transactional integrity (integration; stubs for catalog completeness)
// ---------------------------------------------------------------------------

test "TC-DB-03-01: successful transaction commits both event row and state update atomically" {
    return error.SkipZigTest;
}

test "TC-DB-03-02: failed state-table update causes full transaction rollback" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// DB-04: Health check query
// ---------------------------------------------------------------------------

test "TC-DB-04-01: health check returns latency_ms on successful SELECT 1" {
    return error.SkipZigTest;
}

test "TC-DB-04-02: health check returns ExhaustedPool when all connections are in use" {
    return error.SkipZigTest;
}
