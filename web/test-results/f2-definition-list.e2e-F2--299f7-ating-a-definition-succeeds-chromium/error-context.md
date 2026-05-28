# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: f2-definition-list.e2e.spec.ts >> F2 — Definition List View (PD-UI-01 through PD-UI-04) >> PD-UI-04 — Create definition >> TC-PDUI04-03: creating a definition succeeds
- Location: tests\e2e\f2-definition-list.e2e.spec.ts:450:5

# Error details

```
TimeoutError: page.waitForURL: Timeout 15000ms exceeded.
=========================== logs ===========================
waiting for navigation until "load"
============================================================
```

# Page snapshot

```yaml
- generic [ref=e3]:
  - complementary [ref=e4]:
    - generic [ref=e5]: BPM Platform
    - navigation [ref=e6]:
      - link "Instances" [ref=e7] [cursor=pointer]:
        - /url: /instances
      - link "My Tasks" [ref=e8] [cursor=pointer]:
        - /url: /tasks
      - link "Definitions" [ref=e9] [cursor=pointer]:
        - /url: /definitions
      - link "DLQ" [ref=e10] [cursor=pointer]:
        - /url: /dlq
      - link "Webhooks" [ref=e11] [cursor=pointer]:
        - /url: /webhooks
      - link "Users" [ref=e12] [cursor=pointer]:
        - /url: /admin/users
      - link "Groups" [ref=e13] [cursor=pointer]:
        - /url: /admin/groups
      - link "Tokens" [ref=e14] [cursor=pointer]:
        - /url: /admin/tokens
      - link "Audit" [ref=e15] [cursor=pointer]:
        - /url: /admin/audit
      - link "Health" [ref=e16] [cursor=pointer]:
        - /url: /admin/health
      - link "Metrics" [ref=e17] [cursor=pointer]:
        - /url: /admin/metrics
    - generic [ref=e18]:
      - generic [ref=e19]: Admin User
      - generic [ref=e20]: PLATFORM_ADMIN
      - button "Sign out" [ref=e21] [cursor=pointer]
  - main [ref=e22]:
    - generic [ref=e23]:
      - generic [ref=e24]:
        - heading "Process Definitions" [level=2] [ref=e25]
        - textbox "Search definitions..." [ref=e26]
        - generic [ref=e27]:
          - generic [ref=e28]: Status
          - combobox [ref=e29]:
            - option "All" [selected]
            - option "Draft"
            - option "Active"
            - option "Deprecated"
            - option "Archived"
        - button "+ New Definition" [ref=e30] [cursor=pointer]
      - table [ref=e31]:
        - rowgroup [ref=e32]:
          - row "Name Version Status Updated Actions" [ref=e33]:
            - columnheader "Name" [ref=e34]
            - columnheader "Version" [ref=e35]
            - columnheader "Status" [ref=e36]
            - columnheader "Updated" [ref=e37]
            - columnheader "Actions" [ref=e38]
        - rowgroup [ref=e39]:
          - row "TC-PD-08-01 Process 1.0.0 DRAFT 10/13/58361 Activate" [ref=e40]:
            - cell "TC-PD-08-01 Process" [ref=e41]:
              - link "TC-PD-08-01 Process" [ref=e42] [cursor=pointer]:
                - /url: /definitions/702be060-e1cb-47cb-b7cf-acbc0b02a926
            - cell "1.0.0" [ref=e43]
            - cell "DRAFT" [ref=e44]
            - cell "10/13/58361" [ref=e45]
            - cell "Activate" [ref=e46]:
              - button "Activate" [ref=e47] [cursor=pointer]
          - row "TC-PD-08-02 Process 1.0.0 DRAFT 10/13/58361 Activate" [ref=e48]:
            - cell "TC-PD-08-02 Process" [ref=e49]:
              - link "TC-PD-08-02 Process" [ref=e50] [cursor=pointer]:
                - /url: /definitions/31c4479b-3fdd-437a-86e1-2575576a4dec
            - cell "1.0.0" [ref=e51]
            - cell "DRAFT" [ref=e52]
            - cell "10/13/58361" [ref=e53]
            - cell "Activate" [ref=e54]:
              - button "Activate" [ref=e55] [cursor=pointer]
          - row "TC-PD-08-03 Process 1.0.0 DRAFT 10/13/58361 Activate" [ref=e56]:
            - cell "TC-PD-08-03 Process" [ref=e57]:
              - link "TC-PD-08-03 Process" [ref=e58] [cursor=pointer]:
                - /url: /definitions/c933eeda-54dc-4e1f-9ecc-dde5907f0038
            - cell "1.0.0" [ref=e59]
            - cell "DRAFT" [ref=e60]
            - cell "10/13/58361" [ref=e61]
            - cell "Activate" [ref=e62]:
              - button "Activate" [ref=e63] [cursor=pointer]
          - row "TC-PD-08-06 Process 1.0.0 DRAFT 10/13/58361 Activate" [ref=e64]:
            - cell "TC-PD-08-06 Process" [ref=e65]:
              - link "TC-PD-08-06 Process" [ref=e66] [cursor=pointer]:
                - /url: /definitions/64096f66-bd26-43a5-9391-bc791a03060b
            - cell "1.0.0" [ref=e67]
            - cell "DRAFT" [ref=e68]
            - cell "10/13/58361" [ref=e69]
            - cell "Activate" [ref=e70]:
              - button "Activate" [ref=e71] [cursor=pointer]
          - row "TC-PD-08-07 Process 1.0.0 DRAFT 10/13/58361 Activate" [ref=e72]:
            - cell "TC-PD-08-07 Process" [ref=e73]:
              - link "TC-PD-08-07 Process" [ref=e74] [cursor=pointer]:
                - /url: /definitions/5e5dfefd-2b3a-40ff-88d2-c76a73266749
            - cell "1.0.0" [ref=e75]
            - cell "DRAFT" [ref=e76]
            - cell "10/13/58361" [ref=e77]
            - cell "Activate" [ref=e78]:
              - button "Activate" [ref=e79] [cursor=pointer]
          - row "TC-EE-01-06 Process 1.0 ACTIVE 10/13/58361 Archive" [ref=e80]:
            - cell "TC-EE-01-06 Process" [ref=e81]:
              - link "TC-EE-01-06 Process" [ref=e82] [cursor=pointer]:
                - /url: /definitions/7396258f-a68b-4b5f-bf5e-bb7072944b61
            - cell "1.0" [ref=e83]
            - cell "ACTIVE" [ref=e84]
            - cell "10/13/58361" [ref=e85]
            - cell "Archive" [ref=e86]:
              - button "Archive" [ref=e87] [cursor=pointer]
          - row "EE09-TC01 1.0 ACTIVE 10/13/58361 Archive" [ref=e88]:
            - cell "EE09-TC01" [ref=e89]:
              - link "EE09-TC01" [ref=e90] [cursor=pointer]:
                - /url: /definitions/8a037252-3d90-4323-9fa2-241c54018166
            - cell "1.0" [ref=e91]
            - cell "ACTIVE" [ref=e92]
            - cell "10/13/58361" [ref=e93]
            - cell "Archive" [ref=e94]:
              - button "Archive" [ref=e95] [cursor=pointer]
          - row "EE09-TC02 1.0 ACTIVE 10/13/58361 Archive" [ref=e96]:
            - cell "EE09-TC02" [ref=e97]:
              - link "EE09-TC02" [ref=e98] [cursor=pointer]:
                - /url: /definitions/e1577da8-d4df-40ba-b61e-707864d36dab
            - cell "1.0" [ref=e99]
            - cell "ACTIVE" [ref=e100]
            - cell "10/13/58361" [ref=e101]
            - cell "Archive" [ref=e102]:
              - button "Archive" [ref=e103] [cursor=pointer]
          - row "EE09-TC04 1.0 ACTIVE 10/13/58361 Archive" [ref=e104]:
            - cell "EE09-TC04" [ref=e105]:
              - link "EE09-TC04" [ref=e106] [cursor=pointer]:
                - /url: /definitions/dceb70df-087f-40ec-9fd7-e07365446f2a
            - cell "1.0" [ref=e107]
            - cell "ACTIVE" [ref=e108]
            - cell "10/13/58361" [ref=e109]
            - cell "Archive" [ref=e110]:
              - button "Archive" [ref=e111] [cursor=pointer]
          - row "EE09-TC05 1.0 ACTIVE 10/13/58361 Archive" [ref=e112]:
            - cell "EE09-TC05" [ref=e113]:
              - link "EE09-TC05" [ref=e114] [cursor=pointer]:
                - /url: /definitions/433d3b8f-addf-4690-ac03-be1dd2c5fa06
            - cell "1.0" [ref=e115]
            - cell "ACTIVE" [ref=e116]
            - cell "10/13/58361" [ref=e117]
            - cell "Archive" [ref=e118]:
              - button "Archive" [ref=e119] [cursor=pointer]
          - row "EE10-TC01 1.0 ACTIVE 10/13/58361 Archive" [ref=e120]:
            - cell "EE10-TC01" [ref=e121]:
              - link "EE10-TC01" [ref=e122] [cursor=pointer]:
                - /url: /definitions/109ecb9c-41b0-4656-9166-f85f3c5212c1
            - cell "1.0" [ref=e123]
            - cell "ACTIVE" [ref=e124]
            - cell "10/13/58361" [ref=e125]
            - cell "Archive" [ref=e126]:
              - button "Archive" [ref=e127] [cursor=pointer]
          - row "EE10-TC02 1.0 ACTIVE 10/13/58361 Archive" [ref=e128]:
            - cell "EE10-TC02" [ref=e129]:
              - link "EE10-TC02" [ref=e130] [cursor=pointer]:
                - /url: /definitions/f46fadcf-ccfa-4cff-878e-03ff8f25b542
            - cell "1.0" [ref=e131]
            - cell "ACTIVE" [ref=e132]
            - cell "10/13/58361" [ref=e133]
            - cell "Archive" [ref=e134]:
              - button "Archive" [ref=e135] [cursor=pointer]
          - row "EE10-TC03 1.0 ACTIVE 10/13/58361 Archive" [ref=e136]:
            - cell "EE10-TC03" [ref=e137]:
              - link "EE10-TC03" [ref=e138] [cursor=pointer]:
                - /url: /definitions/169c5560-3fa9-4923-b6d1-3e8966fab965
            - cell "1.0" [ref=e139]
            - cell "ACTIVE" [ref=e140]
            - cell "10/13/58361" [ref=e141]
            - cell "Archive" [ref=e142]:
              - button "Archive" [ref=e143] [cursor=pointer]
          - row "EE10-TC04 1.0 ACTIVE 10/13/58361 Archive" [ref=e144]:
            - cell "EE10-TC04" [ref=e145]:
              - link "EE10-TC04" [ref=e146] [cursor=pointer]:
                - /url: /definitions/3d1e27a6-cf81-4bdb-91f6-9ad852d7951c
            - cell "1.0" [ref=e147]
            - cell "ACTIVE" [ref=e148]
            - cell "10/13/58361" [ref=e149]
            - cell "Archive" [ref=e150]:
              - button "Archive" [ref=e151] [cursor=pointer]
          - row "EE10-TC05 1.0 ACTIVE 10/13/58361 Archive" [ref=e152]:
            - cell "EE10-TC05" [ref=e153]:
              - link "EE10-TC05" [ref=e154] [cursor=pointer]:
                - /url: /definitions/cf995e62-442f-40f4-b927-1a6b39df2087
            - cell "1.0" [ref=e155]
            - cell "ACTIVE" [ref=e156]
            - cell "10/13/58361" [ref=e157]
            - cell "Archive" [ref=e158]:
              - button "Archive" [ref=e159] [cursor=pointer]
          - row "EE10-TC06 1.0 ACTIVE 10/13/58361 Archive" [ref=e160]:
            - cell "EE10-TC06" [ref=e161]:
              - link "EE10-TC06" [ref=e162] [cursor=pointer]:
                - /url: /definitions/64f89320-c147-4294-bf45-2a0ee9161856
            - cell "1.0" [ref=e163]
            - cell "ACTIVE" [ref=e164]
            - cell "10/13/58361" [ref=e165]
            - cell "Archive" [ref=e166]:
              - button "Archive" [ref=e167] [cursor=pointer]
          - row "SCH01-TC03 1.0 ACTIVE 10/15/58361 Archive" [ref=e168]:
            - cell "SCH01-TC03" [ref=e169]:
              - link "SCH01-TC03" [ref=e170] [cursor=pointer]:
                - /url: /definitions/7caf94fd-7f6a-45f2-8d11-3b5006634e53
            - cell "1.0" [ref=e171]
            - cell "ACTIVE" [ref=e172]
            - cell "10/15/58361" [ref=e173]
            - cell "Archive" [ref=e174]:
              - button "Archive" [ref=e175] [cursor=pointer]
          - row "TestDef 1.0.0 DRAFT 6/14/58375 Activate" [ref=e176]:
            - cell "TestDef" [ref=e177]:
              - link "TestDef" [ref=e178] [cursor=pointer]:
                - /url: /definitions/2aa08d88-a3b1-41b3-9cad-9c484a700ada
            - cell "1.0.0" [ref=e179]
            - cell "DRAFT" [ref=e180]
            - cell "6/14/58375" [ref=e181]
            - cell "Activate" [ref=e182]:
              - button "Activate" [ref=e183] [cursor=pointer]
          - row "Alpha Flow pd-ui-e2e-search-1779987567890 1.0.0 DRAFT 7/25/58375 Activate" [ref=e184]:
            - cell "Alpha Flow pd-ui-e2e-search-1779987567890" [ref=e185]:
              - link "Alpha Flow pd-ui-e2e-search-1779987567890" [ref=e186] [cursor=pointer]:
                - /url: /definitions/9535d749-9031-4666-8377-b87eae54ca46
            - cell "1.0.0" [ref=e187]
            - cell "DRAFT" [ref=e188]
            - cell "7/25/58375" [ref=e189]
            - cell "Activate" [ref=e190]:
              - button "Activate" [ref=e191] [cursor=pointer]
          - row "Beta Flow pd-ui-e2e-search-1779987567890 1.0.0 DRAFT 7/25/58375 Activate" [ref=e192]:
            - cell "Beta Flow pd-ui-e2e-search-1779987567890" [ref=e193]:
              - link "Beta Flow pd-ui-e2e-search-1779987567890" [ref=e194] [cursor=pointer]:
                - /url: /definitions/b56e8f7b-53e6-4702-8a7c-b59899e0f828
            - cell "1.0.0" [ref=e195]
            - cell "DRAFT" [ref=e196]
            - cell "7/25/58375" [ref=e197]
            - cell "Activate" [ref=e198]:
              - button "Activate" [ref=e199] [cursor=pointer]
      - generic [ref=e201]:
        - heading "Create New Definition" [level=3] [ref=e202]
        - paragraph [ref=e203]: Failed to create definition
        - generic [ref=e204]:
          - generic [ref=e205]: Name *
          - textbox "My Process" [ref=e206]: E2E Created pd-ui-e2e-create-1779988281383
        - generic [ref=e207]:
          - generic [ref=e208]: Version *
          - textbox "1.0.0" [ref=e209]
        - generic [ref=e210]:
          - generic [ref=e211]: Description
          - textbox "Optional description" [ref=e212]: Created by E2E test
        - generic [ref=e213]:
          - button "Cancel" [ref=e214] [cursor=pointer]
          - button "Create" [ref=e215] [cursor=pointer]
```

# Test source

```ts
  372 | 
  373 |       await loginWithToken(page, authToken)
  374 |       await navigateToDefinitions(page)
  375 | 
  376 |       // Expand first
  377 |       await page.getByTestId(`def-name-${def.id}`).click()
  378 |       await page.waitForTimeout(1000)
  379 |       await expect(page.getByTestId('version-history-row')).toBeVisible()
  380 | 
  381 |       // Click again to collapse
  382 |       await page.getByTestId(`def-name-${def.id}`).click()
  383 |       await page.waitForTimeout(500)
  384 | 
  385 |       // Version history row should be gone
  386 |       await expect(page.getByTestId('version-history-row')).not.toBeVisible()
  387 | 
  388 |       await shot(page, 'TC03-04-collapsed')
  389 |       // VERDICT: Screen no longer shows version history after clicking name again
  390 |     })
  391 |   })
  392 | 
  393 |   // ═══════════════════════════════════════════════════════════════════════════════
  394 |   // PD-UI-04 — Create definition
  395 |   // ═══════════════════════════════════════════════════════════════════════════════
  396 | 
  397 |   test.describe('PD-UI-04 — Create definition', () => {
  398 |     test('TC-PDUI04-01: "New Definition" button opens create dialog', async ({ page }) => {
  399 |       await loginWithToken(page, authToken)
  400 |       await navigateToDefinitions(page)
  401 | 
  402 |       // Click the "New Definition" button
  403 |       const newDefButton = page.getByTestId('btn-new-definition')
  404 |       await expect(newDefButton).toBeVisible()
  405 |       await newDefButton.click()
  406 | 
  407 |       // Screen shows create definition dialog
  408 |       const dialog = page.getByTestId('create-definition-dialog')
  409 |       await expect(dialog).toBeVisible({ timeout: 5_000 })
  410 | 
  411 |       // Dialog title is "Create New Definition"
  412 |       await expect(dialog).toContainText('Create New Definition')
  413 | 
  414 |       // Form fields present
  415 |       await expect(page.getByTestId('create-name-input')).toBeVisible()
  416 |       await expect(page.getByTestId('create-version-input')).toBeVisible()
  417 |       await expect(page.getByTestId('create-description-input')).toBeVisible()
  418 | 
  419 |       // Buttons present
  420 |       await expect(page.getByTestId('create-submit')).toBeVisible()
  421 |       await expect(page.getByTestId('create-cancel')).toBeVisible()
  422 | 
  423 |       await shot(page, 'TC04-01-create-dialog-open')
  424 |       // VERDICT: Screen shows "Create New Definition" dialog with name, version, and description fields
  425 |     })
  426 | 
  427 |     test('TC-PDUI04-02: dialog validates required name field', async ({ page }) => {
  428 |       await loginWithToken(page, authToken)
  429 |       await navigateToDefinitions(page)
  430 | 
  431 |       // Open dialog
  432 |       await page.getByTestId('btn-new-definition').click()
  433 |       await expect(page.getByTestId('create-definition-dialog')).toBeVisible({ timeout: 5_000 })
  434 | 
  435 |       // Clear the name field (default might be empty) and submit
  436 |       const nameInput = page.getByTestId('create-name-input')
  437 |       await nameInput.fill('')
  438 | 
  439 |       // Submit
  440 |       await page.getByTestId('create-submit').click()
  441 |       await page.waitForTimeout(500)
  442 | 
  443 |       // Screen shows validation error
  444 |       await expect(page.getByText('Name is required')).toBeVisible()
  445 | 
  446 |       await shot(page, 'TC04-02-validation-error')
  447 |       // VERDICT: Screen shows "Name is required" validation error when name is empty
  448 |     })
  449 | 
  450 |     test('TC-PDUI04-03: creating a definition succeeds', async ({ page }) => {
  451 |       const uniqueSuffix = testId('create')
  452 | 
  453 |       await loginWithToken(page, authToken)
  454 |       await navigateToDefinitions(page)
  455 | 
  456 |       // Open dialog
  457 |       await page.getByTestId('btn-new-definition').click()
  458 |       await expect(page.getByTestId('create-definition-dialog')).toBeVisible({ timeout: 5_000 })
  459 | 
  460 |       // Fill form
  461 |       const defName = `E2E Created ${uniqueSuffix}`
  462 |       await page.getByTestId('create-name-input').fill(defName)
  463 |       await page.getByTestId('create-version-input').fill('1.0.0')
  464 |       await page.getByTestId('create-description-input').fill('Created by E2E test')
  465 | 
  466 |       await shot(page, 'TC04-03-form-filled')
  467 | 
  468 |       // Submit — this should navigate away to /definitions/:id
  469 |       await page.getByTestId('create-submit').click()
  470 | 
  471 |       // Wait for navigation to the new definition's editor page
> 472 |       await page.waitForURL(/\/definitions\/(?!new$)([0-9a-f-]+)/, { timeout: 15_000 })
      |                  ^ TimeoutError: page.waitForURL: Timeout 15000ms exceeded.
  473 | 
  474 |       await shot(page, 'TC04-03-after-creation')
  475 |       // VERDICT: Screen navigated to /definitions/{id} after successful creation
  476 |     })
  477 | 
  478 |     test('TC-PDUI04-05: Cancel button dismisses the dialog', async ({ page }) => {
  479 |       await loginWithToken(page, authToken)
  480 |       await navigateToDefinitions(page)
  481 | 
  482 |       // Open dialog
  483 |       await page.getByTestId('btn-new-definition').click()
  484 |       await expect(page.getByTestId('create-definition-dialog')).toBeVisible({ timeout: 5_000 })
  485 | 
  486 |       // Click Cancel
  487 |       await page.getByTestId('create-cancel').click()
  488 |       await page.waitForTimeout(500)
  489 | 
  490 |       // Dialog is closed
  491 |       await expect(page.getByTestId('create-definition-dialog')).not.toBeVisible()
  492 | 
  493 |       // User is still on /definitions
  494 |       await expect(page).toHaveURL(/\/definitions/)
  495 | 
  496 |       await shot(page, 'TC04-05-after-cancel')
  497 |       // VERDICT: Screen shows /definitions page without the dialog after clicking Cancel
  498 |     })
  499 |   })
  500 | })
  501 | 
```