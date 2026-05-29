import json, uuid, os

run_id     = 'WF02-f2a-canvas-batch1-20260528'
step       = '02b'
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
    'created_at': '2026-05-28T18:59:18Z',
    'started_at': '2026-05-28T18:59:18Z',
    'status': 'PENDING',
    'priority': 'NORMAL',
    'context': {
        'stage': 'Stage F2 — Batch 1: Canvas Foundation',
        'requirement_ids': ['PD-UI-09', 'PD-UI-10', 'PD-UI-11', 'PD-UI-12'],
        'related_handoff_ids': ['bda11b76', '95d95e43', '8e008eb2'],
        'artifacts_in': [
            'src/design/canvas-f2-batch1.md',
            'docs/BPM_Platform_Frontend_Requirements.md',
            'docs/guides/frontend_developer_guide.md',
            'docs/guides/frontend_design_system.md',
            'docs/agents/protocols/GIT_MERGE.md'
        ]
    },
    'task': {
        'description': (
            'Implement the React Flow visual canvas components for PD-UI-09 through PD-UI-12. '
            'Follow the design artefact at src/design/canvas-f2-batch1.md exactly. '
            'Do NOT create a separate feature branch — the branch already exists as feature/WF02-f2a-canvas-batch1-20260528. '
            'Just implement, commit, and push to it. '
            'See docs/agents/protocols/GIT_MERGE.md for final merge protocol. '
            'Install @xyflow/react v12.x as dependency. '
            'Create the following files under web/src/:\n'
            '- components/canvas/ProcessCanvas.tsx (main canvas wrapper)\n'
            '- components/canvas/NodePalette.tsx (sidebar palette)\n'
            '- components/canvas/PropertyPanel.tsx (node property editor)\n'
            '- components/canvas/ValidationSummaryBar.tsx (inline feedback)\n'
            '- components/canvas/ConditionDialog.tsx (CEL prompt on edge creation)\n'
            '- components/canvas/nodes/STARTNode.tsx, ENDNode.tsx, HumanTaskNode.tsx, ServiceTaskNode.tsx\n'
            '- components/canvas/nodes/ExclusiveGatewayNode.tsx, ParallelGatewayNode.tsx, TimerNode.tsx, SubProcessNode.tsx\n'
            '- components/canvas/edges/ConditionEdge.tsx\n'
            '- utils/canvas/graphToFlow.ts (DefinitionGraph -> React Flow nodes/edges)\n'
            '- utils/canvas/flowToGraph.ts (React Flow -> DefinitionGraph JSON)\n'
            '- stores/canvasStore.ts (Zustand store for local state)\n'
            '- Modify pages/definitions/DefinitionEditorPage.tsx to integrate the canvas\n'
            '- Modify types/api.ts if any type additions needed\n\n'
            'Validation commands after implementation:\n'
            'cd web && npm run type-check\n'
            'cd web && npm run lint\n'
            'cd web && npm run build\n\n'
            'Commit and push:\n'
            'git add -A\n'
            'git commit -m "feat(WF02-f2a-canvas-batch1): implement React Flow canvas (PD-UI-09..12)"\n'
            'git push origin feature/WF02-f2a-canvas-batch1-20260528'
        ),
        'acceptance_criteria': [
            'npm run type-check exits 0',
            'npm run lint exits 0',
            'npm run build exits 0',
            'ProcessCanvas renders with React Flow nodes from graph API data',
            'NodePalette shows all 8 NodeType options, drag-and-drop adds nodes to canvas',
            'PropertyPanel opens on node click, shows type-specific fields',
            'Edge creation by dragging between handles works, ConditionDialog prompts for CEL',
            'Save button serializes canvas state back to DefinitionGraph and calls PUT',
            'Graph-to-flow and flow-to-graph converters are bijective for valid graphs',
            'Commit pushed to feature/WF02-f2a-canvas-batch1-20260528'
        ],
        'functions_to_call': ['fn:read-frontend-conventions', 'fn:read-design-artefact']
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

log_line = f'2026-05-28T18:59:18Z | ROUTE | {run_id} | {handoff_id[:8]} | ORCH -> {to_agent} | PENDING\n'
with open('handoffs/orchestrator.log', 'a') as f:
    f.write(log_line)

print(f'Handoff created: {filename}')
print(f'ID: {handoff_id}')
