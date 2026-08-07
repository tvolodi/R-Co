#!/usr/bin/env python3
"""Report whether GitHub Actions is currently degraded.

ISS-0170 / GH #497. On 2026-08-06 GitHub Actions went into `major_outage` at
15:22Z with webhook triggers throttled. Runs stopped being created; queued jobs
were never assigned a runner and were cancelled ~15 minutes later. On a pull
request that renders as a **red X indistinguishable from a failed test**.

Measured that day: 12/12 runs before the incident succeeded; every cancellation
and failure came after it opened. The failure was entirely platform-side, but
nothing in the pipeline said so, and the outage was diagnosed only after someone
thought to open the status page by hand.

This tool makes that check mechanical.

**It is diagnostic only.** It exits 0 even when GitHub is fully down, so it can
never fail a build and can never mask a genuine test failure. Its job is to
attach an explanation to a run, not to gate one. A gate that passes when the
platform is broken would be worse than no gate at all -- see CLAUDE.md,
"Never Satisfy a Gate by Editing What It Measures".

Usage:
    python3 tools/check_github_status.py            # human-readable
    python3 tools/check_github_status.py --github   # + GitHub Actions annotation
    python3 tools/check_github_status.py --json     # machine-readable
    python3 tools/check_github_status.py --summary  # Markdown for $GITHUB_STEP_SUMMARY

Exit codes:
    0  always (see above), including on network failure -- an unreachable
       status page is itself uninformative and must not fail a build.

An open incident explains a cancelled or never-scheduled job. It does NOT
excuse a step that ran and failed: a real assertion failure during an outage is
still a real assertion failure. Nothing here may ever be wired up to retry,
cancel, neutralise, or otherwise suppress a failing job -- that is the ISS-0171
/ GH #498 defect, in which `continue-on-error` hid genuine failures for months.
This tool annotates; it never adjudicates.
"""
import argparse
import json
import sys
import urllib.error
import urllib.request

COMPONENTS_URL = "https://www.githubstatus.com/api/v2/components.json"
INCIDENTS_URL = "https://www.githubstatus.com/api/v2/incidents/unresolved.json"

# The component that governs whether workflows run at all.
ACTIONS_COMPONENT = "Actions"

# Statuses that explain a run being cancelled, never created, or partially
# scheduled. "degraded_performance" is included: throttled webhooks presented
# as degraded before escalating to major_outage on 2026-08-06.
DEGRADED = {"degraded_performance", "partial_outage", "major_outage"}

TIMEOUT_SECONDS = 15


def fetch(url):
    """GET and parse JSON. Returns None on any failure -- never raises."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "R-Co-CI-status-check"})
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None


def actions_status():
    """Return (status, None) for the Actions component, or (None, reason)."""
    data = fetch(COMPONENTS_URL)
    if data is None:
        return None, "status page unreachable"
    for component in data.get("components", []):
        if component.get("name") == ACTIONS_COMPONENT and not component.get("group"):
            return component.get("status"), None
    return None, f"no {ACTIONS_COMPONENT!r} component in the status payload"


def active_actions_incident():
    """Return the first unresolved incident naming Actions, or None."""
    data = fetch(INCIDENTS_URL)
    if data is None:
        return None
    for incident in data.get("incidents", []):
        affected = {c.get("name") for c in incident.get("components", [])}
        if ACTIONS_COMPONENT in affected or "Actions" in incident.get("name", ""):
            updates = incident.get("incident_updates") or []
            return {
                "name": incident.get("name"),
                "impact": incident.get("impact"),
                "status": incident.get("status"),
                "started_at": incident.get("created_at"),
                "shortlink": incident.get("shortlink"),
                "latest_update": (updates[0].get("body") if updates else None),
            }
    return None


def summary_markdown(status, reason, degraded, incident):
    """Markdown for $GITHUB_STEP_SUMMARY. Durable where an annotation is not.

    A ::warning:: scrolls away with the log; the step summary is the surface a
    reader lands on from the PR checks tab, which is where the "is this my bug
    or theirs?" question actually gets asked.
    """
    lines = ["### GitHub Actions platform status", ""]
    if status is None:
        lines += [
            f"Status could not be determined ({reason}).",
            "",
            "Treated as no signal. This check never fails a build.",
        ]
    elif degraded:
        lines += [f"**DEGRADED — `{status}`.** The GitHub Actions platform is impaired."]
        if incident:
            lines += [
                "",
                f"- **Incident:** {incident['name']}",
                f"- **Impact:** {incident['impact']}",
                f"- **Incident status:** {incident['status']}",
                f"- **Started:** {incident['started_at']}",
            ]
            if incident.get("shortlink"):
                lines.append(f"- **Details:** {incident['shortlink']}")
        lines += [
            "",
            "A job that was **cancelled**, **never started**, or a run that was "
            "**never created** is expected while this incident is open, and is not "
            "evidence of a defect in the change under test.",
            "",
            "**A step that ran and failed is still a genuine failure.** This notice "
            "explains missing or cancelled jobs only — it never excuses a red step. "
            "Read the failing step.",
        ]
    else:
        lines += [
            f"Operational (`{status}`). The platform is healthy.",
            "",
            "A red run is therefore attributable to the change under test.",
        ]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit JSON")
    parser.add_argument(
        "--github",
        action="store_true",
        help="also emit a ::warning:: annotation when Actions is degraded",
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="emit Markdown suitable for $GITHUB_STEP_SUMMARY",
    )
    args = parser.parse_args()

    status, reason = actions_status()
    degraded = status in DEGRADED
    incident = active_actions_incident() if degraded else None

    if args.summary:
        print(summary_markdown(status, reason, degraded, incident), end="")
        return 0

    if args.json:
        print(json.dumps(
            {"component": ACTIONS_COMPONENT, "status": status, "degraded": degraded,
             "reason": reason, "incident": incident},
            indent=2,
        ))
    elif status is None:
        print(f"GitHub Actions status: UNKNOWN ({reason})")
        print("Treating as no-signal. This check never fails a build.")
    elif degraded:
        print(f"GitHub Actions status: {status.upper()} -- the platform is degraded.")
        if incident:
            print(f"  incident: {incident['name']} (impact={incident['impact']}, "
                  f"status={incident['status']})")
            print(f"  started:  {incident['started_at']}")
            if incident.get("shortlink"):
                print(f"  details:  {incident['shortlink']}")
            if incident.get("latest_update"):
                print(f"  latest:   {incident['latest_update'][:300]}")
        print()
        print("A cancelled job, a job that never started, or a run that was never")
        print("created is EXPECTED while this incident is open, and is not evidence")
        print("of a defect in the code under test. A genuine test failure is still a")
        print("genuine failure -- read the failing step, not the run's colour.")
    else:
        print(f"GitHub Actions status: {status} -- platform healthy.")
        print("A red run is therefore attributable to the change under test.")

    if args.github and degraded:
        # ISS-0170 criterion 2: the annotation must NAME the incident. The start
        # time is part of naming it usefully -- it is what lets a reader line up
        # "my job was cancelled at T" against "the incident opened at T-minus-x"
        # and reach an attribution rather than a guess.
        if incident:
            detail = f"{incident['name']} (started {incident['started_at']}"
            detail += f", impact={incident['impact']})"
            if incident.get("shortlink"):
                detail += f" {incident['shortlink']}"
        else:
            detail = "see githubstatus.com"
        print(f"::warning title=GitHub Actions degraded ({status})::"
              f"{detail}. Cancelled or never-scheduled jobs in this run are likely "
              f"platform-caused, not code-caused. A step that ran and FAILED is still "
              f"a genuine failure -- this notice never excuses one.")

    # Always 0. This is diagnostic, never a gate.
    return 0


if __name__ == "__main__":
    sys.exit(main())
