# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: f2-canvas.e2e.spec.ts >> F2 — Process Designer Canvas (PD-UI-09 through PD-UI-12) >> PD-UI-12 — Node properties panel >> TC-PDUI12-01: Clicking a node opens the property panel
- Location: tests\e2e\f2-canvas.e2e.spec.ts:678:5

# Error details

```
Error: expect(locator).toHaveValue(expected) failed

Locator:  getByTestId('prop-name-input')
Expected: "Review Task pd-ui-canvas-e2e-props-01-1780019069988"
Received: ""
Timeout:  5000ms

Call log:
  - Expect "toHaveValue" with timeout 5000ms
  - waiting for getByTestId('prop-name-input')
    14 × locator resolved to <input value="" placeholder="Node name" data-testid="prop-name-input"/>
       - unexpected value ""

```

```yaml
- textbox "Node name"
```

# Test source

```ts
  598 |         // Core functionality verified: nodes render, handles present, ConditionDialog component exists.
  599 |         return
  600 |       }
  601 | 
  602 |       // ConditionDialog appears
  603 |       const conditionDialog = page.getByTestId('condition-dialog')
  604 |       await expect(conditionDialog).toBeVisible({ timeout: 5_000 })
  605 | 
  606 |       // Dialog has title "Edge Condition"
  607 |       await expect(conditionDialog).toContainText('Edge Condition')
  608 | 
  609 |       // Dialog has CEL input field
  610 |       const celInput = page.getByTestId('condition-cel-input')
  611 |       await expect(celInput).toBeVisible()
  612 |       await expect(celInput).toHaveAttribute('placeholder', /status/i)
  613 | 
  614 |       // Dialog has "Default edge" checkbox
  615 |       const defaultCheckbox = page.getByTestId('condition-default-checkbox')
  616 |       await expect(defaultCheckbox).toBeVisible()
  617 | 
  618 |       // Dialog has Cancel and Confirm buttons
  619 |       await expect(page.getByTestId('condition-confirm')).toBeVisible()
  620 |       await expect(page.getByTestId('condition-cancel')).toBeVisible()
  621 | 
  622 |       await shot(page, 'TC11-02-condition-dialog')
  623 |       // VERDICT: Screen shows ConditionDialog with title "Edge Condition", CEL input, default edge checkbox, Cancel and Confirm buttons
  624 | 
  625 |       // Cancel the dialog — edge should NOT be created
  626 |       await page.getByTestId('condition-cancel').click()
  627 |       await page.waitForTimeout(300)
  628 |       await expect(conditionDialog).not.toBeVisible()
  629 | 
  630 |       // Edge should not exist (cancelled)
  631 |       const edgesAfterCancel = page.locator('.react-flow__edge')
  632 |       await expect(edgesAfterCancel).toHaveCount(0)
  633 | 
  634 |       await shot(page, 'TC11-02-after-cancel')
  635 |       // VERDICT: Screen shows canvas without new edge after cancelling ConditionDialog
  636 |     })
  637 | 
  638 |     test('TC-PDUI11-03: Edge deletion removes the edge', async ({ page, request }) => {
  639 |       const uniqueSuffix = testId('deledge-03')
  640 |       const graph = startEndGraph()
  641 |       const def = await createTestDefinition(request, authToken, `Delete Edge ${uniqueSuffix}`, '1.0.0', graph)
  642 |       createdDefinitionIds.push(def.id)
  643 | 
  644 |       await loginWithToken(page, authToken)
  645 |       await navigateToCanvas(page, def.id)
  646 | 
  647 |       // One edge exists initially
  648 |       const edgeElements = page.locator('.react-flow__edge')
  649 |       await expect(edgeElements).toHaveCount(1)
  650 | 
  651 |       // Click the edge's interaction path (wider invisible hit area) to select it
  652 |       const edgeInteraction = page.locator('.react-flow__edge-interaction').first()
  653 |       await expect(edgeInteraction).toBeVisible()
  654 |       await edgeInteraction.click({ force: true })
  655 |       await page.waitForTimeout(300)
  656 | 
  657 |       // Press Delete key
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
> 698 |       await expect(nameInput).toHaveValue(`Review Task ${uniqueSuffix}`)
      |                               ^ Error: expect(locator).toHaveValue(expected) failed
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
  758 |       await expect(page.getByText('saved', { exact: false })).toBeVisible({ timeout: 10_000 })
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
```