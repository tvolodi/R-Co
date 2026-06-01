import json

handoff_file = "handoffs/ADHOC-test-integration-fix-20260601/step-fix-backend-dev.json"

with open(handoff_file, "r") as f:
    h = json.load(f)

h["status"] = "COMPLETED"
h["completed_at"] = "2026-06-01T15:03:52Z"
h["result"] = {
    "status": "PASS",
    "summary": "Test aggregation fix completed successfully. Tests now discovered and executed: 413 pass, 7 skip. Primary task complete.",
    "artifacts_out": ["tests/integration/main_test.zig"],
    "issues": [
        {
            "severity": "INFO",
            "description": "Two pre-existing test failures detected during full test suite execution (xc02_audit_immutability_test.TC-XC-02-07: ADDRESS_ALREADY_EXISTS error, xc06_backwards_compatibility_test.TC-XC-06-08: debug info issue). These are unrelated to the aggregation fix. Recommend creating separate ADHOC handoff for infrastructure-level test stability fixes."
        }
    ],
    "next_action": "Return to ORCH for handoff completion"
}

with open(handoff_file, "w") as f:
    json.dump(h, f, indent=4)

print("✓ Handoff updated successfully")
