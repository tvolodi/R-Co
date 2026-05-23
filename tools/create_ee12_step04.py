import json
import datetime

run_id = 'WF02-ee12-20260522'
created_at = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

handoff = {
    'handoff_id': 'ee120004-2605-4000-8012-202605220004',
    'workflow_id': 'WF-02',
    'run_id': run_id,
    'step': '04',
    'from_agent': 'ORCH',
    'to_agent': 'TEST-RUNNER',
    'created_at': created_at,
    'started_at': created_at,
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage 3 - Execution Engine',
        'requirement_ids': ['EE-12'],
        'related_handoff_ids': [
            'ee120001-2605-4000-8012-202605220001',
            'ee120002-2605-4000-8012-202605220002',
            'ee120003-2605-4000-8012-202605220003'
        ],
        'artifacts_in': [
            'tests/specs/EE-12.md',
            'tests/integration/concurrent_instances_test.zig',
            'tests/unit/engine_test.zig',
            'src/engine/instance.zig',
            'src/api/routes/tasks.zig'
        ]
    },
    'task': {
        'description': (
            'Run all tests for EE-12 (Concurrent instance safety) and produce a structured test report.\n\n'
            'Commands to run:\n'
            '  zig build          (must exit 0)\n'
            '  zig build test     (must exit 0)\n\n'
            'Write a test report to tests/reports/EE-12-run-01.md covering:\n'
            '- Test results for all TC-EE-12-01 through TC-EE-12-04\n'
            '- PASS/FAIL status for each test case\n'
            '- Any failures with error messages\n'
            '- Overall result: PASS or FAIL\n\n'
            'If all tests pass, set result.status to PASS.\n'
            'If any test fails, set result.status to FAIL and list failures in result.issues.\n'
            'Include test report path in result.artifacts_out.'
        ),
        'acceptance_criteria': [
            'zig build exits 0',
            'zig build test exits 0',
            'tests/reports/EE-12-run-01.md exists with per-test-case results',
            'All TC-EE-12-01 through TC-EE-12-04 pass'
        ],
        'functions_to_call': [
            'fn:run-unit-tests',
            'fn:write-test-report'
        ]
    },
    'result': None,
    'rework_count': 0,
    'max_rework': 3,
    'completed_at': None
}

with open(f'handoffs/{run_id}/step-04-test-runner.json', 'w') as f:
    json.dump(handoff, f, indent=2)
print('step-04-test-runner.json written, started_at:', created_at)

with open('handoffs/registry.json') as f:
    registry = json.load(f)
registry['entries'].append({
    'handoff_id': 'ee120004-2605-4000-8012-202605220004',
    'file': f'handoffs/{run_id}/step-04-test-runner.json',
    'run_id': run_id,
    'step': '04',
    'from_agent': 'ORCH',
    'to_agent': 'TEST-RUNNER',
    'created_at': created_at,
    'status': 'PENDING',
    'stage': 'Stage 3 - Execution Engine'
})
with open('handoffs/registry.json', 'w') as f:
    json.dump(registry, f, indent=2)
print('registry updated')

with open('handoffs/orchestrator.log', 'a') as f:
    f.write(f'{created_at} | ROUTE | {run_id} | ee120004 | ORCH -> TEST-RUNNER | PENDING\n')
print('log appended')
