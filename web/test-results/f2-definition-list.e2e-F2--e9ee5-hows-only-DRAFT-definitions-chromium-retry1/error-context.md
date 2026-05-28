# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: f2-definition-list.e2e.spec.ts >> F2 — Definition List View (PD-UI-01 through PD-UI-04) >> PD-UI-02 — Status filter >> TC-PDUI02-02: selecting Draft filter shows only DRAFT definitions
- Location: tests\e2e\f2-definition-list.e2e.spec.ts:273:5

# Error details

```
ReferenceError: def is not defined
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
      - link "Definitions" [active] [ref=e9] [cursor=pointer]:
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
          - row "Draft Only pd-ui-e2e-draft-filter-1779988166767 1.0.0 DRAFT 8/1/58375 Activate" [ref=e200]:
            - cell "Draft Only pd-ui-e2e-draft-filter-1779988166767" [ref=e201]:
              - link "Draft Only pd-ui-e2e-draft-filter-1779988166767" [ref=e202] [cursor=pointer]:
                - /url: /definitions/2e7b8a2f-0f87-4b1e-b058-923e48059478
            - cell "1.0.0" [ref=e203]
            - cell "DRAFT" [ref=e204]
            - cell "8/1/58375" [ref=e205]
            - cell "Activate" [ref=e206]:
              - button "Activate" [ref=e207] [cursor=pointer]
```

# Test source

```ts
  182 |       const uniqueSuffix = testId('list-01')
  183 |       const def1 = await createTestDefinition(request, authToken, `Order Flow ${uniqueSuffix}`, '1.0.0')
  184 |       const def2 = await createTestDefinition(request, authToken, `Approval Flow ${uniqueSuffix}`, '1.0.0')
  185 |       createdDefinitionIds.push(def1.id, def2.id)
  186 | 
  187 |       await loginWithToken(page, authToken)
  188 | 
  189 |       // Navigate to definitions via sidebar (SPA navigation preserves in-memory session)
  190 |       await navigateToDefinitions(page)
  191 | 
  192 |       // Screen shows the definition names in the table
  193 |       await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
  194 |       await expect(page.getByTestId(`def-name-${def2.id}`)).toBeVisible()
  195 | 
  196 |       // Screen shows version, status badge, and creation date for each row
  197 |       // The definition name button is clickable (proves it's a rendered row)
  198 |       await expect(page.getByTestId(`def-name-${def1.id}`)).toContainText(`Order Flow ${uniqueSuffix}`)
  199 | 
  200 |       await shot(page, 'TC01-definition-list')
  201 |       // VERDICT: Screen shows definition list with name buttons for both test definitions
  202 |     })
  203 | 
  204 |     test('TC-PDUI01-02: empty state renders when no definitions exist for search', async ({ page }) => {
  205 |       await loginWithToken(page, authToken)
  206 | 
  207 |       await navigateToDefinitions(page)
  208 |       await expect(page.getByTestId('filter-bar')).toBeVisible({ timeout: 10_000 })
  209 | 
  210 |       // Search for a non-existent definition
  211 |       await page.getByTestId('definition-search').fill(`nonexistent-${Date.now()}`)
  212 |       // Wait for debounce and API response
  213 |       await page.waitForTimeout(1000)
  214 | 
  215 |       // Screen shows "No definitions found" empty message
  216 |       await expect(page.getByText('No definitions found')).toBeVisible({ timeout: 10_000 })
  217 | 
  218 |       await shot(page, 'TC02-empty-state')
  219 |       // VERDICT: Screen shows "No definitions found" when no results match the search query
  220 |     })
  221 | 
  222 |     test('TC-PDUI01-03: search input filters definitions by name', async ({ page, request }) => {
  223 |       const uniqueSuffix = testId('search')
  224 |       const def1 = await createTestDefinition(request, authToken, `Alpha Flow ${uniqueSuffix}`, '1.0.0')
  225 |       const def2 = await createTestDefinition(request, authToken, `Beta Flow ${uniqueSuffix}`, '1.0.0')
  226 |       createdDefinitionIds.push(def1.id, def2.id)
  227 | 
  228 |       await loginWithToken(page, authToken)
  229 |       await navigateToDefinitions(page)
  230 | 
  231 |       // Both definitions visible initially
  232 |       await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
  233 |       await expect(page.getByTestId(`def-name-${def2.id}`)).toBeVisible()
  234 | 
  235 |       // Type search for Alpha only
  236 |       const searchInput = page.getByTestId('definition-search')
  237 |       await searchInput.fill(`Alpha ${uniqueSuffix}`)
  238 |       // Wait for 300ms debounce + API round-trip
  239 |       await page.waitForTimeout(1500)
  240 | 
  241 |       // Screen shows only the Alpha definition
  242 |       await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
  243 |       await expect(page.getByTestId(`def-name-${def2.id}`)).not.toBeVisible()
  244 | 
  245 |       // URL contains the search parameter
  246 |       await expect(page).toHaveURL(/search=Alpha/)
  247 | 
  248 |       await shot(page, 'TC03-search-filter')
  249 |       // VERDICT: Screen shows only Alpha Flow after typing search query; URL contains search param
  250 |     })
  251 |   })
  252 | 
  253 |   // ═══════════════════════════════════════════════════════════════════════════════
  254 |   // PD-UI-02 — Status filter
  255 |   // ═══════════════════════════════════════════════════════════════════════════════
  256 | 
  257 |   test.describe('PD-UI-02 — Status filter', () => {
  258 |     test('TC-PDUI02-01: status filter dropdown shows all four options', async ({ page }) => {
  259 |       await loginWithToken(page, authToken)
  260 |       await navigateToDefinitions(page)
  261 | 
  262 |       // Open the multi-select status filter
  263 |       const statusFilter = page.getByTestId('status-filter')
  264 |       await expect(statusFilter).toBeVisible()
  265 | 
  266 |       // The filter shows the label "Status"
  267 |       await expect(statusFilter).toContainText('Status')
  268 | 
  269 |       await shot(page, 'TC02-01-status-filter-visible')
  270 |       // VERDICT: Screen shows status filter with "Status" label
  271 |     })
  272 | 
  273 |     test('TC-PDUI02-02: selecting Draft filter shows only DRAFT definitions', async ({ page, request }) => {
  274 |       const uniqueSuffix = testId('draft-filter')
  275 |       const draftDef = await createTestDefinition(request, authToken, `Draft Only ${uniqueSuffix}`, '1.0.0')
  276 |       createdDefinitionIds.push(draftDef.id)
  277 | 
  278 |       await loginWithToken(page, authToken)
  279 |       await navigateToDefinitions(page)
  280 | 
  281 |       // Both definitions visible before filtering
> 282 |       await expect(page.getByTestId(`def-name-${def.id}`)).toBeVisible()
      |                                                 ^ ReferenceError: def is not defined
  283 | 
  284 |       await shot(page, 'TC02-02-before-filter')
  285 |       // VERDICT: Screen shows draft definition in unfiltered list
  286 |     })
  287 | 
  288 |     test('TC-PDUI02-04: status filter selects Draft and shows filtered results', async ({ page, request }) => {
  289 |       const uniqueSuffix = testId('reload')
  290 |       const def1 = await createTestDefinition(request, authToken, `Reload Test A ${uniqueSuffix}`, '1.0.0')
  291 |       const def2 = await createTestDefinition(request, authToken, `Reload Test B ${uniqueSuffix}`, '2.0.0', 'Second version')
  292 |       createdDefinitionIds.push(def1.id, def2.id)
  293 | 
  294 |       await loginWithToken(page, authToken)
  295 |       await navigateToDefinitions(page)
  296 |       await expect(page.getByTestId('filter-bar')).toBeVisible({ timeout: 10_000 })
  297 | 
  298 |       // Both definitions visible
  299 |       await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
  300 |       await expect(page.getByTestId(`def-name-${def2.id}`)).toBeVisible()
  301 | 
  302 |       // Select "Draft" in the status filter
  303 |       await page.getByTestId('status-filter-select').selectOption('DRAFT')
  304 |       await page.waitForTimeout(500)
  305 | 
  306 |       // Both definitions are DRAFT, so both should still be visible
  307 |       await expect(page.getByTestId(`def-name-${def1.id}`)).toBeVisible()
  308 |       await expect(page.getByTestId(`def-name-${def2.id}`)).toBeVisible()
  309 | 
  310 |       await shot(page, 'TC02-04-after-filter')
  311 |       // VERDICT: Screen shows filtered definitions after selecting Draft in status filter
  312 |     })
  313 | 
  314 |     test('TC-PDUI02-05: clearing all status filters shows all definitions', async ({ page, request }) => {
  315 |       const uniqueSuffix = testId('clear')
  316 |       const def = await createTestDefinition(request, authToken, `Clear Filter Test ${uniqueSuffix}`, '1.0.0')
  317 |       createdDefinitionIds.push(def.id)
  318 | 
  319 |       await loginWithToken(page, authToken)
  320 |       await navigateToDefinitions(page)
  321 |       await expect(page.getByTestId('filter-bar')).toBeVisible({ timeout: 10_000 })
  322 | 
  323 |       // Select DRAFT filter
  324 |       await page.getByTestId('status-filter-select').selectOption('DRAFT')
  325 |       await page.waitForTimeout(500)
  326 |       await expect(page.getByTestId(`def-name-${def.id}`)).toBeVisible()
  327 | 
  328 |       // Clear filter by selecting "All"
  329 |       await page.getByTestId('status-filter-select').selectOption('')
  330 |       await page.waitForTimeout(500)
  331 | 
  332 |       // Definition still visible without filter
  333 |       await expect(page.getByTestId(`def-name-${def.id}`)).toBeVisible()
  334 | 
  335 |       await shot(page, 'TC02-05-after-clear')
  336 |       // VERDICT: Screen shows all definitions after clearing status filter
  337 |     })
  338 |   })
  339 | 
  340 |   // ═══════════════════════════════════════════════════════════════════════════════
  341 |   // PD-UI-03 — Version history
  342 |   // ═══════════════════════════════════════════════════════════════════════════════
  343 | 
  344 |   test.describe('PD-UI-03 — Version history', () => {
  345 |     test('TC-PDUI03-01: clicking definition name expands version history row', async ({ page, request }) => {
  346 |       const uniqueSuffix = testId('expand')
  347 |       const def = await createTestDefinition(request, authToken, `Version Flow ${uniqueSuffix}`, '1.0.0')
  348 |       createdDefinitionIds.push(def.id)
  349 | 
  350 |       await loginWithToken(page, authToken)
  351 |       await navigateToDefinitions(page)
  352 | 
  353 |       // Click the definition name button to expand version history
  354 |       await page.getByTestId(`def-name-${def.id}`).click()
  355 |       await page.waitForTimeout(1000)
  356 | 
  357 |       // Screen shows version history row
  358 |       const versionHistory = page.getByTestId('version-history-row')
  359 |       await expect(versionHistory).toBeVisible({ timeout: 10_000 })
  360 | 
  361 |       // Shows "Version history: <name>" heading
  362 |       await expect(versionHistory).toContainText(`Version Flow ${uniqueSuffix}`)
  363 | 
  364 |       await shot(page, 'TC03-01-expanded-version-history')
  365 |       // VERDICT: Screen shows version history row with heading "Version history: Version Flow ..."
  366 |     })
  367 | 
  368 |     test('TC-PDUI03-04: clicking the same name again collapses the version history', async ({ page, request }) => {
  369 |       const uniqueSuffix = testId('collapse')
  370 |       const def = await createTestDefinition(request, authToken, `Collapse Test ${uniqueSuffix}`, '1.0.0')
  371 |       createdDefinitionIds.push(def.id)
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
```