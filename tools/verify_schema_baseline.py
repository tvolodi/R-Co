#!/usr/bin/env python3
"""verify_schema_baseline.py — enforce INV-TI-1 / INV-TI-2 invariants on the
shared db_test database.

Implements docs/guides/test_infrastructure_guide.md §6.
Required by docs/guides/test_infrastructure_guide.md §3 (Infrastructure Health
Checklist) for every zig build test-integration invocation.

Exit codes:
  0  baseline healthy
  1  baseline drift detected (print offending query + offending row count)
  2  bad invocation / missing BPM_TEST_DB_URL

CLI flags:
  --check-tenants   Strict mode: also verify every public.tenant row maps
                    to an existing Postgres schema.
  --auto-fix        On drift, attempt a one-shot auto-reconcile by re-emitting
                    the GBL-105 ledger reconcile SQL. Backed by the change-2
                    applier guard.
  --migrations-dir  Override the migrations directory (default: ./migrations).
  --db-url          Override the database URL (default: $BPM_TEST_DB_URL).
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Iterable, Optional

try:
    import psycopg2
except ImportError:  # pragma: no cover - defensive
    print("ERROR: psycopg2 is required. pip install psycopg2-binary", file=sys.stderr)
    sys.exit(2)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MIGRATIONS_DIR = REPO_ROOT / "migrations"


def get_migration_files(migrations_dir: Path) -> list[str]:
    """Return the sorted list of *.sql filenames in migrations_dir."""
    if not migrations_dir.is_dir():
        print(
            f"ERROR: migrations directory does not exist: {migrations_dir}",
            file=sys.stderr,
        )
        sys.exit(2)
    return sorted(p.name for p in migrations_dir.glob("*.sql"))


def connect(db_url: str):
    """Connect to Postgres with autocommit (read-mostly) and return a connection."""
    return psycopg2.connect(db_url)


def fetch_scalar(conn, sql: str, params: Optional[Iterable] = None) -> Optional[int]:
    """Execute SQL, return first column of first row as int (or None)."""
    with conn.cursor() as cur:
        cur.execute(sql, params or ())
        row = cur.fetchone()
        if not row:
            return None
        return int(row[0])


def fetch_rows(conn, sql: str, params: Optional[Iterable] = None) -> list[tuple]:
    """Execute SQL, return all rows as list[tuple]."""
    with conn.cursor() as cur:
        cur.execute(sql, params or ())
        return list(cur.fetchall())


def check_migration_ledger_count(conn, migration_files: list[str]) -> tuple[bool, str]:
    """Compare count(public.schema_migrations WHERE schema_name='public') to
    on-disk migrations/*.sql file count."""
    n = fetch_scalar(
        conn,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name='public'",
    )
    ledger_count = n if n is not None else 0
    file_count = len(migration_files)
    if ledger_count != file_count:
        return False, (
            f"public.schema_migrations has {ledger_count} rows for schema_name='public', "
            f"but migrations/ contains {file_count} *.sql files (delta = {ledger_count - file_count})"
        )
    return True, f"ledger row count = {ledger_count} == files count = {file_count}"


def check_per_migration_row_present(conn, migration_files: list[str]) -> list[str]:
    """Return list of migrations/*.sql filenames with no public row. Empty list = pass."""
    missing: list[str] = []
    for filename in migration_files:
        # Filenames come from on-disk and we trust ourselves, but defend against
        # injection by validating the filename.
        if (
            "'" in filename
            or ";" in filename
            or "--" in filename
            or "/" in filename
            or "\\" in filename
        ):
            print(f"WARN: skipping suspicious filename {filename!r}", file=sys.stderr)
            continue
        sql = (
            "SELECT count(*) FROM public.schema_migrations "
            "WHERE schema_name='public' AND version=%s"
        )
        n = fetch_scalar(conn, sql, (filename,))
        if n is None or n == 0:
            missing.append(filename)
    return missing


def check_tenant_schemas_consistent(conn) -> list[str]:
    """For each public.tenant row whose storage_mode='SCHEMA', verify the
    expected Postgres schema exists. Returns list of missing schema names.
    Empty list = pass."""
    rows = fetch_rows(
        conn,
        "SELECT id, storage_mode FROM public.tenant WHERE storage_mode='SCHEMA'",
    )
    missing: list[str] = []
    for tenant_id, _storage_mode in rows:
        tenant_id_s = str(tenant_id)
        if tenant_id_s == "00000000-0000-0000-0000-000000000000":
            schema_name = "tenant_default"
        else:
            schema_name = "tenant_" + tenant_id_s.replace("-", "")
        n = fetch_scalar(
            conn,
            "SELECT 1 FROM information_schema.schemata WHERE schema_name=%s",
            (schema_name,),
        )
        if n is None or n == 0:
            missing.append(f"{tenant_id_s} -> {schema_name}")
    return missing


def check_expected_check_constraints(conn) -> list[str]:
    """Verify the expected-by-tests CHECK constraints exist:
    webhook_deliveries_status_check, tenant_storage_mode_check.
    Returns list of missing constraint names. Empty list = pass."""
    expected = ["webhook_deliveries_status_check", "tenant_storage_mode_check"]
    missing: list[str] = []
    for cname in expected:
        n = fetch_scalar(conn, "SELECT count(*) FROM pg_constraint WHERE conname=%s", (cname,))
        if n is None or n == 0:
            missing.append(cname)
    return missing


def auto_fix(db_url: str, migrations_dir: Path) -> None:
    """Best-effort auto-reconcile. Re-applies GBL-105."""
    gbl_path = migrations_dir / "GBL-105_iss0112_schema_ledger_reconcile.sql"
    if not gbl_path.is_file():
        print(f"ERROR: {gbl_path} not found; cannot auto-fix", file=sys.stderr)
        return
    sql = gbl_path.read_text(encoding="utf-8")
    try:
        with psycopg2.connect(db_url) as conn:
            with conn.cursor() as cur:
                cur.execute(sql)
            conn.commit()
        print("auto-fix GBL-105 applied")
    except Exception as exc:  # noqa: BLE001
        print(f"auto-fix GBL-105 failed: {exc}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--check-tenants",
        action="store_true",
        help=(
            "Strict mode: also verify every public.tenant row maps to an "
            "existing Postgres schema."
        ),
    )
    parser.add_argument(
        "--auto-fix",
        action="store_true",
        help="On drift, attempt a one-shot auto-reconcile via GBL-105.",
    )
    parser.add_argument(
        "--migrations-dir",
        default=str(DEFAULT_MIGRATIONS_DIR),
        help=f"Override the migrations directory (default: {DEFAULT_MIGRATIONS_DIR})",
    )
    parser.add_argument(
        "--db-url",
        default=os.environ.get("BPM_TEST_DB_URL"),
        help="Override the database URL (default: $BPM_TEST_DB_URL)",
    )
    args = parser.parse_args()

    if not args.db_url:
        print("ERROR: BPM_TEST_DB_URL is required (or pass --db-url)", file=sys.stderr)
        return 2

    migrations_dir = Path(args.migrations_dir)
    migration_files = get_migration_files(migrations_dir)

    failures: list[str] = []

    try:
        with connect(args.db_url) as conn:
            ok, msg = check_migration_ledger_count(conn, migration_files)
            print(f"[{'OK' if ok else 'FAIL'}] check_migration_ledger_count: {msg}")
            if not ok:
                failures.append(msg)

            missing = check_per_migration_row_present(conn, migration_files)
            if missing:
                msg = (
                    f"missing ledger rows for {len(missing)} migration file(s): "
                    f"{missing[:5]}{'...' if len(missing) > 5 else ''}"
                )
                print(f"[FAIL] check_per_migration_row_present: {msg}")
                failures.append(msg)
            else:
                print(
                    f"[OK] check_per_migration_row_present: all "
                    f"{len(migration_files)} migrations have a ledger row"
                )

            if args.check_tenants:
                missing_schemas = check_tenant_schemas_consistent(conn)
                if missing_schemas:
                    msg = (
                        f"missing Postgres schemas for {len(missing_schemas)} tenant(s): "
                        f"{missing_schemas[:5]}{'...' if len(missing_schemas) > 5 else ''}"
                    )
                    print(f"[FAIL] check_tenant_schemas_consistent: {msg}")
                    failures.append(msg)
                else:
                    print(
                        "[OK] check_tenant_schemas_consistent: "
                        "all SCHEMA-mode tenants have a Postgres schema"
                    )

            missing_constraints = check_expected_check_constraints(conn)
            if missing_constraints:
                msg = f"missing CHECK constraint(s): {missing_constraints}"
                print(f"[FAIL] check_expected_check_constraints: {msg}")
                failures.append(msg)
            else:
                print(
                    "[OK] check_expected_check_constraints: "
                    "webhook_deliveries_status_check + tenant_storage_mode_check present"
                )
    except psycopg2.OperationalError as exc:
        print(f"ERROR: could not connect to {args.db_url}: {exc}", file=sys.stderr)
        return 2

    if failures and args.auto_fix:
        print("\n--auto-fix requested; re-applying GBL-105...", flush=True)
        auto_fix(args.db_url, migrations_dir)
        # Re-run checks once after the fix.
        print("\nRe-running checks after auto-fix...")
        return main()

    if failures:
        print(f"\nFAIL: {len(failures)} drift condition(s) detected.", file=sys.stderr)
        return 1

    print("\nAll baseline checks PASS.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
