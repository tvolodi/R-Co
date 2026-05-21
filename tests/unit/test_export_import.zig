//! Unit tests for PD-09 — Definition import/export (ExportImportStore).
//!
//! The only DB-free path in `export_import.zig` is the `EXPORT_SCHEMA_VERSION`
//! constant, which is exercised as a compile-time check and a runtime
//! `expectEqualStrings` test (TC-PD-09-const).
//!
//! All `ExportImportStore` methods require a live database connection through
//! `Pool.acquire()`.  All test blocks below (TC-PD-09-01 through TC-PD-09-07)
//! return `error.SkipZigTest` and exist for requirement traceability only.
//!
//! Full verification is provided by:
//!   tests/integration/test_export_import_integration.zig
//!
//! Requirement traceability:
//!   PD-09 → TC-PD-09-const, TC-PD-09-01 through TC-PD-09-07
//!   (see tests/specs/PD-09.md for full Given/When/Then specs)
//!
//! Run with: zig build test
const std = @import("std");
const bpm = @import("bpm");
const export_import_mod = bpm.definition_export_import;

// Compile-time assertion: catches schema version regressions at build time.
comptime {
    if (!std.mem.eql(u8, export_import_mod.EXPORT_SCHEMA_VERSION, "bpm/definition/v1")) {
        @compileError("EXPORT_SCHEMA_VERSION must equal \"bpm/definition/v1\"");
    }
}

// ---------------------------------------------------------------------------
// TC-PD-09-const: EXPORT_SCHEMA_VERSION constant value
// ---------------------------------------------------------------------------

test "TC-PD-09-const: EXPORT_SCHEMA_VERSION equals bpm/definition/v1" {
    try std.testing.expectEqualStrings(
        "bpm/definition/v1",
        export_import_mod.EXPORT_SCHEMA_VERSION,
    );
}

// ---------------------------------------------------------------------------
// TC-PD-09-01: Export happy path — any status
// ---------------------------------------------------------------------------

test "TC-PD-09-01: ExportImportStore.exportDefinition — happy path returns ExportDocument with matching fields" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-PD-09-02: Export unknown id returns DefinitionNotFound
// ---------------------------------------------------------------------------

test "TC-PD-09-02: ExportImportStore.exportDefinition — unknown id returns DefinitionNotFound" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-PD-09-03: Import happy path — creates with DRAFT status
// ---------------------------------------------------------------------------

test "TC-PD-09-03: ExportImportStore.importDefinition — happy path creates definition with DRAFT status" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-PD-09-04: Import with name+version conflict returns NameVersionConflict
// ---------------------------------------------------------------------------

test "TC-PD-09-04: ExportImportStore.importDefinition — name+version conflict returns NameVersionConflict" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-PD-09-05: Import with invalid CEL condition returns InvalidGraph
// ---------------------------------------------------------------------------

test "TC-PD-09-05: ExportImportStore.importDefinition — invalid CEL condition returns InvalidGraph" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-PD-09-06: Import with unknown schema version returns UnknownSchemaVersion
// ---------------------------------------------------------------------------

test "TC-PD-09-06: ExportImportStore.importDefinition — unknown schema version returns UnknownSchemaVersion" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// TC-PD-09-07: Export-import round-trip preserves full graph
// ---------------------------------------------------------------------------

test "TC-PD-09-07: ExportImportStore export/import round-trip preserves full graph" {
    return error.SkipZigTest;
}
