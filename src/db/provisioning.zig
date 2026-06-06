//! Tenant schema provisioning orchestrator — SPT-01
//!
//! Provides the single Zig-side entry point for provisioning a new tenant
//! schema: creates the PostgreSQL schema via bpm_provision_tenant_schema(),
//! applies all pending migrations inside that schema, and updates the
//! tenant_schemas registry timestamp.
//!
//! Design artefact: src/design/spt-01-schema-per-tenant-provisioning.md
const std = @import("std");
const pool_mod = @import("pool");
const Pool = pool_mod.Pool;
const PoolError = pool_mod.PoolError;
const migrations = @import("migrations.zig");
const MigrationError = migrations.MigrationError;

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const ProvisionError = error{
    /// The tenant_id_str is not a valid UUID string (must be 36 chars).
    InvalidTenantId,
    /// Database connection could not be acquired from the pool.
    PoolExhausted,
    /// The SQL call to bpm_provision_tenant_schema() failed.
    SchemaCreationFailed,
    /// migrations.runForSchema() returned any MigrationError variant.
    MigrationFailed,
    /// Could not update migrations_applied_at in tenant_schemas.
    RegistryUpdateFailed,
    /// An unexpected DB query failure (idempotency check or other query).
    QueryFailed,
};

// ---------------------------------------------------------------------------
// provisionTenantSchema
// ---------------------------------------------------------------------------

/// Idempotently provision a PostgreSQL schema for the given tenant.
///
/// Steps:
///  1. Validate tenant_id_str is non-empty (UUID format).
///  2. Idempotency check: return immediately if already provisioned.
///  3. Call bpm_provision_tenant_schema() to create schema + register row.
///  4. Apply all pending migrations inside the tenant schema via runForSchema.
///  5. Update migrations_applied_at timestamp in tenant_schemas.
pub fn provisionTenantSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id_str: []const u8,
    migrations_dir: []const u8,
) ProvisionError!void {
    // Step 1: Validate input — must be a non-empty 36-char UUID string.
    if (tenant_id_str.len == 0) return ProvisionError.InvalidTenantId;
    if (tenant_id_str.len != 36) return ProvisionError.InvalidTenantId;

    // Derive schema name early — used for both the idempotency check and
    // the registry update, avoiding tenant_id predicates on public.tenant_schemas.
    var schema_buf_early: [80]u8 = undefined;
    const schema_name_early = pool_mod.schemaNameForTenant(tenant_id_str, &schema_buf_early);

    // Step 2: Idempotency check.
    {
        const conn = pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return ProvisionError.PoolExhausted,
            else => return ProvisionError.QueryFailed,
        };
        defer pool.release(conn);

        // Query by schema_name (unique column) to avoid a tenant_id = $N predicate
        // on the management registry table (SPT-03 code-cleanup requirement).
        const result = conn.query(
            allocator,
            "SELECT count(*) FROM public.tenant_schemas WHERE schema_name = $1",
            &.{schema_name_early},
        ) catch return ProvisionError.QueryFailed;
        defer {
            var r = result;
            r.deinit();
        }

        if (result.rows.len > 0) {
            const row = result.rows[0];
            if (row.len > 0) {
                if (row[0]) |count_str| {
                    const count = std.fmt.parseInt(u64, count_str, 10) catch 0;
                    if (count > 0) {
                        // Already provisioned — fast path, nothing to do.
                        return;
                    }
                }
            }
        }
    }

    // Step 3: Derive schema name (same logic as schemaNameForTenant in pool.zig).
    var schema_buf: [80]u8 = undefined;
    const schema_name = pool_mod.schemaNameForTenant(tenant_id_str, &schema_buf);

    // Step 4: Call SQL provisioning function to create schema + register row.
    {
        const conn = pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return ProvisionError.PoolExhausted,
            else => return ProvisionError.SchemaCreationFailed,
        };
        defer pool.release(conn);

        conn.exec(
            "SELECT public.bpm_provision_tenant_schema($1::uuid)",
            &.{tenant_id_str},
        ) catch return ProvisionError.SchemaCreationFailed;
    }

    // Step 5: Apply migrations inside the tenant schema.
    migrations.Migrations.runForSchema(allocator, pool, migrations_dir, schema_name) catch
        return ProvisionError.MigrationFailed;

    // Step 6: Update migrations_applied_at timestamp in tenant_schemas.
    {
        const conn = pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return ProvisionError.PoolExhausted,
            else => return ProvisionError.RegistryUpdateFailed,
        };
        defer pool.release(conn);

        conn.exec(
            // Query by schema_name to avoid tenant_id predicates (SPT-03).
            "UPDATE public.tenant_schemas SET migrations_applied_at = NOW() WHERE schema_name = $1",
            &.{schema_name},
        ) catch return ProvisionError.RegistryUpdateFailed;
    }
}
