import json
import datetime

run_id = 'WF02-ee12-20260522'
created_at = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

handoff = {
    'handoff_id': 'ee120006-2605-4000-8012-202605220006',
    'workflow_id': 'WF-02',
    'run_id': run_id,
    'step': '06',
    'from_agent': 'ORCH',
    'to_agent': 'DOC-UPDATER',
    'created_at': created_at,
    'started_at': created_at,
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage 3 - Execution Engine',
        'requirement_ids': ['EE-12'],
        'related_handoff_ids': [
            'ee120005-2605-4000-8012-202605220005'
        ],
        'artifacts_in': [
            'docs/status/release-EE-12-20260522.json',
            'docs/status/requirement_status.json',
            'CHANGELOG.md',
            'handoffs/WF02-ee12-20260522/estimation.json',
            'handoffs/WF02-ee12-20260522/step-01-code-designer.json',
            'handoffs/WF02-ee12-20260522/step-02-backend-dev.json',
            'handoffs/WF02-ee12-20260522/step-03-test-designer.json',
            'handoffs/WF02-ee12-20260522/step-04-test-runner.json',
            'handoffs/WF02-ee12-20260522/step-05-release-validator.json'
        ]
    },
    'task': {
        'description': (
            'Update all documentation to reflect the RELEASED status of EE-12 (Concurrent instance safety).\n\n'
            '1. Update docs/status/requirement_status.json for EE-12:\n'
            '   - status: "RELEASED"\n'
            '   - implemented_in: ["src/engine/instance.zig", "src/api/routes/tasks.zig"]\n'
            '   - test_spec: "tests/specs/EE-12.md"\n'
            '   - test_run: "EE-12-run-01.md"\n'
            '   - tested_at: "2026-05-22"\n'
            '   - released_at: "2026-05-22"\n'
            '   - release_run: "WF02-ee12-20260522"\n\n'
            '2. Add a CHANGELOG.md entry under the appropriate version/date heading for EE-12:\n'
            '   ### EE-12 — Concurrent instance safety\n'
            '   - Row-level locking (FOR UPDATE NOWAIT) on instance row serialises concurrent operations per instance\n'
            '   - Two concurrent task completions on the same instance: first succeeds (HTTP 200), second returns HTTP 409 CONCURRENT_MODIFICATION\n'
            '   - 100 concurrent task completions across 100 distinct instances all succeed with zero cross-instance contention\n'
            '   - New error variant ConcurrentModification in CompleteTaskError set\n'
            '   - No schema migration required (existing row-per-instance structure sufficient)\n\n'
            '3. Run the retrospective procedure (this run has an estimation.json):\n'
            '   a. Read handoffs/WF02-ee12-20260522/estimation.json\n'
            '   b. Compute actual work time per step from started_at/completed_at in each step handoff\n'
            '   c. Compare estimated vs actual, compute variance_pct per step and overall\n'
            '   d. If |variance_pct| > 25% for a step, consider whether to adjust docs/metrics/estimation_rules.json\n'
            '      (only adjust if this is a pattern seen across >= 2 consecutive runs at same difficulty)\n'
            '   e. Write docs/metrics/retrospectives/WF02-ee12-20260522.json\n\n'
            '4. Set result.status to PASS when all updates are complete.'
        ),
        'acceptance_criteria': [
            'docs/status/requirement_status.json shows EE-12 status as RELEASED',
            'CHANGELOG.md has an EE-12 entry with ConcurrentModification and FOR UPDATE NOWAIT details',
            'docs/metrics/retrospectives/WF02-ee12-20260522.json written',
            'result.artifacts_out includes requirement_status.json, CHANGELOG.md, and retrospective file'
        ],
        'functions_to_call': [
            'fn:update-requirement-status',
            'fn:update-changelog'
        ]
    },
    'result': None,
    'rework_count': 0,
    'max_rework': 3,
    'completed_at': None
}

with open(f'handoffs/{run_id}/step-06-doc-updater.json', 'w') as f:
    json.dump(handoff, f, indent=2)
print('step-06-doc-updater.json written, started_at:', created_at)

with open('handoffs/registry.json') as f:
    registry = json.load(f)
registry['entries'].append({
    'handoff_id': 'ee120006-2605-4000-8012-202605220006',
    'file': f'handoffs/{run_id}/step-06-doc-updater.json',
    'run_id': run_id,
    'step': '06',
    'from_agent': 'ORCH',
    'to_agent': 'DOC-UPDATER',
    'created_at': created_at,
    'status': 'PENDING',
    'stage': 'Stage 3 - Execution Engine'
})
with open('handoffs/registry.json', 'w') as f:
    json.dump(registry, f, indent=2)
print('registry updated')

with open('handoffs/orchestrator.log', 'a') as f:
    f.write(f'{created_at} | ROUTE | {run_id} | ee120006 | ORCH -> DOC-UPDATER | PENDING\n')
print('log appended')
