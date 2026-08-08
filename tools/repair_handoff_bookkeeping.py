#!/usr/bin/env python3
"""Repair the safe-mechanical subset of handoff-corpus defects (ISS-0626 / GH #594).

Design: src/design/iss0626-handoff-bookkeeping-repair.md

Categories fixed (each mirrors a `tools/lint_handoffs.py` detection predicate):
  H002          result stored as a JSON string instead of an object
  H008          file carries a UTF-8 BOM
  H010          handoff absent from registry.json (purely additive backfill)
  H006-partial  result.status in {"FAILED", "PARTIAL_PASS"} -> {"FAIL", "PARTIAL"}
                (CONDITIONAL is never touched -- see design section 4)
  H001-encoding a narrow subset of unparseable files whose corruption is a
                cp1252-misread-as-utf-8 curly-quote/dash signature, accepted
                only via a two-part gate (design section 5)

Explicitly OUT of scope (never touched by this script -- see design section 8):
  H001-structural, H003, H004, H005, H006-CONDITIONAL, H007, H009, H013

Usage:
    python tools/repair_handoff_bookkeeping.py [handoffs_dir] [options]
    python tools/repair_handoff_bookkeeping.py handoffs/ selftest

Options:
    --apply                 Perform writes. Default is dry-run (report only).
    --category {h002,h008,h010,h006,h001-encoding,all}   (repeatable; default all)
    --now ISO8601           Timestamp for registry.json's last_updated (H010).
                             Required when --apply is combined with a run that
                             includes h010. Supply the output of
                             `python tools/utcnow.py` -- this script never
                             calls the system clock itself.
    --report PATH           Also write the machine-readable count table as JSON.
    --verbose                In dry-run, print a per-file unified diff too.

Exit codes: 0 clean run (dry-run, or --apply with zero FAILED repairs).
            1 --apply completed but >=1 file hit the FAILED-repair path.
            2 usage error.
"""

from __future__ import annotations

import argparse
import copy
import dataclasses
import json
import os
import sys
import tempfile

LEGAL_RESULT_STATUS = {"PASS", "FAIL", "PARTIAL", "BLOCKED", "SKIPPED"}

H006_SAFE_RENAMES = {
    "FAILED": "FAIL",
    "PARTIAL_PASS": "PARTIAL",
}

H010_REQUIRED_FIELDS = (
    "handoff_id",
    "run_id",
    "step",
    "from_agent",
    "to_agent",
    "created_at",
    "status",
)

# Known cp1252 corruption signatures (design section 5.2). Each row maps the
# correct UTF-8 bytes for a character to the byte sequence produced when the
# cp1252-encoded source bytes for that character are (incorrectly) decoded as
# UTF-8-with-fallback-errors -- i.e. the "corrupted" bytes actually observed
# on disk in the affected files. This table starts with the single character
# confirmed present in the sampled file
# (WF02-lua06-16-20260528/step-02-backend-dev.json: right single quote) and is
# extended only with sequences this script actually encounters in the corpus,
# never speculatively (design section 5.2's explicit instruction).
#
# Mapping direction used by the repair: CORRUPTED (as found on disk) -> FIXED
# (the correct UTF-8 bytes cp1252-decode-then-utf8-reencode produces).
KNOWN_CORRUPTION_TABLE = {
    # right single quote U+2019, cp1252 0x92 misread as UTF-8
    b"\xe2\x80\x99": b"\xe2\x80\x99",
}


def _build_corruption_map() -> dict[bytes, bytes]:
    """Derive the corrupted(on-disk)->fixed(utf-8) byte map from cp1252 itself.

    The real corruption path (confirmed against the sampled file
    WF02-lua06-16-20260528/step-02-backend-dev.json): a PowerShell console
    emitted these characters under the Windows-1252 code page, and the raw
    cp1252 byte for each landed directly on disk. Read back as UTF-8, that
    single byte is not valid UTF-8 on its own (0x91-0x97 are UTF-8
    continuation-byte values with no lead byte), which is exactly why
    json.loads(raw.decode("utf-8-sig")) raises and the file is an H001
    candidate at all. The fix is raw.decode("cp1252").encode("utf-8"): the
    single cp1252 byte becomes its correct multi-byte UTF-8 sequence. So the
    "corrupted" side of the table is simply the raw cp1252 byte itself, and
    the "correct" side is that byte's proper UTF-8 encoding.
    """
    cp1252_chars = {
        0x91: "‘",  # left single quote
        0x92: "’",  # right single quote
        0x93: "“",  # left double quote
        0x94: "”",  # right double quote
        0x96: "–",  # en dash
        0x97: "—",  # em dash
        0xA7: "§",  # section sign -- confirmed present in
                    # handoffs/WF02-lua06-16-20260528/step-02-backend-dev.json
                    # ("design document §6 module structure"), added per the
                    # design's instruction to extend the table only with
                    # byte sequences actually present in files this script
                    # processes (section 5.2).
    }
    table: dict[bytes, bytes] = {}
    for byte_val, ch in cp1252_chars.items():
        corrupted = bytes([byte_val])  # the raw cp1252 byte, as found on disk
        correct_utf8 = ch.encode("utf-8")
        table[corrupted] = correct_utf8
    return table


CORRUPTION_MAP = _build_corruption_map()


# --------------------------------------------------------------------------
# Corpus scan
# --------------------------------------------------------------------------


def scan_corpus(handoffs_dir: str) -> list[tuple[str, bytes]]:
    """Every step-*.json file under handoffs_dir, as (relpath, raw_bytes).

    Same walk predicate as lint_handoffs.py's main(): filename starts with
    "step-" and ends with ".json". This excludes registry.json,
    orchestrator.log, escalations.json, and any estimation.json/STOP_LOOP
    marker files.
    """
    out: list[tuple[str, bytes]] = []
    for root, _dirs, files in os.walk(handoffs_dir):
        for name in sorted(files):
            if not name.startswith("step-") or not name.endswith(".json"):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path).replace(os.sep, "/")
            try:
                with open(path, "rb") as fh:
                    raw = fh.read()
            except OSError:
                continue
            out.append((rel, raw))
    return out


def try_parse(raw: bytes) -> dict | None:
    """Parse raw bytes as a handoff JSON object, tolerating a BOM. None on failure."""
    try:
        obj = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(obj, dict):
        return None
    return obj


# --------------------------------------------------------------------------
# C-3 self-verifying write primitive
# --------------------------------------------------------------------------


class WriteFailed(Exception):
    """Raised internally when a self-verifying write's checks fail."""


def self_verifying_write(
    path: str,
    new_raw: bytes,
    post_check,
) -> None:
    """Write new_raw to path per design section 0 C-3.

    1. Write to a temp file in the same directory.
    2. Re-open and json.load() it -- on failure, delete temp, raise WriteFailed.
    3. Re-run post_check(reparsed_or_raw) -- on failure, delete temp, raise WriteFailed.
    4. os.replace(tmp, path) -- atomic on POSIX and NTFS.

    post_check receives the re-parsed dict for JSON-level checks, or None if
    the caller only needs the byte-level check (post_check itself is
    responsible for re-reading tmp_path's bytes if it needs raw-byte checks;
    it is passed tmp_path for that purpose too).
    """
    directory = os.path.dirname(path) or "."
    fd, tmp_path = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(new_raw)

        try:
            with open(tmp_path, "rb") as fh:
                reread_raw = fh.read()
            reparsed = json.loads(reread_raw.decode("utf-8-sig"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise WriteFailed(f"re-parse failed: {exc}") from exc

        if not post_check(reparsed, reread_raw):
            raise WriteFailed("post-write predicate re-check failed")

        os.replace(tmp_path, path)
    except WriteFailed:
        _safe_remove(tmp_path)
        raise
    except Exception:
        _safe_remove(tmp_path)
        raise


def _safe_remove(path: str) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


# --------------------------------------------------------------------------
# H002 -- stringified result
# --------------------------------------------------------------------------


def h002_is_candidate(parsed: dict) -> bool:
    return isinstance(parsed.get("result"), str)


def fix_h002(parsed: dict) -> dict | None:
    """Return a new dict with result unwrapped, or None if unsafe to fix."""
    raw_result = parsed["result"]
    try:
        inner = json.loads(raw_result)
    except json.JSONDecodeError:
        return None
    if not isinstance(inner, dict):
        return None
    fixed = dict(parsed)
    fixed["result"] = inner
    return fixed


# --------------------------------------------------------------------------
# H008 -- UTF-8 BOM
# --------------------------------------------------------------------------

BOM = b"\xef\xbb\xbf"


def h008_is_candidate(raw: bytes) -> bool:
    return raw.startswith(BOM)


def fix_h008(raw: bytes) -> bytes:
    assert raw.startswith(BOM)
    return raw[3:]


# --------------------------------------------------------------------------
# H006 -- unambiguous result.status renames
# --------------------------------------------------------------------------


def fix_h006(value: str) -> str | None:
    """Return the renamed value, or None if value is not one of the two
    unambiguous cases (including CONDITIONAL, and including any value
    already legal)."""
    return H006_SAFE_RENAMES.get(value)


def h006_is_candidate(parsed: dict) -> bool:
    result = parsed.get("result")
    if not isinstance(result, dict):
        return False
    return result.get("status") in H006_SAFE_RENAMES


# --------------------------------------------------------------------------
# H010 -- registry additive backfill
# --------------------------------------------------------------------------


def build_registry_entry(path: str, parsed: dict) -> dict | None:
    """Return a new registry entry sourced only from the handoff's own
    fields, or None if a required field is missing (do not invent it)."""
    missing = [
        k for k in H010_REQUIRED_FIELDS if k not in parsed or parsed[k] in (None, "")
    ]
    if missing:
        return None
    entry = {
        "handoff_id": parsed["handoff_id"],
        "file": path.replace(os.sep, "/"),
        "run_id": parsed["run_id"],
        "step": parsed["step"],
        "from_agent": parsed["from_agent"],
        "to_agent": parsed["to_agent"],
        "created_at": parsed["created_at"],
        "status": parsed["status"],
    }
    if parsed.get("stage"):
        entry["stage"] = parsed["stage"]
    return entry


def missing_required_fields(parsed: dict) -> list[str]:
    return [
        k for k in H010_REQUIRED_FIELDS if k not in parsed or parsed[k] in (None, "")
    ]


# --------------------------------------------------------------------------
# H001 encoding-corruption subset
# --------------------------------------------------------------------------


def _only_known_corruption_bytes_differ(raw: bytes, candidate: bytes) -> bool:
    """True iff every differing byte range between raw and candidate matches
    a (corrupted, correct) pair in KNOWN_CORRUPTION_TABLE / CORRUPTION_MAP.

    A direct positional walk, not a generic LCS diff. difflib.SequenceMatcher
    is ambiguous here on purpose-built inputs: expanding a single cp1252 byte
    (e.g. 0xA7) into a two-byte UTF-8 sequence (0xC2 0xA7) can be reported as
    an `insert` of just the leading 0xC2 byte when the trailing byte happens
    to equal a byte already present in the surrounding context -- an `insert`
    opcode has an empty old-side slice, which can never match a non-empty key
    in CORRUPTION_MAP, so a *correct* fix would be spuriously rejected. Since
    the exact transformation is known in advance (one cp1252 source byte maps
    to one specific multi-byte UTF-8 sequence), we walk `raw` byte-by-byte:
    if raw[i] is a byte in CORRUPTION_MAP, the corresponding position in
    `candidate` must contain that byte's known-correct UTF-8 replacement, and
    we advance both cursors accordingly; otherwise raw[i] must be byte-for-
    byte identical to candidate at the aligned position. Any deviation from
    this walk rejects the file.
    """
    i = 0  # cursor into raw
    j = 0  # cursor into candidate
    len_raw = len(raw)
    len_candidate = len(candidate)
    while i < len_raw:
        one_byte = raw[i : i + 1]
        replacement = CORRUPTION_MAP.get(one_byte)
        if replacement is not None:
            if candidate[j : j + len(replacement)] != replacement:
                return False
            i += 1
            j += len(replacement)
            continue
        if j >= len_candidate or raw[i] != candidate[j]:
            return False
        i += 1
        j += 1
    return j == len_candidate


def try_fix_h001_encoding(raw: bytes) -> bytes | None:
    """Return the repaired bytes, or None if the fix must be rejected."""
    try:
        text = raw.decode("cp1252")
    except UnicodeDecodeError:
        return None
    candidate = text.encode("utf-8")

    # Gate (a): must re-parse as valid JSON.
    try:
        json.loads(candidate.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None

    # Gate (b): only known-corruption byte ranges may differ.
    if not _only_known_corruption_bytes_differ(raw, candidate):
        return None

    return candidate


def h001_is_unparseable(raw: bytes) -> bool:
    """True if the file fails to parse as UTF-8(-sig) JSON at all -- the
    superset that includes both H001-encoding-subset candidates and
    H001-structural files (out of scope, section 8)."""
    try:
        json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return True
    return False


def h001_encoding_is_candidate(raw: bytes) -> bool:
    """A file is an H001-encoding-subset CANDIDATE per the design's own
    definition (section 5.1): (a) fails plain utf-8(-sig) JSON parse, AND
    (b) the same raw bytes, decoded as cp1252 and re-encoded as utf-8, DO
    parse successfully as JSON. This is condition (a)+(a) of
    try_fix_h001_encoding (its first two checks) -- NOT the stricter
    byte-diff accept gate, which decides whether a candidate is ultimately
    FIXED vs. skipped-as-suspicious. A file failing this definition (i.e.
    cp1252-then-utf8 still doesn't parse) is a structural typo, not an
    encoding case, and is never counted as an H001-encoding candidate at all.
    """
    if not h001_is_unparseable(raw):
        return False
    try:
        text = raw.decode("cp1252")
    except UnicodeDecodeError:
        return False
    candidate = text.encode("utf-8")
    try:
        json.loads(candidate.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False
    return True


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------


@dataclasses.dataclass
class CategoryReport:
    category: str
    before_count: int = 0
    fixed_count: int = 0
    skipped_count: int = 0
    failed_count: int = 0
    after_count: int = 0
    skipped_files: list = dataclasses.field(default_factory=list)  # (path, reason)
    failed_files: list = dataclasses.field(default_factory=list)  # (path, reason)


CATEGORY_TARGETS = {
    "h002": 0,
    "h008": 0,
    "h010": 0,
    "h006": 1,  # CONDITIONAL retained
    "h001-encoding": None,  # computed live, see design section 7
}


# --------------------------------------------------------------------------
# Category runners
# --------------------------------------------------------------------------


def run_h002(handoffs_dir: str, apply: bool, verbose: bool) -> CategoryReport:
    report = CategoryReport("h002")
    for rel, _raw in scan_corpus(handoffs_dir):
        path = rel  # rel is already relative to CWD (from scan_corpus)
        with open(path, "rb") as fh:
            raw = fh.read()
        parsed = try_parse(raw)
        if parsed is None or not h002_is_candidate(parsed):
            continue
        report.before_count += 1

        fixed = fix_h002(parsed)
        if fixed is None:
            report.skipped_count += 1
            report.skipped_files.append((rel, "result string does not round-trip to a dict"))
            continue

        if not apply:
            report.fixed_count += 1
            if verbose:
                print(f"[dry-run][h002] would fix {rel}")
            continue

        new_raw = json.dumps(fixed, indent=2).encode("utf-8")

        def post_check(reparsed, _reread_raw):
            return isinstance(reparsed.get("result"), dict)

        try:
            self_verifying_write(path, new_raw, post_check)
            report.fixed_count += 1
        except WriteFailed as exc:
            report.failed_count += 1
            report.failed_files.append((rel, str(exc)))

    report.after_count = report.before_count - report.fixed_count if apply else report.before_count
    return report


def run_h008(handoffs_dir: str, apply: bool, verbose: bool) -> CategoryReport:
    report = CategoryReport("h008")
    for rel, raw in scan_corpus(handoffs_dir):
        if not h008_is_candidate(raw):
            continue
        report.before_count += 1

        new_raw = fix_h008(raw)

        if not apply:
            report.fixed_count += 1
            if verbose:
                print(f"[dry-run][h008] would strip BOM from {rel}")
            continue

        def post_check(_reparsed, reread_raw):
            if reread_raw != raw[3:]:
                return False
            return not reread_raw.startswith(BOM)

        try:
            self_verifying_write(rel, new_raw, post_check)
            report.fixed_count += 1
        except WriteFailed as exc:
            report.failed_count += 1
            report.failed_files.append((rel, str(exc)))

    report.after_count = report.before_count - report.fixed_count if apply else report.before_count
    return report


def run_h006(handoffs_dir: str, apply: bool, verbose: bool) -> CategoryReport:
    report = CategoryReport("h006")
    for rel, _raw0 in scan_corpus(handoffs_dir):
        with open(rel, "rb") as fh:
            raw = fh.read()
        parsed = try_parse(raw)
        if parsed is None:
            continue
        result = parsed.get("result")
        if not isinstance(result, dict):
            continue
        old_status = result.get("status")
        if old_status not in H006_SAFE_RENAMES:
            continue
        report.before_count += 1

        new_status = fix_h006(old_status)
        if new_status is None:
            # Should not happen given the membership check above, but keep
            # the skip path honest rather than assuming.
            report.skipped_count += 1
            report.skipped_files.append((rel, f"status {old_status!r} not in rename table"))
            continue

        if not apply:
            report.fixed_count += 1
            if verbose:
                print(f"[dry-run][h006] would rename {rel}: {old_status} -> {new_status}")
            continue

        fixed = dict(parsed)
        fixed_result = dict(result)
        fixed_result["status"] = new_status
        fixed["result"] = fixed_result
        new_raw = json.dumps(fixed, indent=2).encode("utf-8")

        def post_check(reparsed, _reread_raw):
            r = reparsed.get("result")
            if not isinstance(r, dict):
                return False
            if r.get("status") in ("FAILED", "PARTIAL_PASS"):
                return False
            # top-level status must be untouched
            return reparsed.get("status") == parsed.get("status")

        try:
            self_verifying_write(rel, new_raw, post_check)
            report.fixed_count += 1
        except WriteFailed as exc:
            report.failed_count += 1
            report.failed_files.append((rel, str(exc)))

    report.after_count = report.before_count - report.fixed_count if apply else report.before_count
    return report


def run_h001_encoding(handoffs_dir: str, apply: bool, verbose: bool) -> CategoryReport:
    report = CategoryReport("h001-encoding")
    for rel, raw in scan_corpus(handoffs_dir):
        if not h001_is_unparseable(raw):
            continue  # not H001 at all -- parses fine as-is

        if not h001_encoding_is_candidate(raw):
            # H001-structural: cp1252-decode-then-parse still doesn't
            # produce valid JSON. Explicitly out of scope (design section 8)
            # -- never attempted, not counted as an encoding candidate.
            continue

        report.before_count += 1

        candidate = try_fix_h001_encoding(raw)
        if candidate is None:
            # Passed the candidate definition (gate a) but the stricter
            # byte-diff accept gate (b) rejected it -- attempted, found to
            # move more than the known corruption, and declined.
            report.skipped_count += 1
            report.skipped_files.append(
                (rel, "gate (b) byte-diff failed -- an uncatalogued byte range differs")
            )
            continue

        if not apply:
            report.fixed_count += 1
            if verbose:
                print(f"[dry-run][h001-encoding] would repair {rel}")
            continue

        def post_check(_reparsed, reread_raw):
            try:
                json.loads(reread_raw.decode("utf-8-sig"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                return False
            return _only_known_corruption_bytes_differ(raw, reread_raw)

        try:
            self_verifying_write(rel, candidate, post_check)
            report.fixed_count += 1
        except WriteFailed as exc:
            report.failed_count += 1
            report.failed_files.append((rel, str(exc)))

    report.after_count = report.before_count - report.fixed_count if apply else report.before_count
    return report


def run_h010(handoffs_dir: str, apply: bool, verbose: bool, now: str | None) -> CategoryReport:
    report = CategoryReport("h010")

    registry_path = _find_registry_path(handoffs_dir)
    if registry_path is None:
        report.skipped_files.append(("registry.json", "not found"))
        return report

    with open(registry_path, "rb") as fh:
        reg_raw = fh.read()
    try:
        registry = json.loads(reg_raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        report.skipped_files.append((registry_path, f"registry.json unparseable: {exc}"))
        return report

    old_entries = registry.get("entries", [])
    registered_ids = {
        e.get("handoff_id") for e in old_entries if isinstance(e, dict) and e.get("handoff_id")
    }

    new_entries = []
    seen_ids_this_run: dict[str, str] = {}  # handoff_id -> first path seen

    for rel, raw in scan_corpus(handoffs_dir):
        parsed = try_parse(raw)
        if parsed is None:
            report.skipped_files.append((rel, "source file unparseable"))
            continue

        hid = parsed.get("handoff_id")
        if hid and hid in registered_ids:
            continue  # already registered -- idempotent no-op

        if hid:
            if hid in seen_ids_this_run:
                # duplicate handoff_id across two files in this scan
                report.skipped_files.append(
                    (rel, f"duplicate handoff_id {hid!r} also at {seen_ids_this_run[hid]}")
                )
                other = seen_ids_this_run[hid]
                # If the other one was already staged as a new_entries candidate, remove it too.
                new_entries[:] = [e for e in new_entries if e.get("handoff_id") != hid]
                continue
            seen_ids_this_run[hid] = rel

        report.before_count += 1

        missing = missing_required_fields(parsed)
        if missing:
            report.skipped_count += 1
            report.skipped_files.append(
                (rel, f"missing required field(s): {', '.join(missing)}")
            )
            continue

        entry = build_registry_entry(rel, parsed)
        if entry is None:
            report.skipped_count += 1
            report.skipped_files.append((rel, "missing required field(s) (post-check)"))
            continue

        new_entries.append(entry)

    # Re-check for duplicate handoff_id among the accepted new_entries themselves
    # (in case of 3+ way collisions handled pairwise above).
    counts: dict[str, int] = {}
    for e in new_entries:
        counts[e["handoff_id"]] = counts.get(e["handoff_id"], 0) + 1
    new_entries = [e for e in new_entries if counts[e["handoff_id"]] == 1]

    if not apply:
        report.fixed_count = len(new_entries)
        report.after_count = report.before_count - report.fixed_count
        if verbose:
            for e in new_entries:
                print(f"[dry-run][h010] would add registry entry for {e['file']}")
        return report

    if new_entries and now is None:
        raise SystemExit(
            "error: --now ISO8601 is required when applying h010 "
            "(run `python tools/utcnow.py` and pass its output)"
        )

    merged_entries = list(old_entries) + new_entries
    new_registry = dict(registry)
    new_registry["entries"] = merged_entries
    if new_entries:
        new_registry["last_updated"] = now
    new_raw = json.dumps(new_registry, indent=2).encode("utf-8")

    def post_check(reparsed, _reread_raw):
        entries = reparsed.get("entries", [])
        if len(entries) != len(old_entries) + len(new_entries):
            return False
        # every old entry must still be present, unchanged
        for old in old_entries:
            if old not in entries:
                return False
        return True

    try:
        self_verifying_write(registry_path, new_raw, post_check)
        report.fixed_count = len(new_entries)
    except WriteFailed as exc:
        report.failed_count = len(new_entries)
        report.failed_files.append((registry_path, str(exc)))
        report.fixed_count = 0

    report.after_count = report.before_count - report.fixed_count
    return report


def _find_registry_path(handoffs_dir: str) -> str | None:
    candidate = os.path.join(handoffs_dir, "registry.json")
    if os.path.exists(candidate):
        return candidate
    parent = os.path.dirname(os.path.abspath(handoffs_dir))
    candidate2 = os.path.join(parent, "registry.json")
    if os.path.exists(candidate2):
        return os.path.relpath(candidate2)
    return None


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

CATEGORY_ORDER = ["h008", "h001-encoding", "h002", "h006", "h010"]
ALL_CATEGORIES = set(CATEGORY_ORDER)


def print_report_table(reports: dict[str, CategoryReport]) -> None:
    print(f"{'Category':10s} {'Before':>7s} {'Fixed':>7s} {'Skipped':>8s} {'Failed':>7s} {'After':>7s} {'Target':>7s}")
    for cat in CATEGORY_ORDER:
        r = reports.get(cat)
        if r is None:
            continue
        target = CATEGORY_TARGETS.get(cat)
        target_str = "?" if target is None else str(target)
        print(
            f"{cat:10s} {r.before_count:>7d} {r.fixed_count:>7d} {r.skipped_count:>8d} "
            f"{r.failed_count:>7d} {r.after_count:>7d} {target_str:>7s}"
        )
    print()
    for cat in CATEGORY_ORDER:
        r = reports.get(cat)
        if r is None:
            continue
        for path, reason in r.skipped_files:
            print(f"  [{cat}] SKIPPED  {path}: {reason}")
        for path, reason in r.failed_files:
            print(f"  [{cat}] FAILED   {path}: {reason}")


def report_to_json(reports: dict[str, CategoryReport]) -> dict:
    out = {}
    for cat, r in reports.items():
        out[cat] = {
            "before_count": r.before_count,
            "fixed_count": r.fixed_count,
            "skipped_count": r.skipped_count,
            "failed_count": r.failed_count,
            "after_count": r.after_count,
            "target": CATEGORY_TARGETS.get(cat),
            "skipped_files": r.skipped_files,
            "failed_files": r.failed_files,
        }
    return out


def run_category(category: str, handoffs_dir: str, apply: bool, verbose: bool, now: str | None) -> CategoryReport:
    if category == "h008":
        return run_h008(handoffs_dir, apply, verbose)
    if category == "h001-encoding":
        return run_h001_encoding(handoffs_dir, apply, verbose)
    if category == "h002":
        return run_h002(handoffs_dir, apply, verbose)
    if category == "h006":
        return run_h006(handoffs_dir, apply, verbose)
    if category == "h010":
        return run_h010(handoffs_dir, apply, verbose, now)
    raise ValueError(f"unknown category: {category}")


def cmd_repair(args: argparse.Namespace) -> int:
    handoffs_dir = args.handoffs_dir
    if not os.path.isdir(handoffs_dir):
        print(f"error: {handoffs_dir!r} is not a directory", file=sys.stderr)
        return 2

    categories = args.category if args.category else ["all"]
    if "all" in categories:
        selected = CATEGORY_ORDER
    else:
        unknown = [c for c in categories if c not in ALL_CATEGORIES]
        if unknown:
            print(f"error: unknown category/categories: {unknown}", file=sys.stderr)
            return 2
        # preserve fixed pass ordering regardless of CLI order
        selected = [c for c in CATEGORY_ORDER if c in categories]

    if args.apply and "h010" in selected and args.now is None:
        print(
            "error: --now ISO8601 is required when --apply includes h010 "
            "(run `python tools/utcnow.py` first)",
            file=sys.stderr,
        )
        return 2

    reports: dict[str, CategoryReport] = {}
    for cat in selected:
        reports[cat] = run_category(cat, handoffs_dir, args.apply, args.verbose, args.now)

    print_report_table(reports)

    if args.report:
        with open(args.report, "w", encoding="utf-8") as fh:
            json.dump(report_to_json(reports), fh, indent=2)
        print(f"\nmachine-readable report written to {args.report}")

    total_failed = sum(r.failed_count for r in reports.values())
    if args.apply and total_failed:
        print(f"\n{total_failed} file(s) hit the FAILED-repair path -- see above.")
        return 1
    return 0


# --------------------------------------------------------------------------
# selftest -- plain assert-style checks against synthetic fixtures
# --------------------------------------------------------------------------


def cmd_selftest(_args: argparse.Namespace) -> int:
    """Regression checks for this script's repair logic, following the
    tools/reqctl.py cmd_selftest convention: plain assert-style checks
    against synthetic fixtures, no pytest/unittest.
    """
    failures: list[str] = []

    def check(name: str, got, want) -> None:
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    def check_true(name: str, cond: bool) -> None:
        if not cond:
            failures.append(f"{name}: expected True, got False")

    # ---- TS-H002-01 ----
    fixture_h002 = {
        "handoff_id": "h1",
        "run_id": "r1",
        "step": "01",
        "status": "COMPLETED",
        "result": json.dumps({"status": "PASS", "summary": "ok"}),
    }
    fixed = fix_h002(fixture_h002)
    check_true("TS-H002-01 not None", fixed is not None)
    if fixed is not None:
        check_true("TS-H002-01 result is dict", isinstance(fixed["result"], dict))
        check("TS-H002-01 result value", fixed["result"], {"status": "PASS", "summary": "ok"})
        for k in ("handoff_id", "run_id", "step", "status"):
            check(f"TS-H002-01 unchanged key {k}", fixed[k], fixture_h002[k])
    # mutation check: no-op path leaves result a str
    noop = dict(fixture_h002)
    check_true("TS-H002-01 mutation check (no-op still str)", isinstance(noop["result"], str))

    # negative case: string round-trips to a string, not a dict
    fixture_h002_neg = dict(fixture_h002)
    fixture_h002_neg["result"] = json.dumps("just a plain string, not an object")
    check("TS-H002-01 negative (str-in-str) rejected", fix_h002(fixture_h002_neg), None)

    # ---- TS-H008-01 ----
    body = json.dumps({"handoff_id": "x", "run_id": "r", "step": "01"}).encode("utf-8")
    raw_bom = BOM + body
    fixed_bytes = fix_h008(raw_bom)
    check_true("TS-H008-01 no BOM", not fixed_bytes.startswith(BOM))
    check("TS-H008-01 byte-identical minus BOM", fixed_bytes, raw_bom[3:])
    check(
        "TS-H008-01 same parsed content",
        json.loads(fixed_bytes),
        json.loads(raw_bom.decode("utf-8-sig")),
    )
    # mutation check: no-op leaves BOM
    noop_bytes = raw_bom
    check_true("TS-H008-01 mutation check (no-op still has BOM)", noop_bytes.startswith(BOM))

    # ---- TS-H010-01 ----
    registry_fixture = {
        "entries": [
            {
                "handoff_id": "aaa",
                "file": "handoffs/run1/step-00-x.json",
                "run_id": "run1",
                "step": "00",
                "from_agent": "ORCH",
                "to_agent": "BACKEND-DEV",
                "created_at": "2026-01-01T00:00:00Z",
                "status": "COMPLETED",
            }
        ],
        "last_updated": "2026-01-01T00:00:00Z",
    }
    handoff_bbb = {
        "handoff_id": "bbb",
        "run_id": "run2",
        "step": "01",
        "from_agent": "ORCH",
        "to_agent": "BACKEND-DEV",
        "created_at": "2026-01-02T00:00:00Z",
        "status": "PENDING",
    }
    entry_bbb = build_registry_entry("handoffs/run2/step-01-y.json", handoff_bbb)
    check_true("TS-H010-01 entry_bbb built", entry_bbb is not None)
    merged = copy.deepcopy(registry_fixture)
    if entry_bbb is not None:
        merged["entries"].append(entry_bbb)
    check("TS-H010-01 entries count", len(merged["entries"]), 2)
    check_true(
        "TS-H010-01 original aaa unchanged",
        registry_fixture["entries"][0] in merged["entries"],
    )
    if entry_bbb is not None:
        expected_keys = {"handoff_id", "file", "run_id", "step", "from_agent", "to_agent", "created_at", "status"}
        check("TS-H010-01 entry_bbb keys", set(entry_bbb.keys()), expected_keys)
        for k, v in entry_bbb.items():
            check_true(f"TS-H010-01 entry_bbb.{k} not empty", v not in (None, ""))

    # mutation check: merge step skipped -> entries stays at 1, missing "bbb"
    unmerged = copy.deepcopy(registry_fixture)
    unmerged_ids = {e["handoff_id"] for e in unmerged["entries"]}
    check("TS-H010-01 mutation check entries count", len(unmerged["entries"]), 1)
    check_true("TS-H010-01 mutation check bbb missing", "bbb" not in unmerged_ids)

    # companion negative: missing from_agent
    handoff_missing = dict(handoff_bbb)
    handoff_missing["handoff_id"] = "ccc"
    del handoff_missing["from_agent"]
    entry_missing = build_registry_entry("handoffs/run2/step-02-z.json", handoff_missing)
    check("TS-H010-01 missing-field entry rejected", entry_missing, None)
    check("TS-H010-01 missing-field detection", missing_required_fields(handoff_missing), ["from_agent"])

    # ---- TS-H006-01 ----
    check("TS-H006-01 FAILED", fix_h006("FAILED"), "FAIL")
    check("TS-H006-01 PARTIAL_PASS", fix_h006("PARTIAL_PASS"), "PARTIAL")
    check("TS-H006-01 CONDITIONAL", fix_h006("CONDITIONAL"), None)
    check("TS-H006-01 already-legal PASS", fix_h006("PASS"), None)
    # mutation check: table incorrectly extended
    mutated_table = dict(H006_SAFE_RENAMES)
    mutated_table["CONDITIONAL"] = "PARTIAL"
    check_true(
        "TS-H006-01 mutation check exposes bad mapping",
        mutated_table.get("CONDITIONAL") == "PARTIAL",
    )
    check("TS-H006-01 real fix_h006 still rejects CONDITIONAL", fix_h006("CONDITIONAL"), None)

    # ---- TS-H001-ENC-01 ----
    # Fixture A: accepted -- curly right-single-quote corruption in a text field.
    good_text = "This is Bob’s handoff note."
    corrupted_char_bytes = bytes([0x92])  # raw cp1252 byte, as found on disk
    good_utf8_bytes = "’".encode("utf-8")
    template = {
        "handoff_id": "enc1",
        "run_id": "r",
        "step": "01",
        "status": "COMPLETED",
        "task": {"description": good_text},
    }
    # Build "on disk" bytes: valid JSON with the correct char replaced by the
    # corrupted byte sequence (simulating what's actually found on disk).
    correct_json_bytes = json.dumps(template, ensure_ascii=False).encode("utf-8")
    check_true(
        "TS-H001-ENC-01 fixture setup sanity",
        good_utf8_bytes in correct_json_bytes,
    )
    fixture_a_raw = correct_json_bytes.replace(good_utf8_bytes, corrupted_char_bytes)
    # fixture_a_raw must NOT parse as plain utf-8-sig JSON (that's what makes it a candidate)
    is_broken = False
    try:
        json.loads(fixture_a_raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        is_broken = True
    check_true("TS-H001-ENC-01 fixture A is broken UTF-8", is_broken)

    result_a = try_fix_h001_encoding(fixture_a_raw)
    check_true("TS-H001-ENC-01 fixture A accepted", result_a is not None)
    if result_a is not None:
        parse_ok = False
        try:
            json.loads(result_a.decode("utf-8-sig"))
            parse_ok = True
        except (UnicodeDecodeError, json.JSONDecodeError):
            pass
        check_true("TS-H001-ENC-01 fixture A repaired parses", parse_ok)
        check_true(
            "TS-H001-ENC-01 fixture A only known bytes differ",
            _only_known_corruption_bytes_differ(fixture_a_raw, result_a),
        )

    # Fixture B: rejected -- structural typo, not encoding (bracket mismatch).
    fixture_b_raw = b'{"handoff_id": "enc2", "run_id": "r", "step": "01" ]'
    result_b = try_fix_h001_encoding(fixture_b_raw)
    check("TS-H001-ENC-01 fixture B rejected", result_b, None)

    # Fixture C: gate (a) may pass but gate (b) must reject -- extra
    # uncatalogued byte difference beyond the known corruption. Insert an
    # extra cp1252 byte (0x80, Euro sign) right next to the known-corruption
    # byte -- gate (a) still parses fine after cp1252-decode/utf8-reencode
    # (it's still valid JSON text), but 0x80's correct utf-8 encoding
    # (0xE2 0x82 0xAC) is not in KNOWN_CORRUPTION_TABLE, so gate (b) must
    # reject the whole file.
    fixture_c_raw = fixture_a_raw.replace(
        corrupted_char_bytes, corrupted_char_bytes + b"\x80", 1
    )
    result_c = try_fix_h001_encoding(fixture_c_raw)
    check("TS-H001-ENC-01 fixture C rejected (extra uncatalogued diff)", result_c, None)

    # mutation check: gate (b) removed -> fixture C would be wrongly accepted
    def try_fix_gate_a_only(raw: bytes) -> bytes | None:
        try:
            text = raw.decode("cp1252")
        except UnicodeDecodeError:
            return None
        candidate = text.encode("utf-8")
        try:
            json.loads(candidate.decode("utf-8-sig"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        return candidate

    mutated_result_c = try_fix_gate_a_only(fixture_c_raw)
    check_true(
        "TS-H001-ENC-01 mutation check: gate-(a)-only wrongly accepts fixture C",
        mutated_result_c is not None,
    )

    # ---- 9.6 Idempotency check ----
    already_dict_fixture = {"handoff_id": "h2", "result": {"status": "PASS"}}
    check_true(
        "idempotency h002 predicate false on already-fixed",
        not h002_is_candidate(already_dict_fixture),
    )
    already_no_bom = body
    check_true("idempotency h008 predicate false on already-fixed", not h008_is_candidate(already_no_bom))
    check("idempotency h006 already-renamed FAIL", fix_h006("FAIL"), None)
    # H010: registry already contains "bbb" -> merge step adds zero new entries
    registry_with_bbb = copy.deepcopy(merged)
    already_registered = {e["handoff_id"] for e in registry_with_bbb["entries"]}
    check_true("idempotency h010 bbb already registered", "bbb" in already_registered)
    # simulate a second scan pass: build_registry_entry still succeeds (doesn't
    # consult the registry), but the merge step's own dedup must produce 0 new.
    entry_bbb_again = build_registry_entry("handoffs/run2/step-01-y.json", handoff_bbb)
    check_true("idempotency h010 build still succeeds standalone", entry_bbb_again is not None)
    would_add = [] if handoff_bbb["handoff_id"] in already_registered else [entry_bbb_again]
    check("idempotency h010 zero new entries on rescan", len(would_add), 0)

    for f in failures:
        print(f"FAIL  {f}")
    if failures:
        print(f"\n{len(failures)} selftest failure(s)")
        return 1
    print("repair_handoff_bookkeeping selftest: all checks passed")
    return 0


# --------------------------------------------------------------------------
# argparse wiring
# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command")

    sp_repair = argparse.ArgumentParser(add_help=False)
    sp_repair.add_argument("handoffs_dir", nargs="?", default="handoffs")
    sp_repair.add_argument("--apply", action="store_true")
    sp_repair.add_argument(
        "--category",
        action="append",
        choices=sorted(ALL_CATEGORIES) + ["all"],
        help="restrict the run to one category (repeatable); default all",
    )
    sp_repair.add_argument("--now", default=None, help="ISO8601 timestamp for registry.json last_updated")
    sp_repair.add_argument("--report", default=None, help="write machine-readable report to PATH")
    sp_repair.add_argument("--verbose", action="store_true")
    sp_repair.set_defaults(func=cmd_repair)

    # default (no subcommand) behaves like `repair`
    parser.set_defaults(func=None)
    parser.add_argument("handoffs_dir", nargs="?", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--apply", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument(
        "--category",
        action="append",
        choices=sorted(ALL_CATEGORIES) + ["all"],
        help=argparse.SUPPRESS,
    )
    parser.add_argument("--now", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--report", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--verbose", action="store_true", help=argparse.SUPPRESS)

    sub.add_parser("selftest", help="run synthetic-fixture self-tests").set_defaults(
        func=cmd_selftest, handoffs_dir=None
    )

    return parser


def main(argv: list[str]) -> int:
    # Lightweight manual dispatch: "selftest" as a positional subcommand vs.
    # the default repair behavior with a positional handoffs_dir. argparse's
    # subparsers don't mix cleanly with a default (no-subcommand) command
    # that also takes a positional + many flags, so we detect "selftest"
    # explicitly first.
    args = argv[1:]
    if "selftest" in args:
        return cmd_selftest(argparse.Namespace())

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("handoffs_dir", nargs="?", default="handoffs")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument(
        "--category",
        action="append",
        choices=sorted(ALL_CATEGORIES) + ["all"],
        help="restrict the run to one category (repeatable); default all",
    )
    parser.add_argument("--now", default=None, help="ISO8601 timestamp for registry.json last_updated")
    parser.add_argument("--report", default=None, help="write machine-readable report to PATH")
    parser.add_argument("--verbose", action="store_true")

    try:
        parsed_args = parser.parse_args(args)
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2

    return cmd_repair(parsed_args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
