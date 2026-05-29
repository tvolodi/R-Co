import json, uuid, os

run_id     = 'WF03-f2a-canvas-fix-20260528'
step       = '01'
agent_slug = 'issue-fixer'
to_agent   = 'ISSUE-FIXER'

handoff_id = str(uuid.uuid4())
filename   = f'handoffs/{run_id}/step-{step}-{agent_slug}.json'
os.makedirs(f'handoffs/{run_id}', exist_ok=True)

handoff = {
    'handoff_id': handoff_id,
    'run_id': run_id,
    'step': step,
    'from_agent': 'ORCH',
    'to_agent': to_agent,
    'created_at': '2026-05-28T19:20:49Z',
    'started_at': '2026-05-28T19:20:49Z',
    'status': 'PENDING',
    'priority': 'HIGH',
    'context': {
        'stage': 'Stage F2 — Batch 1: Canvas Foundation',
        'requirement_ids': ['PD-UI-09', 'PD-UI-10', 'PD-UI-11', 'PD-UI-12'],
        'related_handoff_ids': ['49a593b4'],
        'artifacts_in': [
            'web/tests/e2e/f2-canvas.e2e.spec.ts',
            'src/definition/graph.zig',
            'tests/reports/report-2026-05-29-WF02-f2a-canvas-batch1-20260528.json',
            'src/design/canvas-f2-batch1.md'
        ]
    },
    'task': {
        'description': (
            'Fix the E2E test data format in web/tests/e2e/f2-canvas.e2e.spec.ts. '
            'All 13 tests fail because the test helper functions use incorrect GraphNode field names.\n\n'
            'Root cause: The backend GraphNode struct (src/definition/graph.zig) has:\n'
            '  label: ?[]const u8,  (NOT "name")\n'
            '  attributes: ?[]const u8 = null,  (JSON string, NOT a JSON object)\n\n'
            'Fixes needed in the test file:\n'
            '1. Replace all occurrences of name: "..." in graph node objects with label: "..."\n'
            '2. Serialize attributes values as JSON strings, e.g. attributes: JSON.stringify({...}) instead of attributes: {...}\n'
            '3. After fixing, run: cd web && npx playwright test f2-canvas.e2e.spec.ts --reporter=list\n'
            '4. Confirm at least some tests pass (or get past setup)'
        ),
        'acceptance_criteria': [
            'Test setup succeeds (POST /api/v1/definitions returns 201, not 400)',
            'At least some E2E tests pass'
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

log_line = f'2026-05-28T19:20:49Z | ROUTE | {run_id} | {handoff_id[:8]} | ORCH -> {to_agent} | PENDING\n'
with open('handoffs/orchestrator.log', 'a') as f:
    f.write(log_line)

print(f'Handoff created: {filename}')
print(f'ID: {handoff_id}')
