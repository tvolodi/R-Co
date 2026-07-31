#!/usr/bin/env python3
"""Clean all data from the test database before running integration tests.

Uses docker-compose exec to run DELETE statements via psql inside the
db_test container.  Tables are deleted in FK-safe order.
"""
import re
import subprocess
import sys
import os

DB = "bpm_test"
USER = "bpm"

# Tables in FK-safe deletion order (children before parents).
# NOTE: schema_migrations is deliberately excluded — we clean test DATA only,
# not the migration tracking table. This allows migrations to remain idempotent:
# TestHarness.init() will see which migrations have already run and skip them.
TABLES = [
    "instance_definition_snapshots",
    "tasks",
    "timers",
    "instance_projections",
    "variable_schemas",
    "process_definitions",
    "events",
    "audit_log",
    "audit_entries",
    "dead_letter_items",
    "webhook_subscriptions",
]

# Mandatory system roles seeded across identity migrations. Integration cleanup
# must restore them so deterministic runs do not depend on historical DB state.
SYSTEM_ROLES = [
    ("PLATFORM_ADMIN", "Full platform access; cannot be deleted"),
    ("PROCESS_DESIGNER", "Create/modify process definitions"),
    ("PROCESS_OPERATOR", "Manage instances and tasks"),
    ("VIEWER", "Read-only access to instances and definitions"),
    ("TASK_WORKER", "Complete and read assigned tasks"),
    ("AGENT_RUNNER", "Agent execution account role for pipeline/runtime automation"),
]


def run_psql(sql: str) -> bool:
    """Execute SQL via docker-compose exec db_test psql.  Returns True on success."""
    cmd = [
        "docker-compose", "exec", "-T", "db_test",
        "psql", "-U", USER, "-d", DB,
        "-c", sql,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        # Ignore "relation does not exist" errors (table may not have been created yet).
        stderr_lower = result.stderr.lower()
        if "does not exist" in stderr_lower or "relation" in stderr_lower:
            return True
        print(f"WARNING: psql '{sql[:60]}...' failed: {result.stderr.strip()}", file=sys.stderr)
        return False
    return True


def run_psql_query(sql: str) -> list[str]:
    """Execute a SELECT via psql in tuples-only/unaligned mode and return the
    rows as a list of raw strings. Returns [] on any failure (best-effort)."""
    cmd = [
        "docker-compose", "exec", "-T", "db_test",
        "psql", "-U", USER, "-d", DB,
        "-t", "-A", "-c", sql,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines() if line.strip()]


def drop_orphaned_tenant_schemas() -> None:
    """Drop every provisioned tenant schema except tenant_default, and clear
    their public.tenant_schemas / public.schema_migrations rows.

    ISS-0090: per-test tenant schemas (tests/integration/*_test.zig call
    bpm_provision_tenant_schema() with a fresh random UUID) are only cleaned
    up via a Zig `defer`, which never runs if the test process is killed,
    times out, or the cleanup's own pool.acquire() fails. Left unchecked this
    accumulates one real Postgres schema per crashed/killed test run
    indefinitely. This sweep makes every integration run start from a known
    baseline regardless of how the previous run ended.

    Checks both public.tenant_schemas (the normal registration path) and
    information_schema.schemata directly, since a provisioning race or a
    test that creates a schema without registering it can leak a schema
    with no corresponding tenant_schemas row.
    """
    # Union two sources: schemas registered in tenant_schemas (the normal case)
    # and schemas that exist in Postgres but were never registered there (a
    # provisioning race, or a test that created the schema directly instead of
    # calling bpm_provision_tenant_schema). Either source can leak.
    registered = run_psql_query(
        "SELECT schema_name FROM public.tenant_schemas WHERE schema_name != 'tenant_default'"
    )
    unregistered = run_psql_query(
        "SELECT schema_name FROM information_schema.schemata "
        "WHERE schema_name LIKE 'tenant\\_%' AND schema_name != 'tenant_default'"
    )
    schema_names = sorted(set(registered) | set(unregistered))
    if not schema_names:
        return

    # Schema names are always the fixed 'tenant_' + 32-hex-digit convention
    # (see bpm_provision_tenant_schema in migrations/060). Validate before
    # interpolating into DDL so a corrupt row can never inject SQL.
    valid_name = re.compile(r"^tenant_[0-9a-f]{32}$")
    dropped = 0
    for schema_name in schema_names:
        if not valid_name.match(schema_name):
            print(f"WARNING: skipping unexpected tenant schema name: {schema_name!r}", file=sys.stderr)
            continue
        if run_psql(f"DROP SCHEMA IF EXISTS {schema_name} CASCADE"):
            dropped += 1

    run_psql("DELETE FROM public.tenant_schemas WHERE schema_name != 'tenant_default'")
    run_psql("DELETE FROM public.schema_migrations WHERE schema_name != 'tenant_default' AND schema_name != 'public'")
    print(f"Dropped {dropped} orphaned tenant schema(s).", flush=True)


def main() -> None:
    print("Cleaning test database...", flush=True)
    # Use TRUNCATE with CASCADE to properly handle foreign key dependencies.
    # This is much faster than DELETE and guarantees all dependent rows are removed.
    # Order doesn't matter with CASCADE, but we keep the original order for clarity.

    # Build comma-separated list of all tables for atomic TRUNCATE.
    tables_str = ", ".join(TABLES)
    ok = run_psql(f"TRUNCATE TABLE {tables_str} CASCADE")
    if not ok:
        print("ERROR: Test database cleanup failed; aborting integration run.", file=sys.stderr)
        sys.exit(1)

    # Clean tenant-schema tables (Stage 12 schema-per-tenant).
    # Public-schema TRUNCATE does not reach tenant_default.* tables; clean them
    # separately using a SET search_path so FK-referencing tables are also cleared.
    TENANT_SCHEMAS = ["tenant_default"]
    TENANT_TABLES = [
        "instance_definition_snapshots",
        "tasks",
        "timers",
        "instance_projections",
        "variable_schemas",
        "process_definitions",
        "events",
    ]
    for schema in TENANT_SCHEMAS:
        tenant_tables_str = ", ".join(TENANT_TABLES)
        run_psql(
            f"SET search_path TO {schema},public; "
            f"TRUNCATE TABLE {tenant_tables_str} CASCADE"
        )

    # Clean tenant rows created by integration tests.
    # ENV-01 added ON DELETE RESTRICT: test tenants must be deleted BEFORE production tenants.
    # Use two-step DELETE to avoid FK violation (test tenant references production tenant).
    # The default system tenant (slug = 'default') is preserved.
    run_psql("DELETE FROM public.tenant WHERE tenant_type = 'test' AND slug != 'default'")
    run_psql("DELETE FROM public.tenant WHERE tenant_type = 'production' AND slug != 'default'")

    # ISS-0090: drop orphaned per-tenant schemas (tests that crash, time out, or
    # get killed mid-run skip their `defer cleanupTenant()` and leak a real
    # Postgres schema + a public.tenant_schemas row). Sweep every registered
    # schema except tenant_default, which is the harness's persistent fixture.
    drop_orphaned_tenant_schemas()

    for role_name, role_description in SYSTEM_ROLES:
        sql = (
            "INSERT INTO roles (name, description, is_system) "
            f"VALUES ('{role_name}', '{role_description}', true) "
            "ON CONFLICT (name) DO NOTHING"
        )
        if not run_psql(sql):
            print("ERROR: Failed to reseed mandatory system roles; aborting integration run.", file=sys.stderr)
            sys.exit(1)

    print("Test database cleaned.", flush=True)


if __name__ == "__main__":
    main()
