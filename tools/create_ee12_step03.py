import json
import datetime

run_id = 'WF02-ee12-20260522'
created_at = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

description = (
    'Write test specifications and test code for EE-12 (Concurrent instance safety) per the design in '
    'src/design/engine.md section EE-12.\n\n'
    'Required test artefacts:\n\n'
    '1. Test spec file: tests/specs/EE-12.md covering:\n'
    '   - Test case TC-EE-12-01: 100 concurrent task completions across 100 DISTINCT instances all succeed\n'
    '   - Test case TC-EE-12-02: Two concurrent task completions on the SAME instance - one HTTP 200, one HTTP 409\n'
    '   - Test case TC-EE-12-03: Verify no deadlock occurs with multiple concurrent instances\n'
    '   - Test case TC-EE-12-04: Verify HTTP 409 with code CONCURRENT_MODIFICATION is returned on contention\n'
    '   Format: follow the style of tests/specs/EE-11.md or similar existing specs.\n\n'
    '2. Integration test file: tests/integration/test_ee12_concurrent.zig (or equivalent Zig test file) '
    'implementing the above test cases. The tests should:\n'
    '   - TC-EE-12-01: Create 100 process instances, advance each to USER_TASK, then complete all 100 tasks '
    'concurrently (using threads or async). Assert all 100 succeed and final instance state is correct.\n'
    '   - TC-EE-12-02: Create 1 instance, advance to USER_TASK, then fire two concurrent completeTask calls '
    'on the same instance. Assert exactly one succeeds (HTTP 200) and one fails (HTTP 409 CONCURRENT_MODIFICATION).\n'
    '   - TC-EE-12-03: Run TC-EE-12-01 scenario and assert no deadlock (all goroutines/threads complete within timeout).\n'
    '   - TC-EE-12-04: Trigger the NOWAIT path and verify the JSON response contains the field code with value '
    'CONCURRENT_MODIFICATION.\n\n'
    'The ConcurrentModification error and HTTP 409 translation are already implemented in src/engine/instance.zig '
    'and src/api/routes/tasks.zig.\n\n'
    'After writing tests, run zig build test to verify all tests compile and pass.\n'
    'Run zig build to confirm no build regressions.'
)

handoff = {
    'handoff_id': 'ee120003-2605-4000-8012-202605220003',
    'workflow_id': 'WF-02',
    'run_id': run_id,
    'step': '03',
    'from_agent': 'ORCH',
    'to_agent': 'TEST-DESIGNER',
    'created_at': created_at,
    'started_at': created_at,
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage 3 - Execution Engine',
        'requirement_ids': ['EE-12'],
        'related_handoff_ids': [
            'ee120001-2605-4000-8012-202605220001',
            'ee120002-2605-4000-8012-202605220002'
        ],
        'artifacts_in': [
            'src/design/engine.md',
            'docs/requirements/EE-12.md',
            'src/engine/instance.zig',
            'src/api/routes/tasks.zig',
            'tests/specs/EE-11.md'
        ]
    },
    'task': {
        'description': description,
        'acceptance_criteria': [
            'tests/specs/EE-12.md exists with test cases TC-EE-12-01 through TC-EE-12-04',
            'Integration test file exists implementing concurrent test scenarios',
            'TC-EE-12-01 verifies 100 distinct-instance concurrent completions all succeed',
            'TC-EE-12-02 verifies same-instance contention: one HTTP 200, one HTTP 409 CONCURRENT_MODIFICATION',
            'zig build exits 0',
            'zig build test exits 0'
        ],
        'functions_to_call': [
            'fn:read-test-conventions',
            'fn:check-zig-build'
        ]
    },
    'result': None,
    'rework_count': 0,
    'max_rework': 3,
    'completed_at': None
}

with open(f'handoffs/{run_id}/step-03-test-designer.json', 'w') as f:
    json.dump(handoff, f, indent=2)
print('step-03-test-designer.json written, started_at:', created_at)

with open('handoffs/registry.json') as f:
    registry = json.load(f)
registry['entries'].append({
    'handoff_id': 'ee120003-2605-4000-8012-202605220003',
    'file': f'handoffs/{run_id}/step-03-test-designer.json',
    'run_id': run_id,
    'step': '03',
    'from_agent': 'ORCH',
    'to_agent': 'TEST-DESIGNER',
    'created_at': created_at,
    'status': 'PENDING',
    'stage': 'Stage 3 - Execution Engine'
})
with open('handoffs/registry.json', 'w') as f:
    json.dump(registry, f, indent=2)
print('registry updated')

with open('handoffs/orchestrator.log', 'a') as f:
    f.write(f'{created_at} | ROUTE | {run_id} | ee120003 | ORCH -> TEST-DESIGNER | PENDING\n')
print('log appended')
