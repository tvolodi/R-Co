# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: f2-canvas.e2e.spec.ts >> F2 — Process Designer Canvas (PD-UI-09 through PD-UI-12) >> PD-UI-12 — Node properties panel >> TC-PDUI12-03: Saving the definition persists property changes
- Location: tests\e2e\f2-canvas.e2e.spec.ts:736:5

# Error details

```
Error: expect(locator).toBeVisible() failed

Locator: getByText('Definition saved')
Expected: visible
Timeout: 10000ms
Error: element(s) not found

Call log:
  - Expect "toBeVisible" with timeout 10000ms
  - waiting for getByText('Definition saved')

```

```yaml
- complementary:
  - text: BPM Platform
  - navigation:
    - link "Instances":
      - /url: /instances
    - link "My Tasks":
      - /url: /tasks
    - link "Definitions":
      - /url: /definitions
    - link "DLQ":
      - /url: /dlq
    - link "Webhooks":
      - /url: /webhooks
    - link "Users":
      - /url: /admin/users
    - link "Groups":
      - /url: /admin/groups
    - link "Tokens":
      - /url: /admin/tokens
    - link "Audit":
      - /url: /admin/audit
    - link "Health":
      - /url: /admin/health
    - link "Metrics":
      - /url: /admin/metrics
  - text: Admin User PLATFORM_ADMIN
  - button "Sign out"
- main:
  - heading "Save Test pd-ui-canvas-e2e-save-03-1780044208713" [level=2]
  - button "Show Raw JSON"
  - button "Re-layout"
  - button "Save"
  - text: Unprocessable Entity Node Palette Events
  - img
  - text: Start
  - img
  - text: End
  - img
  - text: Timer Tasks
  - img
  - text: Human Task
  - img
  - text: Service Task
  - img
  - text: Sub-process Gateways ✕ Exclusive Gateway + Parallel Gateway
  - application:
    - img:
      - group "Edge from start to task-pd-ui-canvas-e2e-save-03-1780044208713"
    - img:
      - group "Edge from task-pd-ui-canvas-e2e-save-03-1780044208713 to end"
    - group:
      - img
    - group:
      - img
      - text: Saved Task pd-ui-canvas-e2e-save-03-1780044208713 Human Task
    - group:
      - img
    - img
    - img "Mini Map"
    - button "Zoom In":
      - img
    - button "Zoom Out":
      - img
    - button "Fit View":
      - img
    - button "Toggle Interactivity":
      - img
    - link "React Flow attribution":
      - /url: https://reactflow.dev
      - text: React Flow
  - text: Properties
  - button "Close panel": ✕
  - text: "Node: task-pd-ui-canvas-e2e-save-03-1780044208713 (HUMAN_TASK) Name"
  - textbox "Node name": Saved Task pd-ui-canvas-e2e-save-03-1780044208713
  - text: Assignee Type
  - combobox:
    - option "User" [selected]
    - option "Group"
    - option "Role"
    - option "Unassigned"
  - text: Assignee Ref
  - textbox "Assignee reference"
  - text: Form Schema
  - textbox "JSON Schema"
  - paragraph: Select a node on the canvas to edit its properties. Changes are saved locally until you click Save.
```

# Test source

```ts
  665 |       // Nodes remain
  666 |       const nodeElements = page.locator('.react-flow__node')
  667 |       await expect(nodeElements).toHaveCount(2)
  668 | 
  669 |       await shot(page, 'TC11-03-edge-deleted')
  670 |       // VERDICT: Screen shows canvas with 2 nodes and 0 edges after deleting the edge
  671 |     })
  672 |   })
  673 | 
  674 |   // ═══════════════════════════════════════════════════════════════════════════════
  675 |   // PD-UI-12 — Node properties panel
  676 |   // ═══════════════════════════════════════════════════════════════════════════════
  677 | 
  678 |   test.describe('PD-UI-12 — Node properties panel', () => {
  679 |     test('TC-PDUI12-01: Clicking a node opens the property panel', async ({ page, request }) => {
  680 |       const uniqueSuffix = testId('props-01')
  681 |       const graph = threeNodeGraph(uniqueSuffix)
  682 |       const def = await createTestDefinition(request, authToken, `Properties ${uniqueSuffix}`, '1.0.0', graph)
  683 |       createdDefinitionIds.push(def.id)
  684 | 
  685 |       await loginWithToken(page, authToken)
  686 |       await navigateToCanvas(page, def.id)
  687 | 
  688 |       // Click the HUMAN_TASK node
  689 |       await page.getByText(`Review Task ${uniqueSuffix}`).click()
  690 |       await page.waitForTimeout(500)
  691 | 
  692 |       // Property panel slides in
  693 |       const propertyPanel = page.getByTestId('property-panel')
  694 |       await expect(propertyPanel).toBeVisible({ timeout: 5_000 })
  695 | 
  696 |       // Panel contains the node name input
  697 |       const nameInput = page.getByTestId('prop-name-input')
  698 |       await expect(nameInput).toBeVisible()
  699 |       await expect(nameInput).toHaveValue(`Review Task ${uniqueSuffix}`)
  700 | 
  701 |       // Panel shows type-specific fields for HUMAN_TASK
  702 |       await expect(page.getByTestId('prop-assignee-type')).toBeVisible()
  703 |       await expect(page.getByTestId('prop-assignee-ref')).toBeVisible()
  704 | 
  705 |       await shot(page, 'TC12-01-property-panel-open')
  706 |       // VERDICT: Screen shows property panel with node name "Review Task ..." and HUMAN_TASK attribute fields
  707 |     })
  708 | 
  709 |     test('TC-PDUI12-02: Editing a property updates node data locally', async ({ page, request }) => {
  710 |       const uniqueSuffix = testId('edit-02')
  711 |       const graph = threeNodeGraph(uniqueSuffix)
  712 |       const def = await createTestDefinition(request, authToken, `Edit Prop ${uniqueSuffix}`, '1.0.0', graph)
  713 |       createdDefinitionIds.push(def.id)
  714 | 
  715 |       await loginWithToken(page, authToken)
  716 |       await navigateToCanvas(page, def.id)
  717 | 
  718 |       // Click the HUMAN_TASK node
  719 |       await page.getByText(`Review Task ${uniqueSuffix}`).click()
  720 |       await page.waitForTimeout(500)
  721 |       await expect(page.getByTestId('property-panel')).toBeVisible()
  722 | 
  723 |       // Change the name
  724 |       const nameInput = page.getByTestId('prop-name-input')
  725 |       await nameInput.clear()
  726 |       await nameInput.fill(`Updated Task ${uniqueSuffix}`)
  727 | 
  728 |       // The node on the canvas should show the updated name
  729 |       await page.waitForTimeout(300)
  730 |       await expect(page.getByText(`Updated Task ${uniqueSuffix}`)).toBeVisible()
  731 | 
  732 |       await shot(page, 'TC12-02-after-property-edit')
  733 |       // VERDICT: Screen shows canvas node with updated name "Updated Task ..." after editing in property panel
  734 |     })
  735 | 
  736 |     test('TC-PDUI12-03: Saving the definition persists property changes', async ({ page, request }) => {
  737 |       const uniqueSuffix = testId('save-03')
  738 |       // Use a valid connected graph (backend rejects isolated nodes with 422)
  739 |       const graph = threeNodeGraph(uniqueSuffix)
  740 |       const def = await createTestDefinition(request, authToken, `Save Test ${uniqueSuffix}`, '1.0.0', graph)
  741 |       createdDefinitionIds.push(def.id)
  742 | 
  743 |       await loginWithToken(page, authToken)
  744 |       await navigateToCanvas(page, def.id)
  745 | 
  746 |       // Verify 3 nodes loaded from the valid graph
  747 |       await expect(page.locator('.react-flow__node')).toHaveCount(3)
  748 | 
  749 |       // Change a node name to mark dirty
  750 |       await page.getByText(`Review Task ${uniqueSuffix}`).click()
  751 |       await page.waitForTimeout(500)
  752 |       await expect(page.getByTestId('property-panel')).toBeVisible()
  753 |       const nameInput = page.getByTestId('prop-name-input')
  754 |       await nameInput.clear()
  755 |       await nameInput.fill(`Saved Task ${uniqueSuffix}`)
  756 |       await page.waitForTimeout(300)
  757 | 
  758 |       // Click the Save button
  759 |       const saveButton = page.getByTestId('btn-save-definition')
  760 |       await expect(saveButton).toBeVisible()
  761 |       await expect(saveButton).not.toBeDisabled()
  762 |       await saveButton.click()
  763 | 
  764 |       // Wait for success toast
> 765 |       await expect(page.getByText('Definition saved', { exact: false })).toBeVisible({ timeout: 10_000 })
      |                                                                          ^ Error: expect(locator).toBeVisible() failed
  766 | 
  767 |       await shot(page, 'TC12-03-after-save')
  768 |       // VERDICT: Screen shows success toast after saving
  769 | 
  770 |       // Reload the page — changes should persist (re-authenticate since token is in-memory)
  771 |       await page.reload()
  772 |       await loginWithToken(page, authToken)
  773 |       await navigateToCanvas(page, def.id)
  774 | 
  775 |       // The graph should have 3 nodes after reload
  776 |       const nodesAfterReload = page.locator('.react-flow__node')
  777 |       await expect(nodesAfterReload).toHaveCount(3)
  778 | 
  779 |       // The saved name should persist
  780 |       await expect(page.getByText(`Saved Task ${uniqueSuffix}`)).toBeVisible()
  781 | 
  782 |       await shot(page, 'TC12-03-after-reload')
  783 |       // VERDICT: Screen shows canvas with 3 nodes and saved name after reload — changes persisted via PATCH
  784 |     })
  785 | 
  786 |     test('TC-PDUI12-04: Property panel shows correct fields per node type', async ({ page, request }) => {
  787 |       const uniqueSuffix = testId('fields-04')
  788 |       // Create a definition with multiple node types — all connected (backend rejects isolated nodes with 422)
  789 |       const graph = {
  790 |         nodes: [
  791 |           { id: 'start', node_type: 'START', label: null, attributes: null },
  792 |           { id: `human-${uniqueSuffix}`, node_type: 'HUMAN_TASK', label: `Human ${uniqueSuffix}`, attributes: '{"role":"admin-user","assignee_type":"user","assignee_ref":"admin-user"}' },
  793 |           { id: `service-${uniqueSuffix}`, node_type: 'SERVICE_TASK', label: `Service ${uniqueSuffix}`, attributes: '{"role":"admin-user","service_type":"http","endpoint":"https://example.com/api","service_config":"{}"}' },
  794 |           { id: `timer-${uniqueSuffix}`, node_type: 'TIMER', label: `Timer ${uniqueSuffix}`, attributes: '{"role":"admin-user","timer_type":"duration","timer_duration":"PT1H","duration_iso8601":"PT1H"}' },
  795 |           { id: `gw-${uniqueSuffix}`, node_type: 'EXCLUSIVE_GATEWAY', label: null, attributes: null },
  796 |           { id: 'end', node_type: 'END', label: null, attributes: null },
  797 |         ],
  798 |         edges: [
  799 |           { id: 'e1', source: 'start', target: `human-${uniqueSuffix}`, condition: null, is_default: false },
  800 |           { id: 'e2', source: `human-${uniqueSuffix}`, target: `service-${uniqueSuffix}`, condition: null, is_default: false },
  801 |           { id: 'e3', source: `service-${uniqueSuffix}`, target: `timer-${uniqueSuffix}`, condition: null, is_default: false },
  802 |           { id: 'e4', source: `timer-${uniqueSuffix}`, target: `gw-${uniqueSuffix}`, condition: null, is_default: false },
  803 |           { id: 'e5', source: `gw-${uniqueSuffix}`, target: 'end', condition: "status == 'approved'", is_default: false },
  804 |           { id: 'e6', source: `gw-${uniqueSuffix}`, target: 'end', condition: null, is_default: true },
  805 |         ],
  806 |       }
  807 |       const def = await createTestDefinition(request, authToken, `Field Types ${uniqueSuffix}`, '1.0.0', graph)
  808 |       createdDefinitionIds.push(def.id)
  809 | 
  810 |       await loginWithToken(page, authToken)
  811 |       await navigateToCanvas(page, def.id)
  812 | 
  813 |       // Click HUMAN_TASK node — panel shows assignee fields
  814 |       await page.getByText(`Human ${uniqueSuffix}`).click()
  815 |       await page.waitForTimeout(500)
  816 |       await expect(page.getByTestId('prop-assignee-type')).toBeVisible()
  817 |       await expect(page.getByTestId('prop-form-schema')).toBeVisible()
  818 |       await shot(page, 'TC12-04-human-task-fields')
  819 |       // VERDICT: Screen shows HUMAN_TASK property panel with assignee_type, assignee_ref, form_schema fields
  820 | 
  821 |       // Click SERVICE_TASK node — panel shows service fields
  822 |       await page.getByText(`Service ${uniqueSuffix}`).click()
  823 |       await page.waitForTimeout(500)
  824 |       await expect(page.getByTestId('prop-service-type')).toBeVisible()
  825 |       await expect(page.getByTestId('prop-service-config')).toBeVisible()
  826 |       await shot(page, 'TC12-04-service-task-fields')
  827 |       // VERDICT: Screen shows SERVICE_TASK property panel with service_type, service_config fields
  828 | 
  829 |       // Click TIMER node — TimerNode renders only a clock icon, no text label.
  830 |       // Node order: START, HUMAN_TASK, SERVICE_TASK, TIMER (4th), GATEWAY, END.
  831 |       // Click the canvas pane first to deselect the previously selected SERVICE_TASK node,
  832 |       // then click the TIMER node using its React Flow data-testid attribute.
  833 |       await page.getByTestId('process-canvas').click({ position: { x: 10, y: 10 } })
  834 |       await page.waitForTimeout(300)
  835 |       await page.locator('[data-testid^="rf__node-timer-"]').click()
  836 |       await page.waitForTimeout(500)
  837 |       await expect(page.getByTestId('prop-timer-type')).toBeVisible()
  838 |       await expect(page.getByTestId('prop-timer-duration')).toBeVisible()
  839 |       await shot(page, 'TC12-04-timer-fields')
  840 |       // VERDICT: Screen shows TIMER property panel with timer_type, timer_duration fields
  841 | 
  842 |       // Click EXCLUSIVE_GATEWAY node — panel shows no node-level attributes
  843 |       await page.getByTestId('process-canvas').locator('.react-flow__node').filter({ hasText: /EXCLUSIVE|GATEWAY/i }).first().click()
  844 |       await page.waitForTimeout(500)
  845 |       // Gateway should not show node-level attribute fields like assignee_type
  846 |       await expect(page.getByTestId('prop-assignee-type')).not.toBeVisible()
  847 |       await shot(page, 'TC12-04-gateway-no-fields')
  848 |       // VERDICT: Screen shows EXCLUSIVE_GATEWAY property panel with no node-level attribute fields
  849 |     })
  850 |   })
  851 | 
  852 |   // ═══════════════════════════════════════════════════════════════════════════════
  853 |   // Save workflow
  854 |   // ═══════════════════════════════════════════════════════════════════════════════
  855 | 
  856 |   test.describe('Save workflow', () => {
  857 |     test('TC-SAVE-01: Modified canvas saves via PUT and reload shows saved changes', async ({ page, request }) => {
  858 |       const uniqueSuffix = testId('fullsave-01')
  859 |       // Use a valid connected graph (backend rejects isolated nodes with 422)
  860 |       const graph = threeNodeGraph(uniqueSuffix)
  861 |       const def = await createTestDefinition(request, authToken, `Full Save ${uniqueSuffix}`, '1.0.0', graph)
  862 |       createdDefinitionIds.push(def.id)
  863 | 
  864 |       await loginWithToken(page, authToken)
  865 |       await navigateToCanvas(page, def.id)
```