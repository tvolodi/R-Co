import json, uuid, os

run_id     = 'WF02-f2a-canvas-batch1-20260528'
step       = '03b'
agent_slug = 'test-design-validator'
to_agent   = 'TEST-DESIGN-VALIDATOR'

handoff_id = str(uuid.uuid4())
filename   = f'handoffs/{run_id}/step-{step}-{agent_slug}.json'
os.makedirs(f'handoffs/{run_id}', exist_ok=True)

handoff = {
    'handoff_id': handoff_id,
    'run_id': run_id,
    'step': step,
    'from_agent': 'ORCH',
    'to_agent': to_agent,
    'created_at': '2026-05-28T19:13:15Z',
    'started_at': '2026-05-28T19:13:15Z',
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage F2 — Batch 1: Canvas Foundation',
        'requirement_ids': ['PD-UI-09', 'PD-UI-10', 'PD-UI-11', 'PD-UI-12'],
        'related_handoff_ids': ['d536fdd3'],
        'artifacts_in': [
            'tests/specs/PD-UI-09-12.md',
            'web/tests/e2e/f2-canvas.e2e.spec.ts',
            'docs/BPM_Platform_Frontend_Requirements.md'
        ]
    },
    'task': {
        'description': (
            'Review the test spec and E2E test files for PD-UI-09 through PD-UI-12. '
            'This is a HARD GATE — FAIL immediately if any check fails. '
            'Verify:\n'
            '1. Every MUST requirement has a runnable E2E Playwright test file\n'
            '2. No test.skip on any MUST requirement test\n'
            '3. All fixtures use per-test UUIDs (no collision risk)\n'
            '4. Tests clean up after themselves (delete created resources)\n'
            '5. Tests fail clearly if BPM_TEST_DB_URL is absent (no silent skip)\n'
            '6. No mocks, stubs, or HTTP-level mocking (DIRECTIVE T-2)\n'
            '7. Screenshots taken after every significant UI action (DIRECTIVE T-3)'
        ),
        'acceptance_criteria': [
            'All 7 checks pass without issues',
            'FAIL result with issue list if any check fails'
        ],
        'functions_to_call': ['fn:load-requirements']
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

log_line = f'2026-05-28T19:13:15Z | ROUTE | {run_id} | {handoff_id[:8]} | ORCH -> {to_agent} | PENDING\n'
with open('handoffs/orchestrator.log', 'a') as f:
    f.write(log_line)

print(f'Handoff created: {filename}')
print(f'ID: {handoff_id}')
