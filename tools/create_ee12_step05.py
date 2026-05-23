import json
import datetime

run_id = 'WF02-ee12-20260522'
created_at = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

handoff = {
    'handoff_id': 'ee120005-2605-4000-8012-202605220005',
    'workflow_id': 'WF-02',
    'run_id': run_id,
    'step': '05',
    'from_agent': 'ORCH',
    'to_agent': 'RELEASE-VALIDATOR',
    'created_at': created_at,
    'started_at': created_at,
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage 3 - Execution Engine',
        'requirement_ids': ['EE-12'],
        'related_handoff_ids': [
            'ee120004-2605-4000-8012-202605220004'
        ],
        'artifacts_in': [
            'tests/reports/EE-12-run-01.md',
            'docs/requirements/EE-12.md',
            'docs/status/requirement_status.json'
        ]
    },
    'task': {
        'description': (
            'Validate that EE-12 (Concurrent instance safety) is ready for release.\n\n'
            'Steps:\n'
            '1. Read tests/reports/EE-12-run-01.md and verify overall result is PASS.\n'
            '2. Run zig build and zig build test and confirm both exit 0.\n'
            '3. Verify all EE-12 acceptance criteria from docs/requirements/EE-12.md are satisfied by '
            'the implementation:\n'
            '   - Row-level locking used (FOR UPDATE NOWAIT in src/engine/instance.zig)\n'
            '   - Two concurrent task completions on same instance: one HTTP 200, one HTTP 409\n'
            '   - 100 concurrent completions across 100 distinct instances all succeed\n'
            '   - Cross-instance contention is zero (no global lock)\n'
            '4. Write a release decision to docs/status/release-EE-12-20260522.json with fields:\n'
            '   - run_id, requirement_ids, decision (RELEASED or BLOCKED), rationale, tested_at, released_at\n'
            '5. Set result.status to PASS if all checks pass, FAIL otherwise.\n'
            '6. Include docs/status/release-EE-12-20260522.json in result.artifacts_out.'
        ),
        'acceptance_criteria': [
            'zig build exits 0',
            'zig build test exits 0',
            'test report shows PASS for all EE-12 test cases',
            'All EE-12 acceptance criteria verified against implementation',
            'docs/status/release-EE-12-20260522.json written with decision RELEASED'
        ],
        'functions_to_call': [
            'fn:check-zig-build',
            'fn:write-release-decision'
        ]
    },
    'result': None,
    'rework_count': 0,
    'max_rework': 3,
    'completed_at': None
}

with open(f'handoffs/{run_id}/step-05-release-validator.json', 'w') as f:
    json.dump(handoff, f, indent=2)
print('step-05-release-validator.json written, started_at:', created_at)

with open('handoffs/registry.json') as f:
    registry = json.load(f)
registry['entries'].append({
    'handoff_id': 'ee120005-2605-4000-8012-202605220005',
    'file': f'handoffs/{run_id}/step-05-release-validator.json',
    'run_id': run_id,
    'step': '05',
    'from_agent': 'ORCH',
    'to_agent': 'RELEASE-VALIDATOR',
    'created_at': created_at,
    'status': 'PENDING',
    'stage': 'Stage 3 - Execution Engine'
})
with open('handoffs/registry.json', 'w') as f:
    json.dump(registry, f, indent=2)
print('registry updated')

with open('handoffs/orchestrator.log', 'a') as f:
    f.write(f'{created_at} | ROUTE | {run_id} | ee120005 | ORCH -> RELEASE-VALIDATOR | PENDING\n')
print('log appended')
