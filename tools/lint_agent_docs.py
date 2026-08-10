#!/usr/bin/env python3
"""Keep the agent instruction layers consistent with their shared protocol.

The pipeline carries three instruction layers that say overlapping things:

    CLAUDE.md                       (Claude Code, project-wide)
    .github/agents/*.agent.md       (Claude Code, per-agent)
    .github/instructions/*.md       (GitHub Copilot, per-agent)

Before the 2026-08-05 audit, every shared rule was written out in all three.
The cost was measurable: `lint_test_isolation.py` was mandated in CLAUDE.md but
missing from test-designer.agent.md — the layer that actually runs — which is
why 17 of 21 TEST-DESIGN-VALIDATOR rejections were violations a linter already
detected. Four agent files also told agents to set `started_at` themselves while
the rest correctly said ORCH stamps it.

Shared rules now live in docs/agents/shared/*.md. This linter checks that the
per-agent files reference the shared protocol rather than re-stating it, so the
duplication cannot silently return.

Checks:
  A001  BLOCKER  agent file completes handoffs but never references the shared protocol
  A002  MAJOR    agent file contradicts the shared protocol on started_at ownership
  A003  MAJOR    agent file re-states a shared rule inline instead of referencing it
  A004  MAJOR    referenced shared file does not exist
  A005  MINOR    agent file has malformed frontmatter
  A006  BLOCKER  agent file defines a pipeline gate as a match on command output
  A007  MINOR    a .github/ role file has meaningfully diverged from its
                  .claude/agents/ counterpart (content-hash drift check)

Usage:
    python3 tools/lint_agent_docs.py [--quiet]
    python3 tools/lint_agent_docs.py --no-baseline    # A007: ignore the baseline, report all drift

Exit codes: 0 = no BLOCKER/MAJOR, 1 = findings. A007 is MINOR (report-only by
severity policy — see SEVERITY_ORDER / the exit-code rule below) and is further
suppressed against tools/lint_agent_docs.baseline.json by default so that
today's known, deliberately-out-of-scope drift (GH-693 / ISS-0661) does not
retroactively block every future PR — see that file's header for the
acknowledgment record and docs/agents/AGENT_SYSTEM.md §9 for the rationale.
--no-baseline reports the full, unsuppressed A007 finding set (still MINOR,
still non-blocking) for when a human wants to see current drift in full.
"""

from __future__ import annotations

import glob
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

SHARED_DIR = "docs/agents/shared"
SHARED_PROTOCOL = f"{SHARED_DIR}/HANDOFF_PROTOCOL.md"

AGENT_GLOBS = (
    ".claude/agents/*.md",
    ".github/agents/*.agent.md",
    ".github/instructions/*.instructions.md",
)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_A007_BASELINE = REPO_ROOT / "tools" / "lint_agent_docs.baseline.json"

# A007 role-name extraction: strip the harness-specific suffix to get the bare
# role slug shared across all three surfaces, e.g.
#   .claude/agents/backend-dev.md            -> backend-dev
#   .github/agents/backend-dev.agent.md       -> backend-dev
#   .github/instructions/backend-dev.instructions.md -> backend-dev
ROLE_SUFFIXES = (".agent.md", ".instructions.md", ".md")

# A007 divergence threshold: below this Jaccard similarity on normalized
# significant-word sets, two files are considered to have "meaningfully
# diverged" rather than merely reformatted. Chosen empirically (see
# tools/lint_agent_docs.baseline.json regeneration_note) — high enough that
# two files saying the same thing with different markdown/heading structure
# still match, low enough that a genuinely missing section (e.g. an entire
# codegen workflow) drops below it.
A007_SIMILARITY_THRESHOLD = 0.55

_WORD_RE = re.compile(r"[a-z][a-z0-9_./-]{3,}")
_STOPWORDS = frozenset(
    {
        "this", "that", "with", "from", "your", "have", "will", "must",
        "then", "when", "each", "into", "read", "file", "step", "before",
        "after", "handoff", "agent", "status", "never", "always", "which",
        "these", "those", "should", "shell", "command", "output", "exact",
    }
)

# A file "completes handoffs" if it talks about writing a result back.
COMPLETES_HANDOFF = re.compile(
    r"complete-handoff|completed_at|Complete the handoff", re.I
)

# Instructions that contradict the shared protocol's ownership of started_at.
CONTRADICTS_STARTED_AT = re.compile(
    r"set\s+`?started_at`?\s+to\s+(the\s+)?current", re.I
)

# Rules that belong to the shared protocol. If a per-agent file spells one of
# these out in full rather than referencing the shared file, the duplication is
# back and will drift. Each entry: (code-ish name, detector, why it matters).
SHARED_RULES = (
    (
        "legal result.status enumeration",
        re.compile(r"`?PASS`?\s*[/|]\s*`?FAIL`?\s*[/|]\s*`?PARTIAL`?\s*[/|]\s*`?BLOCKED`?"),
        "the legal result.status set is defined once in the shared protocol §4",
    ),
    (
        "handoff lint gate command",
        re.compile(r"lint_handoffs\.py"),
        "reference the shared protocol §5 instead of restating the gate",
    ),
)

# A file may mention a shared rule *while* referencing the shared file — that is
# a summary, not duplication. Only flag when the shared file is never mentioned.

# Gates must be defined as exit codes, not as text matched against a command's
# output. A gate an implementing agent can satisfy by editing the matched text
# will eventually be satisfied that way -- see the 2026-05-30 incident where
# `zig build bench`'s source labels were renamed so ORCH's grep stopped firing.
# Prose that *describes* the historical incident is fine; a live instruction to
# match on output is not. Distinguished by whether the line reads as a directive.
GATE_BY_OUTPUT_MATCH = re.compile(
    r"^(?!\s*>).*?(?:If (?:the )?output (?:contains|shows)|"
    r"\$result\s*-match|grep -qiE?)\s*.{0,40}"
    r"(?:BENCHMARK_SETUP_ERROR|BPM_DB_URL)",
    re.M,
)

SEVERITY_ORDER = {"BLOCKER": 0, "MAJOR": 1, "MINOR": 2}


def role_slug(path: str) -> str:
    """Bare role name shared across all three harness surfaces.

    '.claude/agents/backend-dev.md' -> 'backend-dev'
    '.github/agents/backend-dev.agent.md' -> 'backend-dev'
    '.github/instructions/backend-dev.instructions.md' -> 'backend-dev'
    """
    name = os.path.basename(path)
    for suffix in ROLE_SUFFIXES:
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


def normalized_word_set(body: str) -> set[str]:
    """Content signal for A007's divergence check.

    Strips YAML frontmatter (harness-specific: name/description differ in
    quoting style, not content), lowercases, and extracts significant words
    (>=4 chars, alnum/path-ish) minus a small stopword list of connective
    tissue that every one of these files shares regardless of content
    (headings like "Session start", boilerplate like "never/always/must").
    What's left is dominated by the nouns that actually distinguish one
    role's instructions from another's — tool names, file paths, command
    names, requirement IDs — so a file that lost a whole section (e.g. the
    Type A/C codegen workflow) loses a cluster of matching words, while a
    file that was merely reformatted or re-ordered does not.
    """
    if body.startswith("---"):
        end = body.find("\n---", 3)
        if end != -1:
            body = body[end + 4 :]
    words = _WORD_RE.findall(body.lower())
    return {w for w in words if w not in _STOPWORDS}


def jaccard(a: set[str], b: set[str]) -> float:
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def a007_key(path: str, counterpart: str, similarity: float) -> str:
    return f"A007|{path}|{counterpart}|{round(similarity, 2)}"


def load_a007_baseline(path: Path) -> set[str]:
    """Same shape/contract as tools/lint_test_isolation.py's load_baseline:
    missing or malformed file degrades to an empty set (report everything),
    never a crash."""
    if not path.exists():
        return set()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return set()
    if not isinstance(raw, dict):
        return set()
    issues = raw.get("issues", [])
    if not isinstance(issues, list):
        return set()
    out: set[str] = set()
    for item in issues:
        if not isinstance(item, dict):
            continue
        key = item.get("matching_key")
        if isinstance(key, str):
            out.add(key)
    return out


class Finding:
    __slots__ = ("code", "severity", "path", "message", "baseline_key")

    def __init__(self, code, severity, path, message, baseline_key=None):
        self.code = code
        self.severity = severity
        self.path = path
        self.message = message
        self.baseline_key = baseline_key

    def __str__(self):
        return f"{self.severity:7s} {self.code}  {self.path}\n         {self.message}"


def agent_files() -> list[str]:
    out: list[str] = []
    for pattern in AGENT_GLOBS:
        out.extend(sorted(glob.glob(pattern)))
    return out


def main(argv: list[str]) -> int:
    quiet = "--quiet" in argv[1:]
    no_baseline = "--no-baseline" in argv[1:]
    findings: list[Finding] = []

    if not os.path.exists(SHARED_PROTOCOL):
        findings.append(
            Finding(
                "A004",
                "MAJOR",
                SHARED_PROTOCOL,
                "Shared protocol file is missing; every agent reference points at nothing.",
            )
        )

    files = agent_files()
    if not files:
        print("lint_agent_docs: no agent files found", file=sys.stderr)
        return 0

    bodies: dict[str, str] = {}

    for path in files:
        rel = path.replace(os.sep, "/")
        with open(path, encoding="utf-8-sig") as fh:
            body = fh.read()
        bodies[rel] = body

        references_shared = "HANDOFF_PROTOCOL" in body

        if not body.startswith("---"):
            findings.append(
                Finding("A005", "MINOR", rel, "File does not start with a frontmatter block.")
            )

        if COMPLETES_HANDOFF.search(body) and not references_shared:
            findings.append(
                Finding(
                    "A001",
                    "BLOCKER",
                    rel,
                    "This agent completes handoffs but never references "
                    f"`{SHARED_PROTOCOL}`. Add the shared-protocol read to its session-start "
                    "block, or the agent will follow whatever this file happens to say and "
                    "drift from every other agent.",
                )
            )

        m = CONTRADICTS_STARTED_AT.search(body)
        if m:
            line_no = body[: m.start()].count("\n") + 1
            findings.append(
                Finding(
                    "A002",
                    "MAJOR",
                    f"{rel}:{line_no}",
                    "Tells the agent to set `started_at` itself. ORCH stamps `started_at` "
                    "immediately before dispatch — an agent that sets it produces a value "
                    "later than its own dispatch. See shared protocol §3.",
                )
            )

        gate = GATE_BY_OUTPUT_MATCH.search(body)
        if gate:
            line_no = body[: gate.start()].count("\n") + 1
            findings.append(
                Finding(
                    "A006",
                    "BLOCKER",
                    f"{rel}:{line_no}",
                    "Defines a pipeline gate by matching text in a command's output. "
                    "An agent can satisfy that by editing the text — which is exactly "
                    "what happened on 2026-05-30. Use an exit code instead: "
                    "`zig build test-env-verify`.",
                )
            )

        if not references_shared:
            for name, detector, why in SHARED_RULES:
                hit = detector.search(body)
                if hit:
                    line_no = body[: hit.start()].count("\n") + 1
                    findings.append(
                        Finding(
                            "A003",
                            "MAJOR",
                            f"{rel}:{line_no}",
                            f"Re-states the shared rule '{name}' without referencing the "
                            f"shared protocol — {why}.",
                        )
                    )

    # ------------------------------------------------------------------
    # A007 — cross-surface drift detection (GH-693 / ISS-0661).
    #
    # .claude/agents/<role>.md is canonical (AGENT_SYSTEM.md §9). For every
    # role that also has a .github/agents/<role>.agent.md and/or
    # .github/instructions/<role>.instructions.md file, compare each against
    # its canonical counterpart via normalized_word_set()/jaccard(). Below
    # A007_SIMILARITY_THRESHOLD means the two files have meaningfully
    # diverged in content, not just formatting — flag it.
    #
    # This does NOT run when the canonical file doesn't exist for a role
    # (e.g. no .claude/agents/ file at all) — that is a structural gap, not
    # drift, and outside A007's job.
    # ------------------------------------------------------------------
    canonical_by_role: dict[str, str] = {}
    for rel in bodies:
        if rel.startswith(".claude/agents/"):
            canonical_by_role[role_slug(rel)] = rel

    a007_findings: list[Finding] = []
    for rel, body in bodies.items():
        if rel.startswith(".claude/agents/"):
            continue
        role = role_slug(rel)
        canonical_rel = canonical_by_role.get(role)
        if canonical_rel is None:
            continue  # no canonical counterpart to diff against — not A007's job
        sim = jaccard(normalized_word_set(body), normalized_word_set(bodies[canonical_rel]))
        if sim < A007_SIMILARITY_THRESHOLD:
            a007_findings.append(
                Finding(
                    "A007",
                    "MINOR",
                    rel,
                    f"Content similarity to canonical `{canonical_rel}` is "
                    f"{sim:.2f} (threshold {A007_SIMILARITY_THRESHOLD}) — this file has "
                    "meaningfully diverged, not just been reformatted. Fold any content "
                    f"`{canonical_rel}` is missing back into it (canonical, per "
                    "AGENT_SYSTEM.md §9), then re-sync this file, or confirm the gap is "
                    "already tracked as known debt.",
                    baseline_key=a007_key(rel, canonical_rel, sim),
                )
            )

    suppressed_a007 = 0
    baseline_path = DEFAULT_A007_BASELINE
    if not no_baseline and a007_findings:
        baseline_keys = load_a007_baseline(baseline_path)
        if baseline_keys:
            remaining: list[Finding] = []
            for f in a007_findings:
                if f.baseline_key in baseline_keys:
                    suppressed_a007 += 1
                    continue
                remaining.append(f)
            a007_findings = remaining

    findings.extend(a007_findings)

    findings.sort(key=lambda f: (SEVERITY_ORDER.get(f.severity, 9), f.code, f.path))

    counts: dict[str, int] = defaultdict(int)
    for f in findings:
        counts[f.severity] += 1

    if not quiet:
        for f in findings:
            print(f)
        if findings:
            print()

    print(
        f"lint_agent_docs: {len(files)} agent files checked — "
        f"{counts['BLOCKER']} BLOCKER, {counts['MAJOR']} MAJOR, {counts['MINOR']} MINOR"
    )
    if suppressed_a007:
        print(
            f"lint_agent_docs: {suppressed_a007} A007 finding(s) suppressed by "
            f"{baseline_path.relative_to(REPO_ROOT).as_posix()} "
            "(pre-existing, acknowledged drift — GH-693 / ISS-0661; use --no-baseline to see them)"
        )
    return 1 if (counts["BLOCKER"] or counts["MAJOR"]) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
