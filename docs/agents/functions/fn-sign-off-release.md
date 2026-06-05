# fn:sign-off-release

**Used by:** `PRODUCT-OWNER`
**Called at:** WF-05 Step 2b, after all BO sign-offs are collected

---

## Purpose

Aggregates all BO sign-offs, checks cross-tenant coherence and platform
requirement coverage, and writes the final PO sign-off file. This is the
last business gate before RELEASE-VALIDATOR runs NFR checks.

---

## Execution

```python
import yaml
from pathlib import Path
from datetime import datetime, timezone

def sign_off_release(run_id: str, current_stage: str) -> dict:
    """
    Reads all bo-signoff-*.yaml files for this run_id.
    Returns the PO sign-off dict (caller writes the file).
    """
    companies = ["swiftroute", "vortex", "meridian"]
    signoffs = {}
    for company in companies:
        path = Path(f"tests/uat-reports/bo-signoff-{company}-{run_id}.yaml")
        if not path.exists():
            raise FileNotFoundError(f"Missing BO sign-off: {path}")
        with open(path) as f:
            signoffs[company] = yaml.safe_load(f)

    # Collect all issues
    all_issues = []
    for company, signoff in signoffs.items():
        for issue in signoff.get("domain_issues", []):
            all_issues.append({**issue, "company": company})

    # Check for any open BLOCKERs
    blockers = [i for i in all_issues if i["severity"] == "BLOCKER"]
    majors   = [i for i in all_issues if i["severity"] == "MAJOR"]

    # Check platform requirement coverage
    with open(f"tests/uat-reports/uat-{run_id}.yaml") as f:
        uat = yaml.safe_load(f)

    scenarios_passed = uat["summary"]["passed"]
    scenarios_total  = uat["summary"]["total_scenarios"]

    recommendation = "APPROVED" if not blockers and not majors else "BLOCKED"

    return {
        "report_id": f"po-signoff-{run_id}",
        "run_id": run_id,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "bo_verdicts": {c: s["domain_verdict"] for c, s in signoffs.items()},
        "platform_coverage": {
            "scenarios_passed": scenarios_passed,
            "scenarios_total": scenarios_total,
        },
        "release_recommendation": recommendation,
        "issues": all_issues,
    }
```

---

## Output

Write the result to:
```
tests/uat-reports/po-signoff-<run_id>.yaml
```

The `release_recommendation` field drives ORCH Step 2 routing:
- `APPROVED` → dispatch RELEASE-VALIDATOR (WF-05 Step 3)
- `BLOCKED`  → spawn WF-03 per BLOCKER/MAJOR issue, then re-run WF-05 Step 1

---

## Mandatory language rule

The `release_rationale` field MUST be written in plain business language
suitable for a product changelog or stakeholder communication. It is not
a technical report. Example:

**Correct:**
> "All three companies' core business processes have been validated by their
> respective business owners. No blocking issues were found. The platform
> correctly enforces Meridian's BaFin compliance obligations, Vortex's
> ISO 9001 quality gates, and SwiftRoute's financial authority thresholds.
> Release is approved."

**Forbidden:**
> "Unit tests pass with 94% coverage. Integration test suite completed
> in 47 seconds. No assertion failures in Playwright."
