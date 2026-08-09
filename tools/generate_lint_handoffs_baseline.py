#!/usr/bin/env python3
"""Generate tools/lint_handoffs.baseline.json — one-time reviewed script.

Design: src/design/iss0627-lint-handoffs-acknowledgment.md
Issue:  ISS-0627 / GH #596 (H003/H004/H005/H009 permanent-acknowledgment subset)

This script never modifies a handoff file. It only ever writes
tools/lint_handoffs.baseline.json — a machine-read baseline that gives 225
frozen-history findings (148 H003 + 34 H004 + 5 H005 + 38 H009) a third
outcome in tools/lint_handoffs.py: permanently ACKNOWLEDGED (still printed,
excluded from the BLOCKER/MAJOR gate).

Reuses tools/lint_handoffs.py's own detection functions
(read_handoff, _lint_parsed_handoff, lint_orphans, matching_key_for) rather
than reimplementing the H003/H004/H005/H009 predicates a second time — that
duplication is exactly the drift risk this design and
preexisting_file_finding_codes/preexisting_run_finding_codes (GH-594) both
exist to avoid.

Usage:
    python3 tools/generate_lint_handoffs_baseline.py [handoffs_dir] [--apply]
        [--out PATH] [--now ISO8601] [--run-id STR]
    python3 tools/generate_lint_handoffs_baseline.py selftest

Without --apply: dry-run. Prints proposed before/after entry counts per code
and the full JSON to stdout; writes nothing.

With --apply: writes tools/lint_handoffs.baseline.json (or --out's path).
Requires --now (this script never calls the system clock itself — supply
`python3 tools/utcnow.py`'s output, matching repair_handoff_bookkeeping.py's
own --now convention).

Exit codes: 0 dry-run or --apply completed. 2 usage error.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

from lint_handoffs import (  # noqa: E402
    Finding,
    _lint_parsed_handoff,
    lint_orphans,
    matching_key_for,
    read_handoff,
    step_sort_key,
)

DEFAULT_OUT = REPO_ROOT / "tools" / "lint_handoffs.baseline.json"

SCOPED_CODES = ("H003", "H004", "H005", "H009")

REASONS = {
    "H003": (
        "ISS-0627 §H003: completed_at precedes started_at with no "
        "whole-hour-offset signature (that subset is H013, separately "
        "tracked). No field in the handoff file recovers the true value; "
        "any correction would be fabricated audit-trail data. Accepted as "
        "permanent historical record."
    ),
    "H004": (
        "ISS-0627 §H004: started_at precedes created_at. Same "
        "unrecoverable-history problem as H003, opposite field pair. "
        "Accepted as permanent historical record."
    ),
    "H005": (
        "ISS-0627 §H005: status is COMPLETED but completed_at was "
        "never set. No value to recover from any source in the file. "
        "Accepted as permanent historical record."
    ),
    "H009": (
        "ISS-0627 §H009: a PENDING/IN_PROGRESS step has later "
        "COMPLETED steps in the same run. Marking the orphaned step "
        "COMPLETED or FAILED after the fact would fabricate evidence the "
        "record does not show; this is a real historical process "
        "irregularity, not a data-entry error. Accepted as permanent "
        "historical record."
    ),
}


# --------------------------------------------------------------------------
# Corpus walk — mirrors lint_handoffs.py's main() exactly (same step-*.json
# filename filter, same directory walk, same runs dict construction).
# --------------------------------------------------------------------------


def walk_corpus(handoffs_dir: str) -> tuple[list[tuple[str, dict]], dict[str, list[tuple[str, dict]]]]:
    """Return (all (rel, parsed) pairs, runs dict keyed by run_id).

    Unparseable files are skipped (nothing to baseline for H001 — out of
    scope per design §2.3).
    """
    parsed_files: list[tuple[str, dict]] = []
    runs: dict[str, list[tuple[str, dict]]] = {}

    for root, _dirs, files in os.walk(handoffs_dir):
        for name in sorted(files):
            if not name.startswith("step-") or not name.endswith(".json"):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path).replace(os.sep, "/")
            parsed, _had_bom, _err = read_handoff(path)
            if parsed is None or not isinstance(parsed, dict):
                continue
            parsed_files.append((rel, parsed))
            run_id = parsed.get("run_id") or os.path.basename(root)
            runs.setdefault(run_id, []).append((rel, parsed))

    return parsed_files, runs


# --------------------------------------------------------------------------
# H003/H004/H005 — reuse _lint_parsed_handoff, filter to scoped codes.
# --------------------------------------------------------------------------


def scan_h003_h004_h005(parsed_files: list[tuple[str, dict]]) -> list[Finding]:
    out: list[Finding] = []
    for rel, parsed in parsed_files:
        tmp: list[Finding] = []
        _lint_parsed_handoff(parsed, rel, tmp)
        out.extend(f for f in tmp if f.code in ("H003", "H004", "H005"))
    return out


# --------------------------------------------------------------------------
# H009 — reuse lint_orphans via its `capture` kwarg (design §2.2/§3.1)
# to obtain later_completed's path list alongside the real Finding, without
# reimplementing the predicate itself.
# --------------------------------------------------------------------------


def scan_h009(
    runs: dict[str, list[tuple[str, dict]]]
) -> list[tuple[Finding, list[str]]]:
    findings: list[Finding] = []
    capture: dict[int, list[str]] = {}
    lint_orphans(runs, findings, capture=capture)
    return [(f, capture.get(id(f), [])) for f in findings]


# --------------------------------------------------------------------------
# Local orphan-walk copy — ONLY used by the differential selftest (TS-
# BASELINE-05, design §2.2) to prove scan_h009 (which calls the real
# lint_orphans) behaves identically to a hand-written copy of the same 8-
# line iteration. This is not a second predicate implementation used in the
# generation path itself — production code always goes through scan_h009 /
# lint_orphans. It exists only so the differential check has something
# independent to compare against.
# --------------------------------------------------------------------------


def _local_orphan_walk(
    runs: dict[str, list[tuple[str, dict]]]
) -> list[tuple[Finding, list[str]]]:
    open_statuses = {"PENDING", "IN_PROGRESS"}
    out: list[tuple[Finding, list[str]]] = []
    for run_id, entries in runs.items():
        ordered = sorted(entries, key=lambda e: step_sort_key(e[1].get("step", "")))
        for idx, (rel, handoff) in enumerate(ordered):
            if handoff.get("status") not in open_statuses:
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
                out.append((finding, list(later_completed)))
    return out


# --------------------------------------------------------------------------
# Baseline entry assembly
# --------------------------------------------------------------------------


def build_baseline_entries(
    findings: list[Finding],
    h009_pairs: list[tuple[Finding, list[str]]],
    now: str,
    run_id: str,
) -> list[dict]:
    later_completed_by_id = {id(f): paths for f, paths in h009_pairs}
    all_findings = list(findings) + [f for f, _ in h009_pairs]

    entries: list[dict] = []
    for f in all_findings:
        key = matching_key_for(f, later_completed_by_id)
        entries.append(
            {
                "file": f.path,
                "code": f.code,
                "matching_key": key,
                "reason_ref": f.code,
                "acknowledged_at": now,
                "acknowledged_by": f"{run_id} / tools/generate_lint_handoffs_baseline.py",
            }
        )
    # Deterministic ordering: by code, then file, then key — makes the
    # generated file diffable across regenerations.
    entries.sort(key=lambda e: (e["code"], e["file"], e["matching_key"]))
    return entries


def render_baseline_file(entries: list[dict], now: str, source_cmd: str, run_id: str) -> dict:
    counts: dict[str, int] = {}
    for e in entries:
        counts[e["code"]] = counts.get(e["code"], 0) + 1
    count_str = ", ".join(f"{counts.get(c, 0)} {c}" for c in SCOPED_CODES)
    return {
        "version": 1,
        "generated_at": now,
        "source": source_cmd,
        "regenerated_by": (
            f"{run_id} (GitHub #596 / ISS-0627, H003/H004/H005/H009 "
            "permanent-acknowledgment subset)"
        ),
        "regeneration_note": (
            f"Initial generation: {len(entries)} entries ({count_str}), one per "
            "finding tools/lint_handoffs.py reported against the full corpus "
            "at generation time. See docs/issues/ISS-0627.json for the shared "
            "root-cause narrative this baseline's reason_ref values point to."
        ),
        "reasons": dict(REASONS),
        "issues": entries,
    }


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def cmd_generate(args: argparse.Namespace) -> int:
    handoffs_dir = args.handoffs_dir
    if not os.path.isdir(handoffs_dir):
        print(f"error: {handoffs_dir!r} is not a directory", file=sys.stderr)
        return 2

    if args.apply and args.now is None:
        print(
            "error: --now ISO8601 is required with --apply "
            "(run `python3 tools/utcnow.py` and pass its output)",
            file=sys.stderr,
        )
        return 2

    parsed_files, runs = walk_corpus(handoffs_dir)
    findings_345 = scan_h003_h004_h005(parsed_files)
    h009_pairs = scan_h009(runs)

    now = args.now if args.now is not None else "<dry-run: --now not supplied>"
    out_path = Path(args.out) if args.out else DEFAULT_OUT
    source_cmd = (
        f"tools/generate_lint_handoffs_baseline.py --apply --now {now} "
        f"--run-id {args.run_id}"
    )
    entries = build_baseline_entries(findings_345, h009_pairs, now, args.run_id)
    doc = render_baseline_file(entries, now, source_cmd, args.run_id)

    counts: dict[str, int] = {}
    for e in entries:
        counts[e["code"]] = counts.get(e["code"], 0) + 1
    print("Proposed baseline entry counts:")
    for code in SCOPED_CODES:
        print(f"  {code}: {counts.get(code, 0)}")
    print(f"  TOTAL: {len(entries)}")

    if not args.apply:
        print()
        print(json.dumps(doc, indent=2, ensure_ascii=False))
        print()
        print("(dry-run — nothing written. Pass --apply --now <ts> to write.)")
        return 0

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(f"\nWrote {len(entries)} entries to {out_path}")
    return 0


# --------------------------------------------------------------------------
# selftest -- plain assert-style checks against synthetic fixtures
# --------------------------------------------------------------------------


def cmd_selftest() -> int:
    failures: list[str] = []

    def check(name: str, got, want) -> None:
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    def check_true(name: str, cond: bool) -> None:
        if not cond:
            failures.append(f"{name}: expected True, got False")

    # ---- Basic H003/H004/H005 scan via the real _lint_parsed_handoff ----
    parsed_h003 = {
        "handoff_id": "h1",
        "run_id": "r1",
        "step": "01",
        "from_agent": "ORCH",
        "to_agent": "BACKEND-DEV",
        "created_at": "2026-05-23T00:00:00Z",
        "started_at": "2026-05-23T04:40:00Z",
        "completed_at": "2026-05-23T01:10:00Z",
        "status": "COMPLETED",
    }
    findings_345 = scan_h003_h004_h005([("handoffs/FIX-01/step-01-x.json", parsed_h003)])
    codes = sorted(f.code for f in findings_345)
    check_true("selftest: H003 detected via real predicate", "H003" in codes)

    # ---- H005: COMPLETED with no completed_at ----
    parsed_h005 = {
        "handoff_id": "h2",
        "run_id": "r1",
        "step": "02",
        "from_agent": "ORCH",
        "to_agent": "BACKEND-DEV",
        "created_at": "2026-05-23T00:00:00Z",
        "status": "COMPLETED",
    }
    findings_h005 = scan_h003_h004_h005([("handoffs/FIX-01/step-02-x.json", parsed_h005)])
    check_true("selftest: H005 detected via real predicate", any(f.code == "H005" for f in findings_h005))

    # ---- H004 ----
    parsed_h004 = {
        "handoff_id": "h3",
        "run_id": "r1",
        "step": "03",
        "from_agent": "ORCH",
        "to_agent": "BACKEND-DEV",
        "created_at": "2026-05-23T05:00:00Z",
        "started_at": "2026-05-23T04:00:00Z",
        "status": "IN_PROGRESS",
    }
    findings_h004 = scan_h003_h004_h005([("handoffs/FIX-01/step-03-x.json", parsed_h004)])
    check_true("selftest: H004 detected via real predicate", any(f.code == "H004" for f in findings_h004))

    # ---- TS-BASELINE-05: generation script's local H009 orphan-walk matches
    # lint_orphans exactly (differential check, design §2.2) ----
    runs_fixture = {
        "WF02-x": [
            ("handoffs/WF02-x/step-02a-....json", {"step": "02a", "status": "PENDING"}),
            ("handoffs/WF02-x/step-03-....json", {"step": "03", "status": "COMPLETED"}),
            ("handoffs/WF02-x/step-04-....json", {"step": "04", "status": "COMPLETED"}),
        ]
    }
    findings_a: list[Finding] = []
    capture_a: dict[int, list[str]] = {}
    lint_orphans(runs_fixture, findings_a, capture=capture_a)
    check("selftest TS-BASELINE-05: exactly one H009 from real lint_orphans", len(findings_a), 1)

    pairs_b = _local_orphan_walk(runs_fixture)
    check("selftest TS-BASELINE-05: exactly one H009 from local orphan-walk", len(pairs_b), 1)

    if findings_a and pairs_b:
        msg_a = findings_a[0].message
        msg_b = pairs_b[0][0].message
        check("selftest TS-BASELINE-05: messages byte-identical", msg_a, msg_b)

        later_completed_paths = pairs_b[0][1]
        # Cross-check the captured list's length against the count embedded
        # in the official function's own message (lint_orphans discards the
        # list itself unless `capture` is passed — here we compare local
        # walk's captured list to the count parsed back out of the real
        # message, per design §7.5's second assertion).
        import re as _re

        m = _re.search(r"but (\d+) later step", msg_a)
        check_true("selftest TS-BASELINE-05: count parseable from message", m is not None)
        if m:
            check(
                "selftest TS-BASELINE-05: captured later_completed length matches message count",
                len(later_completed_paths),
                int(m.group(1)),
            )

        # Also cross-check against capture_a (the real function's own capture
        # side-channel) for full parity.
        real_later_completed = capture_a.get(id(findings_a[0]), [])
        check(
            "selftest TS-BASELINE-05: local walk's later_completed matches real capture",
            sorted(later_completed_paths),
            sorted(real_later_completed),
        )

    # Mutation check: off-by-one (ordered[idx + 2:] instead of
    # ordered[idx + 1:]) would incorrectly skip the step immediately after
    # the orphan, producing a different later_completed count/message. (Using
    # ordered[idx:] instead of ordered[idx + 1:] is NOT a usable mutation for
    # this differential check: the orphan step's own status is by definition
    # never COMPLETED — that is what makes it an orphan — so including index
    # `idx` itself never changes which entries pass the `status == COMPLETED`
    # filter, and the resulting message would be byte-identical to the
    # correct one regardless of fixture shape. ordered[idx + 2:] is the
    # off-by-one variant that this differential check can actually catch.)
    def _mutated_local_orphan_walk(
        runs: dict[str, list[tuple[str, dict]]]
    ) -> list[tuple[Finding, list[str]]]:
        open_statuses = {"PENDING", "IN_PROGRESS"}
        out: list[tuple[Finding, list[str]]] = []
        for run_id, entries in runs.items():
            ordered = sorted(entries, key=lambda e: step_sort_key(e[1].get("step", "")))
            for idx, (rel, handoff) in enumerate(ordered):
                if handoff.get("status") not in open_statuses:
                    continue
                # BUG: off-by-one, should be ordered[idx + 1:]
                later_completed = [
                    other for other, oh in ordered[idx + 2 :] if oh.get("status") == "COMPLETED"
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
                    out.append((finding, list(later_completed)))
        return out

    mutated_pairs = _mutated_local_orphan_walk(runs_fixture)
    if findings_a and mutated_pairs:
        check_true(
            "selftest TS-BASELINE-05 mutation check: off-by-one produces a different message",
            mutated_pairs[0][0].message != findings_a[0].message,
        )
    check_true(
        "selftest TS-BASELINE-05 mutation check: off-by-one fixture actually triggers the mutation",
        len(mutated_pairs) == 1,
    )

    # ---- build_baseline_entries / render_baseline_file smoke test ----
    entries = build_baseline_entries(findings_345 + findings_h005 + findings_h004, [], "2026-08-09T00:00:00Z", "TEST-RUN")
    check("selftest: build_baseline_entries produces expected count", len(entries), len(findings_345) + len(findings_h005) + len(findings_h004))
    for e in entries:
        check_true(f"selftest: entry for {e['file']} has reason_ref in REASONS", e["reason_ref"] in REASONS)

    doc = render_baseline_file(entries, "2026-08-09T00:00:00Z", "cmd", "TEST-RUN")
    check_true("selftest: rendered doc has 'issues' key with right length", len(doc["issues"]) == len(entries))
    check_true("selftest: rendered doc has all 4 reasons", set(doc["reasons"].keys()) == set(SCOPED_CODES))

    for f in failures:
        print(f"FAIL  {f}")
    if failures:
        print(f"\n{len(failures)} selftest failure(s)")
        return 1
    print("generate_lint_handoffs_baseline selftest: all checks passed")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("handoffs_dir", nargs="?", default="handoffs")
    parser.add_argument("--apply", action="store_true", help="write the baseline file (default: dry-run)")
    parser.add_argument("--out", default=None, help=f"output path (default: {DEFAULT_OUT})")
    parser.add_argument("--now", default=None, help="ISO8601 timestamp for generated_at/acknowledged_at (required with --apply)")
    parser.add_argument("--run-id", default="ADHOC", dest="run_id", help="run/PR identifier recorded in regenerated_by/acknowledged_by")
    return parser


def main(argv: list[str]) -> int:
    args = argv[1:]
    if "selftest" in args:
        return cmd_selftest()

    parser = build_parser()
    try:
        parsed_args = parser.parse_args(args)
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2

    return cmd_generate(parsed_args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
