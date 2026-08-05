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

Usage:
    python3 tools/lint_agent_docs.py [--quiet]

Exit codes: 0 = no BLOCKER/MAJOR, 1 = findings.
"""

from __future__ import annotations

import glob
import os
import re
import sys
from collections import defaultdict

SHARED_DIR = "docs/agents/shared"
SHARED_PROTOCOL = f"{SHARED_DIR}/HANDOFF_PROTOCOL.md"

AGENT_GLOBS = (
    ".github/agents/*.agent.md",
    ".github/instructions/*.instructions.md",
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
SEVERITY_ORDER = {"BLOCKER": 0, "MAJOR": 1, "MINOR": 2}


class Finding:
    __slots__ = ("code", "severity", "path", "message")

    def __init__(self, code, severity, path, message):
        self.code = code
        self.severity = severity
        self.path = path
        self.message = message

    def __str__(self):
        return f"{self.severity:7s} {self.code}  {self.path}\n         {self.message}"


def agent_files() -> list[str]:
    out: list[str] = []
    for pattern in AGENT_GLOBS:
        out.extend(sorted(glob.glob(pattern)))
    return out


def main(argv: list[str]) -> int:
    quiet = "--quiet" in argv[1:]
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

    for path in files:
        rel = path.replace(os.sep, "/")
        with open(path, encoding="utf-8-sig") as fh:
            body = fh.read()

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
    return 1 if (counts["BLOCKER"] or counts["MAJOR"]) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
