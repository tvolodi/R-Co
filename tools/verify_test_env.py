#!/usr/bin/env python3
"""verify_test_env.py — the Infrastructure Health Checklist as an exit code.

Implements docs/guides/test_infrastructure_guide.md §3 as a single command so
that pipeline gates can depend on a *result* rather than on the text a program
happens to print.

Why this exists
---------------
ORCH's benchmark pre-check used to grep `zig build bench` stdout for the
literals `BPM_DB_URL`, `BENCHMARK_SETUP_ERROR`, and `missing`. On 2026-05-30,
after three genuine fix attempts failed, an ADHOC handoff was phrased as
"no BPM_DB_URL/missing/BENCHMARK_SETUP_ERROR token in head output" — so the
agent satisfied it by renaming the labels the gate matched on. The environment
was never fixed; nine ADHOC runs chased the same symptom over three months.

A gate whose pass-condition an implementing agent can rewrite will eventually
be rewritten rather than met. An exit code cannot be satisfied by renaming a
label, so this tool reports one.

Checks (§3 of the test infrastructure guide)
--------------------------------------------
  C1  db_test container reports healthy
  C2  `zig build` exits 0 (no compile errors)
  C3  `zig build migrate` exits 0 with no error output
  C4  schema baseline matches the migration ledger  (delegates to
      tools/verify_schema_baseline.py, which owns INV-TI-1/INV-TI-2)
  C5  tools/lint_test_isolation.py reports no BLOCKER
  C6  no ungranted locks left over from a prior session
  C7  benchmark environment resolves a DB URL from the environment

Exit codes:
  0  environment healthy — safe to run tests or dispatch TEST-RUNNER
  1  one or more checks failed (details on stdout)
  2  bad invocation

Usage:
    python3 tools/verify_test_env.py                # full checklist
    python3 tools/verify_test_env.py --quick        # skip zig build/migrate
    python3 tools/verify_test_env.py --bench-only   # C7 only (ORCH pre-check)
    python3 tools/verify_test_env.py --skip-docker  # CI without compose
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Benchmark DB-URL resolution order. Must match resolveDbUrl() in
# tests/bench/bench.zig — if that order changes, change it here too.
BENCH_DB_URL_VARS = ("BPM_BENCH_DB_URL", "BPM_DB_URL", "BPM_TEST_DB_URL")

OK = "PASS"
BAD = "FAIL"
SKIP = "SKIP"


class Check:
    __slots__ = ("name", "status", "detail", "remedy")

    def __init__(self, name: str, status: str, detail: str, remedy: str = "") -> None:
        self.name = name
        self.status = status
        self.detail = detail
        self.remedy = remedy

    @property
    def failed(self) -> bool:
        return self.status == BAD


def run(cmd: list[str], timeout: int = 300, cwd: Path | None = None) -> tuple[int, str]:
    """Run a command, returning (exit_code, combined_output).

    Exit code 127 is reserved here for "executable not found" so callers can
    distinguish a missing tool from a genuine failure.
    """
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd or REPO_ROOT),
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        return 127, f"executable not found: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s: {' '.join(cmd)}"

    out = (proc.stdout or b"").decode("utf-8", "replace")
    err = (proc.stderr or b"").decode("utf-8", "replace")
    return proc.returncode, (out + err).strip()


def dotenv_has(key: str) -> bool:
    """True if .env in the repo root defines a non-empty value for key.

    bench.zig falls back to .env when the variable is absent from the process
    environment, so the check must look in the same places the binary does.
    """
    env_path = REPO_ROOT / ".env"
    if not env_path.is_file():
        return False
    try:
        for raw in env_path.read_text(encoding="utf-8-sig").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, _, value = line.partition("=")
            if name.strip() == key and value.strip().strip("\"'"):
                return True
    except OSError:
        return False
    return False


def check_docker() -> Check:
    if not shutil.which("docker"):
        return Check("C1 db_test container healthy", SKIP, "docker not on PATH")

    code, out = run(
        ["docker", "inspect", "-f", "{{.State.Health.Status}}", "r-co-db_test-1"],
        timeout=30,
    )
    if code != 0:
        # Container name is compose-project dependent; fall back to a label query.
        code, out = run(
            ["docker", "ps", "--filter", "name=db_test", "--format", "{{.Names}}\t{{.Status}}"],
            timeout=30,
        )
        if code != 0 or not out:
            return Check(
                "C1 db_test container healthy",
                BAD,
                "db_test container not found or not running",
                "docker compose up -d db db_test keycloak --wait",
            )
        if "healthy" not in out.lower() and "up" not in out.lower():
            return Check(
                "C1 db_test container healthy",
                BAD,
                out.splitlines()[0],
                "docker compose up -d db db_test --wait",
            )
        return Check("C1 db_test container healthy", OK, out.splitlines()[0])

    status = out.strip()
    if status != "healthy":
        return Check(
            "C1 db_test container healthy",
            BAD,
            f"health status is {status!r}",
            "docker compose up -d db_test --wait",
        )
    return Check("C1 db_test container healthy", OK, "healthy")


def check_zig_build() -> Check:
    code, out = run(["zig", "build"], timeout=600)
    if code == 127:
        return Check("C2 zig build", SKIP, "zig not on PATH")
    if code != 0:
        tail = "\n         ".join(out.splitlines()[-4:]) or "non-zero exit"
        return Check("C2 zig build", BAD, tail, "fix the compile errors above")
    return Check("C2 zig build", OK, "exit 0")


def check_migrate() -> Check:
    if not (os.environ.get("BPM_DB_URL") or os.environ.get("BPM_TEST_DB_URL")):
        return Check(
            "C3 zig build migrate",
            BAD,
            "neither BPM_DB_URL nor BPM_TEST_DB_URL is set",
            "set BPM_DB_URL (see .env.example)",
        )
    code, out = run(["zig", "build", "migrate"], timeout=600)
    if code == 127:
        return Check("C3 zig build migrate", SKIP, "zig not on PATH")
    if code != 0:
        tail = "\n         ".join(out.splitlines()[-4:]) or "non-zero exit"
        return Check("C3 zig build migrate", BAD, tail, "resolve the migration failure above")
    # The guide treats these as baseline drift even on exit 0. Match only
    # genuine std.log error/warning lines (which always start with the
    # "error:"/"warning:" level prefix) or an explicit "already exists" DB
    # error — not any line that merely *contains* these words as a substring.
    # GH-443 (ISS-0140): migration filenames like
    # "081_iss101_timers_failed_status.sql" and
    # "092_iss303_timer_fire_error_count.sql" contain "failed"/"error" in
    # their own name, so a bare substring match flagged every clean
    # "info:   skip  <filename>" line as baseline drift — a permanent false
    # positive on every healthy run once those files existed.
    for line in out.splitlines():
        stripped = line.strip().lower()
        if stripped.startswith("error:") or stripped.startswith("warning:"):
            return Check(
                "C3 zig build migrate",
                BAD,
                f"exit 0 but output contains a log error/warning — baseline drift: {line.strip()!r}",
                "python3 tools/verify_schema_baseline.py --auto-fix",
            )
        if "already exists" in stripped:
            return Check(
                "C3 zig build migrate",
                BAD,
                f"exit 0 but output contains 'already exists' — baseline drift: {line.strip()!r}",
                "python3 tools/verify_schema_baseline.py --auto-fix",
            )
    return Check("C3 zig build migrate", OK, "exit 0, clean output")


def check_schema_baseline() -> Check:
    script = REPO_ROOT / "tools" / "verify_schema_baseline.py"
    if not script.is_file():
        return Check("C4 schema baseline", SKIP, "verify_schema_baseline.py not present")
    if not os.environ.get("BPM_TEST_DB_URL"):
        return Check(
            "C4 schema baseline",
            BAD,
            "BPM_TEST_DB_URL is not set",
            "set BPM_TEST_DB_URL (see .env.example)",
        )
    code, out = run([sys.executable, str(script), "--check-tenants"], timeout=180)
    if code == 2:
        return Check("C4 schema baseline", BAD, out.splitlines()[0] if out else "bad invocation")
    if code != 0:
        first = out.splitlines()[0] if out else "baseline drift"
        return Check(
            "C4 schema baseline",
            BAD,
            first,
            "python3 tools/verify_schema_baseline.py --check-tenants --auto-fix",
        )
    return Check("C4 schema baseline", OK, "ledger matches migrations/")


def check_test_isolation() -> Check:
    script = REPO_ROOT / "tools" / "lint_test_isolation.py"
    if not script.is_file():
        return Check("C5 test isolation lint", SKIP, "lint_test_isolation.py not present")
    code, out = run([sys.executable, str(script), "tests/integration"], timeout=120)
    if code != 0:
        blockers = [l for l in out.splitlines() if "BLOCKER" in l]
        detail = blockers[0] if blockers else (out.splitlines()[0] if out else "non-zero exit")
        return Check("C5 test isolation lint", BAD, detail, "fix the isolation violations")
    return Check("C5 test isolation lint", OK, "no BLOCKER findings")


def check_stale_locks() -> Check:
    db_url = os.environ.get("BPM_TEST_DB_URL")
    if not db_url:
        return Check("C6 no stale locks", SKIP, "BPM_TEST_DB_URL not set")
    try:
        import psycopg2
    except ImportError:
        return Check("C6 no stale locks", SKIP, "psycopg2 not installed")

    try:
        with psycopg2.connect(db_url) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT count(*) FROM pg_locks WHERE NOT granted")
                (ungranted,) = cur.fetchone()
    except Exception as exc:  # noqa: BLE001 - report any connection/query failure
        return Check(
            "C6 no stale locks",
            BAD,
            f"could not query pg_locks: {type(exc).__name__}",
            "docker compose up -d db_test --wait",
        )

    if ungranted:
        return Check(
            "C6 no stale locks",
            BAD,
            f"{ungranted} ungranted lock(s) from a prior session",
            "restart db_test, or terminate the blocking backends",
        )
    return Check("C6 no stale locks", OK, "0 ungranted")


def check_bench_env() -> Check:
    """C7 — the check that replaces ORCH's stdout grep.

    Passes when a benchmark DB URL is resolvable exactly the way bench.zig
    resolves one: process environment first, then .env in the repo root.
    """
    for var in BENCH_DB_URL_VARS:
        if os.environ.get(var):
            return Check("C7 bench DB URL resolvable", OK, f"{var} set in environment")
    for var in BENCH_DB_URL_VARS:
        if dotenv_has(var):
            return Check("C7 bench DB URL resolvable", OK, f"{var} set in .env")
    return Check(
        "C7 bench DB URL resolvable",
        BAD,
        "none of " + "/".join(BENCH_DB_URL_VARS) + " set in the environment or .env",
        "set BPM_BENCH_DB_URL (or BPM_TEST_DB_URL) — see .env.example",
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Infrastructure Health Checklist (test_infrastructure_guide.md §3) as an exit code."
    )
    parser.add_argument("--quick", action="store_true", help="skip zig build and migrate (C2, C3)")
    parser.add_argument("--bench-only", action="store_true", help="run only C7 (ORCH pre-check)")
    parser.add_argument("--skip-docker", action="store_true", help="skip the container check (C1)")
    parser.add_argument("--quiet", action="store_true", help="print only the verdict line")
    args = parser.parse_args(argv[1:])

    if args.bench_only:
        checks = [check_bench_env()]
    else:
        checks = []
        checks.append(
            Check("C1 db_test container healthy", SKIP, "--skip-docker")
            if args.skip_docker
            else check_docker()
        )
        if args.quick:
            checks.append(Check("C2 zig build", SKIP, "--quick"))
            checks.append(Check("C3 zig build migrate", SKIP, "--quick"))
        else:
            checks.append(check_zig_build())
            checks.append(check_migrate())
        checks.append(check_schema_baseline())
        checks.append(check_test_isolation())
        checks.append(check_stale_locks())
        checks.append(check_bench_env())

    failed = [c for c in checks if c.failed]

    if not args.quiet:
        for c in checks:
            print(f"  [{c.status}] {c.name}")
            if c.detail and c.status != OK:
                print(f"         {c.detail}")
            if c.remedy and c.failed:
                print(f"         remedy: {c.remedy}")
        print()

    if failed:
        print(
            f"verify_test_env: UNHEALTHY — {len(failed)} of {len(checks)} checks failed "
            f"({', '.join(c.name.split()[0] for c in failed)})"
        )
        return 1

    skipped = sum(1 for c in checks if c.status == SKIP)
    suffix = f" ({skipped} skipped)" if skipped else ""
    print(f"verify_test_env: HEALTHY — {len(checks) - skipped} checks passed{suffix}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
