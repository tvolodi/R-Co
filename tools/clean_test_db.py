#!/usr/bin/env python3
"""Clean all data from the test database before running integration tests.

Runs DELETE/TRUNCATE statements via psql against the test database. Tables
are deleted in FK-safe order.

Connection mode (GH-292 / ISS-0077 / PI-02): if BPM_TEST_DB_URL is set, psql
connects to it directly. Otherwise this falls back to the historical
`docker-compose exec -T db_test psql ...` path, which requires a local
docker-compose stack with a `db_test` service and is what every developer
workflow and every zig build test-integration-* step used exclusively before
this change.

The direct-URL mode exists because build.zig wires this script as an
unconditional ordering predecessor of every `test-integration-*` step (see
addIntegrationRun / src/design/iss0148_clean_test_db_ordering_and_lock.md),
so any CI job that runs one of those steps against a plain `services:
postgres:` container (no docker-compose stack, e.g. the tenant_isolation_tests
job added by GH-292) needs a way to reach that database that does not assume
docker-compose exists on the runner. BPM_TEST_DB_URL is already the
established interface `zig build test-integration-*` itself requires — this
just extends this one script to honour the same variable instead of assuming
a docker-compose-based local dev environment. Nothing about the
docker-compose path changes for a local run that does not set the variable.
"""
import argparse
import subprocess
import sys
import os

DB = "bpm_test"
USER = "bpm"

# Set (once) by main() from the BPM_TEST_DB_URL environment variable, if
# present. When None, every psql-invoking helper below falls back to the
# historical `docker-compose exec -T db_test psql ...` invocation.
_DIRECT_DB_URL: str | None = None


def _psql_base_cmd() -> list[str]:
    """Return the psql invocation prefix (connection portion only) for the
    active connection mode — direct BPM_TEST_DB_URL if set, else
    docker-compose exec into the db_test container."""
    if _DIRECT_DB_URL:
        return ["psql", _DIRECT_DB_URL]
    return ["docker-compose", "exec", "-T", "db_test", "psql", "-U", USER, "-d", DB]

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
    """Execute SQL via psql (direct BPM_TEST_DB_URL, or docker-compose exec
    db_test as a fallback — see _psql_base_cmd). Returns True on success."""
    cmd = _psql_base_cmd() + ["-c", sql]
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
    cmd = _psql_base_cmd() + ["-t", "-A", "-c", sql]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines() if line.strip()]


def run_psql_script(script: str) -> subprocess.CompletedProcess:
    """Execute a MULTI-STATEMENT script in a SINGLE psql session.

    ISS-0148 (GitHub #477): run_psql() and run_psql_query() each spawn a fresh
    psql process, so every statement they run gets its own session and its own
    implicit transaction. That makes them unusable for anything needing a
    transaction-scoped advisory lock: a lock taken by one run_psql() call is
    released the instant that process exits, before the next call even starts.
    A naive "run_psql(SELECT pg_advisory_xact_lock(...)) then run_psql(DROP ...)"
    therefore protects nothing at all.

    This helper feeds the whole script to one psql invocation on stdin, so a
    BEGIN ... COMMIT block inside it really is one transaction in one session,
    and a pg_advisory_xact_lock() taken inside it is held continuously until
    the COMMIT.

    Returns the CompletedProcess so the caller can inspect returncode/stdout/stderr.
    """
    cmd = _psql_base_cmd() + [
        # -v ON_ERROR_STOP=1 so a failure inside the script aborts the
        # transaction rather than silently continuing past it with the lock held.
        "-v", "ON_ERROR_STOP=1",
        "-t", "-A", "-f", "-",
    ]
    return subprocess.run(cmd, input=script, capture_output=True, text=True)


# ISS-0148: the exact advisory-lock key expression used by the migration runner.
# Verbatim from src/db/migrations.zig (MIGRATIONS_LOCK_KEY_SQL). Reusing this
# EXACT key is what makes the guard correct: it is the same primitive
# Migrations.runForSchema already holds, so the sweep and any in-flight
# runForSchema transaction become mutually exclusive by construction. Inventing
# a second key would serialize the sweep against nothing.
#
# The lock is transaction-scoped (pg_advisory_xact_lock), so it is released
# automatically at COMMIT/ROLLBACK and can never leak across a failed sweep --
# unlike the session-scoped pg_advisory_lock, which an aborted sweep could leak
# and thereby block every subsequent migration on the database.
MIGRATIONS_LOCK_SQL = (
    "SELECT pg_advisory_xact_lock(hashtext('bpm.migrations.runForSchema')::bigint)"
)


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
    # ISS-0148 (GitHub #477): the ENTIRE enumerate -> validate -> drop ->
    # delete-ledger sequence is the critical section, and it runs as ONE
    # transaction in ONE psql session while holding the migration runner's
    # advisory lock.
    #
    # Enumeration happens UNDER the lock, not before it. An enumeration taken
    # before acquisition could name a schema that a concurrent test provisions
    # and starts migrating in the interval, reintroducing the race in miniature.
    # This is the same "re-check under the lock" discipline ISS-0144 established
    # for the migration runner's `applied` snapshot.
    #
    # The sweep BLOCKS on the lock; it does not skip and does not use the _try_
    # variant. A sweep that gave up because a migration was in flight would
    # return without cleaning and the run would proceed against a dirty
    # database, reintroducing the ISS-0090 leak the sweep exists to prevent.
    # The wait is bounded in practice: the runner takes this lock per migration
    # FILE and releases it at each COMMIT, so the sweep waits at most for one
    # per-file transaction, never for a whole ~80-file sequence.
    #
    # The name-shape validation (^tenant_[0-9a-f]{32}$) moves server-side with
    # the enumeration as an equivalent pattern check. It is a SQL-injection
    # guard on interpolated DDL and is NOT dropped on the grounds that "the
    # names come from the database anyway". Names failing it are reported via
    # the `skipped` channel below and are never interpolated into DDL.
    #
    # ISS-0101 / GH-359: cold-start guard. On a genuinely empty database (zero
    # migrations ever applied -- e.g. db_test recreated from a fresh Docker
    # volume), public.tenant_schemas does not exist yet, because this sweep
    # runs BEFORE the test binary's own TestHarness.init() migration pass
    # (build.zig wires clean_test_db as an ordering predecessor of every
    # test-integration run step -- see src/design/iss0148_clean_test_db_
    # ordering_and_lock.md). The script below is a single ON_ERROR_STOP=1
    # psql session (needed so the advisory lock and the sweep share one
    # transaction -- see run_psql_script's docstring), so an undefined-relation
    # error on `public.tenant_schemas` aborts the whole script and the
    # transaction rolls back -- unlike run_psql()/run_psql_query() above, this
    # helper has no missing-relation tolerance of its own. There is nothing to
    # sweep on a database that has never been migrated, so detect that case
    # with a cheap best-effort existence probe and skip the transactional sweep
    # entirely rather than let it hard-fail the whole integration run before a
    # single migration has had a chance to create the table it is about to
    # query.
    probe = run_psql_query("SELECT to_regclass('public.tenant_schemas')")
    if not probe or probe[0].strip() == "":
        print(
            "Skipping orphaned-tenant-schema sweep: public.tenant_schemas does "
            "not exist yet (cold-start database, no migrations applied).",
            flush=True,
        )
        return

    # tenant_default is never dropped -- it is the harness's persistent fixture.
    script = f"""
BEGIN;
{MIGRATIONS_LOCK_SQL};

CREATE TEMP TABLE _sweep_candidates ON COMMIT DROP AS
SELECT schema_name FROM public.tenant_schemas
 WHERE schema_name <> 'tenant_default'
UNION
SELECT schema_name FROM information_schema.schemata
 WHERE schema_name LIKE 'tenant\\_%' AND schema_name <> 'tenant_default';

-- Server-side equivalent of the ^tenant_[0-9a-f]{{32}}$ guard. Anything failing
-- it is reported and never reaches the DROP below.
SELECT 'SKIPPED:' || schema_name FROM _sweep_candidates
 WHERE schema_name !~ '^tenant_[0-9a-f]{{32}}$';

DO $$
DECLARE
    s text;
    n int := 0;
BEGIN
    FOR s IN
        SELECT schema_name FROM _sweep_candidates
         WHERE schema_name ~ '^tenant_[0-9a-f]{{32}}$'
         ORDER BY schema_name
    LOOP
        BEGIN
            -- format('%I') quotes the identifier; combined with the regex guard
            -- above this makes DDL injection impossible.
            EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', s);
            n := n + 1;
        EXCEPTION WHEN OTHERS THEN
            -- Best-effort posture preserved: one undroppable leaked schema
            -- warns and continues rather than failing the whole run.
            RAISE WARNING 'could not drop schema %: %', s, SQLERRM;
        END;
    END LOOP;
    RAISE NOTICE 'DROPPED_COUNT:%', n;
END $$;

DELETE FROM public.tenant_schemas WHERE schema_name <> 'tenant_default';
DELETE FROM public.schema_migrations
 WHERE schema_name <> 'tenant_default' AND schema_name <> 'public';

COMMIT;
"""

    result = run_psql_script(script)

    # Lock acquisition / connection failure: the sweep could not establish
    # exclusivity, so proceeding would be exactly the unguarded behaviour being
    # removed here. Abort non-zero, following the precedent set by the initial
    # TRUNCATE failure path in main().
    if result.returncode != 0:
        print(
            "ERROR: orphaned-tenant-schema sweep failed under the migrations advisory "
            f"lock; aborting integration run: {result.stderr.strip()}",
            file=sys.stderr,
        )
        sys.exit(1)

    combined = (result.stdout or "") + (result.stderr or "")

    for line in combined.splitlines():
        if line.startswith("SKIPPED:"):
            print(
                f"WARNING: skipping unexpected tenant schema name: {line[len('SKIPPED:'):]!r}",
                file=sys.stderr,
            )

    dropped = 0
    for line in combined.splitlines():
        marker = "DROPPED_COUNT:"
        if marker in line:
            try:
                dropped = int(line.split(marker, 1)[1].strip())
            except ValueError:
                pass

    for line in combined.splitlines():
        if "could not drop schema" in line:
            print(f"WARNING: {line.strip()}", file=sys.stderr)

    # Diagnostic output line retained verbatim: the ISS-0148 smoking-gun analysis
    # depended on it, and CLAUDE.md forbids removing or rewording output to make
    # a gate stop matching.
    print(f"Dropped {dropped} orphaned tenant schema(s).", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Clean test database")
    parser.add_argument(
        "--include-fixtures",
        action="store_true",
        help=(
            "Drop leaked LEGACY_RLS fixture tenant rows whose tenant_type "
            "defaults to 'production' because the harness pre-dates GBL-080 "
            "(or default-seeded without an explicit tenant_type). Off by "
            "default — only set this on operator-initiated cleanup of a "
            "contaminated db_test; do not set it in a baseline-clean CI run."
        ),
    )
    args = parser.parse_args()

    global _DIRECT_DB_URL
    _DIRECT_DB_URL = os.environ.get("BPM_TEST_DB_URL") or None
    if _DIRECT_DB_URL:
        print("Cleaning test database (direct BPM_TEST_DB_URL connection)...", flush=True)
    else:
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
    # GH-402: TRUNCATE on tenant_default.* tables hangs indefinitely due to
    # long-running transaction or lock. Skipped for now; per-test cleanup handles isolation.
    # TODO: Investigate the root cause and re-enable after fixing the underlying issue.
    # Original code for reference:
    # TENANT_SCHEMAS = ["tenant_default"]
    # TENANT_TABLES = [...]
    # for schema in TENANT_SCHEMAS:
    #     run_psql(f"SET search_path TO {schema},public; TRUNCATE TABLE {tenant_tables_str} CASCADE")
    TENANT_TABLES = [
        "instance_definition_snapshots",
        "tasks",
        "timers",
        "instance_projections",
        "variable_schemas",
        "process_definitions",
        "events",
    ]
    # GH-402: Skip tenant-schema TRUNCATE due to indefinite hang
    # TODO(GH-402): Investigate why TRUNCATE on tenant_default.* tables blocks indefinitely
    # (likely long-running transaction or lock). For now, rely on per-test cleanup.
    # for schema in TENANT_SCHEMAS:
    #     print(f"GH-402 DEBUG: Cleaning tenant schema: {schema}", flush=True)
    #     tenant_tables_str = ", ".join(TENANT_TABLES)
    #     run_psql(
    #         f"SET search_path TO {schema},public; "
    #         f"TRUNCATE TABLE {tenant_tables_str} CASCADE"
    #     )
    #     print(f"GH-402 DEBUG: Finished cleaning tenant schema: {schema}", flush=True)

    # Clean tenant rows created by integration tests.
    # ENV-01 added ON DELETE RESTRICT: test tenants must be deleted BEFORE production tenants.
    # Use two-step DELETE to avoid FK violation (test tenant references production tenant).
    # The default system tenant (slug = 'default') is preserved.
    run_psql("DELETE FROM public.tenant WHERE tenant_type = 'test' AND slug != 'default'")
    run_psql("DELETE FROM public.tenant WHERE tenant_type = 'production' AND slug != 'default'")

    # GH-443 (ISS-0140): provisionTenantSchema() (src/db/provisioning.zig) writes
    # the public.tenant row (storage_mode='SCHEMA', Step 6a) in a separate
    # statement AFTER bpm_provision_tenant_schema() + tenant_schemas registration
    # (Step 4). A test run that races against this cleanup sweep (or is
    # killed/times out between steps) can leave a public.tenant row claiming
    # storage_mode='SCHEMA' with no corresponding tenant_schemas row and no
    # Postgres schema ever created. The sweep above only removes rows by
    # tenant_type/slug, so this half-provisioned row survives every cleanup and
    # trips verify_schema_baseline.py's check_tenant_schemas_consistent forever.
    # Delete any SCHEMA-mode tenant row with no matching tenant_schemas entry —
    # it is never a fully-provisioned tenant, so it is always safe to remove.
    run_psql(
        "DELETE FROM public.tenant t WHERE t.storage_mode = 'SCHEMA' "
        "AND t.slug != 'default' "
        "AND NOT EXISTS (SELECT 1 FROM public.tenant_schemas ts WHERE ts.tenant_id = t.id)"
    )

    # ISS-0090: drop orphaned per-tenant schemas (tests that crash, time out, or
    # get killed mid-run skip their `defer cleanupTenant()` and leak a real
    # Postgres schema + a public.tenant_schemas row). Sweep every registered
    # schema except tenant_default, which is the harness's persistent fixture.
    drop_orphaned_tenant_schemas()

    # ISS-0112 (GitHub #375): optional --include-fixtures sweep. Drops leaked
    # LEGACY_RLS fixture tenant rows that pre-date GBL-080's tenant_type
    # column (or were seeded without an explicit tenant_type), plus their
    # dependent Postgres schemas. Off by default to preserve CI's baseline-
    # clean default. Operator-initiated cleanup only.
    if args.include_fixtures:
        print("--include-fixtures: dropping leaked LEGACY_RLS fixture tenants...", flush=True)
        run_psql(
            "DELETE FROM public.tenant WHERE "
            "slug LIKE 'tc-%' OR slug LIKE 'svc%' OR slug LIKE 'env%' OR "
            "slug LIKE 'exp%' OR slug LIKE 'adp%' OR slug LIKE 'webhook%' OR "
            "slug = 'legacy-fixture'"
        )
        run_psql(
            "DELETE FROM public.tenant WHERE "
            "storage_mode='LEGACY_RLS' AND tenant_type='test'"
        )
        # Re-sweep schemas the fixture rows left behind.
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
