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
  C0  the resolved DB URLs are the intended ones (ISS-0180)
  C1  db_test container reports healthy AND publishes BPM_TEST_DB_URL's port
  C2  `zig build` exits 0 (no compile errors)
  C3  `zig build migrate` exits 0 against the TEST database, and that database's
      migration ledger is then complete
  C4  schema baseline matches the migration ledger  (delegates to
      tools/verify_schema_baseline.py, which owns INV-TI-1/INV-TI-2)
  C5  tools/lint_test_isolation.py reports no BLOCKER
  C6  no ungranted locks left over from a prior session
  C7  benchmark environment resolves a DB URL from the environment

One checklist, one database (ISS-0180 / GH #511)
------------------------------------------------
Every check that touches a database must touch *the database the tests use* —
the one named by BPM_TEST_DB_URL. Before ISS-0180 the checklist did not agree
with itself about this: C3 ran a bare `zig build migrate`, and
src/tools/migrate.zig resolves its target from BPM_DB_URL alone (the
development database), while C4, C6 and every integration test read
BPM_TEST_DB_URL. In the normal configuration those are two different
databases, so C3 could report PASS having migrated a database that C4 never
inspects and no test ever opens — a false green on a hard gate. It was observed
directly: C3 PASS and C4 FAIL in the same run, on the same workspace.

C3 therefore overrides BPM_DB_URL *in the child process only* for the duration
of the migrate call, and then asserts the test database's ledger is complete.
migrate.zig's own contract (read BPM_DB_URL) is deliberately left alone: it is
also the production bootstrap path, and changing which variable it honours to
fix a test-gate defect would move the problem rather than solve it.

C1 likewise verifies that the container it inspected is the one BPM_TEST_DB_URL
addresses, by comparing published ports — a container merely *named* db_test
may belong to a different workspace on the same host.

Environment resolution
----------------------
Every check resolves BPM_DB_URL / BPM_TEST_DB_URL / BPM_BENCH_DB_URL the way
the rest of the toolchain does: the process environment first, then `.env` in
the repo root (bench.zig's resolveDbUrl order). Values found only in `.env` are
exported into os.environ before any check runs, because the subprocesses these
checks spawn — `zig build migrate`, verify_schema_baseline.py — read their own
environment and do not parse `.env` themselves.

This resolves *where* configuration is read from. It does not supply defaults:
a variable absent from both the environment and `.env` stays absent, and the
check that requires it still fails.

Because the process environment wins, a stale BPM_TEST_DB_URL inherited from a
sibling checkout silently retargets the whole checklist at another workspace's
database. C0 exists to make that visible: it prints the URLs actually in force
(credentials redacted) before any check runs.

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
from urllib.parse import urlsplit

REPO_ROOT = Path(__file__).resolve().parent.parent

# Benchmark DB-URL resolution order. Must match resolveDbUrl() in
# tests/bench/bench.zig — if that order changes, change it here too.
BENCH_DB_URL_VARS = ("BPM_BENCH_DB_URL", "BPM_DB_URL", "BPM_TEST_DB_URL")

# Variables the checks (and the subprocesses they spawn) resolve from the
# process environment, falling back to .env. See load_dotenv_into_environ().
DOTENV_KEYS = ("BPM_DB_URL", "BPM_TEST_DB_URL", "BPM_BENCH_DB_URL")

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


def run(
    cmd: list[str],
    timeout: int = 300,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> tuple[int, str]:
    """Run a command, returning (exit_code, combined_output).

    Exit code 127 is reserved here for "executable not found" so callers can
    distinguish a missing tool from a genuine failure.

    `env`, when given, fully replaces the child's environment (callers pass a
    copy of os.environ with specific keys overridden). C3 uses this to point
    `zig build migrate` at BPM_TEST_DB_URL without disturbing this process's
    own environment, which C4 and C6 still read.
    """
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd or REPO_ROOT),
            capture_output=True,
            timeout=timeout,
            check=False,
            env=env,
        )
    except FileNotFoundError:
        return 127, f"executable not found: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s: {' '.join(cmd)}"

    out = (proc.stdout or b"").decode("utf-8", "replace")
    err = (proc.stderr or b"").decode("utf-8", "replace")
    return proc.returncode, (out + err).strip()


def dotenv_get(key: str) -> str | None:
    """Value of key from .env in the repo root, or None if absent/empty.

    bench.zig falls back to .env when the variable is absent from the process
    environment (see readDotEnvValue/parseDotEnvValue in tests/bench/bench.zig),
    so the checks must look in the same places the binaries do — and parse the
    file the same way: skip blanks and `#` comments, split on the first `=`,
    strip surrounding whitespace, then strip one layer of matching quotes.
    """
    env_path = REPO_ROOT / ".env"
    if not env_path.is_file():
        return None
    try:
        contents = env_path.read_text(encoding="utf-8-sig")
    except OSError:
        return None
    for raw in contents.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, value = line.partition("=")
        if name.strip() != key:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        return value or None
    return None


def load_dotenv_into_environ(keys: tuple[str, ...]) -> list[str]:
    """Populate os.environ from .env for keys the process environment lacks.

    ISS-0151 / GH #468: C3, C4 and C6 read only os.environ, so a workspace whose
    .env correctly defines BPM_DB_URL failed the gate unless the operator had
    manually exported it — while C7, which already consulted .env, passed. The
    gate therefore disagreed with itself about the same workspace.

    Loading .env here rather than teaching each check to call dotenv_get() is
    deliberate: `zig build migrate` (src/tools/migrate.zig) and
    tools/verify_schema_baseline.py are *subprocesses* that read BPM_DB_URL /
    BPM_TEST_DB_URL from their own process environment and do not read .env.
    A check that merely consulted .env itself would report PASS-able state and
    then still watch the subprocess die. Exporting into os.environ is what makes
    the child processes see the same configuration the checks do.

    Precedence matches bench.zig's resolveDbUrl(): the real process environment
    always wins; .env fills gaps only. Values genuinely absent from BOTH sources
    stay absent, so every check's failure path remains fully reachable — this
    resolves where configuration is read from, it does not weaken what is
    required. Returns the names actually loaded, for reporting.
    """
    loaded: list[str] = []
    for key in keys:
        if os.environ.get(key):
            continue
        value = dotenv_get(key)
        if value:
            os.environ[key] = value
            loaded.append(key)
    return loaded


def redact(url: str) -> str:
    """A DB URL with any password removed, safe to print in gate output.

    C0 prints the URLs the checklist resolved, so an operator can see which
    database is actually being certified. That is only usable if it can be
    printed without leaking a credential into CI logs.
    """
    parsed = urlsplit(url)
    if not parsed.hostname:
        return url
    userinfo = ""
    if parsed.username:
        userinfo = parsed.username + ("@" if not parsed.password else ":***@")
    port = f":{parsed.port}" if parsed.port else ""
    return f"{parsed.scheme}://{userinfo}{parsed.hostname}{port}{parsed.path}"


def db_identity(url: str) -> tuple[str, int | None, str]:
    """(host, port, database) for a DB URL — what makes two URLs the same DB.

    Compared rather than the raw strings so that cosmetic differences (a
    trailing query string, different credentials for the same database) do not
    hide the fact that two variables address one database.
    """
    parsed = urlsplit(url)
    return ((parsed.hostname or "").lower(), parsed.port, parsed.path.lstrip("/"))


def check_url_targets() -> Check:
    """C0 — the checklist states which databases it is about to verify.

    ISS-0180 / GH #511. Two failure modes, both of which make every later check
    untrustworthy rather than merely inconvenient:

      * BPM_TEST_DB_URL absent — C3/C4/C6 have no test database to verify, and
        before this check C3 would quietly fall back to migrating the dev
        database and report PASS anyway.

      * BPM_DB_URL and BPM_TEST_DB_URL naming the same host:port/database —
        a misconfiguration in its own right (integration tests would mutate the
        development database), and one that would additionally mask ISS-0180 by
        making C3's old dev-database behaviour accidentally correct.

    Printing the resolved URLs is the other half of the check. The process
    environment takes precedence over .env, so a stale value inherited from a
    sibling checkout retargets the entire checklist at a database the operator
    never intended — invisibly, until now.
    """
    dev_url = os.environ.get("BPM_DB_URL")
    test_url = os.environ.get("BPM_TEST_DB_URL")

    if not test_url:
        return Check(
            "C0 DB URL targets",
            BAD,
            "BPM_TEST_DB_URL is not set — the checklist has no test database to verify",
            "set BPM_TEST_DB_URL (see .env.example)",
        )

    if dev_url and db_identity(dev_url) == db_identity(test_url):
        return Check(
            "C0 DB URL targets",
            BAD,
            f"BPM_DB_URL and BPM_TEST_DB_URL both resolve to {redact(test_url)} — "
            "integration tests would run against the development database",
            "point BPM_TEST_DB_URL at the db_test container, not db (see .env.example)",
        )

    dev_label = redact(dev_url) if dev_url else "(unset)"
    return Check(
        "C0 DB URL targets",
        OK,
        f"test={redact(test_url)} dev={dev_label}",
    )


def compose_project_name() -> str:
    """This workspace's compose project, from the environment or .env.

    ISS-0180: the container name is `<project>-db_test-1`, and several checkouts
    of this repo can run side by side on one host under different project names
    (`.env` sets COMPOSE_PROJECT_NAME for exactly that reason). Hardcoding one
    project's container name means the check inspects a sibling workspace's
    container — or falls through to a name-substring match that accepts any of
    them.
    """
    return os.environ.get("COMPOSE_PROJECT_NAME") or dotenv_get("COMPOSE_PROJECT_NAME") or "r-co"


def container_publishes_port(name: str, port: int) -> bool:
    """True if the named container publishes `port` on the host.

    Uses `docker port`, whose output lists the host bindings for the container's
    exposed ports (e.g. "5432/tcp -> 0.0.0.0:5453").
    """
    code, out = run(["docker", "port", name], timeout=30)
    if code != 0:
        return False
    return any(binding.rsplit(":", 1)[-1].strip() == str(port) for binding in out.splitlines() if ":" in binding)


def check_docker() -> Check:
    """C1 — the db_test container is healthy AND is the one the tests connect to.

    ISS-0180: a container merely *named* db_test proves nothing on a host running
    several workspaces. After confirming health, this check confirms the
    container publishes the port in BPM_TEST_DB_URL, so C1 is talking about the
    same database as C3, C4 and C6.
    """
    if not shutil.which("docker"):
        return Check("C1 db_test container healthy", SKIP, "docker not on PATH")

    container = f"{compose_project_name()}-db_test-1"

    code, out = run(
        ["docker", "inspect", "-f", "{{.State.Health.Status}}", container],
        timeout=30,
    )
    if code != 0:
        # Compose v1 used underscores; fall back before giving up on the name.
        legacy = f"{compose_project_name()}_db_test_1"
        code, out = run(
            ["docker", "inspect", "-f", "{{.State.Health.Status}}", legacy],
            timeout=30,
        )
        if code != 0:
            return Check(
                "C1 db_test container healthy",
                BAD,
                f"container {container!r} not found (COMPOSE_PROJECT_NAME={compose_project_name()!r})",
                "docker compose up -d db db_test keycloak --wait",
            )
        container = legacy

    status = out.strip()
    if status != "healthy":
        return Check(
            "C1 db_test container healthy",
            BAD,
            f"{container}: health status is {status!r}",
            "docker compose up -d db_test --wait",
        )

    # The container is healthy — but is it the one BPM_TEST_DB_URL addresses?
    test_url = os.environ.get("BPM_TEST_DB_URL")
    if test_url:
        _, port, _ = db_identity(test_url)
        if port and not container_publishes_port(container, port):
            return Check(
                "C1 db_test container healthy",
                BAD,
                f"{container} is healthy but does not publish port {port} from "
                f"BPM_TEST_DB_URL ({redact(test_url)}) — the healthy container is not "
                "the database the tests connect to",
                "align COMPOSE_PROJECT_NAME and BPM_TEST_DB_URL's port (see .env)",
            )
        return Check("C1 db_test container healthy", OK, f"{container} healthy, publishes :{port}")

    return Check("C1 db_test container healthy", OK, f"{container} healthy")


def check_zig_build() -> Check:
    code, out = run(["zig", "build"], timeout=600)
    if code == 127:
        return Check("C2 zig build", SKIP, "zig not on PATH")
    if code != 0:
        tail = "\n         ".join(out.splitlines()[-4:]) or "non-zero exit"
        return Check("C2 zig build", BAD, tail, "fix the compile errors above")
    return Check("C2 zig build", OK, "exit 0")


def migration_file_count() -> int:
    """Number of *.sql files in migrations/ — the ledger's expected row count."""
    return len(list((REPO_ROOT / "migrations").glob("*.sql")))


def applied_migration_count(db_url: str) -> int | str:
    """Rows in public.schema_migrations for schema_name='public', or an error string."""
    try:
        import psycopg2
    except ImportError:
        return "psycopg2 not installed"
    try:
        with psycopg2.connect(db_url) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT count(*) FROM public.schema_migrations WHERE schema_name = 'public'"
                )
                (count,) = cur.fetchone()
                return int(count)
    except Exception as exc:  # noqa: BLE001 - report any connection/query failure
        return f"{type(exc).__name__}: {exc}".strip()


def check_migrate() -> Check:
    """C3 — the TEST database is fully migrated.

    ISS-0180 / GH #511. Two things changed here, and neither relaxes anything:

    1. `zig build migrate` is invoked with BPM_DB_URL overridden to
       BPM_TEST_DB_URL *in the child environment only*. src/tools/migrate.zig
       resolves its target from BPM_DB_URL by contract and is also the
       production bootstrap path, so the variable is retargeted for this one
       call rather than the program being taught a new variable. Previously C3
       migrated the development database and reported PASS about it, while C4
       verified the test database — the two checks describing two different
       databases is what made a false green possible.

    2. Exit 0 is necessary but not sufficient. `migrate` exits 0 when there is
       nothing to do, which is exactly what it reported while the test database
       sat behind. C3 now compares the test database's ledger against
       migrations/ and fails naming the delta, so C3 detects the ISS-0180
       condition on its own instead of leaving it to C4.
    """
    test_url = os.environ.get("BPM_TEST_DB_URL")
    if not test_url:
        return Check(
            "C3 zig build migrate",
            BAD,
            "BPM_TEST_DB_URL is not set — cannot migrate the database the tests use",
            "set BPM_TEST_DB_URL (see .env.example)",
        )

    # Retarget the child process only; this process's own environment (and
    # therefore C4's and C6's view) is untouched.
    child_env = dict(os.environ)
    child_env["BPM_DB_URL"] = test_url

    code, out = run(["zig", "build", "migrate"], timeout=600, env=child_env)
    if code == 127:
        return Check("C3 zig build migrate", SKIP, "zig not on PATH")
    if code != 0:
        tail = "\n         ".join(out.splitlines()[-4:]) or "non-zero exit"
        return Check(
            "C3 zig build migrate",
            BAD,
            f"migrate failed against the test database ({redact(test_url)}):\n         {tail}",
            "resolve the migration failure above — it is a genuine migration error, "
            "not a wrong-database problem",
        )
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

    # ISS-0180: exit 0 only proves the runner did not crash. `migrate` exits 0
    # with "No new migrations to apply." whenever its target is current — which
    # is precisely what it reported while pointed at the development database
    # and the test database sat behind. Assert the ledger instead, so C3's PASS
    # is a statement about the test database rather than about a subprocess.
    expected = migration_file_count()
    applied = applied_migration_count(test_url)
    if isinstance(applied, str):
        return Check(
            "C3 zig build migrate",
            BAD,
            f"migrate exited 0 but the test database's ledger could not be read "
            f"({redact(test_url)}): {applied}",
            "confirm BPM_TEST_DB_URL points at a reachable db_test container",
        )
    if applied != expected:
        return Check(
            "C3 zig build migrate",
            BAD,
            f"migrate exited 0 but {redact(test_url)} has {applied} applied migration(s) "
            f"for schema_name='public' while migrations/ contains {expected} *.sql file(s) "
            f"(delta = {applied - expected}) — the test database is not fully migrated",
            "python3 tools/verify_schema_baseline.py --check-tenants --auto-fix",
        )

    return Check(
        "C3 zig build migrate",
        OK,
        f"exit 0, clean output, {applied}/{expected} applied on {redact(test_url)}",
    )


def check_schema_baseline() -> Check:
    # ISS-0605 / GH-537: C4 self-heal. Before delegating to
    # verify_schema_baseline.py --check-tenants, run the orphan-row DELETE
    # sweep that lives in tools/clean_test_db.py (lines 332-336, added by
    # ISS-0140 / GH-443). The clean_test_db sweep is the only path that
    # actually removes half-provisioned public.tenant rows with
    # storage_mode='SCHEMA' and no matching tenant_schemas entry; the
    # check_tenant_schemas_consistent() detector only reports them. Without
    # this pre-step, every C4 run since the orphans were created has failed
    # — see src/design/iss0605-test-env-c4-orphan-selfheal.md §3.1.
    pre_step = _run_clean_test_db_sweep()
    if pre_step.failed:
        return pre_step
    # SKIP is informational, not fatal — the existing BPM_TEST_DB_URL / script
    # checks below will produce a clearer message in that case.

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


def _run_clean_test_db_sweep() -> Check:
    """Helper: invoke tools/clean_test_db.py in default mode as a sub-process.

    Used by C4 (check_schema_baseline) to remove orphan public.tenant rows
    before the verify_schema_baseline.py --check-tenants detector runs. The
    sweep is the DELETE at clean_test_db.py lines 332-336 (added by ISS-0140
    / GH-443) which this helper trusts verbatim — it is the canonical
    remediation.

    Returns a Check whose status reports PASS/FAIL/SKIP. Never raises; a
    non-zero exit returns a Check(BAD) with a one-line excerpt so the
    existing C4 detail printing carries the failure forward.

    The helper invokes clean_test_db.py in its DEFAULT mode (no
    --include-fixtures) — that flag is operator-curated and C4 must not flip
    it. Environment is inherited so BPM_TEST_DB_URL reaches the subprocess
    the same way every other test-gate subprocess reads it.
    """
    name = "C4 cleanup pre-step"
    script = REPO_ROOT / "tools" / "clean_test_db.py"
    if not script.is_file():
        return Check(name, SKIP, "clean_test_db.py not present")
    if not os.environ.get("BPM_TEST_DB_URL"):
        return Check(name, SKIP, "BPM_TEST_DB_URL not set")
    code, out = run([sys.executable, str(script)], timeout=120)
    if code != 0:
        first = out.splitlines()[0] if out else "non-zero exit"
        return Check(
            name,
            BAD,
            first,
            "python tools/clean_test_db.py — fix the cleanup failure above",
        )
    first = out.splitlines()[0] if out else "sweep exited 0"
    return Check(name, OK, first)


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

    ISS-0180: that precedence prefers BPM_DB_URL over BPM_TEST_DB_URL, which is
    bench.zig's own documented contract and is deliberately left unchanged here
    — a gate must mirror the behaviour it is checking, not a preferred one. What
    did change is that C7 now names the resolved URL as well as the variable, so
    an operator can see which database the benchmark will actually use instead
    of inferring it from a variable name.
    """
    for var in BENCH_DB_URL_VARS:
        value = os.environ.get(var)
        if value:
            return Check(
                "C7 bench DB URL resolvable",
                OK,
                f"{var} set in environment → {redact(value)}",
            )
    for var in BENCH_DB_URL_VARS:
        value = dotenv_get(var)
        if value:
            return Check(
                "C7 bench DB URL resolvable",
                OK,
                f"{var} set in .env → {redact(value)}",
            )
    return Check(
        "C7 bench DB URL resolvable",
        BAD,
        "none of " + "/".join(BENCH_DB_URL_VARS) + " set in the environment or .env",
        "set BPM_BENCH_DB_URL (or BPM_TEST_DB_URL) — see .env.example",
    )


def check_tenant_provisioning_lint() -> Check:
    """C8 — lint guard against the orphan-tenant INSERT pattern.

    ISS-0605 / GH-537: every test that inserts or UPDATEs public.tenant with
    storage_mode='SCHEMA' must co-locate a provisionTenantSchema() (or
    bpm_provision_tenant_schema()) call in the same test block. Otherwise a
    test that crashes mid-run leaves a half-provisioned row claiming a Postgres
    schema that was never created — the same defect class as ISS-0140 / GH-443,
    recurring. tools/lint_test_tenant_provisioning.py is the prevention layer
    that catches this statically; this check wires it into the gate.

    The lint is a static check — it does not touch the database, so it runs
    cheaply after the DB-touching checks (C0-C7) and never delays them.
    """
    script = REPO_ROOT / "tools" / "lint_test_tenant_provisioning.py"
    if not script.is_file():
        return Check(
            "C8 tenant provisioning lint",
            SKIP,
            "lint_test_tenant_provisioning.py not present",
        )
    code, out = run([sys.executable, str(script), "tests/integration"], timeout=120)
    if code != 0:
        blockers = [l for l in out.splitlines() if "BLOCKER" in l]
        detail = blockers[0] if blockers else (out.splitlines()[0] if out else "non-zero exit")
        return Check(
            "C8 tenant provisioning lint",
            BAD,
            detail,
            "fix the provisioning violations above",
        )
    return Check("C8 tenant provisioning lint", OK, "no BLOCKER findings")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Infrastructure Health Checklist (test_infrastructure_guide.md §3) as an exit code."
    )
    parser.add_argument("--quick", action="store_true", help="skip zig build and migrate (C2, C3)")
    parser.add_argument("--bench-only", action="store_true", help="run only C7 (ORCH pre-check)")
    parser.add_argument("--skip-docker", action="store_true", help="skip the container check (C1)")
    parser.add_argument("--quiet", action="store_true", help="print only the verdict line")
    args = parser.parse_args(argv[1:])

    # ISS-0151: resolve DB URLs from .env before any check runs, so the checks
    # and the subprocesses they spawn agree on the workspace's configuration.
    loaded = load_dotenv_into_environ(DOTENV_KEYS)
    if loaded and not args.quiet:
        print(f"  [info] loaded from .env: {', '.join(loaded)}")

    if args.bench_only:
        checks = [check_bench_env()]
    else:
        checks = []
        # C0 first: it names the databases every later check is about. ISS-0180.
        checks.append(check_url_targets())
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
        checks.append(check_tenant_provisioning_lint())

    failed = [c for c in checks if c.failed]

    if not args.quiet:
        for c in checks:
            print(f"  [{c.status}] {c.name}")
            # ISS-0180: print the detail on PASS too. A check that certifies a
            # *specific* database must say which one — a bare "[PASS] C3" is
            # exactly the uninformative green this issue was about.
            if c.detail:
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
