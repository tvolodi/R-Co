import json, uuid, os

run_id     = 'WF02-f2a-canvas-batch1-20260528'
step       = '03'
agent_slug = 'test-designer'
to_agent   = 'TEST-DESIGNER'

handoff_id = str(uuid.uuid4())
filename   = f'handoffs/{run_id}/step-{step}-{agent_slug}.json'
os.makedirs(f'handoffs/{run_id}', exist_ok=True)

handoff = {
    'handoff_id': handoff_id,
    'run_id': run_id,
    'step': step,
    'from_agent': 'ORCH',
    'to_agent': to_agent,
    'created_at': '2026-05-28T19:10:13Z',
    'started_at': '2026-05-28T19:10:13Z',
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage F2 — Batch 1: Canvas Foundation',
        'requirement_ids': ['PD-UI-09', 'PD-UI-10', 'PD-UI-11', 'PD-UI-12'],
        'related_handoff_ids': ['bda11b76', '95d95e43', '8e008eb2', 'b43256db'],
        'artifacts_in': [
            'src/design/canvas-f2-batch1.md',
            'docs/BPM_Platform_Frontend_Requirements.md',
            'docs/guides/frontend_developer_guide.md',
            'docs/guides/frontend_design_system.md',
            'docs/guides/test_developer_guide.md',
            'docs/anti-patterns.md'
        ]
    },
    'task': {
        'description': (
            'Write E2E test specifications and Playwright test files for the React Flow canvas features (PD-UI-09 through PD-UI-12). '
            'Tests must follow DIRECTIVE T-2: no mocks, no stubs, real backend always. '
            'All API-dependent tests must be E2E tests against the real running backend and real database. '
            'Follow DIRECTIVE T-3: after every significant UI action, take a screenshot and visually inspect it. '
            'Write test spec files to tests/specs/ and test source files to web/tests/e2e/. '
            'Each MUST requirement must have a fully implemented E2E Playwright test. '
            'All fixtures must use per-test UUIDs. '
            'Tests must be self-sufficient (start required services or fail clearly if unavailable). '
            'The backend already supports all APIs needed (definitions CRUD, graph validation). '
            'The test file should be named f2-canvas.e2e.spec.ts and placed in web/tests/e2e/. '
            'Required test coverage:\n'
            '- PD-UI-09: Canvas renders with existing definition graph, shows all nodes/edges, read-only mode shows non-interactive canvas\n'
            '- PD-UI-10: Node palette is visible, drag-and-drop adds a node to canvas, delete node removes it\n'
            '- PD-UI-11: Drag from a source handle to a target handle creates an edge, ConditionDialog appears for EXCLUSIVE_GATEWAY edges\n'
            '- PD-UI-12: Clicking a node opens the property panel, editing a property and saving persists it\n'
            '- Save workflow: modified canvas saves via PUT, reloading shows saved changes\n'
            '- JSON textarea fallback is accessible via debug drawer'
        ),
        'acceptance_criteria': [
            'Every MUST requirement has a runnable E2E Playwright test',
            'No mocks, stubs, or HTTP-level mocking (DIRECTIVE T-2)',
            'All tests use real backend and real database',
            'Screenshots taken after every significant UI action (DIRECTIVE T-3)',
            'Test spec file written to tests/specs/',
            'No test.skip on MUST requirement tests',
            'Fixtures use per-test UUIDs'
        ],
        'functions_to_call': ['fn:load-requirements', 'fn:read-frontend-conventions']
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

log_line = f'2026-05-28T19:10:13Z | ROUTE | {run_id} | {handoff_id[:8]} | ORCH -> {to_agent} | PENDING\n'
with open('handoffs/orchestrator.log', 'a') as f:
    f.write(log_line)

print(f'Handoff created: {filename}')
print(f'ID: {handoff_id}')
