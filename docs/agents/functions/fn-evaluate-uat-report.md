# fn:evaluate-uat-report

**Used by:** `BO-SWIFTROUTE`, `BO-VORTEX`, `BO-MERIDIAN`, `PRODUCT-OWNER`
**Called at:** WF-05 Step 2a-* (BO agents), WF-05 Step 2b (PRODUCT-OWNER)

---

## Purpose

Reads a UAT report and the relevant company's process definitions, then
produces a domain-specific verdict in business language. Each BO agent
calls this function filtered to their company's scenarios. PRODUCT-OWNER
calls it across all companies.

---

## Execution

```python
import yaml
from pathlib import Path

def evaluate_uat_report(run_id: str, company_id: str | None = None) -> dict:
    """
    Returns a dict of {scenario_id: {verdict, business_note, issues}}
    filtered to company_id if provided.
    """
    with open(f"tests/uat-reports/uat-{run_id}.yaml") as f:
        report = yaml.safe_load(f)

    scenarios = report["scenarios"]
    if company_id:
        scenarios = [s for s in scenarios if s["company"] == company_id]

    results = {}
    for scenario in scenarios:
        proc_file = next(
            Path(f"tests/simulation/companies/{scenario['company']}").glob(
                f"*{scenario['process'].split('-', 2)[-1]}*.yaml"
            ), None
        )
        proc_def = yaml.safe_load(open(proc_file)) if proc_file else {}

        results[scenario["id"]] = {
            "scenario": scenario,
            "process_def": proc_def,
            "outcomes": scenario.get("outcomes", []),
            "issues": scenario.get("issues", []),
        }

    return results
```

The calling BO agent then reasons over `results` using its domain knowledge
and persona to produce `persona_verdict` and `business_note` per scenario.

---

## Output

The function produces input data for the BO sign-off YAML. The BO agent
writes the sign-off file; this function does not write files directly.
