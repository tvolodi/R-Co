import json
import uuid
import os
from datetime import datetime

run_id = "WF02-f4-task-inbox-20260530"
created_at = "2026-05-30T05:29:31Z"
requirement_ids = ["TK-UI-01", "TK-UI-02", "TK-UI-03", "TK-UI-04", "TK-UI-05", "TK-UI-06", "TK-UI-07", "TK-UI-08", "TK-UI-09", "TK-UI-10"]

# Create run directory
os.makedirs(f"handoffs/{run_id}", exist_ok=True)

# Read existing registry
with open("handoffs/registry.json") as f:
    registry = json.load(f)

# Step 00: FRONTEND-DEV git setup
step_00 = {
    "handoff_id": str(uuid.uuid4()),
    "run_id": run_id,
    "workflow_id": "WF-02",
    "step": "00",
    "from_agent": "ORCH",
    "to_agent": "FRONTEND-DEV",
    "created_at": created_at,
    "status": "PENDING",
    "priority": "NORMAL",
    "context": {
        "stage": "Stage F4 - Task inbox",
        "requirement_ids": requirement_ids,
        "artifacts_in": [],
        "related_handoff_ids": []
    },
    "task": {
        "description": "Set up feature branch for Stage F4 (Task inbox) frontend implementation",
        "acceptance_criteria": ["feature/WF02-f4-task-inbox-20260530 branch created and pushed to origin"],
        "functions_to_call": ["fn:git-setup"]
    },
    "result": None,
    "rework_count": 0,
    "max_rework": 1,
    "started_at": None,
    "completed_at": None
}

with open(f"handoffs/{run_id}/step-00-frontend-dev.json", "w") as f:
    json.dump(step_00, f, indent=2)

# Step 01: CODE-DESIGNER
step_01 = {
    "handoff_id": str(uuid.uuid4()),
    "run_id": run_id,
    "workflow_id": "WF-02",
    "step": "01",
    "from_agent": "ORCH",
    "to_agent": "CODE-DESIGNER",
    "created_at": created_at,
    "status": "PENDING",
    "priority": "NORMAL",
    "context": {
        "stage": "Stage F4 - Task inbox",
        "requirement_ids": requirement_ids,
        "artifacts_in": ["docs/BPM_Platform_Frontend_Requirements.md"],
        "related_handoff_ids": []
    },
    "task": {
        "description": "Design frontend components and pages for Stage F4 task inbox features: task list page, task detail panel, form rendering for task completion, task claim/reassign dialogs, badge count, escalation indicator, mobile UI.",
        "acceptance_criteria": [
            "Design covers all 10 requirement acceptance criteria",
            "Page structure documented (TaskInboxPage, TaskDetailPanel, TaskFormRenderer)",
            "Component hierarchy specified with props and types",
            "API integration points documented",
            "State management approach defined",
            "Design is implementation-code-free"
        ],
        "functions_to_call": ["fn:classify-lego-types"]
    },
    "result": None,
    "rework_count": 0,
    "max_rework": 2,
    "started_at": None,
    "completed_at": None
}

with open(f"handoffs/{run_id}/step-01-code-designer.json", "w") as f:
    json.dump(step_01, f, indent=2)

# Step 01b: CODE-DESIGN-VALIDATOR
step_01b = {
    "handoff_id": str(uuid.uuid4()),
    "run_id": run_id,
    "workflow_id": "WF-02",
    "step": "01b",
    "from_agent": "ORCH",
    "to_agent": "CODE-DESIGN-VALIDATOR",
    "created_at": created_at,
    "status": "PENDING",
    "priority": "NORMAL",
    "context": {
        "stage": "Stage F4 - Task inbox",
        "requirement_ids": requirement_ids,
        "artifacts_in": [],
        "related_handoff_ids": []
    },
    "task": {
        "description": "Validate CODE-DESIGNER output for completeness and correctness. Verify all acceptance criteria are covered, design has no implementation code, and is sufficient for FRONTEND-DEV to proceed.",
        "acceptance_criteria": [
            "Every MUST requirement (TK-UI-01 to TK-UI-06, TK-UI-10) has design elements",
            "Every SHOULD requirement (TK-UI-07, TK-UI-08, TK-UI-09) has design elements or is marked deferred with justification",
            "Design is free of implementation code (no JSX, no TypeScript logic)",
            "All component signatures and data types are specified",
            "API integration points are documented"
        ],
        "functions_to_call": []
    },
    "result": None,
    "rework_count": 0,
    "max_rework": 2,
    "started_at": None,
    "completed_at": None
}

with open(f"handoffs/{run_id}/step-01b-code-design-validator.json", "w") as f:
    json.dump(step_01b, f, indent=2)

# Step 02b: FRONTEND-DEV implementation
step_02b = {
    "handoff_id": str(uuid.uuid4()),
    "run_id": run_id,
    "workflow_id": "WF-02",
    "step": "02b",
    "from_agent": "ORCH",
    "to_agent": "FRONTEND-DEV",
    "created_at": created_at,
    "status": "PENDING",
    "priority": "NORMAL",
    "context": {
        "stage": "Stage F4 - Task inbox",
        "requirement_ids": requirement_ids,
        "artifacts_in": [],
        "related_handoff_ids": []
    },
    "task": {
        "description": "Implement Stage F4 task inbox features per design artefact: TaskInboxPage with filtering/sorting, TaskDetailPanel, dynamic form rendering from schema, task claim/complete/reassign operations, badge count, escalation indicator, mobile-optimized task completion flow.",
        "acceptance_criteria": [
            "npm run type-check exits 0",
            "npm run lint exits 0",
            "npm run build exits 0",
            "All implementation committed to feature branch and pushed to origin",
            "E2E tests ready for TEST-DESIGNER (ready status)"
        ],
        "functions_to_call": ["fn:check-frontend-conventions", "fn:type-check"]
    },
    "result": None,
    "rework_count": 0,
    "max_rework": 2,
    "started_at": None,
    "completed_at": None
}

with open(f"handoffs/{run_id}/step-02b-frontend-dev.json", "w") as f:
    json.dump(step_02b, f, indent=2)

# Step 03: TEST-DESIGNER
step_03 = {
    "handoff_id": str(uuid.uuid4()),
    "run_id": run_id,
    "workflow_id": "WF-02",
    "step": "03",
    "from_agent": "ORCH",
    "to_agent": "TEST-DESIGNER",
    "created_at": created_at,
    "status": "PENDING",
    "priority": "NORMAL",
    "context": {
        "stage": "Stage F4 - Task inbox",
        "requirement_ids": requirement_ids,
        "artifacts_in": [],
        "related_handoff_ids": []
    },
    "task": {
        "description": "Design E2E test specs for Stage F4: task inbox page display and filtering, task detail panel rendering, form submission, task claim/complete/reassign operations, escalation indicators, mobile responsiveness. Every MUST requirement must have a runnable integration test.",
        "acceptance_criteria": [
            "Test spec file created at web/tests/e2e/f4-task-inbox.e2e.spec.ts",
            "Every MUST requirement (TK-UI-01, 02, 03, 04, 05, 06, 10) has an E2E test case",
            "Each test is independent, uses per-test fixtures, no shared state",
            "Tests verify backend API integration (real server)"
        ],
        "functions_to_call": []
    },
    "result": None,
    "rework_count": 0,
    "max_rework": 2,
    "started_at": None,
    "completed_at": None
}

with open(f"handoffs/{run_id}/step-03-test-designer.json", "w") as f:
    json.dump(step_03, f, indent=2)

# Step 03b: TEST-DESIGN-VALIDATOR
step_03b = {
    "handoff_id": str(uuid.uuid4()),
    "run_id": run_id,
    "workflow_id": "WF-02",
    "step": "03b",
    "from_agent": "ORCH",
    "to_agent": "TEST-DESIGN-VALIDATOR",
    "created_at": created_at,
    "status": "PENDING",
    "priority": "NORMAL",
    "context": {
        "stage": "Stage F4 - Task inbox",
        "requirement_ids": requirement_ids,
        "artifacts_in": [],
        "related_handoff_ids": []
    },
    "task": {
        "description": "Validate TEST-DESIGNER output. Verify every MUST requirement has a runnable E2E test, no test.skip on MUST tests, fixtures are isolated, tests connect to real backend.",
        "acceptance_criteria": [
            "Every MUST requirement (TK-UI-01 to TK-UI-06, TK-UI-10) has a passing E2E test",
            "No test.skip decorators on MUST requirement tests",
            "Tests are self-sufficient (start services or fail clearly)",
            "Tests use per-test fixture creation",
            "Tests run against real backend"
        ],
        "functions_to_call": []
    },
    "result": None,
    "rework_count": 0,
    "max_rework": 1,
    "started_at": None,
    "completed_at": None
}

with open(f"handoffs/{run_id}/step-03b-test-design-validator.json", "w") as f:
    json.dump(step_03b, f, indent=2)

# Step 04: TEST-RUNNER
step_04 = {
    "handoff_id": str(uuid.uuid4()),
    "run_id": run_id,
    "workflow_id": "WF-02",
    "step": "04",
    "from_agent": "ORCH",
    "to_agent": "TEST-RUNNER",
    "created_at": created_at,
    "status": "PENDING",
    "priority": "NORMAL",
    "context": {
        "stage": "Stage F4 - Task inbox",
        "requirement_ids": requirement_ids,
        "artifacts_in": [],
        "related_handoff_ids": []
    },
    "task": {
        "description": "Execute E2E tests for Stage F4 task inbox features. Run npx playwright test and collect results.",
        "acceptance_criteria": [
            "All E2E tests pass",
            "Test report generated at tests/reports/report-*-WF02-f4-task-inbox-20260530.yaml",
            "Coverage includes all MUST requirements"
        ],
        "functions_to_call": ["fn:run-e2e-tests", "fn:collect-results"]
    },
    "result": None,
    "rework_count": 0,
    "max_rework": 2,
    "started_at": None,
    "completed_at": None
}

with open(f"handoffs/{run_id}/step-04-test-runner.json", "w") as f:
    json.dump(step_04, f, indent=2)

# Step 05: RELEASE-VALIDATOR
step_05 = {
    "handoff_id": str(uuid.uuid4()),
    "run_id": run_id,
    "workflow_id": "WF-02",
    "step": "05",
    "from_agent": "ORCH",
    "to_agent": "RELEASE-VALIDATOR",
    "created_at": created_at,
    "status": "PENDING",
    "priority": "NORMAL",
    "context": {
        "stage": "Stage F4 - Task inbox",
        "requirement_ids": requirement_ids,
        "artifacts_in": [],
        "related_handoff_ids": []
    },
    "task": {
        "description": "Validate that all Stage F4 MUST requirements have passing test coverage and meet acceptance criteria. Approve release to production.",
        "acceptance_criteria": [
            "All MUST requirement tests pass",
            "Test report shows 100% pass rate for Stage F4 requirements",
            "No deferred test coverage on MUST requirements"
        ],
        "functions_to_call": ["fn:validate-test-coverage"]
    },
    "result": None,
    "rework_count": 0,
    "max_rework": 1,
    "started_at": None,
    "completed_at": None
}

with open(f"handoffs/{run_id}/step-05-release-validator.json", "w") as f:
    json.dump(step_05, f, indent=2)

# Step 06: DOC-UPDATER
step_06 = {
    "handoff_id": str(uuid.uuid4()),
    "run_id": run_id,
    "workflow_id": "WF-02",
    "step": "06",
    "from_agent": "ORCH",
    "to_agent": "DOC-UPDATER",
    "created_at": created_at,
    "status": "PENDING",
    "priority": "NORMAL",
    "context": {
        "stage": "Stage F4 - Task inbox",
        "requirement_ids": requirement_ids,
        "artifacts_in": [],
        "related_handoff_ids": []
    },
    "task": {
        "description": "Update CHANGELOG.md and requirement_status.yaml to mark all Stage F4 requirements as RELEASED. Add retrospective analysis if estimation.json exists.",
        "acceptance_criteria": [
            "CHANGELOG.md updated with Stage F4 features",
            "requirement_status.yaml updated with RELEASED status and timestamps for all requirements",
            "All changes committed to feature branch"
        ],
        "functions_to_call": ["fn:update-changelog", "fn:update-requirement-status"]
    },
    "result": None,
    "rework_count": 0,
    "max_rework": 1,
    "started_at": None,
    "completed_at": None
}

with open(f"handoffs/{run_id}/step-06-doc-updater.json", "w") as f:
    json.dump(step_06, f, indent=2)

# Step Final: FRONTEND-DEV git merge
step_final = {
    "handoff_id": str(uuid.uuid4()),
    "run_id": run_id,
    "workflow_id": "WF-02",
    "step": "final",
    "from_agent": "ORCH",
    "to_agent": "FRONTEND-DEV",
    "created_at": created_at,
    "status": "PENDING",
    "priority": "NORMAL",
    "context": {
        "stage": "Stage F4 - Task inbox",
        "requirement_ids": requirement_ids,
        "artifacts_in": [],
        "related_handoff_ids": []
    },
    "task": {
        "description": "Finalize Stage F4 release: create GitHub PR, verify all checks pass, merge to main with squash, delete feature branch, verify cleanup.",
        "acceptance_criteria": [
            "PR created on GitHub with all checks passing",
            "PR merged to main via gh pr merge --squash --delete-branch",
            "Feature branch deleted from GitHub",
            "Merge commit recorded in handoff result"
        ],
        "functions_to_call": ["fn:git-merge"]
    },
    "result": None,
    "rework_count": 0,
    "max_rework": 1,
    "started_at": None,
    "completed_at": None
}

with open(f"handoffs/{run_id}/step-final-frontend-dev.json", "w") as f:
    json.dump(step_final, f, indent=2)

# Update registry
handoffs = [
    (step_00, "00-frontend-dev"),
    (step_01, "01-code-designer"),
    (step_01b, "01b-code-design-validator"),
    (step_02b, "02b-frontend-dev"),
    (step_03, "03-test-designer"),
    (step_03b, "03b-test-design-validator"),
    (step_04, "04-test-runner"),
    (step_05, "05-release-validator"),
    (step_06, "06-doc-updater"),
    (step_final, "final-frontend-dev")
]

for step, suffix in handoffs:
    registry["entries"].append({
        "handoff_id": step["handoff_id"],
        "file": f"handoffs/{run_id}/step-{suffix}.json",
        "run_id": run_id,
        "step": step["step"],
        "from_agent": "ORCH",
        "to_agent": step["to_agent"],
        "created_at": created_at,
        "status": "PENDING",
        "stage": "Stage F4 - Task inbox"
    })

with open("handoffs/registry.json", "w") as f:
    json.dump(registry, f, indent=2)

# Create estimation.json
with open("docs/metrics/estimation_rules.json") as f:
    rules = json.load(f)

difficulty = 3
surface = "medium"
surcharge = 0.25
steps_est = ["code-designer", "code-design-validator", "frontend-dev", "test-designer",
             "test-design-validator", "test-runner", "release-validator", "doc-updater"]

idx = difficulty - 1
step_mins = rules["step_estimates_minutes"]

estimated = {}
for step in steps_est:
    if step in step_mins:
        estimated[step] = round(step_mins[step][idx] * (1 + surcharge))
estimated["total"] = sum(v for k, v in estimated.items() if k != "total")

estimation = {
    "run_id": run_id,
    "created_at": created_at,
    "rules_version": rules["version"],
    "requirement_ids": requirement_ids,
    "difficulty": difficulty,
    "difficulty_rationale": "Frontend feature set with multiple UI components (task list, detail panel, forms) and interactive operations (claim/complete/reassign). Moderate complexity with dynamic form rendering.",
    "integration_surface": surface,
    "integration_surface_rationale": "Touches pages (TaskInboxPage), components (TaskDetailPanel, forms, dialogs), hooks (useInstances), API client. 4+ modules = medium surface.",
    "steps": list(estimated.keys()),
    "estimated_minutes": estimated
}

with open(f"handoffs/{run_id}/estimation.json", "w") as f:
    json.dump(estimation, f, indent=2)

# Log to orchestrator log
with open("handoffs/orchestrator.log", "a") as f:
    f.write(f"{created_at} | ROUTE | {run_id} | --- | ORCH → FRONTEND-DEV(00) | PENDING\n")
    f.write(f"{created_at} | ESTIMATE | {run_id} | D{difficulty}/{surface} | ~{estimated['total']}min | {', '.join(requirement_ids)}\n")

print(f"✓ Created WF-02 run: {run_id}")
print(f"✓ Requirements: {', '.join(requirement_ids)}")
print(f"✓ 10 handoffs created and registered")
print(f"✓ Estimation: Difficulty {difficulty}, {surface} surface, ~{estimated['total']} minutes total")
