#!/usr/bin/env python3
"""
lint_design_artefact.py — Validate a design artefact before BACKEND-DEV / FRONTEND-DEV
picks it up.

Two artefact shapes are supported:

  1. Type E (novel) markdown — src/design/<module>.md
       Checks:
         - File exists, is non-empty
         - Contains "Module purpose", "Public interface", "Error taxonomy" or
           equivalent sections
         - No raw SQL string interpolation patterns (`std.fmt.allocPrint` followed
           by direct concatenation into a query string)
         - All listed requirement IDs match the format <PREFIX>-<NN>[a-z]?
         - No "TODO" or "TBD" markers in headings
         - No fenced code blocks longer than 40 lines (implementation code, not design)

  2. Type A–D YAML parameter files — templates/specs/*.yaml
       Schema-aware checks delegated to the matching template module
       (migration / crud-endpoint / list-page / react-flow-node).

Exit codes:
  0  no issues
  1  one or more issues found
  2  bad invocation

Usage:
  python3 tools/lint_design_artefact.py <path>
  python3 tools/lint_design_artefact.py --json <path>
  python3 tools/lint_design_artefact.py --all          # lint everything under src/design and templates/specs
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Iterable

REPO_ROOT = Path(__file__).resolve().parent.parent

REQUIREMENT_ID_PATTERN = re.compile(r"^[A-Z]{2,6}-\d{1,3}[a-z]?$")
SCHEMA_QUALIFIED_TABLE = re.compile(r"\b(public|pg_catalog|information_schema)\.[a-z_][a-z0-9_]*\b")
SQL_INTERPOLATION_HINT = re.compile(r"std\.fmt\.allocPrint\s*\([^)]*query", re.IGNORECASE)
TODO_HEADING = re.compile(r"^#{1,6}\s.*\b(TODO|TBD|FIXME)\b", re.IGNORECASE | re.MULTILINE)
FENCED_CODE_BLOCK = re.compile(r"```([a-zA-Z0-9_+-]*)\n(.*?)```", re.DOTALL)
ASSERTION_HINT = re.compile(r"\btry\s+expect|try\s+std\.testing\.expect", re.IGNORECASE)

REQUIRED_E_HEADINGS = (
    ("purpose", ("module purpose", "purpose")),
    ("interface", ("public interface", "interface", "api")),
    ("errors", ("error taxonomy", "errors", "error cases")),
)


@dataclass
class Issue:
    severity: str               # BLOCKER | MAJOR | MINOR
    code: str
    file: str
    line: int | None
    message: str

    def render(self) -> str:
        loc = f":{self.line}" if self.line else ""
        return f"[{self.severity}] {self.code} {self.file}{loc} — {self.message}"


@dataclass
class Report:
    issues: list[Issue] = field(default_factory=list)
    files_checked: int = 0

    def add(self, *args, **kwargs) -> None:
        self.issues.append(Issue(*args, **kwargs))

    @property
    def has_failures(self) -> bool:
        return any(i.severity in ("BLOCKER", "MAJOR") for i in self.issues)


# ---------------------------------------------------------------------------
# Type E (markdown) lint
# ---------------------------------------------------------------------------
def lint_markdown_design(path: Path, report: Report) -> None:
    text = path.read_text(encoding="utf-8")
    rel = str(path.relative_to(REPO_ROOT))

    if not text.strip():
        report.add("BLOCKER", "E001", rel, None, "design file is empty")
        return

    lower = text.lower()
    for key, headings in REQUIRED_E_HEADINGS:
        if not any(h in lower for h in headings):
            report.add(
                "MAJOR", "E010", rel, None,
                f"missing required section for `{key}`; expected one of: {headings}",
            )

    for m in TODO_HEADING.finditer(text):
        line = text[: m.start()].count("\n") + 1
        report.add("MAJOR", "E020", rel, line, "heading marked TODO/TBD/FIXME — design is incomplete")

    for m in SCHEMA_QUALIFIED_TABLE.finditer(text):
        line = text[: m.start()].count("\n") + 1
        report.add(
            "MINOR", "E030", rel, line,
            f"schema-qualified name `{m.group(0)}` — unqualified names only (see anti-patterns)",
        )

    for m in SQL_INTERPOLATION_HINT.finditer(text):
        line = text[: m.start()].count("\n") + 1
        report.add(
            "BLOCKER", "E040", rel, line,
            "design shows SQL via `std.fmt.allocPrint` near a query string — use $N placeholders only",
        )

    for m in FENCED_CODE_BLOCK.finditer(text):
        body = m.group(2)
        if body.count("\n") > 40:
            line = text[: m.start()].count("\n") + 1
            report.add(
                "MAJOR", "E050", rel, line,
                "fenced code block exceeds 40 lines — design should sketch signatures, not implement",
            )

    requirement_ids = _extract_requirement_ids(text)
    for rid in requirement_ids:
        if not REQUIREMENT_ID_PATTERN.match(rid):
            report.add(
                "MINOR", "E060", rel, None,
                f"requirement id `{rid}` does not match <PREFIX>-<NN>[a-z]? format",
            )


def _extract_requirement_ids(text: str) -> list[str]:
    out: list[str] = []
    for line in text.splitlines():
        # capture from headings like "Covers: REQ-01, REQ-02" and from "Covered: ..."
        m = re.search(r"\b(?:covers|covered|requirement[s]?)\s*[:\-]\s*([A-Z0-9\-,\s/]+)", line, re.IGNORECASE)
        if not m:
            continue
        for tok in re.split(r"[,\s/]+", m.group(1)):
            tok = tok.strip()
            if tok and tok[0].isalpha():
                out.append(tok)
    return out


# ---------------------------------------------------------------------------
# Type A–D (YAML) lint dispatch
# ---------------------------------------------------------------------------
def _load_yaml(path: Path):
    try:
        import yaml  # PyYAML
    except ImportError as e:
        raise SystemExit(
            "PyYAML is required for YAML lint. Install with `pip install pyyaml`."
        ) from e
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def lint_yaml_spec(path: Path, report: Report) -> None:
    rel = str(path.relative_to(REPO_ROOT))
    data = _load_yaml(path)
    if not isinstance(data, dict):
        report.add("BLOCKER", "Y001", rel, None, "YAML root must be a mapping")
        return

    name = path.name.lower()
    if name.endswith(".migration.yaml") or name == "migration.template.yaml":
        lint_migration_spec(rel, data, report)
    elif name.endswith(".crud-endpoint.yaml") or name == "crud-endpoint.template.yaml":
        lint_crud_endpoint_spec(rel, data, report)
    elif name.endswith(".list-page.yaml") or name == "list-page.template.yaml":
        lint_list_page_spec(rel, data, report)
    elif name.endswith(".react-flow-node.yaml") or name == "react-flow-node.template.yaml":
        lint_react_flow_node_spec(rel, data, report)
    else:
        report.add(
            "MINOR", "Y010", rel, None,
            "YAML file does not match a known Lego spec suffix; skipping schema lint",
        )


def lint_migration_spec(rel: str, data: dict, report: Report) -> None:
    # See templates/migration.schema.md for the full schema reference.
    _require(rel, data, "schema_version", int, report, "Y100")
    _require(rel, data, "migration_number", int, report, "Y101")
    _require(rel, data, "name", str, report, "Y102")
    _require(rel, data, "requirement_ids", list, report, "Y103")
    _require(rel, data, "purpose", str, report, "Y104")
    _require(rel, data, "tables", list, report, "Y105")
    _require(rel, data, "test_cases", list, report, "Y106")

    name = data.get("name")
    if isinstance(name, str) and not re.fullmatch(r"[a-z][a-z0-9_]*", name):
        report.add("MAJOR", "Y110", rel, None, f"name `{name}` is not snake_case")

    number = data.get("migration_number")
    if isinstance(number, int):
        existing = [p.name for p in (REPO_ROOT / "migrations").glob(f"{number:03d}*")]
        if existing:
            report.add(
                "BLOCKER", "Y111", rel, None,
                f"migration_number {number} collides with existing file(s): {existing}",
            )

    req_ids = data.get("requirement_ids") or []
    for rid in req_ids:
        if not (isinstance(rid, str) and REQUIREMENT_ID_PATTERN.match(rid)):
            report.add("MINOR", "Y112", rel, None, f"requirement id `{rid}` not in <PREFIX>-<NN>[a-z]? format")

    for i, table in enumerate(data.get("tables") or []):
        if not isinstance(table, dict):
            report.add("MAJOR", "Y120", rel, None, f"tables[{i}] is not a mapping")
            continue
        mode = table.get("mode")
        tname = table.get("name", "<unknown>")
        if mode not in ("create", "alter"):
            report.add("MAJOR", "Y121", rel, None, f"tables[{i}] mode must be 'create' or 'alter'; got {mode!r}")
        if isinstance(tname, str) and "." in tname:
            report.add("BLOCKER", "Y122", rel, None, f"tables[{i}].name `{tname}` is schema-qualified")
        if mode == "alter" and (table.get("drop_columns") or []):
            report.add(
                "MAJOR", "Y123", rel, None,
                f"tables[{i}] uses drop_columns; append-only policy applies — see anti-patterns",
            )
        if mode == "create":
            cols = table.get("columns") or []
            pk_count = sum(1 for c in cols if isinstance(c, dict) and c.get("pk"))
            if pk_count == 0:
                report.add("MAJOR", "Y124", rel, None, f"tables[{i}] has no primary key column")
            elif pk_count > 1:
                report.add("MAJOR", "Y125", rel, None, f"tables[{i}] has {pk_count} pk:true columns (max 1)")

    test_cases = data.get("test_cases") or []
    if not test_cases:
        report.add("BLOCKER", "Y130", rel, None, "test_cases is empty — every migration requires at least one test")

    rid_set = set(req_ids)
    for i, tc in enumerate(test_cases):
        if not isinstance(tc, dict):
            report.add("MAJOR", "Y131", rel, None, f"test_cases[{i}] is not a mapping")
            continue
        for field_name in ("name", "description", "requirement_ref", "act", "assertions"):
            if not tc.get(field_name):
                report.add("MAJOR", "Y132", rel, None, f"test_cases[{i}] missing `{field_name}`")
        ref = tc.get("requirement_ref")
        if ref and ref not in rid_set:
            report.add(
                "MAJOR", "Y133", rel, None,
                f"test_cases[{i}].requirement_ref `{ref}` not in requirement_ids {sorted(rid_set)}",
            )
        assertions = tc.get("assertions") or ""
        if ASSERTION_HINT.search(assertions):
            report.add(
                "BLOCKER", "Y134", rel, None,
                f"test_cases[{i}].assertions contains real assertion code — must stay a `// CUSTOM:` placeholder",
            )


def lint_crud_endpoint_spec(rel: str, data: dict, report: Report) -> None:
    _require(rel, data, "schema_version", int, report, "Y200")
    _require(rel, data, "resource_name", str, report, "Y201")
    _require(rel, data, "store_module", str, report, "Y202")
    _require(rel, data, "endpoints", list, report, "Y203")
    _require(rel, data, "requirement_ids", list, report, "Y204")
    for i, ep in enumerate(data.get("endpoints") or []):
        if not isinstance(ep, dict):
            report.add("MAJOR", "Y210", rel, None, f"endpoints[{i}] is not a mapping")
            continue
        for field_name in ("method", "path", "operation", "success_status", "error_map"):
            if field_name not in ep:
                report.add("MAJOR", "Y211", rel, None, f"endpoints[{i}] missing `{field_name}`")
        method = ep.get("method")
        if method and method not in ("GET", "POST", "PUT", "PATCH", "DELETE"):
            report.add("MAJOR", "Y212", rel, None, f"endpoints[{i}].method `{method}` not a valid HTTP verb")
        emap = ep.get("error_map") or {}
        if isinstance(emap, dict):
            for err_name, status in emap.items():
                if not isinstance(status, int) or not (400 <= status < 600):
                    report.add("MAJOR", "Y213", rel, None,
                               f"endpoints[{i}].error_map[{err_name}] = {status!r} is not a 4xx/5xx integer")


def lint_list_page_spec(rel: str, data: dict, report: Report) -> None:
    _require(rel, data, "schema_version", int, report, "Y300")
    _require(rel, data, "resource_name", str, report, "Y301")
    _require(rel, data, "list_query_key", str, report, "Y302")
    _require(rel, data, "columns", list, report, "Y303")
    _require(rel, data, "filters", list, report, "Y304")
    _require(rel, data, "row_actions", list, report, "Y305")
    _require(rel, data, "create_form", (dict, type(None)), report, "Y306")
    if isinstance(data.get("list_query_key"), str) and not data["list_query_key"].startswith("queryKeys."):
        report.add(
            "MAJOR", "Y310", rel, None,
            "list_query_key must reference the queryKeys factory (e.g. queryKeys.users.list) — never an inline array",
        )


def lint_react_flow_node_spec(rel: str, data: dict, report: Report) -> None:
    _require(rel, data, "schema_version", int, report, "Y400")
    _require(rel, data, "node_type", str, report, "Y401")
    _require(rel, data, "label", str, report, "Y402")
    _require(rel, data, "icon", str, report, "Y403")
    _require(rel, data, "handles", list, report, "Y404")
    _require(rel, data, "data_fields", list, report, "Y405")
    for i, h in enumerate(data.get("handles") or []):
        if not isinstance(h, dict):
            report.add("MAJOR", "Y410", rel, None, f"handles[{i}] is not a mapping")
            continue
        if h.get("kind") not in ("source", "target"):
            report.add("MAJOR", "Y411", rel, None, f"handles[{i}].kind must be 'source' or 'target'")
        if h.get("position") not in ("top", "right", "bottom", "left"):
            report.add("MAJOR", "Y412", rel, None, f"handles[{i}].position must be top/right/bottom/left")


def _require(rel: str, data: dict, key: str, expected_type, report: Report, code: str) -> None:
    if key not in data:
        report.add("BLOCKER", code, rel, None, f"missing required field `{key}`")
        return
    if not isinstance(data[key], expected_type):
        report.add(
            "MAJOR", code, rel, None,
            f"field `{key}` has wrong type; expected {expected_type}, got {type(data[key]).__name__}",
        )


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
def iter_targets(paths: Iterable[Path]) -> Iterable[Path]:
    for p in paths:
        if p.is_dir():
            yield from p.rglob("*.md")
            yield from p.rglob("*.yaml")
        else:
            yield p


def lint_file(path: Path, report: Report) -> None:
    if not path.is_absolute():
        path = (REPO_ROOT / path).resolve()
    if not path.exists():
        report.add("BLOCKER", "X001", str(path), None, "file does not exist")
        return
    report.files_checked += 1
    if path.suffix.lower() == ".md":
        lint_markdown_design(path, report)
    elif path.suffix.lower() in (".yaml", ".yml"):
        lint_yaml_spec(path, report)
    else:
        try:
            rel = str(path.relative_to(REPO_ROOT))
        except ValueError:
            rel = str(path)
        report.add("MINOR", "X002", rel, None, "unsupported file extension; skipped")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("paths", nargs="*", type=Path, help="design files or directories to lint")
    parser.add_argument("--all", action="store_true",
                        help="lint everything under src/design and templates/specs")
    parser.add_argument("--json", action="store_true", help="emit JSON report")
    args = parser.parse_args(argv)

    if args.all:
        targets = [REPO_ROOT / "src" / "design", REPO_ROOT / "templates" / "specs"]
    elif args.paths:
        targets = args.paths
    else:
        parser.error("provide one or more paths or --all")
        return 2

    report = Report()
    for path in iter_targets([Path(p) for p in targets]):
        lint_file(path, report)

    if args.json:
        print(json.dumps({
            "files_checked": report.files_checked,
            "issues": [asdict(i) for i in report.issues],
            "summary": _severity_counts(report.issues),
        }, indent=2))
    else:
        if not report.issues:
            print(f"OK — {report.files_checked} file(s) checked, no issues.")
        else:
            for i in report.issues:
                print(i.render())
            counts = _severity_counts(report.issues)
            print(f"\n{report.files_checked} file(s) checked. "
                  f"BLOCKER={counts['BLOCKER']} MAJOR={counts['MAJOR']} MINOR={counts['MINOR']}")
    return 1 if report.has_failures else 0


def _severity_counts(issues: list[Issue]) -> dict:
    out = {"BLOCKER": 0, "MAJOR": 0, "MINOR": 0}
    for i in issues:
        out[i.severity] = out.get(i.severity, 0) + 1
    return out


if __name__ == "__main__":
    raise SystemExit(main())
