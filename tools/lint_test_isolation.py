#!/usr/bin/env python3
"""
lint_test_isolation.py — Enforce fixture-isolation rules for integration tests.

Anti-patterns this lint catches (see docs/anti-patterns.md):

  T010  Hardcoded UUID literal inside a test file (per-test UUIDs are mandatory).
  T020  Module-level mutable `var` inside a test file (shared state across blocks).
  T030  `test "..."` block with allocations but no `defer` cleanup.
  T040  `error.SkipZigTest` on a MUST requirement test (heuristic: looks for
        `// covers: <REQ>` or `// requirement: <REQ>` comments inside the same block).
  T050  Integration test file that does not reference `BPM_TEST_DB_URL`
        (every integration test must connect to a real Postgres).

Default target: tests/integration/. Pass paths to lint a subset.

Exit codes:
  0  no issues
  1  one or more BLOCKER/MAJOR issues found
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
DEFAULT_BASELINE = REPO_ROOT / "tools" / "lint_test_isolation.baseline.json"

UUID_LITERAL = re.compile(
    r'"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"'
)
ALL_ZEROS_UUID = "00000000-0000-0000-0000-000000000000"
MODULE_VAR = re.compile(r"^\s*var\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*", re.MULTILINE)
TEST_BLOCK = re.compile(r"""^test\s+"([^"]+)"\s*\{""", re.MULTILINE)
SKIP_HINT = re.compile(r"\berror\.SkipZigTest\b")
ALLOC_HINT = re.compile(r"\.(alloc|create|init|connect)\s*\(")
DEFER_HINT = re.compile(r"\bdefer\b")
COVERS_HINT = re.compile(r"//\s*(covers|requirement|requirements?)\s*[:\-]\s*([A-Z0-9\-,\s/]+)", re.IGNORECASE)
DB_URL_HINT = re.compile(r"\bBPM_TEST_DB_URL\b")


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
        return any(i.severity in ("BLOCKER", "MAJOR") for i in self.issues)


def find_line(text: str, pos: int) -> int:
    return text[:pos].count("\n") + 1


def find_test_blocks(text: str) -> list[tuple[str, int, int]]:
    """Return list of (test_name, start_index, end_index) for `test "..." { ... }` blocks."""
    blocks: list[tuple[str, int, int]] = []
    for m in TEST_BLOCK.finditer(text):
        name = m.group(1)
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
                    blocks.append((name, m.start(), i + 1))
                    break
            i += 1
    return blocks


def lint_file(path: Path, report: Report) -> None:
    resolved_path = path.resolve()
    try:
        rel = str(resolved_path.relative_to(REPO_ROOT)).replace("\\", "/")
    except ValueError:
        rel = str(path).replace("\\", "/")
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, PermissionError):
        return
    report.files_checked += 1

    # T010: hardcoded UUID literals
    for m in UUID_LITERAL.finditer(text):
        val = m.group(0).strip('"')
        if val == ALL_ZEROS_UUID:
            continue  # zero-UUID is conventional "no value" sentinel
        line = find_line(text, m.start())
        report.issues.append(Issue(
            "MAJOR", "T010", rel, line,
            f"hardcoded UUID `{val}` — generate per-test UUIDs instead",
        ))

    # T020: module-level `var` declarations (`const` is fine)
    # We only count `var` at column 0 (module scope), not inside functions.
    for m in MODULE_VAR.finditer(text):
        # Heuristic: if the match starts at col 0 (no leading whitespace) it's module-level.
        line_start = text.rfind("\n", 0, m.start()) + 1
        if m.start() == line_start:  # truly column 0
            line = find_line(text, m.start())
            report.issues.append(Issue(
                "MAJOR", "T020", rel, line,
                f"module-level mutable var `{m.group(1)}` shared across test blocks",
            ))

    # T050: integration test references BPM_TEST_DB_URL
    if "tests/integration" in rel.replace("\\", "/") or "tests\\integration" in rel:
        if not DB_URL_HINT.search(text):
            report.issues.append(Issue(
                "MAJOR", "T050", rel, 1,
                "integration test does not reference BPM_TEST_DB_URL — must connect to real Postgres",
            ))

    # T030 + T040: per test block
    for name, start, end in find_test_blocks(text):
        block = text[start:end]
        line_no = find_line(text, start)

        # T030: allocations without defer
        if ALLOC_HINT.search(block) and not DEFER_HINT.search(block):
            report.issues.append(Issue(
                "MAJOR", "T030", rel, line_no,
                f'test "{name}" allocates but has no `defer` cleanup',
            ))

        # T040: skip-on-MUST
        if SKIP_HINT.search(block):
            covers = COVERS_HINT.findall(block)
            if covers:
                report.issues.append(Issue(
                    "BLOCKER", "T040", rel, line_no,
                    f'test "{name}" uses error.SkipZigTest but covers requirement(s); skip is forbidden on MUST tests',
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


def issue_key(issue: Issue) -> str:
    return f"{issue.severity}|{issue.code}|{issue.file}|{issue.line}|{issue.message}"


def load_baseline(path: Path) -> set[str]:
    if not path.exists():
        return set()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return set()

    out: set[str] = set()
    issues = raw.get("issues", []) if isinstance(raw, dict) else []
    if not isinstance(issues, list):
        return out

    for item in issues:
        if not isinstance(item, dict):
            continue
        sev = item.get("severity")
        code = item.get("code")
        file = item.get("file")
        line = item.get("line")
        msg = item.get("message")
        if not isinstance(sev, str) or not isinstance(code, str) or not isinstance(file, str) or not isinstance(msg, str):
            continue
        if not isinstance(line, int):
            continue
        out.add(f"{sev}|{code}|{file.replace('\\', '/')}|{line}|{msg}")
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
        help=f"path to baseline JSON for known legacy findings (default: {DEFAULT_BASELINE})",
    )
    parser.add_argument(
        "--no-baseline",
        action="store_true",
        help="disable baseline suppression",
    )
    args = parser.parse_args(argv)

    if args.paths:
        targets = [Path(p) for p in args.paths]
    else:
        targets = [REPO_ROOT / "tests" / "integration"]

    report = Report()
    for path in iter_targets(targets):
        lint_file(path, report)

    suppressed = 0
    if not args.no_baseline:
        baseline_keys = load_baseline(args.baseline.resolve())
        if baseline_keys:
            remaining: list[Issue] = []
            for issue in report.issues:
                if issue_key(issue) in baseline_keys:
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
            print(f"OK — {report.files_checked} file(s) checked, no isolation issues.")
            if suppressed:
                print(f"Suppressed {suppressed} issue(s) from baseline: {args.baseline}")
        else:
            for i in report.issues:
                print(i.render())
            blocker = sum(1 for i in report.issues if i.severity == "BLOCKER")
            major = sum(1 for i in report.issues if i.severity == "MAJOR")
            minor = sum(1 for i in report.issues if i.severity == "MINOR")
            print(f"\n{report.files_checked} file(s) checked. "
                  f"BLOCKER={blocker} MAJOR={major} MINOR={minor}")
            if suppressed:
                print(f"Suppressed {suppressed} issue(s) from baseline: {args.baseline}")
    return 1 if report.has_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
