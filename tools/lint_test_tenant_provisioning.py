#!/usr/bin/env python3
"""lint_test_tenant_provisioning.py — Enforce the tenant-provisioning co-location rule.

ISS-0605 / GH-537: tests/integration/*.zig files that INSERT or UPDATE
public.tenant with storage_mode='SCHEMA' must co-locate a
provisionTenantSchema() (or bpm_provision_tenant_schema()) call in the same
test block. Otherwise a test that races against cleanup (or crashes mid-run)
leaves a half-provisioned public.tenant row whose backing Postgres schema was
never created — the same defect pattern as ISS-0140 / GH-443, recurring.

The lint scans every test "..." { ... } block and emits a single BLOCKER:

  T070  test inserts public.tenant row with storage_mode='SCHEMA' without
        co-located bpm_provision_tenant_schema() — would leave an orphan on
        cleanup failure (ISS-0605)

The lint is intentionally narrow: it only flags the storage_mode='SCHEMA'
INSERT/UPDATE co-location rule. It does not scan for general SQL injection
patterns, FK hygiene, or any other concern.

Anti-patterns this lint catches (see docs/anti-patterns.md):

  T070  Test block inserts or UPDATEs public.tenant with storage_mode='SCHEMA'
        but does not call provisionTenantSchema() / bpm_provision_tenant_schema()
        in the same test block.

Default target: tests/integration/. Pass paths to lint a subset.

The lint recognizes a `baseline` file (tools/lint_test_tenant_provisioning.baseline.json)
that exempts known-good files (the two existing tests that intentionally
exercise the storage_mode column without going through the provisioner, plus
the lint's own fixtures).

Exit codes:
  0  no BLOCKER findings
  1  one or more BLOCKER findings
  2  bad invocation
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BASELINE = REPO_ROOT / "tools" / "lint_test_tenant_provisioning.baseline.json"

TEST_BLOCK = re.compile(r"""^test\s+"([^"]+)"\s*\{""", re.MULTILINE)

# INSERT INTO (optional public.)tenant ( ... ) — captures the column list.
# Note: SQL is matched in raw text (string literals, comments, queries the test
# holds but never executes) — the same scope as the existing T060 INSERT scan
# in lint_test_isolation.py. We do not parse Zig AST; we look at the test block
# as it is written.
INSERT_TENANT = re.compile(
    r"INSERT\s+INTO\s+(?:public\.)?tenant\s*\(([^)]*)\)",
    re.IGNORECASE | re.MULTILINE,
)

# UPDATE tenant [SET ...] storage_mode = 'SCHEMA'
# Anchored on the storage_mode column being assigned 'SCHEMA' so it does not
# flag LEGACY_RLS / unset updates.
UPDATE_TENANT_STORAGE_MODE = re.compile(
    r"UPDATE\s+(?:public\.)?tenant\b[^\n;]*SET\s+[^;]*storage_mode\s*=\s*'SCHEMA'",
    re.IGNORECASE | re.MULTILINE,
)

# The provisioner call sites that satisfy the co-location rule. Both forms
# appear in this codebase: the Zig-side helper `provisionTenantSchema(` (the
# public API in src/db/provisioning.zig) and the SQL function
# `bpm_provision_tenant_schema(` (the implementation called by it).
PROVISION_CALL = re.compile(
    r"\b(?:provisionTenantSchema|bpm_provision_tenant_schema)\s*\("
)

# A SQL string literal that contains 'SCHEMA' attached to the storage_mode
# column. Used to detect literals like 'SCHEMA' inside Zig string assignments
# for the INSERT VALUES clause (where the column list alone does not carry
# the value).
SQL_VALUE_SCHEMA = re.compile(
    r"storage_mode\s*=\s*'SCHEMA'",
    re.IGNORECASE,
)


@dataclass
class Issue:
    severity: str
    code: str
    file: str
    line: int
    message: str

    def render(self) -> str:
        return f"[{self.severity}] {self.code} {self.file}:{self.line} — {self.message}"


@dataclass
class Report:
    issues: list[Issue] = field(default_factory=list)
    files_checked: int = 0

    @property
    def has_failures(self) -> bool:
        return any(i.severity == "BLOCKER" for i in self.issues)


def find_line(text: str, pos: int) -> int:
    return text[:pos].count("\n") + 1


def _strip_comments(text: str) -> str:
    """Replace Zig comment characters with spaces, preserving offsets.

    Zig line comments (`//`) and block comments (`/* ... */`) must not
    contribute to the regex match — the bad fixture's orphan pattern is
    described in a comment that contains the literal token
    `provisionTenantSchema(`, and matching it would silence the lint on the
    exact file that exists to fail it. Whitespace substitution (rather than
    deletion) keeps every line offset intact so `find_line` reports the
    correct source line.
    """
    out = list(text)
    n = len(out)
    i = 0
    while i < n:
        # Strip line comment to end of line. Do NOT extend across \r\n.
        if out[i] == "/" and i + 1 < n and out[i + 1] == "/":
            j = i
            while j < n and out[j] != "\n":
                out[j] = " "
                j += 1
            i = j
            continue
        # Strip block comment (non-nested, like C/Zig).
        if out[i] == "/" and i + 1 < n and out[i + 1] == "*":
            out[i] = " "
            out[i + 1] = " "
            j = i + 2
            while j + 1 < n and not (out[j] == "*" and out[j + 1] == "/"):
                out[j] = " "
                j += 1
            if j + 1 < n:
                out[j] = " "
                out[j + 1] = " "
            i = j + 2
            continue
        # Zig string literals (\\..) span multiple lines until the closing
        # backslash. The orphan pattern lives in such a string in the bad
        # fixture; we keep the string intact so the lint still sees the
        # INSERT inside it. Don't strip here.
        i += 1
    return "".join(out)


def find_test_blocks(text: str) -> list[tuple[str, int, int]]:
    """Return list of (test_name, start_index, end_index) for `test "..." { ... }` blocks."""
    blocks: list[tuple[str, int, int]] = []
    for m in TEST_BLOCK.finditer(text):
        start = m.end() - 1  # at the '{'
        depth = 0
        i = start
        n = len(text)
        while i < n:
            ch = text[i]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    blocks.append((m.group(1), m.start(), i + 1))
                    break
            i += 1
    return blocks


def _has_storage_mode_in_columns(columns_text: str) -> bool:
    """True if the column list of an INSERT includes a `storage_mode` column."""
    for col in columns_text.split(","):
        if col.strip().strip('"').lower() == "storage_mode":
            return True
    return False


def _block_has_schema_insert(text: str, block_start: int, block_end: int) -> list[int]:
    """Return list of line numbers of INSERT INTO tenant statements whose
    column list names `storage_mode` (regardless of the VALUES literal) within
    the test block. The lint flags the INSERT as a candidate and looks for a
    provisionTenantSchema call in the same block, NOT a string match on
    'SCHEMA' — Zig string literals may carry a placeholder schema_mode that
    resolves at runtime (e.g. tenant_config_realm_test.zig's `storage_mode`
    default route), and treating the literal presence as ground truth would
    false-positive on those.
    """
    block = text[block_start:block_end]
    out: list[int] = []
    for m in INSERT_TENANT.finditer(block):
        if not _has_storage_mode_in_columns(m.group(1)):
            continue
        out.append(find_line(text, block_start + m.start()))
    return out


def _block_has_schema_update(text: str, block_start: int, block_end: int) -> list[int]:
    """Return list of line numbers of UPDATE tenant SET storage_mode='SCHEMA' within the block."""
    block = text[block_start:block_end]
    return [find_line(text, block_start + m.start()) for m in UPDATE_TENANT_STORAGE_MODE.finditer(block)]


def _block_has_provision_call(text: str, block_start: int, block_end: int) -> bool:
    """True if the test block contains a provisionTenantSchema( or bpm_provision_tenant_schema( call."""
    return PROVISION_CALL.search(text[block_start:block_end]) is not None


def lint_file(path: Path, rel: str, report: Report) -> None:
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, PermissionError):
        return
    report.files_checked += 1

    # Strip line/block comments so comment text like "call provisionTenantSchema()"
    # does not satisfy the co-location rule. Zig multiline strings (`\\…`) are
    # preserved in full — the INSERT pattern under test lives inside one.
    scan_text = _strip_comments(text)

    for name, start, end in find_test_blocks(scan_text):
        block_line = find_line(scan_text, start)
        storage_inserts = _block_has_schema_insert(scan_text, start, end)
        storage_updates = _block_has_schema_update(scan_text, start, end)
        if not storage_inserts and not storage_updates:
            continue
        if _block_has_provision_call(scan_text, start, end):
            continue
        # Both INSERT and UPDATE candidates point to the test block as the
        # violation site. Reporting the test block's start line keeps the
        # diagnostic unambiguous when multiple statements are present.
        report.issues.append(Issue(
            "BLOCKER", "T070", rel, block_line,
            f'test "{name}" inserts/UPDATEs public.tenant with storage_mode=\'SCHEMA\' '
            'without a co-located bpm_provision_tenant_schema() / provisionTenantSchema() call — '
            'would leave an orphan row on cleanup failure (ISS-0605)',
        ))


def iter_targets(paths: list[Path]) -> list[Path]:
    out: list[Path] = []
    for p in paths:
        p = p.resolve()
        if p.is_dir():
            out.extend(sorted(f.resolve() for f in p.rglob("*.zig")))
        elif p.suffix == ".zig":
            out.append(p)
    return out


def load_baseline(path: Path) -> set[str]:
    """Return the set of file paths the baseline exempts from T070.

    The baseline shape mirrors tools/lint_test_isolation.baseline.json in
    spirit but is structurally simpler: T070 is per-file, not per-line, so the
    suppression key is just the POSIX file path. Per-file exemption is the
    minimum the design needs (and matches the docs/anti-patterns.md note that
    blanket per-file exemptions are acceptable for design-documented test
    detectors like tenant_config_realm_test.zig and iss107_tenant_storage_mode_test.zig).
    """
    if not path.exists():
        return set()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return set()
    out: set[str] = set()
    exempt_files = raw.get("exempt_test_files", {}) if isinstance(raw, dict) else {}
    if isinstance(exempt_files, dict):
        for k in exempt_files.keys():
            out.add(k.replace("\\", "/"))
    for entry in raw.get("exempt_files", []) if isinstance(raw, dict) else []:
        if isinstance(entry, str):
            out.add(entry.replace("\\", "/"))
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("paths", nargs="*", type=Path,
                        help="files or directories to lint (default: tests/integration)")
    parser.add_argument("--json", action="store_true", help="emit JSON report")
    parser.add_argument(
        "--baseline",
        type=Path,
        default=DEFAULT_BASELINE,
        help=f"path to baseline JSON for known-good test files (default: {DEFAULT_BASELINE})",
    )
    parser.add_argument(
        "--no-baseline",
        action="store_true",
        help="disable baseline suppression (use to validate the lint itself)",
    )
    args = parser.parse_args(argv)

    if args.paths:
        targets = [Path(p) for p in args.paths]
    else:
        targets = [REPO_ROOT / "tests" / "integration"]

    report = Report()
    for path in iter_targets(targets):
        try:
            rel = str(path.resolve().relative_to(REPO_ROOT)).replace("\\", "/")
        except ValueError:
            rel = str(path).replace("\\", "/")
        lint_file(path, rel, report)

    suppressed = 0
    if not args.no_baseline:
        baseline_files = load_baseline(args.baseline.resolve())
        if baseline_files:
            remaining: list[Issue] = []
            for issue in report.issues:
                if issue.file in baseline_files:
                    suppressed += 1
                    continue
                remaining.append(issue)
            report.issues = remaining

    if args.json:
        print(json.dumps({
            "files_checked": report.files_checked,
            "suppressed": suppressed,
            "issues": [asdict(i) for i in report.issues],
        }, indent=2))
    else:
        if not report.issues:
            print(f"OK — {report.files_checked} file(s) checked, no T070 violations.")
            if suppressed:
                print(f"Suppressed {suppressed} issue(s) from baseline: {args.baseline}")
        else:
            for i in report.issues:
                print(i.render())
            blocker = sum(1 for i in report.issues if i.severity == "BLOCKER")
            print(f"\n{report.files_checked} file(s) checked. BLOCKER={blocker}")
            if suppressed:
                print(f"Suppressed {suppressed} issue(s) from baseline: {args.baseline}")
    return 1 if report.has_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
