# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: f2-definition-list.e2e.spec.ts >> F2 — Definition List View (PD-UI-01 through PD-UI-04) >> PD-UI-03 — Version history >> TC-PDUI03-04: clicking the same name again collapses the version history
- Location: tests\e2e\f2-definition-list.e2e.spec.ts:368:5

# Error details

```
Error: apiRequestContext.post: connect ECONNREFUSED 127.0.0.1:4173
Call log:
  - → POST http://127.0.0.1:4173/api/v1/definitions
    - user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.7778.96 Safari/537.36
    - accept: */*
    - accept-encoding: gzip,deflate,br
    - Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCIgOiAiSldUIiwia2lkIiA6ICJ6Mi0yT3IwVEUxQjJDZ0xiNGt1LTBlaUR1SGgzRW1KcGxHNlJGVVlJY19BIn0.eyJleHAiOjE3Nzk5ODc4OTcsImlhdCI6MTc3OTk4NzU5NywianRpIjoib25ydHJvOjMzMzkwMDYwLTFkYWUtNDk2Zi05ZGE0LTdhYjU1YjE3ZGFjOSIsImlzcyI6Imh0dHA6Ly9sb2NhbGhvc3Q6ODA4MS9yZWFsbXMvYnBtLWRlZmF1bHQiLCJzdWIiOiI0NjQwZGI3ZS04MTg1LTQ0NmItYTM4Yy0wMGU1MWZiZjA1YjUiLCJ0eXAiOiJCZWFyZXIiLCJhenAiOiJicG0tcGxhdGZvcm0tYXBpIiwic2lkIjoiMmI2ZDUyMGQtMjE4Ni00NWMxLWIyNTItZWFhMGE4NjA1MDFmIiwiYWNyIjoiMSIsImFsbG93ZWQtb3JpZ2lucyI6WyIqIl0sInJlYWxtX2FjY2VzcyI6eyJyb2xlcyI6WyJQTEFURk9STV9BRE1JTiJdfSwic2NvcGUiOiJwcm9maWxlIGVtYWlsIiwiZW1haWxfdmVyaWZpZWQiOnRydWUsInJvbGVzIjpbIlBMQVRGT1JNX0FETUlOIl0sIm5hbWUiOiJBZG1pbiBVc2VyIiwicHJlZmVycmVkX3VzZXJuYW1lIjoiYWRtaW4tdXNlciIsImdpdmVuX25hbWUiOiJBZG1pbiIsImZhbWlseV9uYW1lIjoiVXNlciIsImVtYWlsIjoiYWRtaW5AYnBtLmxvY2FsIn0.TBay-bMBrAF9Z4y7W5LBI2OyswQ4p3t2NE7PlW7oNy7o1JRJjbfDC8D3529lwKiQtV-ImQJ9LKY6f3TykZmRN3oTi1ibkJkTEmVE0qUug0KDfp2iVNdVCQWBh5ZMFsSAlC_PMcRPn2oOzp9UpAp_Sw8O2YZRW737PDwojxdeK7ZMlQXoQLOhHb_sJ-fTjxIJg75jIesCueXtPBUXiw4Glm3kj92NtFQS57NpRd2evXSUn3O92pnESlkPaggNrjd4UWuwK8mybEtKnNUh69c7P9HeTHOHAq-IXsSdvZu1o3ybclFrpp2e4a4xOt-y34eD9ITazy80Gs5XnsgcT_rbNg
    - Content-Type: application/json
    - content-length: 343

```

# Test source

```ts
  8   |  *   - No page.route() stubs for any API endpoint.
  9   |  *   - All HTTP calls go to the real backend:
  10  |  *     1. Keycloak token endpoint (password grant) for authentication
  11  |  *     2. Backend /definitions API for test data setup/teardown
  12  |  *     3. Browser API calls (via the app's client.ts) with real JWT token
  13  |  *
  14  |  * Directive T-3 compliance:
  15  |  *   - After every significant UI action a screenshot is taken and the visible
  16  |  *     DOM is asserted. Every verdict is stated as "screen shows X after Y".
  17  |  *
  18  |  * Infrastructure:
  19  |  *   - Frontend: http://127.0.0.1:4173 (Vite dev server, started by playwright.config.ts)
  20  |  *   - Backend API: available at same origin via Vite proxy (/api → localhost:8080)
  21  |  *   - Keycloak: http://localhost:8081/realms/bpm-default
  22  |  *   - Test user: admin-user / admin-pass (PLATFORM_ADMIN role, has PROCESS_DESIGNER access)
  23  |  *   - Bootstrap token env var: TEST_BOOTSTRAP_TOKEN (fallback if Keycloak unavailable)
  24  |  */
  25  | 
  26  | import { test, expect } from '@playwright/test'
  27  | import * as fs from 'fs'
  28  | import * as path from 'path'
  29  | 
  30  | const SCREENSHOTS_DIR = 'tests/screenshots'
  31  | const KEYCLOAK_TOKEN_URL = 'http://localhost:8081/realms/bpm-default/protocol/openid-connect/token'
  32  | const KEYCLOAK_CLIENT_ID = 'bpm-platform-api'
  33  | const KEYCLOAK_USERNAME = 'admin-user'
  34  | const KEYCLOAK_PASSWORD = 'admin-pass'
  35  | const API_PREFIX = '/api/v1'
  36  | 
  37  | // ── Screenshot helper ─────────────────────────────────────────────────────────
  38  | 
  39  | async function shot(page: import('@playwright/test').Page, name: string): Promise<void> {
  40  |   const dir = path.resolve(SCREENSHOTS_DIR)
  41  |   if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  42  |   await page.screenshot({ path: path.join(dir, `PDUI-${name}.png`) })
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
> 108 |   const response = await request.post(`${API_PREFIX}/definitions`, {
      |                                  ^ Error: apiRequestContext.post: connect ECONNREFUSED 127.0.0.1:4173
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
  143 |   const response = await request.delete(`${API_PREFIX}/definitions/${id}`, {
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
```