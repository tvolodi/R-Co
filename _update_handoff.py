import json

with open('handoffs/WF03-f2a-canvas-fix-20260528/step-01-issue-fixer.json') as f:
    h = json.load(f)

# Reset for re-dispatch
h['status'] = 'PENDING'
h['rework_count'] = 1
h['created_at'] = '2026-05-29T03:09:17Z'
h['started_at'] = '2026-05-29T03:09:17Z'
h['completed_at'] = None
h['result'] = None

h['context']['artifacts_in'] = [
    'web/src/components/canvas/ProcessCanvas.tsx',
    'web/src/components/canvas/ConditionDialog.tsx',
    'web/src/pages/definitions/DefinitionEditorPage.tsx',
    'web/tests/e2e/f2-canvas.e2e.spec.ts',
    'src/design/canvas-f2-batch1.md'
]

h['task']['description'] = (
    "Fix the 4 remaining E2E test failures for the React Flow canvas (12/16 currently pass). "
    "Branch: feature/WF02-f2a-canvas-batch1-20260528. Commit and push fixes.\n\n"
    "Failure 1 - TC-PDUI11-02 (ConditionDialog cancel): "
    "React Flow calls onConnect immediately after dragTo, creating the edge BEFORE "
    "the ConditionDialog opens. When user cancels, the edge already exists. "
    "Fix: in ProcessCanvas.onConnect, for EXCLUSIVE_GATEWAY source: do NOT call addEdges; "
    "instead open ConditionDialog first, only call addEdges if user confirms.\n\n"
    "Failure 2 - TC-PDUI12-03 (Save persists): "
    "Clicking Save does not show saved toast. Check: (a) btn-save-definition is not disabled, "
    "(b) clicking triggers handleSave, (c) PUT request succeeds, (d) saved toast appears.\n\n"
    "Failure 3 - TC-PDUI12-04 (Property fields per type): "
    "Test creates 6 disconnected nodes with no edges; backend rejects POST with 422 ISOLATED_NODE. "
    "Fix: update the test manyNodeTypesGraph() helper to include edges connecting all nodes.\n\n"
    "Failure 4 - TC-SAVE-01 (Save + reload): "
    "Same root cause as Failure 2 - save does not produce toast."
)

h['task']['acceptance_criteria'] = [
    "All 16 canvas E2E tests pass",
    "npm run type-check exits 0",
    "Commit pushed to feature/WF02-f2a-canvas-batch1-20260528"
]

with open('handoffs/WF03-f2a-canvas-fix-20260528/step-01-issue-fixer.json', 'w') as f:
    json.dump(h, f, indent=2)

print('Handoff updated')
