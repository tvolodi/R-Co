import json, uuid, os

run_id     = 'WF02-f2a-canvas-batch1-20260528'
step       = '04'
agent_slug = 'test-runner'
to_agent   = 'TEST-RUNNER'

handoff_id = str(uuid.uuid4())
filename   = f'handoffs/{run_id}/step-{step}-{agent_slug}.json'
os.makedirs(f'handoffs/{run_id}', exist_ok=True)

handoff = {
    'handoff_id': handoff_id,
    'run_id': run_id,
    'step': step,
    'from_agent': 'ORCH',
    'to_agent': to_agent,
    'created_at': '2026-05-28T19:14:49Z',
    'started_at': '2026-05-28T19:14:49Z',
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage F2 — Batch 1: Canvas Foundation',
        'requirement_ids': ['PD-UI-09', 'PD-UI-10', 'PD-UI-11', 'PD-UI-12'],
        'related_handoff_ids': ['6833200b'],
        'artifacts_in': [
            'web/tests/e2e/f2-canvas.e2e.spec.ts',
            'tests/specs/PD-UI-09-12.md'
        ]
    },
    'task': {
        'description': (
            'Run the E2E test suite for the React Flow canvas features. '
            'Benchmark environment has been verified (bench PASS). '
            'Steps:\n'
            '1. Ensure backend is running on port 8080 (start-backend.ps1 if not)\n'
            '2. cd web && npx playwright test f2-canvas.e2e.spec.ts --reporter=list\n'
            '3. Capture all output: passed, failed, skipped counts\n'
            '4. If any test fails, write a detailed failure report to tests/reports/\n'
            '5. Take screenshots of failures for diagnosis'
        ),
        'acceptance_criteria': [
            'All E2E tests for canvas features pass or failures are documented with root cause'
        ],
        'functions_to_call': []
    },
    'result': None,
    'rework_count': 0,
    'max_rework': 3,
    'completed_at': None
}

with open(filename, 'w') as f:
    json.dump(handoff, f, indent=2)

with open('handoffs/registry.json') as f:
    registry = json.load(f)
registry['entries'].append({
    'handoff_id': handoff_id, 'file': filename,
    'run_id': run_id, 'step': step,
    'from_agent': 'ORCH', 'to_agent': to_agent,
    'created_at': handoff['created_at'],
    'status': 'PENDING', 'stage': 'Stage F2 — Batch 1: Canvas Foundation'
})
with open('handoffs/registry.json', 'w') as f:
    json.dump(registry, f, indent=2)

log_line = f'2026-05-28T19:14:49Z | ROUTE | {run_id} | {handoff_id[:8]} | ORCH -> {to_agent} | PENDING\n'
with open('handoffs/orchestrator.log', 'a') as f:
    f.write(log_line)

print(f'Handoff created: {filename}')
print(f'ID: {handoff_id}')
