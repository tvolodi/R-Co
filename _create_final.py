import json, uuid, os

run_id     = 'WF02-f2a-canvas-batch1-20260528'
step       = 'final'
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
    'created_at': '2026-05-29T04:25:14Z',
    'started_at': '2026-05-29T04:25:14Z',
    'status': 'PENDING',
    'priority': 'HIGH',
    'context': {
        'stage': 'Stage F2 — Git Merge',
        'requirement_ids': ['PD-UI-01','PD-UI-02','PD-UI-03','PD-UI-04',
                          'PD-UI-05','PD-UI-06','PD-UI-07','PD-UI-08',
                          'PD-UI-09','PD-UI-10','PD-UI-11','PD-UI-12','PD-UI-15'],
        'related_handoff_ids': ['d3e8ab29'],
        'artifacts_in': ['docs/agents/protocols/GIT_MERGE.md']
    },
    'task': {
        'description': (
            "Execute fn:git-merge per docs/agents/protocols/GIT_MERGE.md.\n"
            "Branch: feature/WF02-f2a-canvas-batch1-20260528\n"
            "1. git fetch origin main && git rebase origin/main (resolve conflicts if any)\n"
            "2. gh pr create --base main --title 'feat(F2): Process Designer Canvas (PD-UI-01..15)'\n"
            "3. gh pr merge --squash --delete-branch\n"
            "4. git checkout main && git pull --ff-only origin main\n"
            "5. Record PR number and merge SHA in result"
        ),
        'acceptance_criteria': [
            "PR created and merged to main",
            "Branch deleted from GitHub after merge",
            "local main is up to date with origin/main",
            "PR number and merge SHA recorded in result"
        ],
        'functions_to_call': ['fn:git-merge']
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
    'status': 'PENDING', 'stage': 'Stage F2 — Git Merge'
})
with open('handoffs/registry.json', 'w') as f:
    json.dump(registry, f, indent=2)

log_line = f'2026-05-29T04:25:14Z | ROUTE | {run_id} | {handoff_id[:8]} | ORCH -> {to_agent} | PENDING\n'
with open('handoffs/orchestrator.log', 'a') as f:
    f.write(log_line)

print(f'Handoff created: {filename}')
print(f'ID: {handoff_id}')
