#!/usr/bin/env python3
"""Lint the pipeline's own bookkeeping artefacts.

Every other linter under tools/ checks source code. This one checks the
handoff corpus, the registry, and the orchestrator log — the directives that
the 2026-08-05 pipeline audit measured at 30-45% compliance precisely because
nothing mechanically verified them.

Checks (BLOCKER unless noted):
  H001  handoff file is not parseable JSON
  H002  result stored as a JSON string instead of an object
  H003  completed_at earlier than started_at (impossible duration)
  H004  started_at earlier than created_at (step began before it was routed)
  H005  status COMPLETED but completed_at missing
  H006  result.status outside the legal enum
  H007  required schema key missing                                    (MAJOR)
  H008  file carries a UTF-8 BOM (invisible to bare json.load)         (MAJOR)
  H009  PENDING/IN_PROGRESS handoff bypassed by later COMPLETED steps  (MAJOR)
  H010  handoff absent from registry.json                              (MINOR)
  H011  orchestrator.log contains UTF-16-interleaved lines
  H012  orchestrator.log shorter than its committed HEAD version (truncation)

Usage:
    python3 tools/lint_handoffs.py [handoffs_dir] [--quiet] [--max-severity=LEVEL]

Exit codes: 0 = no BLOCKER/MAJOR, 1 = findings, 2 = usage error.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from collections import defaultdict

LEGAL_RESULT_STATUS = {"PASS", "FAIL", "PARTIAL", "BLOCKED", "SKIPPED"}
REQUIRED_KEYS = (
    "handoff_id",
    "run_id",
    "step",
    "from_agent",
    "to_agent",
    "created_at",
    "status",
)
TERMINAL_OK = {"COMPLETED", "CANCELLED", "ESCALATED"}
OPEN_STATUSES = {"PENDING", "IN_PROGRESS"}

SEVERITY_ORDER = {"BLOCKER": 0, "MAJOR": 1, "MINOR": 2}

# Timestamps are compared lexically: ISO-8601 UTC with a trailing Z sorts
# identically to chronological order, so no parsing is needed for ordering.
ISO_Z = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


class Finding:
    __slots__ = ("code", "severity", "path", "message")

    def __init__(self, code: str, severity: str, path: str, message: str) -> None:
        self.code = code
        self.severity = severity
        self.path = path
        self.message = message

    def __str__(self) -> str:
        return f"{self.severity:7s} {self.code}  {self.path}\n         {self.message}"


def step_sort_key(step: str) -> tuple:
    """Order steps so '00a' < '01' < '02b' < 'final'.

    Steps are free-form in the corpus ('00', '02a', '04b', 'final', '00-03'),
    so sort by leading integer, then by suffix, with 'final' pinned last.
    """
    s = str(step).strip().lower()
    if s.startswith("final") or s.endswith("final"):
        return (9999, s)
    m = re.match(r"(\d+)(.*)", s)
    if m:
        return (int(m.group(1)), m.group(2))
    return (5000, s)


def read_handoff(path: str) -> tuple[dict | None, bool, str | None]:
    """Return (parsed, had_bom, parse_error)."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        return None, False, str(exc)

    had_bom = raw.startswith(b"\xef\xbb\xbf")
    try:
        # utf-8-sig tolerates the BOM so we can still lint the content; H008
        # separately reports the BOM because CLAUDE.md's own snippets use a
        # bare json.load that does not tolerate it.
        return json.loads(raw.decode("utf-8-sig")), had_bom, None
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return None, had_bom, str(exc)


def lint_handoff_file(path: str, rel: str, findings: list[Finding]) -> dict | None:
    parsed, had_bom, err = read_handoff(path)

    if had_bom:
        findings.append(
            Finding(
                "H008",
                "MAJOR",
                rel,
                "File starts with a UTF-8 BOM; bare json.load(open(f)) — the form used "
                "in CLAUDE.md's ORCH snippets — raises on it, so this handoff is "
                "invisible to the orchestrator. Rewrite without a BOM.",
            )
        )

    if parsed is None:
        findings.append(Finding("H001", "BLOCKER", rel, f"Not parseable JSON: {err}"))
        return None

    if not isinstance(parsed, dict):
        findings.append(
            Finding("H001", "BLOCKER", rel, "Top-level JSON value is not an object.")
        )
        return None

    for key in REQUIRED_KEYS:
        if key not in parsed:
            findings.append(
                Finding("H007", "MAJOR", rel, f"Missing required schema key: {key!r}")
            )

    status = parsed.get("status")
    created = parsed.get("created_at")
    started = parsed.get("started_at")
    completed = parsed.get("completed_at")

    if isinstance(started, str) and isinstance(completed, str):
        if ISO_Z.match(started) and ISO_Z.match(completed) and completed < started:
            findings.append(
                Finding(
                    "H003",
                    "BLOCKER",
                    rel,
                    f"completed_at ({completed}) is earlier than started_at ({started}). "
                    "Timestamps must come from the shell clock, never from session "
                    "context. This corrupts retrospective variance calculations.",
                )
            )

    if isinstance(created, str) and isinstance(started, str):
        if ISO_Z.match(created) and ISO_Z.match(started) and started < created:
            findings.append(
                Finding(
                    "H004",
                    "BLOCKER",
                    rel,
                    f"started_at ({started}) precedes created_at ({created}) — the step "
                    "began before it was routed.",
                )
            )

    if status == "COMPLETED" and not completed:
        findings.append(
            Finding("H005", "BLOCKER", rel, "status is COMPLETED but completed_at is unset.")
        )

    result = parsed.get("result")
    if isinstance(result, str):
        findings.append(
            Finding(
                "H002",
                "BLOCKER",
                rel,
                "result is a JSON string, not an object. Any ORCH lookup of the form "
                'h["result"]["status"] raises TypeError on this file.',
            )
        )
    elif isinstance(result, dict):
        rs = result.get("status")
        if rs is not None and rs not in LEGAL_RESULT_STATUS:
            findings.append(
                Finding(
                    "H006",
                    "BLOCKER",
                    rel,
                    f"result.status is {rs!r}; legal values are "
                    f"{sorted(LEGAL_RESULT_STATUS)}.",
                )
            )

    return parsed


def lint_orphans(runs: dict[str, list[tuple[str, dict]]], findings: list[Finding]) -> None:
    """Report open handoffs that later steps in the same run ran past."""
    for run_id, entries in runs.items():
        ordered = sorted(entries, key=lambda e: step_sort_key(e[1].get("step", "")))
        for idx, (rel, handoff) in enumerate(ordered):
            if handoff.get("status") not in OPEN_STATUSES:
                continue
            later_completed = [
                other
                for other, oh in ordered[idx + 1 :]
                if oh.get("status") == "COMPLETED"
            ]
            if later_completed:
                findings.append(
                    Finding(
                        "H009",
                        "MAJOR",
                        rel,
                        f"status is {handoff.get('status')} but {len(later_completed)} "
                        f"later step(s) in run {run_id} are COMPLETED — the pipeline "
                        "advanced past a step it never closed.",
                    )
                )


def lint_registry(
    registry_path: str, all_ids: set[str], findings: list[Finding], total: int
) -> None:
    if not os.path.exists(registry_path):
        findings.append(
            Finding("H010", "MAJOR", registry_path, "registry.json does not exist.")
        )
        return

    parsed, _, err = read_handoff(registry_path)
    if parsed is None:
        findings.append(
            Finding("H010", "BLOCKER", registry_path, f"registry.json unparseable: {err}")
        )
        return

    registered = {
        e.get("handoff_id")
        for e in parsed.get("entries", [])
        if isinstance(e, dict) and e.get("handoff_id")
    }
    missing = all_ids - registered
    if missing:
        pct = 100.0 * len(missing) / total if total else 0.0
        findings.append(
            Finding(
                "H010",
                "MINOR",
                registry_path,
                f"{len(missing)} of {total} handoffs ({pct:.1f}%) are absent from the "
                "registry that CLAUDE.md designates as the routing index.",
            )
        )


def lint_orchestrator_log(log_path: str, findings: list[Finding]) -> None:
    if not os.path.exists(log_path):
        return

    with open(log_path, "rb") as fh:
        raw = fh.read()

    # UTF-16LE text written into a UTF-8 file shows as NUL-interleaved ASCII.
    # This is what PowerShell's `>>` redirect produces on Windows.
    if b"\x00" in raw:
        interleaved = raw.count(b"\x00")
        findings.append(
            Finding(
                "H011",
                "BLOCKER",
                log_path,
                f"Contains {interleaved} NUL bytes — UTF-16 text interleaved into a "
                "UTF-8 file, the signature of a PowerShell `>>` append. Use the "
                "Python append form, or `Out-File -Encoding utf8 -Append`.",
            )
        )

    current_lines = raw.count(b"\n")

    # Truncation guard: the log is append-only, so it must never shrink
    # relative to the committed version. This is the check that would have
    # caught the 1357 -> 17 line loss on 2026-08-04.
    try:
        head = subprocess.run(
            ["git", "show", f"HEAD:{log_path.replace(os.sep, '/')}"],
            capture_output=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return

    if head.returncode != 0:
        return

    head_lines = head.stdout.count(b"\n")
    if current_lines < head_lines:
        findings.append(
            Finding(
                "H012",
                "BLOCKER",
                log_path,
                f"Log has {current_lines} lines but HEAD has {head_lines} — it was "
                f"truncated by {head_lines - current_lines} lines. orchestrator.log is "
                'append-only: always open it with mode "a", never "w".',
            )
        )


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = {a for a in argv[1:] if a.startswith("--")}
    quiet = "--quiet" in flags

    handoffs_dir = args[0] if args else "handoffs"
    if not os.path.isdir(handoffs_dir):
        print(f"usage: {argv[0]} [handoffs_dir]", file=sys.stderr)
        print(f"error: {handoffs_dir!r} is not a directory", file=sys.stderr)
        return 2

    findings: list[Finding] = []
    runs: dict[str, list[tuple[str, dict]]] = defaultdict(list)
    all_ids: set[str] = set()
    total = 0

    for root, _dirs, files in os.walk(handoffs_dir):
        for name in sorted(files):
            if not name.startswith("step-") or not name.endswith(".json"):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path).replace(os.sep, "/")
            total += 1
            parsed = lint_handoff_file(path, rel, findings)
            if parsed is None:
                continue
            hid = parsed.get("handoff_id")
            if hid:
                all_ids.add(hid)
            run_id = parsed.get("run_id") or os.path.basename(root)
            runs[run_id].append((rel, parsed))

    lint_orphans(runs, findings)
    lint_registry(os.path.join(handoffs_dir, "registry.json"), all_ids, findings, total)
    lint_orchestrator_log(os.path.join(handoffs_dir, "orchestrator.log"), findings)

    findings.sort(key=lambda f: (SEVERITY_ORDER.get(f.severity, 9), f.code, f.path))

    counts = defaultdict(int)
    for f in findings:
        counts[f.severity] += 1

    if not quiet:
        for f in findings:
            print(f)
        if findings:
            print()

    print(
        f"lint_handoffs: {total} handoffs checked — "
        f"{counts['BLOCKER']} BLOCKER, {counts['MAJOR']} MAJOR, {counts['MINOR']} MINOR"
    )

    return 1 if (counts["BLOCKER"] or counts["MAJOR"]) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
