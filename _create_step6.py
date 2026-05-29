import json, uuid, os

run_id     = 'WF02-f2a-canvas-batch1-20260528'
step       = '06'
agent_slug = 'doc-updater'
to_agent   = 'DOC-UPDATER'

handoff_id = str(uuid.uuid4())
filename   = f'handoffs/{run_id}/step-{step}-{agent_slug}.json'
os.makedirs(f'handoffs/{run_id}', exist_ok=True)

handoff = {
    'handoff_id': handoff_id,
    'run_id': run_id,
    'step': step,
    'from_agent': 'ORCH',
    'to_agent': to_agent,
    'created_at': '2026-05-29T04:20:29Z',
    'started_at': '2026-05-29T04:20:29Z',
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage F2 — Documentation Update',
        'requirement_ids': [
            'PD-UI-01', 'PD-UI-02', 'PD-UI-03', 'PD-UI-04',
            'PD-UI-05', 'PD-UI-06', 'PD-UI-07', 'PD-UI-08',
            'PD-UI-09', 'PD-UI-10', 'PD-UI-11', 'PD-UI-12', 'PD-UI-15'
        ],
        'related_handoff_ids': ['42fddac2'],
        'artifacts_in': [
            'docs/status/release-f2-canvas-20260529.json',
            'docs/BPM_Platform_Frontend_Requirements.md',
            'docs/status/implementation_order.md',
            'CHANGELOG.md',
            'docs/status/requirement_status.json'
        ]
    },
    'task': {
        'description': (
            "Update documentation for Stage F2 release:\n"
            "1. Update CHANGELOG.md with Stage F2 release entry\n"
            "2. Update docs/status/requirement_status.json: set status to RELEASED for requirements PD-UI-01 through PD-UI-15 (MUST only)\n"
            "3. Update implementation_order.md stage F2 status if needed\n"
            "SHOULD/COULD requirements (PD-UI-13, PD-UI-14, PD-UI-16..19) are NOT marked released."
        ),
        'acceptance_criteria': [
            "CHANGELOG.md has Stage F2 entry",
            "13 MUST requirements marked RELEASED in requirement_status.json",
            "SHOULD/COULD requirements NOT marked RELEASED"
        ],
        'functions_to_call': ['fn:update-changelog', 'fn:update-requirement-status']
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
    'status': 'PENDING', 'stage': 'Stage F2 — Docs'
})
with open('handoffs/registry.json', 'w') as f:
    json.dump(registry, f, indent=2)

log_line = f'2026-05-29T04:20:29Z | ROUTE | {run_id} | {handoff_id[:8]} | ORCH -> {to_agent} | PENDING\n'
with open('handoffs/orchestrator.log', 'a') as f:
    f.write(log_line)

print(f'Handoff created: {filename}')
print(f'ID: {handoff_id}')
