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
    python3 tools/lint_handoffs.py --no-baseline     # disable ACKNOWLEDGED bucket
    python3 tools/lint_handoffs.py selftest          # synthetic-fixture self-tests

`--changed` is the CI mode. The corpus carries ~260 pre-existing BLOCKERs from
before these checks existed (inverted timestamps, BOMs, hand-edited JSON). Those
are frozen history: gating every pull request on them would fail every build for
defects the author did not introduce, and the predictable response to a gate
that always fails is to stop believing it. `--changed` restricts findings to
handoff files the branch actually touched, so CI blocks new defects while the
backlog is worked separately.

Separately, `tools/lint_handoffs.baseline.json` (ISS-0627 / GH #596) gives a
225-finding subset of that same backlog — H003/H004/H005/H009, none of which
has a recoverable correct value anywhere in the file that produced it — a
third outcome: permanently ACKNOWLEDGED. An acknowledged finding is still
individually printed on every run, under its own `[ACKNOWLEDGED]` label; it is
excluded from exactly one thing, the BLOCKER/MAJOR count that decides the exit
code. This composes as an independent second gate, after `--changed`'s own
pre-existing-diff logic, not merged into it — see `load_lint_handoffs_baseline`
and `matching_key_for` below. `--no-baseline` disables it, for validating the
mechanism itself.

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
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LINT_HANDOFFS_BASELINE = REPO_ROOT / "tools" / "lint_handoffs.baseline.json"

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


def lint_orphans(
    runs: dict[str, list[tuple[str, dict]]],
    findings: list[Finding],
    capture: dict[int, list[str]] | None = None,
) -> None:
    """Report open handoffs that later steps in the same run ran past.

    `capture`, when provided, records `later_completed`'s path list keyed by
    `id(finding)` for each H009 Finding appended to `findings` — the same
    intermediate value this function already computes internally but
    otherwise discards after formatting the message. This is purely additive:
    every existing caller (main()'s pre-baseline call path,
    preexisting_run_finding_codes) omits the argument and is unaffected. It
    exists so H009's baseline-matching key (§0.2/§1.3 of
    src/design/iss0627-lint-handoffs-acknowledgment.md) can fold in the
    sorted fingerprint of *which* later steps bypassed the orphan, not just
    the count already embedded in the message — a plain
    severity|code|path|message key cannot distinguish two different orphan
    situations that happen to share the same later-completed count.
    """
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
                finding = Finding(
                    "H009",
                    "MAJOR",
                    rel,
                    f"status is {handoff.get('status')} but {len(later_completed)} "
                    f"later step(s) in run {run_id} are COMPLETED — the pipeline "
                    "advanced past a step it never closed.",
                )
                findings.append(finding)
                if capture is not None:
                    capture[id(finding)] = list(later_completed)


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


# --------------------------------------------------------------------------
# ISS-0627 / GH #596: permanent-acknowledgment baseline (H003/H004/H005/H009)
#
# See src/design/iss0627-lint-handoffs-acknowledgment.md for the full design.
# This is a strictly separate, independently-composed second gate from the
# --changed mode's preexisting_file_finding_codes/preexisting_run_finding_codes
# logic above (§4 of the design): that logic answers "did THIS branch
# introduce this finding"; this baseline answers "has this specific
# historical finding already been reviewed and accepted as permanent
# record". Neither is aware of the other's internal logic.
# --------------------------------------------------------------------------


def matching_key_for(
    finding: Finding, later_completed_by_id: dict[int, list[str]] | None = None
) -> str:
    """The baseline-matching key for `finding`, per design §1.3.

    H003/H004/H005: `severity|code|path|message` — the message already
    embeds the actual differing timestamp values (H003/H004) or is a fixed
    string backed by a binary predicate with no third variable (H005), so
    plain message-text matching is safe (design §0.1).

    H009 only: the same string, plus a `|later_completed:<sorted,comma-joined
    paths>` suffix. H009's message embeds only a COUNT of later-completed
    steps, never which steps — two genuinely different orphan situations on
    the same file can share an identical message (design §0.2's worked
    collision scenario). The suffix is what prevents that collision; sorting
    is explicit so key construction never depends on `later_completed`'s
    incidental input ordering.
    """
    base = f"{finding.severity}|{finding.code}|{finding.path}|{finding.message}"
    if finding.code != "H009":
        return base
    paths: list[str] = []
    if later_completed_by_id is not None:
        paths = later_completed_by_id.get(id(finding), [])
    return base + f"|later_completed:{','.join(sorted(paths))}"


def load_lint_handoffs_baseline(path: Path) -> dict:
    """Load tools/lint_handoffs.baseline.json.

    Returns {} (not None) if the file is absent or malformed — matching
    tools/lint_test_isolation.py's load_baseline defensive pattern exactly
    (design §6 error taxonomy): every H003/H004/H005/H009 finding then
    reports normally, as if --no-baseline were passed. Not a crash, not a
    silent full-suppression.
    """
    if not path.exists():
        return {}
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    if not isinstance(raw, dict):
        return {}
    issues = raw.get("issues", [])
    if not isinstance(issues, list):
        return {}

    entries: dict[str, dict] = {}
    for item in issues:
        if not isinstance(item, dict):
            continue
        key = item.get("matching_key")
        if not isinstance(key, str):
            continue
        entries[key] = item
    return {"entries": entries, "reasons": raw.get("reasons", {})}


def baseline_reason_for(baseline: dict, entry: dict) -> str:
    """Resolve an entry's reason_ref to display text, per design §6 error
    taxonomy: a reason_ref that can't be resolved degrades to a visible
    placeholder string, never a crash or silent blank."""
    ref = entry.get("reason_ref")
    if not isinstance(ref, str):
        return "(no reason_ref recorded)"
    if ref.startswith("adhoc:"):
        return ref[len("adhoc:") :]
    reasons = baseline.get("reasons", {})
    if isinstance(reasons, dict) and ref in reasons:
        return reasons[ref]
    return (
        f"(reason_ref {ref!r} not found in baseline reasons map — "
        "see tools/lint_handoffs.baseline.json)"
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


# --------------------------------------------------------------------------
# selftest -- plain assert-style checks against synthetic fixtures
#
# Follows the tools/reqctl.py cmd_selftest convention (also used by
# tools/repair_handoff_bookkeeping.py's own selftest subcommand): plain
# assert-style comparisons against synthetic fixtures, no pytest/unittest.
# Covers TS-BASELINE-01..04 from
# src/design/iss0627-lint-handoffs-acknowledgment.md §7. TS-BASELINE-05 (the
# generation script's differential check against lint_orphans) lives in
# tools/generate_lint_handoffs_baseline.py's own selftest, since it exercises
# that script's local orphan-walk copy, not anything in this file.
# --------------------------------------------------------------------------


def _apply_baseline_filter(
    findings: list[Finding],
    baseline_entries: dict[str, dict],
    later_completed_by_id: dict[int, list[str]] | None = None,
) -> tuple[list[Finding], list[Finding]]:
    """Split findings into (remaining, acknowledged) per matching_key_for.

    Factored out of main() so selftest exercises the exact same filtering
    logic the CLI path runs, not a reimplementation of it.
    """
    remaining: list[Finding] = []
    acknowledged: list[Finding] = []
    for f in findings:
        key = matching_key_for(f, later_completed_by_id)
        if key in baseline_entries:
            acknowledged.append(f)
        else:
            remaining.append(f)
    return remaining, acknowledged


def cmd_selftest() -> int:
    failures: list[str] = []

    def check(name: str, got, want) -> None:
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    def check_true(name: str, cond: bool) -> None:
        if not cond:
            failures.append(f"{name}: expected True, got False")

    # ---- TS-BASELINE-01: a baseline-matched finding is excluded from the
    # gating count but still printed ----
    f_h003 = Finding(
        "H003",
        "BLOCKER",
        "handoffs/FIX-01/step-01-x.json",
        "completed_at (2026-05-23T01:10:00Z) is earlier than started_at "
        "(2026-05-23T04:40:00Z). Timestamps must come from the shell clock, "
        "never from session context. This corrupts retrospective variance "
        "calculations.",
    )
    key_01 = matching_key_for(f_h003)
    baseline_entries_01 = {key_01: {"reason_ref": "H003", "acknowledged_at": "t", "acknowledged_by": "who"}}
    remaining_01, acked_01 = _apply_baseline_filter([f_h003], baseline_entries_01)
    counts_01 = defaultdict(int)
    for f in remaining_01:
        counts_01[f.severity] += 1
    check("TS-BASELINE-01 BLOCKER count excludes acknowledged", counts_01["BLOCKER"], 0)
    check_true("TS-BASELINE-01 acknowledged contains the finding", len(acked_01) == 1 and acked_01[0] is f_h003)
    exit_code_01 = 1 if (counts_01["BLOCKER"] or counts_01["MAJOR"]) else 0
    check("TS-BASELINE-01 exit code is 0", exit_code_01, 0)
    # Mutation check: skip the filtering step entirely -> BLOCKER count is 1, exit is 1.
    counts_01_nofilter = defaultdict(int)
    for f in [f_h003]:
        counts_01_nofilter[f.severity] += 1
    check("TS-BASELINE-01 mutation check: no filter -> BLOCKER=1", counts_01_nofilter["BLOCKER"], 1)
    check(
        "TS-BASELINE-01 mutation check: no filter -> exit=1",
        1 if (counts_01_nofilter["BLOCKER"] or counts_01_nofilter["MAJOR"]) else 0,
        1,
    )

    # ---- TS-BASELINE-02: a brand-new finding is NOT excluded, even on a
    # file with existing baseline entries ----
    f_h003_pair_b = Finding(
        "H003",
        "BLOCKER",
        "handoffs/FIX-01/step-01-x.json",
        "completed_at (2026-06-01T01:10:00Z) is earlier than started_at "
        "(2026-06-01T04:40:00Z). Timestamps must come from the shell clock, "
        "never from session context. This corrupts retrospective variance "
        "calculations.",
    )
    key_02 = matching_key_for(f_h003_pair_b)
    check_true("TS-BASELINE-02 pair A/B keys differ", key_02 != key_01)
    remaining_02, acked_02 = _apply_baseline_filter([f_h003_pair_b], baseline_entries_01)
    counts_02 = defaultdict(int)
    for f in remaining_02:
        counts_02[f.severity] += 1
    check("TS-BASELINE-02 BLOCKER count is 1 (new finding reports)", counts_02["BLOCKER"], 1)
    check("TS-BASELINE-02 acknowledged is empty", len(acked_02), 0)
    # Mutation check: weaken the key to severity|code|path only (drop message).
    weak_key_a = f"{f_h003.severity}|{f_h003.code}|{f_h003.path}"
    weak_key_b = f"{f_h003_pair_b.severity}|{f_h003_pair_b.code}|{f_h003_pair_b.path}"
    check_true(
        "TS-BASELINE-02 mutation check: weak key collides A/B",
        weak_key_a == weak_key_b,
    )

    # ---- TS-BASELINE-03: H009 collision case from design §0.2/§1.4 is
    # correctly disambiguated ----
    f_h009_snap1 = Finding(
        "H009",
        "MAJOR",
        "handoffs/WF02-x/step-02a-....json",
        "status is PENDING but 2 later step(s) in run WF02-x are COMPLETED "
        "— the pipeline advanced past a step it never closed.",
    )
    later_completed_snap1 = {
        id(f_h009_snap1): [
            "handoffs/WF02-x/step-03-....json",
            "handoffs/WF02-x/step-04-....json",
        ]
    }
    key_h009_snap1 = matching_key_for(f_h009_snap1, later_completed_snap1)

    f_h009_snap2 = Finding(
        "H009",
        "MAJOR",
        "handoffs/WF02-x/step-02a-....json",
        "status is PENDING but 2 later step(s) in run WF02-x are COMPLETED "
        "— the pipeline advanced past a step it never closed.",
    )
    later_completed_snap2 = {
        id(f_h009_snap2): [
            "handoffs/WF02-x/step-04-....json",
            "handoffs/WF02-x/step-05-....json",
        ]
    }
    key_h009_snap2 = matching_key_for(f_h009_snap2, later_completed_snap2)

    plain_key_snap1 = f"{f_h009_snap1.severity}|{f_h009_snap1.code}|{f_h009_snap1.path}|{f_h009_snap1.message}"
    plain_key_snap2 = f"{f_h009_snap2.severity}|{f_h009_snap2.code}|{f_h009_snap2.path}|{f_h009_snap2.message}"
    check_true("TS-BASELINE-03 plain message-only keys are equal (the collision is real)", plain_key_snap1 == plain_key_snap2)
    check_true("TS-BASELINE-03 full matching_key (with fingerprint) differs", key_h009_snap1 != key_h009_snap2)

    baseline_entries_03 = {key_h009_snap1: {"reason_ref": "H009", "acknowledged_at": "t", "acknowledged_by": "who"}}
    remaining_03, acked_03 = _apply_baseline_filter([f_h009_snap2], baseline_entries_03, later_completed_snap2)
    counts_03 = defaultdict(int)
    for f in remaining_03:
        counts_03[f.severity] += 1
    check("TS-BASELINE-03 MAJOR count is 1 (new H009 reports)", counts_03["MAJOR"], 1)
    check("TS-BASELINE-03 acknowledged is empty", len(acked_03), 0)
    # Mutation check: revert to the plain (insufficient) key scheme -> Snapshot
    # 2 wrongly matches Snapshot 1's baseline entry.
    baseline_entries_03_weak = {plain_key_snap1: {"reason_ref": "H009", "acknowledged_at": "t", "acknowledged_by": "who"}}
    check_true(
        "TS-BASELINE-03 mutation check: plain key wrongly matches",
        plain_key_snap2 in baseline_entries_03_weak,
    )

    # ---- TS-BASELINE-04: --no-baseline restores full gating ----
    # Simulates main()'s no_baseline branch: baseline entries never loaded /
    # filter never applied.
    findings_04 = [f_h003]
    counts_04 = defaultdict(int)
    for f in findings_04:
        counts_04[f.severity] += 1
    check("TS-BASELINE-04 BLOCKER count is 1 under --no-baseline", counts_04["BLOCKER"], 1)
    exit_code_04 = 1 if (counts_04["BLOCKER"] or counts_04["MAJOR"]) else 0
    check("TS-BASELINE-04 exit code is 1 under --no-baseline", exit_code_04, 1)
    # Mutation check: flag wired to hide the print only, while still filtering
    # (defeats the audit purpose) -> BLOCKER count would incorrectly be 0.
    remaining_04_mutated, _ = _apply_baseline_filter(findings_04, baseline_entries_01)
    counts_04_mutated = defaultdict(int)
    for f in remaining_04_mutated:
        counts_04_mutated[f.severity] += 1
    check_true(
        "TS-BASELINE-04 mutation check: print-only-suppression bug drops BLOCKER to 0",
        counts_04_mutated["BLOCKER"] == 0,
    )

    for f in failures:
        print(f"FAIL  {f}")
    if failures:
        print(f"\n{len(failures)} selftest failure(s)")
        return 1
    print("lint_handoffs selftest: all checks passed")
    return 0


def main(argv: list[str]) -> int:
    rest = argv[1:]

    if rest and rest[0] == "selftest":
        return cmd_selftest()

    baseline_path = DEFAULT_LINT_HANDOFFS_BASELINE
    no_baseline = False
    positional: list[str] = []
    flags: set[str] = set()
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--baseline":
            if i + 1 >= len(rest):
                print("error: --baseline requires a PATH argument", file=sys.stderr)
                return 2
            baseline_path = Path(rest[i + 1])
            i += 2
            continue
        if a == "--no-baseline":
            no_baseline = True
            i += 1
            continue
        if a.startswith("--"):
            flags.add(a)
            i += 1
            continue
        positional.append(a)
        i += 1

    args = positional
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

    later_completed_by_id: dict[int, list[str]] = {}
    lint_orphans(runs, findings, capture=later_completed_by_id)
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

    # ISS-0627 / GH #596 permanent-acknowledgment baseline. Runs AFTER the
    # --changed pre-existing-diff block above, operating on whatever findings
    # list that block already produced (design §4's composition rule) — an
    # independent second gate, not merged into --changed's own logic.
    acknowledged: list[Finding] = []
    baseline: dict = {}
    if not no_baseline:
        baseline = load_lint_handoffs_baseline(Path(baseline_path).resolve())
        entries = baseline.get("entries", {}) if baseline else {}
        if entries:
            remaining: list[Finding] = []
            for f in findings:
                key = matching_key_for(f, later_completed_by_id)
                if key in entries:
                    acknowledged.append(f)
                    continue
                remaining.append(f)
            findings = remaining

    findings.sort(key=lambda f: (SEVERITY_ORDER.get(f.severity, 9), f.code, f.path))
    acknowledged.sort(key=lambda f: (SEVERITY_ORDER.get(f.severity, 9), f.code, f.path))

    counts = defaultdict(int)
    for f in findings:
        counts[f.severity] += 1
    ack_count = len(acknowledged)

    if not quiet:
        for f in findings:
            print(f)
        if acknowledged:
            print()
            entries = baseline.get("entries", {}) if baseline else {}
            for f in acknowledged:
                key = matching_key_for(f, later_completed_by_id)
                entry = entries.get(key, {})
                reason = baseline_reason_for(baseline, entry)
                print(f"[ACKNOWLEDGED] {f.severity:7s} {f.code}  {f.path}")
                print(f"               {f.message}")
                print(
                    f"               reason: {reason}  "
                    f"(acknowledged {entry.get('acknowledged_at', '?')} "
                    f"by {entry.get('acknowledged_by', '?')})"
                )
        if findings or acknowledged:
            print()

    if ack_count and not no_baseline:
        print(f"Acknowledged {ack_count} issue(s) from baseline: {baseline_path}")

    summary = (
        f"lint_handoffs: {total} handoffs checked — "
        f"{counts['BLOCKER']} BLOCKER, {counts['MAJOR']} MAJOR, {counts['MINOR']} MINOR"
    )
    if ack_count:
        summary += f", {ack_count} ACKNOWLEDGED"
    print(summary)

    return 1 if (counts["BLOCKER"] or counts["MAJOR"]) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
