//! Solution pack domain types — SOL-01/02/03
//!
//! Self-contained data types for solution pack export, install, and role gate.
//! No I/O in this file: pure structs and enums only.

// ---------------------------------------------------------------------------
// Error set
// ---------------------------------------------------------------------------

pub const SolutionPackError = error{
    /// One or more definition_ids not found in the exporting tenant.
    DefinitionNotFound,
    /// A module_ref dependency is marked non-exportable by its owner.
    ModuleNonExportable,
    /// bpm_export_schema_version unknown or missing required fields.
    InvalidPackDocument,
    /// Target tenant status is not ACTIVE.
    TenantInactive,
    /// service_id exists in target with different request/response schema.
    CatalogConflict,
    /// schema_name exists in target with different schema content.
    VariableSchemaConflict,
    /// One or more manifest roles have no tenant_role binding.
    UnboundRoles,
    /// DB connection pool exhausted.
    PoolExhausted,
    /// DB transaction failed to commit.
    TransactionFailed,
    /// Allocator failure.
    OutOfMemory,
    /// Generic persistence failure (query error, row not found on RETURNING).
    PersistenceFailed,
};

// ---------------------------------------------------------------------------
// Sub-document types
// ---------------------------------------------------------------------------

/// One process definition bundled in the pack.
pub const PackedDefinition = struct {
    /// Source definition UUID string (informational; re-assigned on install).
    definition_id: []const u8,
    /// Process key / name.
    process_key: []const u8,
    /// Human-readable name.
    name: []const u8,
    /// Semver string.
    version: []const u8,
    /// Raw JSON bytes for the definition graph (JSONB column content).
    graph: []const u8,
    /// Variable schema bytes (JSON Schema or "{}").
    variable_schema: []const u8,
};

/// One service catalog entry bundled in the pack.
pub const PackedCatalogEntry = struct {
    service_id: []const u8,
    endpoint_url: []const u8,
    request_schema: []const u8,
    response_schema: []const u8,
    /// "NONE" | "API_KEY" | "OAUTH2" | "MUTUAL_TLS"
    required_auth: []const u8,
    timeout_ms: u32,
    retry_policy: []const u8,
};

/// One variable schema row bundled in the pack.
pub const PackedVariableSchema = struct {
    /// Source definition_id (informational).
    definition_id: []const u8,
    /// Match key for upsert on install (= variable_schemas.variable_key).
    schema_name: []const u8,
    /// JSON Schema bytes.
    schema_content: []const u8,
};

/// Role-name manifest embedded in every pack document.
pub const PackManifest = struct {
    /// Alphabetically sorted distinct set of ROLE-type assignee names.
    required_roles: []const []const u8,
};

// ---------------------------------------------------------------------------
// Top-level document
// ---------------------------------------------------------------------------

/// Self-contained export document produced by exportPack() and consumed by
/// installPack().  All []const u8 fields are caller-owned slices.
pub const SolutionPackDocument = struct {
    pack_id: []const u8,
    version: []const u8,
    bpm_export_schema_version: []const u8,
    exported_at: []const u8,
    definitions: []const PackedDefinition,
    service_catalog_entries: []const PackedCatalogEntry,
    variable_schemas: []const PackedVariableSchema,
    manifest: PackManifest,
};

// ---------------------------------------------------------------------------
// Install result types
// ---------------------------------------------------------------------------

/// One definition created during a pack install.
pub const InstalledDefinition = struct {
    /// Source definition UUID from the pack document.
    source_definition_id: []const u8,
    /// UUID assigned by this tenant for the new definition row.
    new_definition_id: []const u8,
    process_key: []const u8,
    /// Always "DRAFT".
    status: []const u8,
};

/// Role binding status entry for the install checklist.
pub const RoleChecklistEntry = struct {
    role_name: []const u8,
    /// true when a tenant_role binding exists for this name.
    bound: bool,
};

/// Returned by installPack().
pub const InstallResult = struct {
    pack_id: []const u8,
    version: []const u8,
    installed_definitions: []const InstalledDefinition,
    role_mapping_checklist: []const RoleChecklistEntry,
    /// Advisory warnings (e.g. idempotent re-install skips).
    warnings: []const []const u8,
};

// ---------------------------------------------------------------------------
// Activation gate result
// ---------------------------------------------------------------------------

/// Returned by checkRoleGate().
pub const RoleGateResult = struct {
    allowed: bool,
    /// Empty when allowed = true; lists unbound role names when allowed = false.
    unbound_roles: []const []const u8,
};

/// Schema version this platform produces and accepts.
pub const PACK_SCHEMA_VERSION: []const u8 = "bpm/solution-pack/v1";
