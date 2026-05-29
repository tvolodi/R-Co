import json, uuid, os

run_id     = 'WF02-f2a-canvas-batch1-20260528'
step       = '00'
agent_slug = 'frontend-dev'
to_agent   = 'FRONTEND-DEV'

handoff_id = str(uuid.uuid4())
filename   = f'handoffs/{run_id}/step-{step}-{agent_slug}.json'
os.makedirs(f'handoffs/{run_id}', exist_ok=True)

handoff = {
    'handoff_id': handoff_id,
    'run_id': run_id,
    'step': step,
    'from_agent': 'ORCH',
    'to_agent': to_agent,
    'created_at': '2026-05-28T18:51:29Z',
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage F2 — Batch 1: Canvas Foundation',
        'requirement_ids': ['PD-UI-03', 'PD-UI-04', 'PD-UI-05', 'PD-UI-06'],
        'related_handoff_ids': [],
        'artifacts_in': [
            'docs/BPM_Platform_Frontend_Requirements.md',
            'docs/agents/protocols/GIT_SETUP.md',
            'docs/agents/protocols/GIT_MERGE.md'
        ]
    },
    'task': {
        'description': 'Execute fn:git-setup per docs/agents/protocols/GIT_SETUP.md. '
                       'Create and push a feature branch for this run.',
        'acceptance_criteria': [
            'Feature branch feature/WF02-f2a-canvas-batch1-20260528 exists on remote',
            'Branch is based on origin/main with no unrelated changes',
            'git_evidence.branch_name is set',
            'git_evidence.push_status is ok'
        ],
        'functions_to_call': ['fn:git-setup']
    },
    'result': None,
    'rework_count': 0,
    'max_rework': 3,
    'started_at': None,
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

log_line = f"2026-05-28T18:51:29Z | ROUTE | {run_id} | {handoff_id[:8]} | ORCH -> {to_agent} | PENDING\n"
with open('handoffs/orchestrator.log', 'a') as f:
    f.write(log_line)

print(f'Handoff created: {filename}')
print(f'ID: {handoff_id}')
