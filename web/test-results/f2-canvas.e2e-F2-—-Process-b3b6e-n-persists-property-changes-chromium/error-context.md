# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: f2-canvas.e2e.spec.ts >> F2 — Process Designer Canvas (PD-UI-09 through PD-UI-12) >> PD-UI-12 — Node properties panel >> TC-PDUI12-03: Saving the definition persists property changes
- Location: tests\e2e\f2-canvas.e2e.spec.ts:735:5

# Error details

```
Error: expect(locator).toBeVisible() failed

Locator: getByText('saved')
Expected: visible
Timeout: 10000ms
Error: element(s) not found

Call log:
  - Expect "toBeVisible" with timeout 10000ms
  - waiting for getByText('saved')

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
  - heading "Save Test pd-ui-canvas-e2e-save-03-1780019086400" [level=2]
  - button "Show Raw JSON"
  - button "Save"
  - text: Method Not Allowed Node Palette Events
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
      - group "Edge from start to end"
    - group:
      - img
    - group:
      - img
    - group:
      - img
      - text: Human Task Human Task
    - img
    - link "React Flow attribution":
      - /url: https://reactflow.dev
      - text: React Flow
  - text: 1 warning ▼
```

# Test source

```ts
  658 |       await page.keyboard.press('Delete')
  659 |       await page.waitForTimeout(500)
  660 | 
  661 |       // Edge is removed
  662 |       await expect(edgeElements).toHaveCount(0)
  663 | 
  664 |       // Nodes remain
  665 |       const nodeElements = page.locator('.react-flow__node')
  666 |       await expect(nodeElements).toHaveCount(2)
  667 | 
  668 |       await shot(page, 'TC11-03-edge-deleted')
  669 |       // VERDICT: Screen shows canvas with 2 nodes and 0 edges after deleting the edge
  670 |     })
  671 |   })
  672 | 
  673 |   // ═══════════════════════════════════════════════════════════════════════════════
  674 |   // PD-UI-12 — Node properties panel
  675 |   // ═══════════════════════════════════════════════════════════════════════════════
  676 | 
  677 |   test.describe('PD-UI-12 — Node properties panel', () => {
  678 |     test('TC-PDUI12-01: Clicking a node opens the property panel', async ({ page, request }) => {
  679 |       const uniqueSuffix = testId('props-01')
  680 |       const graph = threeNodeGraph(uniqueSuffix)
  681 |       const def = await createTestDefinition(request, authToken, `Properties ${uniqueSuffix}`, '1.0.0', graph)
  682 |       createdDefinitionIds.push(def.id)
  683 | 
  684 |       await loginWithToken(page, authToken)
  685 |       await navigateToCanvas(page, def.id)
  686 | 
  687 |       // Click the HUMAN_TASK node
  688 |       await page.getByText(`Review Task ${uniqueSuffix}`).click()
  689 |       await page.waitForTimeout(500)
  690 | 
  691 |       // Property panel slides in
  692 |       const propertyPanel = page.getByTestId('property-panel')
  693 |       await expect(propertyPanel).toBeVisible({ timeout: 5_000 })
  694 | 
  695 |       // Panel contains the node name input
  696 |       const nameInput = page.getByTestId('prop-name-input')
  697 |       await expect(nameInput).toBeVisible()
  698 |       await expect(nameInput).toHaveValue(`Review Task ${uniqueSuffix}`)
  699 | 
  700 |       // Panel shows type-specific fields for HUMAN_TASK
  701 |       await expect(page.getByTestId('prop-assignee-type')).toBeVisible()
  702 |       await expect(page.getByTestId('prop-assignee-ref')).toBeVisible()
  703 | 
  704 |       await shot(page, 'TC12-01-property-panel-open')
  705 |       // VERDICT: Screen shows property panel with node name "Review Task ..." and HUMAN_TASK attribute fields
  706 |     })
  707 | 
  708 |     test('TC-PDUI12-02: Editing a property updates node data locally', async ({ page, request }) => {
  709 |       const uniqueSuffix = testId('edit-02')
  710 |       const graph = threeNodeGraph(uniqueSuffix)
  711 |       const def = await createTestDefinition(request, authToken, `Edit Prop ${uniqueSuffix}`, '1.0.0', graph)
  712 |       createdDefinitionIds.push(def.id)
  713 | 
  714 |       await loginWithToken(page, authToken)
  715 |       await navigateToCanvas(page, def.id)
  716 | 
  717 |       // Click the HUMAN_TASK node
  718 |       await page.getByText(`Review Task ${uniqueSuffix}`).click()
  719 |       await page.waitForTimeout(500)
  720 |       await expect(page.getByTestId('property-panel')).toBeVisible()
  721 | 
  722 |       // Change the name
  723 |       const nameInput = page.getByTestId('prop-name-input')
  724 |       await nameInput.clear()
  725 |       await nameInput.fill(`Updated Task ${uniqueSuffix}`)
  726 | 
  727 |       // The node on the canvas should show the updated name
  728 |       await page.waitForTimeout(300)
  729 |       await expect(page.getByText(`Updated Task ${uniqueSuffix}`)).toBeVisible()
  730 | 
  731 |       await shot(page, 'TC12-02-after-property-edit')
  732 |       // VERDICT: Screen shows canvas node with updated name "Updated Task ..." after editing in property panel
  733 |     })
  734 | 
  735 |     test('TC-PDUI12-03: Saving the definition persists property changes', async ({ page, request }) => {
  736 |       const uniqueSuffix = testId('save-03')
  737 |       const graph = startEndGraph()
  738 |       const def = await createTestDefinition(request, authToken, `Save Test ${uniqueSuffix}`, '1.0.0', graph)
  739 |       createdDefinitionIds.push(def.id)
  740 | 
  741 |       await loginWithToken(page, authToken)
  742 |       await navigateToCanvas(page, def.id)
  743 | 
  744 |       // Add a HUMAN_TASK node via double-click
  745 |       await page.getByTestId('palette-item-HUMAN_TASK').dblclick()
  746 |       await page.waitForTimeout(500)
  747 | 
  748 |       // Verify 3 nodes now
  749 |       await expect(page.locator('.react-flow__node')).toHaveCount(3)
  750 | 
  751 |       // Click the Save button
  752 |       const saveButton = page.getByTestId('btn-save-definition')
  753 |       await expect(saveButton).toBeVisible()
  754 |       await expect(saveButton).not.toBeDisabled()
  755 |       await saveButton.click()
  756 | 
  757 |       // Wait for success toast
> 758 |       await expect(page.getByText('saved', { exact: false })).toBeVisible({ timeout: 10_000 })
      |                                                               ^ Error: expect(locator).toBeVisible() failed
  759 | 
  760 |       await shot(page, 'TC12-03-after-save')
  761 |       // VERDICT: Screen shows success toast after saving
  762 | 
  763 |       // Reload the page — changes should persist
  764 |       await page.reload()
  765 |       await page.waitForURL(`/definitions/${def.id}`, { timeout: 15_000 })
  766 |       await expect(page.getByTestId('process-canvas')).toBeVisible({ timeout: 15_000 })
  767 | 
  768 |       // The graph should have 3 nodes after reload (the added HUMAN_TASK persisted)
  769 |       const nodesAfterReload = page.locator('.react-flow__node')
  770 |       await expect(nodesAfterReload).toHaveCount(3)
  771 | 
  772 |       await shot(page, 'TC12-03-after-reload')
  773 |       // VERDICT: Screen shows canvas with 3 nodes after reload — the added HUMAN_TASK node persisted via save
  774 |     })
  775 | 
  776 |     test('TC-PDUI12-04: Property panel shows correct fields per node type', async ({ page, request }) => {
  777 |       const uniqueSuffix = testId('fields-04')
  778 |       // Create a definition with multiple node types
  779 |       const graph = {
  780 |         nodes: [
  781 |           { id: 'start', node_type: 'START', label: null, attributes: null },
  782 |           { id: `human-${uniqueSuffix}`, node_type: 'HUMAN_TASK', label: `Human ${uniqueSuffix}`, attributes: '{"role":"admin-user","assignee_type":"user","assignee_ref":"admin-user"}' },
  783 |           { id: `service-${uniqueSuffix}`, node_type: 'SERVICE_TASK', label: `Service ${uniqueSuffix}`, attributes: '{"role":"admin-user","service_type":"http","service_config":"{}"}' },
  784 |           { id: `timer-${uniqueSuffix}`, node_type: 'TIMER', label: `Timer ${uniqueSuffix}`, attributes: '{"role":"admin-user","timer_type":"duration","timer_duration":"PT1H"}' },
  785 |           { id: `gw-${uniqueSuffix}`, node_type: 'EXCLUSIVE_GATEWAY', label: null, attributes: null },
  786 |           { id: 'end', node_type: 'END', label: null, attributes: null },
  787 |         ],
  788 |         edges: [],
  789 |       }
  790 |       const def = await createTestDefinition(request, authToken, `Field Types ${uniqueSuffix}`, '1.0.0', graph)
  791 |       createdDefinitionIds.push(def.id)
  792 | 
  793 |       await loginWithToken(page, authToken)
  794 |       await navigateToCanvas(page, def.id)
  795 | 
  796 |       // Click HUMAN_TASK node — panel shows assignee fields
  797 |       await page.getByText(`Human ${uniqueSuffix}`).click()
  798 |       await page.waitForTimeout(500)
  799 |       await expect(page.getByTestId('prop-assignee-type')).toBeVisible()
  800 |       await expect(page.getByTestId('prop-form-schema')).toBeVisible()
  801 |       await shot(page, 'TC12-04-human-task-fields')
  802 |       // VERDICT: Screen shows HUMAN_TASK property panel with assignee_type, assignee_ref, form_schema fields
  803 | 
  804 |       // Click SERVICE_TASK node — panel shows service fields
  805 |       await page.getByText(`Service ${uniqueSuffix}`).click()
  806 |       await page.waitForTimeout(500)
  807 |       await expect(page.getByTestId('prop-service-type')).toBeVisible()
  808 |       await expect(page.getByTestId('prop-service-config')).toBeVisible()
  809 |       await shot(page, 'TC12-04-service-task-fields')
  810 |       // VERDICT: Screen shows SERVICE_TASK property panel with service_type, service_config fields
  811 | 
  812 |       // Click TIMER node — panel shows timer fields
  813 |       await page.getByText(`Timer ${uniqueSuffix}`).click()
  814 |       await page.waitForTimeout(500)
  815 |       await expect(page.getByTestId('prop-timer-type')).toBeVisible()
  816 |       await expect(page.getByTestId('prop-timer-duration')).toBeVisible()
  817 |       await shot(page, 'TC12-04-timer-fields')
  818 |       // VERDICT: Screen shows TIMER property panel with timer_type, timer_duration fields
  819 | 
  820 |       // Click EXCLUSIVE_GATEWAY node — panel shows no node-level attributes
  821 |       await page.getByTestId('process-canvas').locator('.react-flow__node').filter({ hasText: /EXCLUSIVE|GATEWAY/i }).first().click()
  822 |       await page.waitForTimeout(500)
  823 |       // Gateway should not show node-level attribute fields like assignee_type
  824 |       await expect(page.getByTestId('prop-assignee-type')).not.toBeVisible()
  825 |       await shot(page, 'TC12-04-gateway-no-fields')
  826 |       // VERDICT: Screen shows EXCLUSIVE_GATEWAY property panel with no node-level attribute fields
  827 |     })
  828 |   })
  829 | 
  830 |   // ═══════════════════════════════════════════════════════════════════════════════
  831 |   // Save workflow
  832 |   // ═══════════════════════════════════════════════════════════════════════════════
  833 | 
  834 |   test.describe('Save workflow', () => {
  835 |     test('TC-SAVE-01: Modified canvas saves via PUT and reload shows saved changes', async ({ page, request }) => {
  836 |       const uniqueSuffix = testId('fullsave-01')
  837 |       const graph = startEndGraph()
  838 |       const def = await createTestDefinition(request, authToken, `Full Save ${uniqueSuffix}`, '1.0.0', graph)
  839 |       createdDefinitionIds.push(def.id)
  840 | 
  841 |       await loginWithToken(page, authToken)
  842 |       await navigateToCanvas(page, def.id)
  843 | 
  844 |       // Initial state: 2 nodes, 1 edge
  845 |       await expect(page.locator('.react-flow__node')).toHaveCount(2)
  846 |       await expect(page.locator('.react-flow__edge')).toHaveCount(1)
  847 | 
  848 |       // Add a HUMAN_TASK node
  849 |       await page.getByTestId('palette-item-HUMAN_TASK').dblclick()
  850 |       await page.waitForTimeout(500)
  851 | 
  852 |       // Verify 3 nodes now
  853 |       await expect(page.locator('.react-flow__node')).toHaveCount(3)
  854 | 
  855 |       // Save
  856 |       await page.getByTestId('btn-save-definition').click()
  857 |       await expect(page.getByText('saved', { exact: false })).toBeVisible({ timeout: 10_000 })
  858 | 
```