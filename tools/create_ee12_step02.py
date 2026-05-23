import json
import datetime
import os

run_id = 'WF02-ee12-20260522'
created_at = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

description = (
    'Implement EE-12 (Concurrent instance safety) per the design in src/design/engine.md section EE-12. '
    'Key implementation tasks:\n\n'
    '1. In src/db/instance.zig (or wherever instance row reads happen): upgrade the instance row read '
    'that precedes task completion to use SELECT ... FOR UPDATE NOWAIT on the instance_projections table '
    '(or instances table, whichever holds the row lock). This must be inside the existing DB transaction.\n\n'
    '2. Add a new error variant ConcurrentModification (or equivalent in the existing error set) to signal '
    'lock contention (SQLSTATE 55P03 from PostgreSQL NOWAIT).\n\n'
    '3. In src/tasks/handler.zig (or wherever POST /instances/{id}/tasks/{task_id}/complete is handled): '
    'translate ConcurrentModification to HTTP 409 with a JSON error body containing '
    'the field code set to CONCURRENT_MODIFICATION.\n\n'
    '4. Verify (do NOT break) that instance operations on different instances do not lock each other - '
    'the FOR UPDATE is scoped to a single instance row by WHERE instance_id = $1.\n\n'
    '5. No migration is needed - the existing schema is sufficient (confirmed in design). Do not create '
    'any new migration file.\n\n'
    'After implementing, run:\n'
    '  zig build        (must exit 0)\n'
    '  zig build test   (must exit 0)\n\n'
    'The test files for the concurrency load tests will be written by TEST-DESIGNER in step 03. '
    'You only need to implement the production code changes.'
)

handoff = {
    'handoff_id': 'ee120002-2605-4000-8012-202605220002',
    'workflow_id': 'WF-02',
    'run_id': run_id,
    'step': '02',
    'from_agent': 'ORCH',
    'to_agent': 'BACKEND-DEV',
    'created_at': created_at,
    'started_at': created_at,
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage 3 - Execution Engine',
        'requirement_ids': ['EE-12'],
        'related_handoff_ids': ['ee120001-2605-4000-8012-202605220001'],
        'artifacts_in': [
            'src/design/engine.md',
            'docs/requirements/EE-12.md',
            'src/engine/instance.zig',
            'src/db/instance.zig',
            'src/tasks/handler.zig',
            'migrations/005_instances.sql',
            'migrations/006_tasks.sql'
        ]
    },
    'task': {
        'description': description,
        'acceptance_criteria': [
            'src/db/instance.zig or equivalent acquires FOR UPDATE NOWAIT lock on instance row before task completion',
            'ConcurrentModification error variant exists and is returned on SQLSTATE 55P03',
            'HTTP 409 with code CONCURRENT_MODIFICATION is returned when lock contention occurs',
            'zig build exits 0',
            'zig build test exits 0',
            'No new migration file created'
        ],
        'functions_to_call': [
            'fn:read-backend-conventions',
            'fn:check-zig-build'
        ]
    },
    'result': None,
    'rework_count': 0,
    'max_rework': 3,
    'completed_at': None
}

with open(f'handoffs/{run_id}/step-02-backend-dev.json', 'w') as f:
    json.dump(handoff, f, indent=2)
print('step-02-backend-dev.json written, started_at:', created_at)

with open('handoffs/registry.json') as f:
    registry = json.load(f)
registry['entries'].append({
    'handoff_id': 'ee120002-2605-4000-8012-202605220002',
    'file': f'handoffs/{run_id}/step-02-backend-dev.json',
    'run_id': run_id,
    'step': '02',
    'from_agent': 'ORCH',
    'to_agent': 'BACKEND-DEV',
    'created_at': created_at,
    'status': 'PENDING',
    'stage': 'Stage 3 - Execution Engine'
})
with open('handoffs/registry.json', 'w') as f:
    json.dump(registry, f, indent=2)
print('registry updated')

with open('handoffs/orchestrator.log', 'a') as f:
    f.write(f'{created_at} | ROUTE | {run_id} | ee120002 | ORCH -> BACKEND-DEV | PENDING\n')
print('log appended')
