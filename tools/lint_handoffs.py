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
  H013  timestamps within one run disagree by a whole-hour offset (local-as-UTC)

Usage:
    python3 tools/lint_handoffs.py [handoffs_dir] [--quiet]
    python3 tools/lint_handoffs.py --changed         # only files changed vs origin/main

`--changed` is the CI mode. The corpus carries ~260 pre-existing BLOCKERs from
before these checks existed (inverted timestamps, BOMs, hand-edited JSON). Those
are frozen history: gating every pull request on them would fail every build for
defects the author did not introduce, and the predictable response to a gate
that always fails is to stop believing it. `--changed` restricts findings to
handoff files the branch actually touched, so CI blocks new defects while the
backlog is worked separately.

Touching a file is not the same as introducing every finding it carries: a
branch that only strips a BOM (H008) from a file that separately has an
unrelated, pre-existing H003 pulls that file into --changed's file-level scope
for the first time without having caused the H003. `--changed` mode therefore
compares each touched file's findings, per code, against its merge-base copy
(see `preexisting_file_finding_codes`) and reports only codes that are new on
this branch. This is not a suppression list and it changes no historical
record — it is a same-file, same-code presence check evaluated fresh on every
run directly from git history, so a finding that genuinely gets fixed drops
out of "pre-existing" the next time someone else's branch touches that file,
same as any other frozen-history entry in the ~260 backlog (tracked in
ISS-0627 / GH #596).

Exit codes: 0 = no BLOCKER/MAJOR, 1 = findings, 2 = usage error.
"""

from __future__ import annotations

import datetime
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


def _lint_parsed_handoff(parsed: dict, rel: str, findings: list[Finding]) -> None:
    """Checks that only need the already-parsed dict (not file bytes).

    Factored out of lint_handoff_file so --changed mode's pre-existing-finding
    comparison (preexisting_file_findings) runs the exact same rules against a
    merge-base copy fetched via `git show`, instead of a second, driftable
    copy of the logic.
    """
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

    _lint_parsed_handoff(parsed, rel, findings)

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


def lint_clock_skew(
    runs: dict[str, list[tuple[str, dict]]], findings: list[Finding]
) -> None:
    """Detect local-time-labelled-as-UTC within a single run.

    A handoff whose completed_at precedes its started_at by very close to a
    whole number of hours is not a fabricated timestamp -- it is a real clock
    read through the wrong timezone. Dropping `.ToUniversalTime()` (PowerShell)
    or using `datetime.now()` instead of the UTC form yields a string that is
    byte-identical in shape and wrong by exactly the host's UTC offset.

    Repo-wide these inversions cluster at whole hours (4h, 5h, 11h), which is
    the signature of timezone drift rather than of invented values. Reporting
    it separately from H003 tells the agent to fix its *command*, not its data.
    """
    for run_id, entries in runs.items():
        for rel, handoff in entries:
            started = handoff.get("started_at")
            completed = handoff.get("completed_at")
            if not (isinstance(started, str) and isinstance(completed, str)):
                continue
            if not (ISO_Z.match(started) and ISO_Z.match(completed)):
                continue
            if completed >= started:
                continue

            try:
                a = datetime.datetime.strptime(started, "%Y-%m-%dT%H:%M:%SZ")
                b = datetime.datetime.strptime(completed, "%Y-%m-%dT%H:%M:%SZ")
            except ValueError:
                continue

            gap_hours = (a - b).total_seconds() / 3600.0
            nearest = round(gap_hours)
            # Within 6 minutes of a whole hour, and at least half an hour off.
            if nearest >= 1 and abs(gap_hours - nearest) <= 0.1:
                findings.append(
                    Finding(
                        "H013",
                        "BLOCKER",
                        rel,
                        f"completed_at is {gap_hours:.1f}h before started_at — very close to "
                        f"a whole-hour offset ({nearest}h). This is local time labelled 'Z', "
                        "not a fabricated value: `(Get-Date).ToString(...)` without "
                        "`.ToUniversalTime()`, or `datetime.now()` instead of the UTC form, "
                        "produces exactly this. Use `python3 tools/utcnow.py`.",
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


def changed_handoff_files(base: str = "origin/main") -> set[str] | None:
    """Handoff files this branch touched, relative to `base`.

    Returns None when git cannot answer (no repo, missing ref, git absent), so
    the caller falls back to scanning everything rather than silently checking
    nothing — a gate that quietly passes is worse than no gate at all.
    """
    for ref in (base, "HEAD~1"):
        try:
            proc = subprocess.run(
                ["git", "diff", "--name-only", f"{ref}...HEAD"],
                capture_output=True,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if proc.returncode != 0:
            continue
        names = proc.stdout.decode("utf-8", "replace").splitlines()
        return {
            n.strip().replace("\\", "/")
            for n in names
            if n.strip().startswith("handoffs/") and n.strip().endswith(".json")
        }
    return None


def merge_base_ref(base: str = "origin/main") -> str | None:
    """Resolve the merge-base commit this branch diverged from.

    Falls back to `base` itself, then None, mirroring changed_handoff_files's
    own fallback order so both functions agree on which commit "pre-PR" means.
    """
    for ref in (base, "HEAD~1"):
        try:
            proc = subprocess.run(
                ["git", "merge-base", ref, "HEAD"],
                capture_output=True,
                timeout=15,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if proc.returncode == 0:
            out = proc.stdout.decode("ascii", "replace").strip()
            if out:
                return out
    return None


def preexisting_file_finding_codes(rel: str, merge_base: str) -> set[str] | None:
    """Finding codes `lint_handoff_file` would already report for `rel` at `merge_base`.

    Used by --changed mode to tell "this PR introduced a new defect in a file
    it touched" apart from "this PR touched a file for an unrelated reason
    (e.g. stripping its BOM) and thereby pulled a pre-existing, separately
    tracked defect into --changed's file-level scope for the first time."
    Only the second case is pre-existing history the backlog already owns
    (see ISS-0627 / GH #596) — it must not silently fail every PR that
    happens to touch the file next, or the gate stops being trustworthy for
    exactly the reason CLAUDE.md warns about.

    Compared by code, not by exact message, because messages legitimately
    embed values (a timestamp, an offset) that a genuine fix would change
    without changing whether the *category* of defect was already present.

    Returns None if the file did not exist at merge_base (i.e. it's new on
    this branch — nothing to compare against, so every finding in it counts
    as new).
    """
    try:
        proc = subprocess.run(
            ["git", "show", f"{merge_base}:{rel}"],
            capture_output=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None

    tmp_findings: list[Finding] = []
    had_bom = proc.stdout.startswith(b"\xef\xbb\xbf")
    try:
        parsed = json.loads(proc.stdout.decode("utf-8-sig"))
        err: str | None = None
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        parsed = None
        err = str(exc)

    if had_bom:
        tmp_findings.append(Finding("H008", "MAJOR", rel, "bom"))
    if parsed is None:
        tmp_findings.append(Finding("H001", "BLOCKER", rel, f"unparseable: {err}"))
    elif not isinstance(parsed, dict):
        tmp_findings.append(Finding("H001", "BLOCKER", rel, "not an object"))
    else:
        _lint_parsed_handoff(parsed, rel, tmp_findings)

    return {f.code for f in tmp_findings}


def preexisting_run_finding_codes(
    run_dir: str, merge_base: str
) -> dict[str, set[str]]:
    """Per-file H009/H013 codes lint_orphans/lint_clock_skew would report at merge_base.

    H009 and H013 need a whole run's step list (not just one file), so they
    can't be answered by preexisting_file_finding_codes. Reconstructs the run
    directory as it existed at merge_base via `git ls-tree`, reads each step
    file's merge-base copy via `git show`, and runs the same two checks
    against that snapshot. Returns {} (not None) on any git failure — callers
    treat a missing/unreadable run the same as "no pre-existing findings",
    which is the conservative direction: it may under-suppress (a finding
    stays reported that arguably pre-existed) but never over-suppresses a
    genuinely new one.
    """
    try:
        proc = subprocess.run(
            ["git", "ls-tree", "-r", "--name-only", merge_base, "--", run_dir],
            capture_output=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    if proc.returncode != 0:
        return {}

    names = [
        n.strip().replace("\\", "/")
        for n in proc.stdout.decode("utf-8", "replace").splitlines()
        if n.strip().endswith(".json") and os.path.basename(n.strip()).startswith("step-")
    ]
    if not names:
        return {}

    pre_runs: dict[str, list[tuple[str, dict]]] = defaultdict(list)
    for rel in names:
        try:
            show = subprocess.run(
                ["git", "show", f"{merge_base}:{rel}"],
                capture_output=True,
                timeout=15,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if show.returncode != 0:
            continue
        try:
            parsed = json.loads(show.stdout.decode("utf-8-sig"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if not isinstance(parsed, dict):
            continue
        pre_run_id = parsed.get("run_id") or os.path.basename(run_dir)
        pre_runs[pre_run_id].append((rel, parsed))

    tmp_findings: list[Finding] = []
    lint_orphans(pre_runs, tmp_findings)
    lint_clock_skew(pre_runs, tmp_findings)

    by_path: dict[str, set[str]] = defaultdict(set)
    for f in tmp_findings:
        by_path[f.path].add(f.code)
    return dict(by_path)


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = {a for a in argv[1:] if a.startswith("--")}
    quiet = "--quiet" in flags

    only_changed: set[str] | None = None
    if "--changed" in flags:
        only_changed = changed_handoff_files()
        if only_changed is None:
            print(
                "lint_handoffs: --changed requested but git could not report changed "
                "files; scanning the full corpus instead.",
                file=sys.stderr,
            )
        elif not only_changed:
            print("lint_handoffs: no handoff files changed on this branch — nothing to check.")
            return 0

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
            if only_changed is not None and rel not in only_changed:
                continue
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
    lint_clock_skew(runs, findings)

    # The registry and log live at the handoffs/ root, not inside a run dir.
    # When invoked on a single run (the common case for an agent checking its
    # own work), look for them one level up rather than reporting them missing.
    root = handoffs_dir
    if not os.path.exists(os.path.join(root, "registry.json")):
        parent = os.path.dirname(os.path.abspath(handoffs_dir))
        if os.path.exists(os.path.join(parent, "registry.json")):
            root = parent

    lint_registry(os.path.join(root, "registry.json"), all_ids, findings, total)
    lint_orchestrator_log(os.path.join(root, "orchestrator.log"), findings)

    # --changed mode: a file can land in only_changed for a reason unrelated
    # to a given finding (e.g. an H008 BOM-strip pulls the file into scope,
    # but the same file separately carries a pre-existing H003/H004/H007
    # that this branch never touched). Drop findings whose code already
    # applied to that same file before this branch existed, so the gate
    # blocks genuinely new defects without re-litigating backlog debt that
    # ISS-0627 / GH #596 already owns. A file that is new on this branch (no
    # merge_base copy) keeps every finding, since there is nothing "pre-
    # existing" to subtract.
    if only_changed is not None:
        base = merge_base_ref()
        if base is not None:
            pre_cache: dict[str, set[str] | None] = {}
            run_pre_cache: dict[str, dict[str, set[str]]] = {}
            kept: list[Finding] = []
            for f in findings:
                if f.path not in only_changed:
                    kept.append(f)
                    continue
                if f.code in ("H009", "H013"):
                    # Cross-file checks: reconstruct the owning run directory
                    # at merge_base rather than the single file.
                    run_dir = os.path.dirname(f.path)
                    if run_dir not in run_pre_cache:
                        run_pre_cache[run_dir] = preexisting_run_finding_codes(run_dir, base)
                    pre_codes_run = run_pre_cache[run_dir].get(f.path, set())
                    if f.code in pre_codes_run:
                        continue
                    kept.append(f)
                    continue
                if f.path not in pre_cache:
                    pre_cache[f.path] = preexisting_file_finding_codes(f.path, base)
                pre_codes = pre_cache[f.path]
                if pre_codes is not None and f.code in pre_codes:
                    continue  # pre-existing on this file at merge-base — not a new defect
                kept.append(f)
            findings = kept

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
