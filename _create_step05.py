import json, uuid, os

run_id     = 'WF02-f2a-canvas-batch1-20260528'
step       = '05'
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
    'created_at': '2026-05-29T01:02:36Z',
    'started_at': '2026-05-29T01:02:36Z',
    'status': 'PENDING',
    'priority': 'HIGH',
    'context': {
        'stage': 'Stage F2 — E2E fix + remaining MUST features',
        'requirement_ids': ['PD-UI-07', 'PD-UI-09', 'PD-UI-10', 'PD-UI-11', 'PD-UI-12'],
        'related_handoff_ids': [],
        'artifacts_in': [
            'src/design/canvas-f2-batch1.md',
            'docs/BPM_Platform_Frontend_Requirements.md',
            'web/tests/e2e/f2-canvas.e2e.spec.ts',
            'docs/guides/frontend_design_system.md'
        ]
    },
    'task': {
        'description': (
            'Complete Stage F2 canvas features. The branch is feature/WF02-f2a-canvas-batch1-20260528. '
            'Commit and push all changes. After finishing, run: cd web && npx playwright test f2-canvas.e2e.spec.ts --reporter=list\n\n'
            'Part 1 — Add data-testid attributes to match E2E test expectations (16 tests total, 12 currently failing):\n'
            '- DefinitionEditorPage: add testid="btn-show-raw-json" on the raw JSON toggle button, testid="raw-json-drawer" on the drawer div, testid="raw-json-textarea" on the textarea\n'
            '- DefinitionEditorPage: add testid="read-only-banner" on the read-only mode banner, testid="btn-save-definition" on the Save button\n'
            '- DefinitionEditorPage: add testid="unsaved-changes-dialog" on the unsaved changes confirmation dialog\n'
            '- NodePalette.tsx: add testid="node-palette" on the palette container, testid="palette-item-{NODE_TYPE}" on each palette item (e.g. palette-item-START, palette-item-END, palette-item-HUMAN_TASK, etc.)\n'
            '- PropertyPanel.tsx: add testid="property-panel" on the panel container, testid="property-panel-label" on the label field\n'
            '- ProcessCanvas.tsx (already has process-canvas): add testid="edge-delete-btn" on edge delete buttons, testid="condition-dialog" on the ConditionDialog component\n'
            '- ConditionDialog.tsx: add testid="condition-dialog" on the dialog, testid="condition-input" on the input, testid="condition-save" on save, testid="condition-cancel" on cancel\n\n'
            'Part 2 — Implement PD-UI-07 CEL expression editor:\n'
            '- Enhance ConditionDialog.tsx with a code editor-style textarea for CEL expressions\n'
            '- Add syntax highlighting placeholder (or basic code font + monospace)\n'
            '- Add bracket matching visual hint\n'
            '- Show validation errors from the backend inline below the input\n\n'
            'Part 3 — Implement PD-UI-09 Validation feedback (inline):\n'
            '- ValidationSummaryBar.tsx: show validation errors from canvas validation (missing START/END node, etc.)\n'
            '- Connect to the existing validation logic in DefinitionEditorPage\n'
            '- Show error count badge and expandable violation list\n'
            '- Highlight offending nodes/edges with a red border class\n\n'
            'Validation: npm run type-check must pass. Then run the full E2E suite.'
        ),
        'acceptance_criteria': [
            'All 16 canvas E2E tests pass (npm run type-check first, then npx playwright test f2-canvas.e2e.spec.ts)',
            'CEL expression editor has monospace textarea + inline error display',
            'Validation summary bar shows violations with node highlighting',
            'All changes committed and pushed to feature/WF02-f2a-canvas-batch1-20260528'
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
    'status': 'PENDING', 'stage': 'Stage F2 — Final fixes'
})
with open('handoffs/registry.json', 'w') as f:
    json.dump(registry, f, indent=2)

log_line = f'2026-05-29T01:02:36Z | ROUTE | {run_id} | {handoff_id[:8]} | ORCH -> {to_agent} | PENDING\n'
with open('handoffs/orchestrator.log', 'a') as f:
    f.write(log_line)

print(f'Handoff created: {filename}')
print(f'ID: {handoff_id}')
