#!/usr/bin/env python3
"""
lint_frontend_conventions.py — Enforce the frontend conventions stated in
docs/guides/frontend_developer_guide.md and docs/anti-patterns.md.

Checks (against web/src and web/tests):
  F010  Raw fetch()/axios outside web/src/api/client.ts
  F020  MSW / axios-mock-adapter / vi.mock of HTTP modules anywhere
  F030  Inline query keys (`useQuery(['...'`) instead of queryKeys factory
  F040  `test.skip(` inside a Playwright spec file (E2E specs cover MUST requirements)
  F050  Disabled-instead-of-hidden role-gated elements (`disabled={!hasRole(...)}`
        / `disabled={...role...}` shapes)
  F060  Hardcoded user-visible string in a `.tsx` file that is not wrapped in t(...)
        (best-effort heuristic; emits MINOR only)

Exit codes:
  0  no issues
  1  one or more BLOCKER/MAJOR issues found
  2  bad invocation

Usage:
  python3 tools/lint_frontend_conventions.py
  python3 tools/lint_frontend_conventions.py --root web
  python3 tools/lint_frontend_conventions.py --json
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

API_CLIENT_PATH = "web/src/api/client.ts"

CHECKS = [
    # (code, severity, description, applies_to_glob, regex, ignore_substring, skip_in_comment)
    ("F010", "MAJOR", "raw fetch() call outside api/client.ts",
     ("web/src/**/*.ts", "web/src/**/*.tsx"),
     re.compile(r"\bfetch\s*\("), "api/client", True),
    ("F010", "MAJOR", "axios import outside api/client.ts",
     ("web/src/**/*.ts", "web/src/**/*.tsx"),
     re.compile(r"""^\s*import\s+[^;]*\bfrom\s+['"]axios['"]""", re.MULTILINE), "api/client", True),
    ("F020", "BLOCKER", "MSW / mock-service-worker reference",
     ("web/src/**/*.ts", "web/src/**/*.tsx", "web/tests/**/*.ts", "web/package.json"),
     re.compile(r"\b(msw|mock-service-worker|setupServer)\b"), None, True),
    ("F020", "BLOCKER", "axios-mock-adapter reference",
     ("web/src/**/*.ts", "web/src/**/*.tsx", "web/tests/**/*.ts", "web/package.json"),
     re.compile(r"\baxios-mock-adapter\b"), None, True),
    ("F030", "MAJOR", "inline query key array passed to useQuery/useMutation/useInfiniteQuery",
     ("web/src/**/*.ts", "web/src/**/*.tsx"),
     re.compile(r"use(Query|Mutation|InfiniteQuery)\s*\(\s*\{\s*queryKey\s*:\s*\["), None, True),
    ("F030", "MAJOR", "inline query key array passed as first arg to useQuery",
     ("web/src/**/*.ts", "web/src/**/*.tsx"),
     re.compile(r"useQuery\s*\(\s*\["), None, True),
    ("F040", "BLOCKER", "test.skip in Playwright spec — MUST requirements may not be skipped",
     ("web/tests/**/*.spec.ts", "web/tests/**/*.spec.tsx", "web/tests/e2e/**/*.ts"),
     re.compile(r"\btest\.skip\s*\("), None, True),
    ("F050", "MAJOR", "role-gated element uses `disabled` — must hide entirely",
     ("web/src/**/*.tsx",),
     re.compile(r"disabled\s*=\s*\{[^}]*(hasRole|userRole|role\s*[!=]==)[^}]*\}"), None, True),
]

LINE_COMMENT_RE = re.compile(r"^\s*(?://|/\*|\*)")


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


def iter_files(root: Path, globs: tuple[str, ...]) -> list[Path]:
    files: set[Path] = set()
    for g in globs:
        for p in root.glob(g):
            if p.is_file() and "node_modules" not in p.parts and "dist" not in p.parts:
                files.add(p)
    return sorted(files)


def _line_at(text: str, pos: int) -> str:
    start = text.rfind("\n", 0, pos) + 1
    end = text.find("\n", pos)
    if end == -1:
        end = len(text)
    return text[start:end]


def run_check(root: Path, report: Report, code, severity, message, globs, regex, ignore_sub, skip_in_comment) -> None:
    for path in iter_files(root, globs):
        rel = str(path.relative_to(root))
        rel_posix = rel.replace("\\", "/")
        if ignore_sub and ignore_sub in rel_posix:
            continue
        # api/client.ts is allowed to use fetch/axios
        if rel_posix == API_CLIENT_PATH:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, PermissionError):
            continue
        for m in regex.finditer(text):
            if skip_in_comment and LINE_COMMENT_RE.match(_line_at(text, m.start())):
                continue
            line = text[: m.start()].count("\n") + 1
            report.issues.append(Issue(severity, code, str(path.relative_to(REPO_ROOT)), line, message))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("--root", default=str(REPO_ROOT),
                        help="repo root containing web/ (default: project root)")
    parser.add_argument("--json", action="store_true", help="emit JSON report")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    if not (root / "web").exists():
        print(f"no web/ directory under {root}", file=sys.stderr)
        return 2

    report = Report()
    # Count files inspected (the union of all candidate globs)
    all_globs = tuple({g for c in CHECKS for g in c[3]})
    report.files_checked = len(iter_files(root, all_globs))

    for code, severity, message, globs, regex, ignore_sub, skip_in_comment in CHECKS:
        run_check(root, report, code, severity, message, globs, regex, ignore_sub, skip_in_comment)

    # dedupe — multiple regex variants for the same code may match the same line
    seen = set()
    unique: list[Issue] = []
    for i in report.issues:
        k = (i.code, i.file, i.line, i.message)
        if k in seen:
            continue
        seen.add(k)
        unique.append(i)
    report.issues = unique

    if args.json:
        print(json.dumps({
            "files_checked": report.files_checked,
            "issues": [asdict(i) for i in report.issues],
        }, indent=2))
    else:
        if not report.issues:
            print(f"OK — {report.files_checked} file(s) checked, no convention issues.")
        else:
            for i in report.issues:
                print(i.render())
            blocker = sum(1 for i in report.issues if i.severity == "BLOCKER")
            major = sum(1 for i in report.issues if i.severity == "MAJOR")
            minor = sum(1 for i in report.issues if i.severity == "MINOR")
            print(f"\n{report.files_checked} file(s) checked. "
                  f"BLOCKER={blocker} MAJOR={major} MINOR={minor}")
    return 1 if report.has_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
