//! Tenant schema provisioning orchestrator — SPT-01
//!
//! Provides the single Zig-side entry point for provisioning a new tenant
//! schema: creates the PostgreSQL schema via bpm_provision_tenant_schema(),
//! applies all pending migrations inside that schema, and updates the
//! tenant_schemas registry timestamp.
//!
//! Design artefact: src/design/spt-01-schema-per-tenant-provisioning.md
//!
//! ISS-0114 / GH-377: After bpm_provision_tenant_schema() succeeds, this
//! function MUST additionally INSERT/UPDATE a public.tenant row with
//! storage_mode='SCHEMA' so the routing layer (pool.zig::applyRequestStorageRouting)
//! picks the SCHEMA branch on the very next pool.acquire() in this thread —
//! without relying on the public.tenant_schemas heuristic fallback.
const std = @import("std");
const pool_mod = @import("pool");
const Pool = pool_mod.Pool;
const PoolError = pool_mod.PoolError;
const migrations = @import("migrations.zig");
const MigrationError = migrations.MigrationError;
const tenant_context_mod = @import("tenant_context");

// ISS-0604 / GH-470: re-export the canonical migration classification helpers.
//
// src/tools/migrate.zig (the runner `zig build migrate` executes) needs these,
// but migrations.zig cannot be added to that executable as its own module —
// this file already imports it relatively, and Zig requires a file to belong to
// exactly one module. Re-exporting here gives the CLI the SINGLE canonical
// definition without duplicating it, which matters because ISS-0603 was caused
// precisely by the CLI carrying its own drifted copy of the ordering logic.
pub const migrationOrder = migrations.migrationOrder;
pub const migrationScope = migrations.migrationScope;
pub const MigrationScope = migrations.MigrationScope;
pub const declaresPublicScopeHeader = migrations.declaresPublicScopeHeader;
pub const declaresUnqualifiedTableWork = migrations.declaresUnqualifiedTableWork;

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
    /// ISS-0114 / GH-377: The post-bpm_provision_tenant_schema INSERT
    /// into public.tenant (storage_mode='SCHEMA') failed. Distinct from
    /// SchemaCreationFailed so callers can distinguish provisioning from
    /// promotion failures.
    SchemaPromotionFailed,
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

    // ISS-0131 / GH #424: serialize the whole provisionTenantSchema pass
    // under a session-level advisory lock keyed by tenant_id. Without this,
    // concurrent provisionTenantSchema calls race against each other on
    // the tenant_schemas row and the bpm_provision_tenant_schema() SQL
    // function, surfacing as a C40P01 deadlock between AccessShareLock on
    // the relation and ShareLock on the open transaction under full-suite
    // integration runs. The inner runForSchema advisory lock from
    // ISS-0129 does not cover the pre- and post-migration steps above.
    //
    // The lock is session-scoped (pg_advisory_lock, not pg_advisory_xact_lock)
    // because the per-migration transactions inside runForSchema would
    // release an xact_lock prematurely. We pair it with a matching
    // pg_advisory_unlock from the same connection before pool.release.
    const lock_key = std.fmt.allocPrint(
        allocator,
        "bpm.provisioning.provisionTenantSchema:{s}",
        .{tenant_id_str},
    ) catch return ProvisionError.QueryFailed;
    defer allocator.free(lock_key);
    {
        const lock_conn = pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return ProvisionError.PoolExhausted,
            else => return ProvisionError.QueryFailed,
        };
        defer pool.release(lock_conn);
        lock_conn.exec(
            "SELECT pg_advisory_lock(hashtext($1)::bigint)",
            &.{lock_key},
        ) catch return ProvisionError.QueryFailed;
        defer lock_conn.exec(
            "SELECT pg_advisory_unlock(hashtext($1)::bigint)",
            &.{lock_key},
        ) catch {};
    }

    // Step 2: Idempotency check.
    {
        const conn = pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return ProvisionError.PoolExhausted,
            else => return ProvisionError.QueryFailed,
        };
        defer pool.release(conn);

        const result = conn.query(
            allocator,
            // Only skip if migrations have been applied (migrations_applied_at IS NOT NULL).
            // A schema registered by a SQL migration (GBL-069 etc.) but never fully
            // provisioned by Zig will have migrations_applied_at = NULL — in that case
            // we must still run runForSchema to populate the tenant schema tables.
            "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid AND migrations_applied_at IS NOT NULL",
            &.{tenant_id_str},
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
                        // Already provisioned with migrations applied — fast path, nothing to do.
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
    migrations.Migrations.runForSchema(allocator, pool, migrations_dir, schema_name, false) catch
        return ProvisionError.MigrationFailed;

    // Step 6: Update migrations_applied_at timestamp in tenant_schemas.
    {
        const conn = pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return ProvisionError.PoolExhausted,
            else => return ProvisionError.RegistryUpdateFailed,
        };
        defer pool.release(conn);

        conn.exec(
            "UPDATE public.tenant_schemas SET migrations_applied_at = NOW() WHERE tenant_id = $1::uuid",
            &.{tenant_id_str},
        ) catch return ProvisionError.RegistryUpdateFailed;
    }

    // Step 6a: ISS-0114 / GH-377 — authoritative promotion to SCHEMA storage_mode.
    //
    // After bpm_provision_tenant_schema() succeeds and the migration runner
    // has finished, INSERT/UPDATE a public.tenant row with storage_mode='SCHEMA'
    // for this tenant. This guarantees the next pool.acquire() in this thread
    // receives the SCHEMA routing branch without relying on the heuristic
    // public.tenant_schemas fallback in applyRequestStorageRouting().
    //
    // REWORK 1 (2026-08-04): The original INSERT only populated (id, storage_mode)
    // which violated C23502 NOT NULL on slug, display_name, status, tenant_type,
    // created_at, updated_at. public.tenant has 7 NOT NULL columns total (see
    // information_schema.columns). The patch populates ALL of them with stable
    // defaults derived from the tenant_id (slug, display_name) or with the
    // schema default values (status, tenant_type, created_at, updated_at).
    //
    // Idempotency: ON CONFLICT (id) DO UPDATE only fires when storage_mode is
    // 'LEGACY_RLS' OR NULL, so re-running this for an already-SCHEMA tenant
    // is a no-op. This matches the behaviour of migration 1135.
    {
        const conn = pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return ProvisionError.PoolExhausted,
            else => return ProvisionError.SchemaPromotionFailed,
        };
        defer pool.release(conn);

        conn.exec(
            \\INSERT INTO public.tenant (
            \\    id,
            \\    slug,
            \\    display_name,
            \\    status,
            \\    tenant_type,
            \\    storage_mode,
            \\    created_at,
            \\    updated_at
            \\) VALUES (
            \\    $1::uuid,
            \\    'tenant-' || replace($1::text, '-', ''),
            \\    'Auto-provisioned tenant ' || substr($1::text, 1, 8),
            \\    'ACTIVE',
            \\    'production',
            \\    'SCHEMA',
            \\    NOW(),
            \\    NOW()
            \\)
            \\ON CONFLICT (id) DO UPDATE
            \\  SET storage_mode = 'SCHEMA',
            \\      updated_at = NOW()
            \\  WHERE public.tenant.storage_mode = 'LEGACY_RLS'
            \\     OR public.tenant.storage_mode IS NULL
        , &.{tenant_id_str}) catch return ProvisionError.SchemaPromotionFailed;
    }

    // Step 6b: Prime the thread-local tenant_context so the very next
    // pool.acquire() in this thread sees storage_mode_resolved=true and
    // skips the resolver query. Without this, the first acquire() after
    // provisioning re-runs the resolver, which on a slow DB or under
    // contention can race against the migration runner's residual
    // connection state.
    tenant_context_mod.setStorageMode(.SCHEMA);
}
