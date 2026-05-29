# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: f2-canvas.e2e.spec.ts >> F2 — Process Designer Canvas (PD-UI-09 through PD-UI-12) >> PD-UI-12 — Node properties panel >> TC-PDUI12-04: Property panel shows correct fields per node type
- Location: tests\e2e\f2-canvas.e2e.spec.ts:776:5

# Error details

```
Error: POST /definitions failed (422): {"status":422,"errors":[{"code":"ISOLATED_NODE","message":"Node 'start' is isolated (insufficient incoming or outgoing edges for its type)"},{"code":"ISOLATED_NODE","message":"Node 'human-pd-ui-canvas-e2e-fields-04-1780019111516' is isolated (insufficient incoming or outgoing edges for its type)"},{"code":"ISOLATED_NODE","message":"Node 'service-pd-ui-canvas-e2e-fields-04-1780019111516' is isolated (insufficient incoming or outgoing edges for its type)"},{"code":"ISOLATED_NODE","message":"Node 'timer-pd-ui-canvas-e2e-fields-04-1780019111516' is isolated (insufficient incoming or outgoing edges for its type)"},{"code":"ISOLATED_NODE","message":"Node 'gw-pd-ui-canvas-e2e-fields-04-1780019111516' is isolated (insufficient incoming or outgoing edges for its type)"},{"code":"ISOLATED_NODE","message":"Node 'end' is isolated (insufficient incoming or outgoing edges for its type)"}]}
```

# Test source

```ts
  16  |  *     DOM is asserted. Every verdict is stated as "screen shows X after Y".
  17  |  *
  18  |  * Infrastructure:
  19  |  *   - Frontend: http://127.0.0.1:4173 (Vite dev server, started by playwright.config.ts)
  20  |  *   - Backend API: available at same origin via Vite proxy (/api → localhost:8080)
  21  |  *   - Keycloak: http://localhost:8081/realms/bpm-default
  22  |  *   - Test user: admin-user / admin-pass (PLATFORM_ADMIN role, has PROCESS_DESIGNER access)
  23  |  */
  24  | 
  25  | import { test, expect, type Page, type APIRequestContext } from '@playwright/test'
  26  | import * as fs from 'fs'
  27  | import * as path from 'path'
  28  | 
  29  | const SCREENSHOTS_DIR = 'tests/screenshots'
  30  | const KEYCLOAK_TOKEN_URL = 'http://localhost:8081/realms/bpm-default/protocol/openid-connect/token'
  31  | const KEYCLOAK_CLIENT_ID = 'bpm-platform-api'
  32  | const KEYCLOAK_USERNAME = 'admin-user'
  33  | const KEYCLOAK_PASSWORD = 'admin-pass'
  34  | const API_PREFIX = '/api/v1'
  35  | 
  36  | // ── Screenshot helper ─────────────────────────────────────────────────────────
  37  | 
  38  | async function shot(page: Page, name: string): Promise<void> {
  39  |   const dir = path.resolve(SCREENSHOTS_DIR)
  40  |   if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  41  |   await page.screenshot({ path: path.join(dir, `Canvas-${name}.png`) })
  42  | }
  43  | 
  44  | // ── Token management ──────────────────────────────────────────────────────────
  45  | 
  46  | /**
  47  |  * Obtains a real JWT from Keycloak via the password grant (direct access) flow.
  48  |  * The returned token is a real signed JWT that the backend accepts.
  49  |  */
  50  | async function getKeycloakToken(request: APIRequestContext): Promise<string> {
  51  |   const response = await request.post(KEYCLOAK_TOKEN_URL, {
  52  |     headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  53  |     form: {
  54  |       client_id: KEYCLOAK_CLIENT_ID,
  55  |       username: KEYCLOAK_USERNAME,
  56  |       password: KEYCLOAK_PASSWORD,
  57  |       grant_type: 'password',
  58  |     },
  59  |   })
  60  | 
  61  |   if (!response.ok()) {
  62  |     const body = await response.text()
  63  |     throw new Error(
  64  |       `Keycloak token request failed (${response.status()}): ${body}\n` +
  65  |       `Ensure Keycloak is running at ${KEYCLOAK_TOKEN_URL.replace('/protocol/openid-connect/token', '')}\n` +
  66  |       `and user ${KEYCLOAK_USERNAME} exists with password ${KEYCLOAK_PASSWORD}.`,
  67  |     )
  68  |   }
  69  | 
  70  |   const body = await response.json() as { access_token: string }
  71  |   return body.access_token
  72  | }
  73  | 
  74  | // ── Login via UI with a real token ────────────────────────────────────────────
  75  | 
  76  | async function loginWithToken(page: Page, token: string): Promise<void> {
  77  |   await page.goto('/login')
  78  |   await expect(page.getByTestId('login-token-input')).toBeVisible()
  79  |   await page.getByTestId('login-token-input').fill(token)
  80  |   await page.getByTestId('login-submit').click()
  81  |   // Wait for navigation away from /login to the workspace
  82  |   await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 15_000 })
  83  |   // Verify workspace is rendered
  84  |   await expect(page.getByTestId('user-display-name')).toBeVisible({ timeout: 10_000 })
  85  | }
  86  | 
  87  | // ── API helpers ───────────────────────────────────────────────────────────────
  88  | 
  89  | /**
  90  |  * Creates a DRAFT definition with the specified graph structure.
  91  |  */
  92  | async function createTestDefinition(
  93  |   request: APIRequestContext,
  94  |   token: string,
  95  |   name: string,
  96  |   version: string,
  97  |   graph: { nodes: Array<{ id: string; node_type: string; label?: string | null; attributes?: string | null }>; edges: Array<{ id: string; source: string; target: string; condition?: string | null; is_default?: boolean }> },
  98  |   description?: string,
  99  | ): Promise<{ id: string; name: string; version: string; status: string }> {
  100 |   const response = await request.post(`${API_PREFIX}/definitions`, {
  101 |     headers: {
  102 |       'Authorization': `Bearer ${token}`,
  103 |       'Content-Type': 'application/json',
  104 |     },
  105 |     data: {
  106 |       name,
  107 |       version,
  108 |       description: description ?? '',
  109 |       graph,
  110 |       stage: null,
  111 |     },
  112 |   })
  113 | 
  114 |   if (!response.ok()) {
  115 |     const body = await response.text()
> 116 |     throw new Error(`POST /definitions failed (${response.status()}): ${body}`)
      |           ^ Error: POST /definitions failed (422): {"status":422,"errors":[{"code":"ISOLATED_NODE","message":"Node 'start' is isolated (insufficient incoming or outgoing edges for its type)"},{"code":"ISOLATED_NODE","message":"Node 'human-pd-ui-canvas-e2e-fields-04-1780019111516' is isolated (insufficient incoming or outgoing edges for its type)"},{"code":"ISOLATED_NODE","message":"Node 'service-pd-ui-canvas-e2e-fields-04-1780019111516' is isolated (insufficient incoming or outgoing edges for its type)"},{"code":"ISOLATED_NODE","message":"Node 'timer-pd-ui-canvas-e2e-fields-04-1780019111516' is isolated (insufficient incoming or outgoing edges for its type)"},{"code":"ISOLATED_NODE","message":"Node 'gw-pd-ui-canvas-e2e-fields-04-1780019111516' is isolated (insufficient incoming or outgoing edges for its type)"},{"code":"ISOLATED_NODE","message":"Node 'end' is isolated (insufficient incoming or outgoing edges for its type)"}]}
  117 |   }
  118 | 
  119 |   return response.json() as Promise<{ id: string; name: string; version: string; status: string }>
  120 | }
  121 | 
  122 | 
  123 | 
  124 | async function deleteTestDefinition(
  125 |   request: APIRequestContext,
  126 |   token: string,
  127 |   id: string,
  128 | ): Promise<void> {
  129 |   const response = await request.delete(`${API_PREFIX}/definitions/${id}`, {
  130 |     headers: { 'Authorization': `Bearer ${token}` },
  131 |   })
  132 |   if (response.status() !== 204 && response.status() !== 404) {
  133 |     console.warn(`DELETE /definitions/${id} returned ${response.status()}`)
  134 |   }
  135 | }
  136 | 
  137 | // ── Navigation helper ─────────────────────────────────────────────────────────
  138 | 
  139 | /** Navigate to the definition editor page for a specific ID using SPA navigation. */
  140 | async function navigateToCanvas(page: Page, definitionId: string): Promise<void> {
  141 |   // Use SPA navigation (pushState + popstate event) to navigate without a full page reload.
  142 |   // This preserves the in-memory auth token set by loginWithToken.
  143 |   await page.evaluate((id) => {
  144 |     window.history.pushState({}, '', `/definitions/${id}`)
  145 |     window.dispatchEvent(new PopStateEvent('popstate'))
  146 |   }, definitionId)
  147 |   // Wait for React to re-render with the new route
  148 |   await page.waitForURL(`/definitions/${definitionId}`, { timeout: 10_000 })
  149 |   // Wait for React Flow canvas to be visible
  150 |   await expect(page.getByTestId('process-canvas')).toBeVisible({ timeout: 15_000 })
  151 | }
  152 | 
  153 | // ── Simple graph templates ────────────────────────────────────────────────────
  154 | 
  155 | function startEndGraph() {
  156 |   return {
  157 |     nodes: [
  158 |       { id: 'start', node_type: 'START', label: null, attributes: null },
  159 |       { id: 'end', node_type: 'END', label: null, attributes: null },
  160 |     ],
  161 |     edges: [
  162 |       { id: 'e1', source: 'start', target: 'end', condition: null, is_default: false },
  163 |     ],
  164 |   }
  165 | }
  166 | 
  167 | function threeNodeGraph(suffix: string) {
  168 |   return {
  169 |     nodes: [
  170 |       { id: 'start', node_type: 'START', label: null, attributes: null },
  171 |       { id: `task-${suffix}`, node_type: 'HUMAN_TASK', label: `Review Task ${suffix}`, attributes: '{"role":"admin-user","assignee_type":"user","assignee_ref":"admin-user"}' },
  172 |       { id: 'end', node_type: 'END', label: null, attributes: null },
  173 |     ],
  174 |     edges: [
  175 |       { id: 'e1', source: 'start', target: `task-${suffix}`, condition: null, is_default: false },
  176 |       { id: 'e2', source: `task-${suffix}`, target: 'end', condition: null, is_default: false },
  177 |     ],
  178 |   }
  179 | }
  180 | 
  181 | function gatewayGraph(suffix: string) {
  182 |   return {
  183 |     nodes: [
  184 |       { id: 'start', node_type: 'START', label: null, attributes: null },
  185 |       { id: `gw-${suffix}`, node_type: 'EXCLUSIVE_GATEWAY', label: null, attributes: null },
  186 |       { id: `task-a-${suffix}`, node_type: 'HUMAN_TASK', label: `Approved Path ${suffix}`, attributes: '{"role":"admin-user","assignee_type":"user","assignee_ref":"admin-user"}' },
  187 |       { id: `task-b-${suffix}`, node_type: 'HUMAN_TASK', label: `Rejected Path ${suffix}`, attributes: '{"role":"admin-user","assignee_type":"user","assignee_ref":"admin-user"}' },
  188 |       { id: 'end', node_type: 'END', label: null, attributes: null },
  189 |     ],
  190 |     edges: [
  191 |       { id: 'e1', source: 'start', target: `gw-${suffix}`, condition: null, is_default: false },
  192 |       { id: 'e2', source: `gw-${suffix}`, target: `task-a-${suffix}`, condition: "status == 'approved'", is_default: false },
  193 |       { id: 'e3', source: `gw-${suffix}`, target: `task-b-${suffix}`, condition: null, is_default: true },
  194 |       { id: 'e4', source: `task-a-${suffix}`, target: 'end', condition: null, is_default: false },
  195 |       { id: 'e5', source: `task-b-${suffix}`, target: 'end', condition: null, is_default: false },
  196 |     ],
  197 |   }
  198 | }
  199 | 
  200 | // ── Test suite ────────────────────────────────────────────────────────────────
  201 | 
  202 | test.describe('F2 — Process Designer Canvas (PD-UI-09 through PD-UI-12)', () => {
  203 |   let authToken: string
  204 |   const createdDefinitionIds: string[] = []
  205 | 
  206 |   /** UUID v4-like id for tracking test-created definitions */
  207 |   function testId(label: string): string {
  208 |     return `pd-ui-canvas-e2e-${label}-${Date.now()}`
  209 |   }
  210 | 
  211 |   test.beforeAll(async ({ request }) => {
  212 |     authToken = await getKeycloakToken(request)
  213 |   })
  214 | 
  215 |   test.afterEach(async ({ request }) => {
  216 |     for (const id of createdDefinitionIds) {
```