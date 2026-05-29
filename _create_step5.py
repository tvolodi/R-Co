import json, uuid, os

run_id     = 'WF02-f2a-canvas-batch1-20260528'
step       = '05'
agent_slug = 'release-validator'
to_agent   = 'RELEASE-VALIDATOR'

handoff_id = str(uuid.uuid4())
filename   = f'handoffs/{run_id}/step-{step}-{agent_slug}.json'
os.makedirs(f'handoffs/{run_id}', exist_ok=True)

handoff = {
    'handoff_id': handoff_id,
    'run_id': run_id,
    'step': step,
    'from_agent': 'ORCH',
    'to_agent': to_agent,
    'created_at': '2026-05-29T04:16:17Z',
    'started_at': '2026-05-29T04:16:17Z',
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage F2 — Release Validation',
        'requirement_ids': ['PD-UI-09', 'PD-UI-10', 'PD-UI-11', 'PD-UI-12',
                          'PD-UI-01', 'PD-UI-02', 'PD-UI-03', 'PD-UI-04',
                          'PD-UI-05', 'PD-UI-06', 'PD-UI-08', 'PD-UI-11', 'PD-UI-12', 'PD-UI-15'],
        'related_handoff_ids': ['bda11b76', '95d95e43', '8e008eb2', 'b43256db',
                              'd536fdd3', '6833200b', '49a593b4', 'd79da2ea'],
        'artifacts_in': [
            'docs/BPM_Platform_Frontend_Requirements.md',
            'docs/BPM_Platform_Functional_Requirements.md',
            'docs/status/implementation_order.md',
            'tests/reports/'
        ]
    },
    'task': {
        'description': (
            "Validate Stage F2 readiness for release. All 16 canvas E2E tests pass. "
            "Backend is stable (allocator fix applied). Check:\n"
            "1. All F2 MUST requirements have passing tests\n"
            "2. NFR benchmarks pass (zig build bench)\n"
            "3. No regression in existing tests (zig build test)\n"
            "4. Release decision: APPROVED or BLOCKED\n"
            "Write decision to docs/status/release-f2-canvas-20260529.json"
        ),
        'acceptance_criteria': [
            "Release decision documented in docs/status/",
            "All MUST requirements verified",
            "NFR benchmarks checked"
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
    'status': 'PENDING', 'stage': 'Stage F2 — Release'
})
with open('handoffs/registry.json', 'w') as f:
    json.dump(registry, f, indent=2)

log_line = f'2026-05-29T04:16:17Z | ROUTE | {run_id} | {handoff_id[:8]} | ORCH -> {to_agent} | PENDING\n'
with open('handoffs/orchestrator.log', 'a') as f:
    f.write(log_line)

print(f'Handoff created: {filename}')
print(f'ID: {handoff_id}')
