import json

# Fix Step 01 CODE-DESIGNER handoff
with open('handoffs/WF02-f2a-canvas-batch1-20260528/step-01-code-designer.json') as f:
    h = json.load(f)
h['context']['requirement_ids'] = ['PD-UI-09', 'PD-UI-10', 'PD-UI-11', 'PD-UI-12']
# Update the description
h['task']['description'] = (
    'Design the React Flow visual canvas component architecture for Stage F2 Batch 1. '
    'Requirements: PD-UI-09 (Visual graph canvas using React Flow), '
    'PD-UI-10 (Node palette with drag-and-drop add/delete), '
    'PD-UI-11 (Edge creation by dragging between handles), '
    'PD-UI-12 (Node properties panel on click). '
    'Produce design files in src/design/ covering:'
    ' - React Flow integration approach (which library version, what plugins)'
    ' - Component tree: canvas, node palette, property panel'
    ' - Data flow: how graph JSON from API maps to React Flow nodes/edges'
    ' - Custom node renderers for each NodeType (START, END, HUMAN_TASK, SERVICE_TASK, EXCLUSIVE_GATEWAY, PARALLEL_GATEWAY, TIMER, SUB_PROCESS)'
    ' - Edge creation workflow (drag from handle, CEL condition prompt)'
    ' - Property panel: click node -> slide/edit panel -> save to local state'
    ' - Save workflow: serialize React Flow graph back to DefinitionGraph JSON -> PUT /definitions/:id'
    ' - How the existing JSON textarea fallback co-exists with the canvas'
    ' - State management: local graph state vs API sync'
)
with open('handoffs/WF02-f2a-canvas-batch1-20260528/step-01-code-designer.json', 'w') as f:
    json.dump(h, f, indent=2)
print('Step 01 updated')

# Fix Step 01b CODE-DESIGN-VALIDATOR handoff
with open('handoffs/WF02-f2a-canvas-batch1-20260528/step-01b-code-design-validator.json') as f:
    h = json.load(f)
h['context']['requirement_ids'] = ['PD-UI-09', 'PD-UI-10', 'PD-UI-11', 'PD-UI-12']
h['task']['description'] = (
    'Validate the canvas design artefact against requirements PD-UI-09 through PD-UI-12. '
    'This is a HARD GATE. '
    'Note: The design artefact uses the frontend requirements doc numbering (PD-UI-09..12). '
    'The implementation_order.md uses a different internal ordering scheme.'
)
with open('handoffs/WF02-f2a-canvas-batch1-20260528/step-01b-code-design-validator.json', 'w') as f:
    json.dump(h, f, indent=2)
print('Step 01b updated')
