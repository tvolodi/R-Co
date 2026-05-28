# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: f2-definition-list.e2e.spec.ts >> F2 — Definition List View (PD-UI-01 through PD-UI-04) >> PD-UI-01 — Definition list >> TC-PDUI01-03: search input filters definitions by name
- Location: tests\e2e\f2-definition-list.e2e.spec.ts:222:5

# Error details

```
Error: expect(locator).toBeVisible() failed

Locator: getByTestId('def-name-9535d749-9031-4666-8377-b87eae54ca46')
Expected: visible
Timeout: 5000ms
Error: element(s) not found

Call log:
  - Expect "toBeVisible" with timeout 5000ms
  - waiting for getByTestId('def-name-9535d749-9031-4666-8377-b87eae54ca46')

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
  - heading "Process Definitions" [level=2]
  - textbox "Search definitions..."
  - text: Status
  - combobox:
    - option "All" [selected]
    - option "Draft"
    - option "Active"
    - option "Deprecated"
    - option "Archived"
  - button "+ New Definition"
  - table:
    - rowgroup:
      - row "Name Version Status Updated Actions":
        - columnheader "Name"
        - columnheader "Version"
        - columnheader "Status"
        - columnheader "Updated"
        - columnheader "Actions"
    - rowgroup
```

```
Error: apiRequestContext.delete: connect ECONNREFUSED 127.0.0.1:4173
Call log:
  - → DELETE http://127.0.0.1:4173/api/v1/definitions/9535d749-9031-4666-8377-b87eae54ca46
    - user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.7778.96 Safari/537.36
    - accept: */*
    - accept-encoding: gzip,deflate,br
    - Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCIgOiAiSldUIiwia2lkIiA6ICJ6Mi0yT3IwVEUxQjJDZ0xiNGt1LTBlaUR1SGgzRW1KcGxHNlJGVVlJY19BIn0.eyJleHAiOjE3Nzk5ODc4NjYsImlhdCI6MTc3OTk4NzU2NiwianRpIjoib25ydHJvOjdmNTdlZWFkLWJhMDEtNGNkOC1iY2U2LWY4ODQxMzhkOGUzMCIsImlzcyI6Imh0dHA6Ly9sb2NhbGhvc3Q6ODA4MS9yZWFsbXMvYnBtLWRlZmF1bHQiLCJzdWIiOiI0NjQwZGI3ZS04MTg1LTQ0NmItYTM4Yy0wMGU1MWZiZjA1YjUiLCJ0eXAiOiJCZWFyZXIiLCJhenAiOiJicG0tcGxhdGZvcm0tYXBpIiwic2lkIjoiMDRlZTY1MDYtOWMwYi00MjlkLWIyNTMtYTJhYTA4ZWI3NjE1IiwiYWNyIjoiMSIsImFsbG93ZWQtb3JpZ2lucyI6WyIqIl0sInJlYWxtX2FjY2VzcyI6eyJyb2xlcyI6WyJQTEFURk9STV9BRE1JTiJdfSwic2NvcGUiOiJwcm9maWxlIGVtYWlsIiwiZW1haWxfdmVyaWZpZWQiOnRydWUsInJvbGVzIjpbIlBMQVRGT1JNX0FETUlOIl0sIm5hbWUiOiJBZG1pbiBVc2VyIiwicHJlZmVycmVkX3VzZXJuYW1lIjoiYWRtaW4tdXNlciIsImdpdmVuX25hbWUiOiJBZG1pbiIsImZhbWlseV9uYW1lIjoiVXNlciIsImVtYWlsIjoiYWRtaW5AYnBtLmxvY2FsIn0.VKDByzORoe-0l_BAX6HBiv6SknBnXwp_6cdw68gilMR2F3x7W5--UHcwGrBdqM5psRw3RjsG_YszmQJ1M-MtduuW3htuwlV6sYZmnybYscagnRHK6a4OYS1UVNleVnXSUaNAeuzZTFL-hztNcaYms5bp5xV_Iv7TtkJTFCcD0TildfvG43tbn1uDyeiyqnBEs-iyb9EbdKdZtY0X9-tNPRMCaCoTVgTC5LzBvXqIuLKpPNEiR3Xdqza59gsEECXeOZibIJDJ5MN1JfilzcOahWHtUy9Bb7Bt6ebc5Fge6LjbT4SpHX3iu_HxVOqPnNzlcy5vA72YWjorEUYG26Sasw

```

# Test source

```ts
  43  | }
  44  | 
  45  | // ── Token management ──────────────────────────────────────────────────────────
  46  | 
  47  | /**
  48  |  * Obtains a real JWT from Keycloak via the password grant (direct access) flow.
  49  |  * The returned token is a real signed JWT that the backend accepts.
  50  |  */
  51  | async function getKeycloakToken(request: import('@playwright/test').APIRequestContext): Promise<string> {
  52  |   const response = await request.post(KEYCLOAK_TOKEN_URL, {
  53  |     headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  54  |     form: {
  55  |       client_id: KEYCLOAK_CLIENT_ID,
  56  |       username: KEYCLOAK_USERNAME,
  57  |       password: KEYCLOAK_PASSWORD,
  58  |       grant_type: 'password',
  59  |     },
  60  |   })
  61  | 
  62  |   if (!response.ok()) {
  63  |     const body = await response.text()
  64  |     throw new Error(
  65  |       `Keycloak token request failed (${response.status()}): ${body}\n` +
  66  |       `Ensure Keycloak is running at ${KEYCLOAK_TOKEN_URL.replace('/protocol/openid-connect/token', '')}\n` +
  67  |       `and user ${KEYCLOAK_USERNAME} exists with password ${KEYCLOAK_PASSWORD}.`,
  68  |     )
  69  |   }
  70  | 
  71  |   const body = await response.json() as { access_token: string }
  72  |   return body.access_token
  73  | }
  74  | 
  75  | // ── Login via UI with a real token ────────────────────────────────────────────
  76  | 
  77  | /**
  78  |  * Logs into the application by pasting a real JWT into the token input field
  79  |  * and submitting the login form. This exercises the real login code path:
  80  |  * GET /health/ready → decode JWT → set session → navigate to workspace.
  81  |  */
  82  | async function loginWithToken(page: import('@playwright/test').Page, token: string): Promise<void> {
  83  |   await page.goto('/login')
  84  |   await expect(page.getByTestId('login-token-input')).toBeVisible()
  85  |   await page.getByTestId('login-token-input').fill(token)
  86  |   await page.getByTestId('login-submit').click()
  87  |   // Wait for navigation away from /login to the workspace
  88  |   await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 15_000 })
  89  |   // Verify workspace is rendered
  90  |   await expect(page.getByTestId('user-display-name')).toBeVisible({ timeout: 10_000 })
  91  | }
  92  | 
  93  | /** Navigate to /definitions via the sidebar link (SPA navigation — preserves in-memory session). */
  94  | async function navigateToDefinitions(page: import('@playwright/test').Page): Promise<void> {
  95  |   await page.getByRole('link', { name: 'Definitions' }).click()
  96  |   await page.waitForURL(/\/definitions/, { timeout: 10_000 })
  97  | }
  98  | 
  99  | // ── API helpers (using Playwright request context with real token) ────────────
  100 | 
  101 | async function createTestDefinition(
  102 |   request: import('@playwright/test').APIRequestContext,
  103 |   token: string,
  104 |   name: string,
  105 |   version: string,
  106 |   description?: string,
  107 | ): Promise<{ id: string; name: string; version: string; status: string }> {
  108 |   const response = await request.post(`${API_PREFIX}/definitions`, {
  109 |     headers: {
  110 |       'Authorization': `Bearer ${token}`,
  111 |       'Content-Type': 'application/json',
  112 |     },
  113 |     data: {
  114 |       name,
  115 |       version,
  116 |       description: description ?? '',
  117 |       graph: {
  118 |         nodes: [
  119 |           { id: 'start', node_type: 'START', label: null, attributes: null },
  120 |           { id: 'end', node_type: 'END', label: null, attributes: null },
  121 |         ],
  122 |         edges: [
  123 |           { id: 'e1', source: 'start', target: 'end', condition: null, is_default: false },
  124 |         ],
  125 |       },
  126 |       stage: null,
  127 |     },
  128 |   })
  129 | 
  130 |   if (!response.ok()) {
  131 |     const body = await response.text()
  132 |     throw new Error(`POST /definitions failed (${response.status()}): ${body}`)
  133 |   }
  134 | 
  135 |   return response.json() as Promise<{ id: string; name: string; version: string; status: string }>
  136 | }
  137 | 
  138 | async function deleteTestDefinition(
  139 |   request: import('@playwright/test').APIRequestContext,
  140 |   token: string,
  141 |   id: string,
  142 | ): Promise<void> {
> 143 |   const response = await request.delete(`${API_PREFIX}/definitions/${id}`, {
      |                                        ^ Error: apiRequestContext.delete: connect ECONNREFUSED 127.0.0.1:4173
  144 |     headers: { 'Authorization': `Bearer ${token}` },
  145 |   })
  146 |   // 204 or 404 are both acceptable (already deleted or not found)
  147 |   if (response.status() !== 204 && response.status() !== 404) {
  148 |     console.warn(`DELETE /definitions/${id} returned ${response.status()}`)
  149 |   }
  150 | }
  151 | 
  152 | // ── Test suite ────────────────────────────────────────────────────────────────
  153 | 
  154 | test.describe('F2 — Definition List View (PD-UI-01 through PD-UI-04)', () => {
  155 |   let authToken: string
  156 |   const createdDefinitionIds: string[] = []
  157 | 
  158 |   /** UUID v4-like id for tracking test-created definitions */
  159 |   function testId(label: string): string {
  160 |     return `pd-ui-e2e-${label}-${Date.now()}`
  161 |   }
  162 | 
  163 |   test.beforeAll(async ({ request }) => {
  164 |     // Obtain a real JWT from Keycloak
  165 |     authToken = await getKeycloakToken(request)
  166 |   })
  167 | 
  168 |   test.afterEach(async ({ request }) => {
  169 |     // Clean up all definitions created during tests
  170 |     for (const id of createdDefinitionIds) {
  171 |       await deleteTestDefinition(request, authToken, id)
  172 |     }
  173 |     createdDefinitionIds.length = 0
  174 |   })
  175 | 
  176 |   // ═══════════════════════════════════════════════════════════════════════════════
  177 |   // PD-UI-01 — Definition list
  178 |   // ═══════════════════════════════════════════════════════════════════════════════
  179 | 
  180 |   test.describe('PD-UI-01 — Definition list', () => {
  181 |     test('TC-PDUI01-01: definition list shows definitions from the backend', async ({ page, request }) => {
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
```