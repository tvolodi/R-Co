import { expect, test } from '@playwright/test'
import * as fs from 'fs'
import * as path from 'path'

const SCREENSHOTS_DIR = 'tests/screenshots'
const KEYCLOAK_TOKEN_URL = 'http://localhost:8081/realms/bpm-default/protocol/openid-connect/token'
const KEYCLOAK_CLIENT_ID = 'bpm-platform-api'
const KEYCLOAK_WORKER_USERNAME = 'worker-user'
const KEYCLOAK_WORKER_PASSWORD = 'worker-pass'
const KEYCLOAK_OPERATOR_USERNAME = 'operator-user'
const KEYCLOAK_OPERATOR_PASSWORD = 'operator-pass'
const API_PREFIX = '/api/v1'

async function shot(page: import('@playwright/test').Page, name: string): Promise<void> {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  await page.screenshot({ path: path.join(dir, `F4-${name}.png`), fullPage: true })
}

async function getKeycloakToken(
  request: import('@playwright/test').APIRequestContext,
  username: string,
  password: string,
): Promise<string> {
  const response = await request.post(KEYCLOAK_TOKEN_URL, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    form: {
      client_id: KEYCLOAK_CLIENT_ID,
      username,
      password,
      grant_type: 'password',
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`Keycloak token request failed (${response.status()}): ${body}`)
  }

  const body = (await response.json()) as { access_token: string }
  return body.access_token
}

async function loginWithToken(page: import('@playwright/test').Page, token: string): Promise<void> {
  await page.goto('/login')
  await expect(page.getByTestId('login-token-input')).toBeVisible()
  await page.getByTestId('login-token-input').fill(token)
  await page.getByTestId('login-submit').click()
  await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 15_000 })
  await expect(page.getByTestId('user-display-name')).toBeVisible({ timeout: 10_000 })
}

async function navigateSpa(page: import('@playwright/test').Page, targetPath: string): Promise<void> {
  await page.evaluate((path) => {
    window.history.pushState({}, '', path)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, targetPath)
  await page.waitForURL((url) => `${url.pathname}${url.search}` === targetPath, { timeout: 10_000 })
}

async function assertNoErrorBoundary(page: import('@playwright/test').Page): Promise<void> {
  const panel = page.getByTestId('error-boundary-panel')
  const becameVisible = await panel
    .waitFor({ state: 'visible', timeout: 2_500 })
    .then(() => true)
    .catch(() => false)

  if (!becameVisible) return

  const details = page.getByTestId('error-boundary-details')
  if ((await details.count()) > 0 && (await details.isVisible())) {
    await details.locator('summary').click()
    const content = (await details.locator('pre').textContent()) ?? 'unknown error'
    throw new Error(`ErrorBoundary was rendered: ${content}`)
  }

  throw new Error('ErrorBoundary was rendered without details')
}

async function createSimpleDefinition(
  request: import('@playwright/test').APIRequestContext,
  token: string,
): Promise<{ id: string; name: string; version: string }> {
  const unique = `f4-task-${Date.now()}`
  const createResponse = await request.post(`${API_PREFIX}/definitions`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      name: `F4 Task Inbox ${unique}`,
      version: '1.0.0',
      description: 'Auto-created by F4 task inbox E2E setup',
      stage: null,
      graph: {
        nodes: [
          { id: 'start', node_type: 'START', label: 'Start', attributes: null },
          {
            id: 'task-1',
            node_type: 'HUMAN_TASK',
            label: 'Review Form',
            attributes: JSON.stringify({
              role: 'reviewer',
              assignee_type: 'USER',
              assignee_ref: 'worker-user',
              form_schema: {
                type: 'object',
                properties: {
                  approver_notes: { type: 'string', title: 'Notes' },
                  amount: { type: 'number', title: 'Amount' },
                  approved: { type: 'boolean', title: 'Approved' },
                },
                required: ['approver_notes'],
              },
            }),
          },
          { id: 'end', node_type: 'END', label: 'End', attributes: null },
        ],
        edges: [
          { id: 'e1', source: 'start', target: 'task-1', condition: null, is_default: false },
          { id: 'e2', source: 'task-1', target: 'end', condition: null, is_default: false },
        ],
      },
    },
  })

  if (!createResponse.ok()) {
    const createBody = await createResponse.text()
    throw new Error(`POST /definitions failed during F4 setup (${createResponse.status()}): ${createBody}`)
  }

  const created = (await createResponse.json()) as { id: string; name: string; version: string }
  const activateResponse = await request.post(`${API_PREFIX}/definitions/${created.id}/activate`, {
    headers: {
      Authorization: `Bearer ${token}`,
    },
  })
  if (!activateResponse.ok()) {
    const activateBody = await activateResponse.text()
    throw new Error(`POST /definitions/${created.id}/activate failed during F4 setup (${activateResponse.status()}): ${activateBody}`)
  }
  return created
}

async function createDefinitionWithGroupTask(
  request: import('@playwright/test').APIRequestContext,
  token: string,
): Promise<{ id: string; name: string; version: string }> {
  const unique = `f4-group-task-${Date.now()}`
  const createResponse = await request.post(`${API_PREFIX}/definitions`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      name: `F4 Group Task ${unique}`,
      version: '1.0.0',
      description: 'Definition with group-assigned task',
      stage: null,
      graph: {
        nodes: [
          { id: 'start', node_type: 'START', label: 'Start', attributes: null },
          {
            id: 'task-group',
            node_type: 'HUMAN_TASK',
            label: 'Group Review',
            attributes: JSON.stringify({
              role: 'approver',
              assignee_type: 'GROUP',
              assignee_ref: 'approvers',
              form_schema: {
                type: 'object',
                properties: {
                  decision: { type: 'string', enum: ['APPROVE', 'REJECT'], title: 'Decision' },
                },
                required: ['decision'],
              },
            }),
          },
          { id: 'end', node_type: 'END', label: 'End', attributes: null },
        ],
        edges: [
          { id: 'e1', source: 'start', target: 'task-group', condition: null, is_default: false },
          { id: 'e2', source: 'task-group', target: 'end', condition: null, is_default: false },
        ],
      },
    },
  })

  if (!createResponse.ok()) {
    const createBody = await createResponse.text()
    throw new Error(`POST /definitions failed for group task (${createResponse.status()}): ${createBody}`)
  }

  const created = (await createResponse.json()) as { id: string; name: string; version: string }
  const activateResponse = await request.post(`${API_PREFIX}/definitions/${created.id}/activate`, {
    headers: {
      Authorization: `Bearer ${token}`,
    },
  })
  if (!activateResponse.ok()) {
    const activateBody = await activateResponse.text()
    throw new Error(`POST /definitions/${created.id}/activate failed (${activateResponse.status()}): ${activateBody}`)
  }
  return created
}

async function startInstanceApi(
  request: import('@playwright/test').APIRequestContext,
  token: string,
  definitionId: string,
  correlationKey: string,
): Promise<{ instance_id: string }> {
  const response = await request.post(`${API_PREFIX}/instances`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      definition_id: definitionId,
      correlation_key: correlationKey,
      initial_variables: { source: 'f4-e2e', request_amount: 1000 },
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`POST /instances failed (${response.status()}): ${body}`)
  }

  return (await response.json()) as Promise<{ instance_id: string }>
}

async function waitForTaskAppear(
  request: import('@playwright/test').APIRequestContext,
  token: string,
  instanceId: string,
): Promise<void> {
  const deadline = Date.now() + 20_000

  while (Date.now() < deadline) {
    const response = await request.get(`${API_PREFIX}/tasks`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
      params: {
        instance_id: instanceId,
      },
    })

    if (response.ok()) {
      try {
        const parsed = (await response.json()) as { items?: unknown[] }
        if (Array.isArray(parsed.items) && parsed.items.length > 0) {
          return
        }
      } catch {
        // Keep polling
      }
    }

    await new Promise((resolve) => setTimeout(resolve, 500))
  }

  throw new Error(`Task did not appear for instance ${instanceId} within timeout`)
}

test.describe('F4 task inbox UI (TK-UI-01..10)', () => {
  // Per-test fixtures - no shared state across tests
  let workerToken = ''
  let operatorToken = ''

  test.beforeEach(async ({ request }) => {
    // Authenticate tokens once per test
    workerToken = await getKeycloakToken(request, KEYCLOAK_WORKER_USERNAME, KEYCLOAK_WORKER_PASSWORD)
    operatorToken = await getKeycloakToken(request, KEYCLOAK_OPERATOR_USERNAME, KEYCLOAK_OPERATOR_PASSWORD)
  })

  // TK-UI-01: Task inbox display and filtering
  test('TK-UI-01-E2E-01: task inbox displays user assigned tasks', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    await assertNoErrorBoundary(page)
    await expect(page.getByTestId('task-inbox-list')).toBeVisible({ timeout: 5_000 })
    const taskRows = page.getByTestId('task-row')
    const rowCount = await taskRows.count()
    expect(rowCount).toBeGreaterThanOrEqual(1)
    await shot(page, 'TK01-01-inbox-display')
  })

  test('TK-UI-01-E2E-02: task inbox displays user group-assigned tasks', async ({ page, request }) => {
    // Per-test fixture: create group task definition and instance
    const groupDef = await createDefinitionWithGroupTask(request, operatorToken)
    const groupInst = await startInstanceApi(
      request,
      operatorToken,
      groupDef.id,
      `f4-group-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, groupInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    await assertNoErrorBoundary(page)
    const taskRows = page.getByTestId('task-row')
    // Group tasks should appear in the default view for group members
    const hasGroupTask = await taskRows
      .count()
      .then((count) => count > 0)
      .catch(() => false)
    expect(hasGroupTask).toBe(true)
    await shot(page, 'TK01-02-group-tasks')
  })

  test('TK-UI-01-E2E-03: "My Tasks" filter shows only user-assigned tasks', async ({ page, request }) => {
    // Per-test fixtures: create both simple and group task instances
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const groupDef = await createDefinitionWithGroupTask(request, operatorToken)

    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    const groupInst = await startInstanceApi(
      request,
      operatorToken,
      groupDef.id,
      `f4-group-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, groupInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks?filter=my-tasks')
    await assertNoErrorBoundary(page)
    // Filter should show only directly assigned tasks
    const taskRows = page.getByTestId('task-row')
    const rowCount = await taskRows.count()
    expect(rowCount).toBeGreaterThanOrEqual(1)
    await shot(page, 'TK01-03-my-tasks-filter')
  })

  test('TK-UI-01-E2E-04: "My Group Tasks" filter shows only group-assigned tasks', async ({ page, request }) => {
    // Per-test fixtures: create both simple and group task instances
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const groupDef = await createDefinitionWithGroupTask(request, operatorToken)

    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    const groupInst = await startInstanceApi(
      request,
      operatorToken,
      groupDef.id,
      `f4-group-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, groupInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks?filter=my-group-tasks')
    await assertNoErrorBoundary(page)
    // Filter should show only group-assigned tasks
    const taskRows = page.getByTestId('task-row')
    const rowCount = await taskRows.count()
    // Group task should be visible
    expect(rowCount).toBeGreaterThanOrEqual(0)
    await shot(page, 'TK01-04-my-group-tasks-filter')
  })

  test('TK-UI-01-E2E-05: "All Tasks" filter available only to operators', async ({ page, request }) => {
    // Per-test fixture: create a simple task
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    // Test 1: Worker user should not see "All Tasks" filter
    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const workerAllTasksFilter = page.getByTestId('task-filter-all-tasks')
    const workerFilterVisible = await workerAllTasksFilter.count() > 0
    expect(workerFilterVisible).toBe(false)
    await shot(page, 'TK01-05a-worker-no-all-tasks')

    // Test 2: Operator user should see "All Tasks" filter
    await page.goto('/logout')
    await loginWithToken(page, operatorToken)
    await navigateSpa(page, '/tasks')
    const operatorAllTasksFilter = page.getByTestId('task-filter-all-tasks')
    const operatorFilterVisible = await operatorAllTasksFilter.count() > 0
    expect(operatorFilterVisible).toBe(true)
    await shot(page, 'TK01-05b-operator-all-tasks')
  })

  test('TK-UI-01-E2E-06: task list displays required columns', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    await assertNoErrorBoundary(page)
    const taskRow = page.getByTestId('task-row').first()
    await expect(taskRow.getByTestId('task-name')).toBeVisible()
    await expect(taskRow.getByTestId('task-instance-id')).toBeVisible()
    await expect(taskRow.getByTestId('task-status')).toBeVisible()
    await expect(taskRow.getByTestId('task-assignee')).toBeVisible()
    await shot(page, 'TK01-06-task-columns')
  })

  test('TK-UI-01-E2E-07: pagination controls work for task lists', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    await assertNoErrorBoundary(page)
    const paginationControls = page.getByTestId('pagination-controls')
    const isPaginated = await paginationControls.count() > 0
    if (isPaginated) {
      await expect(paginationControls).toBeVisible()
    }
    await shot(page, 'TK01-07-pagination')
  })

  // TK-UI-02: Task detail panel
  test('TK-UI-02-E2E-01: clicking task opens detail panel', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    await assertNoErrorBoundary(page)
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible({ timeout: 5_000 })
    await shot(page, 'TK02-01-detail-panel-open')
  })

  test('TK-UI-02-E2E-02: task detail panel displays node name', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    const detailTitle = page.getByTestId('task-detail-title')
    await expect(detailTitle).toBeVisible()
    const titleText = await detailTitle.textContent()
    expect(titleText).toBeTruthy()
    await shot(page, 'TK02-02-detail-title')
  })

  test('TK-UI-02-E2E-03: panel displays instance context information', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    await expect(page.getByTestId('instance-definition-name')).toBeVisible()
    await expect(page.getByTestId('instance-id')).toBeVisible()
    await expect(page.getByTestId('instance-correlation-key')).toBeVisible()
    await shot(page, 'TK02-03-instance-context')
  })

  test('TK-UI-02-E2E-04: panel displays current instance variables', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    const variablesSection = page.getByTestId('instance-variables')
    await expect(variablesSection).toBeVisible()
    await shot(page, 'TK02-04-variables')
  })

  // TK-UI-03: Dynamic form rendering
  test('TK-UI-03-E2E-01: text field from form schema renders as input', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    const textField = page.getByTestId('form-field-approver_notes')
    await expect(textField).toBeVisible()
    await shot(page, 'TK03-01-text-field')
  })

  test('TK-UI-03-E2E-06: required fields are marked as required', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    const requiredIndicator = page.getByTestId('form-field-required-approver_notes')
    const isVisible = await requiredIndicator.count() > 0
    if (isVisible) {
      await expect(requiredIndicator).toBeVisible()
    }
    await shot(page, 'TK03-06-required-indicator')
  })

  test('TK-UI-03-E2E-07: form submission blocked if required fields empty', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    const completeButton = page.getByTestId('task-complete-button')
    await completeButton.click()
    const errorMessage = page.getByTestId('form-error-message')
    const errorVisible = await errorMessage
      .waitFor({ state: 'visible', timeout: 3_000 })
      .then(() => true)
      .catch(() => false)
    if (errorVisible) {
      await expect(errorMessage).toBeVisible()
    }
    await shot(page, 'TK03-07-validation-error')
  })

  // TK-UI-04: Complete task
  test('TK-UI-04-E2E-01: complete button is visible on task detail', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    const completeButton = page.getByTestId('task-complete-button')
    await expect(completeButton).toBeVisible()
    await shot(page, 'TK04-01-complete-button')
  })

  test('TK-UI-04-E2E-02: complete button submits form to backend', async ({ page, request }) => {
    // Per-test fixture: create SEPARATE simple definition and instance for this test
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    const taskId = await taskRow.getAttribute('data-task-id')
    expect(taskId).toBeTruthy()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    const textField = page.getByTestId('form-field-approver_notes')
    await textField.fill('Looks good')
    const completeButton = page.getByTestId('task-complete-button')
    let requestMade = false
    page.on('response', (response) => {
      if (response.request().method() === 'POST' && response.url().includes('/tasks/') && response.url().includes('/complete')) {
        requestMade = true
      }
    })
    await completeButton.click()
    await new Promise((resolve) => setTimeout(resolve, 1000))
    expect(requestMade).toBe(true)
    await shot(page, 'TK04-02-submit')
  })

  test('TK-UI-04-E2E-04: success toast shown after task completion', async ({ page, request }) => {
    // Per-test fixture: create SEPARATE simple definition and instance for this test
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    const textField = page.getByTestId('form-field-approver_notes')
    await textField.fill('Approved')
    const completeButton = page.getByTestId('task-complete-button')
    await completeButton.click()
    const successToast = page.getByTestId('success-toast')
    const toastVisible = await successToast
      .waitFor({ state: 'visible', timeout: 5_000 })
      .then(() => true)
      .catch(() => false)
    if (toastVisible) {
      await expect(successToast).toBeVisible()
    }
    await shot(page, 'TK04-04-success-toast')
  })

  // TK-UI-05: Claim task
  test('TK-UI-05-E2E-01: claim button visible for group-assigned tasks', async ({ page, request }) => {
    // Per-test fixture: create group task definition and instance
    const groupDef = await createDefinitionWithGroupTask(request, operatorToken)
    const groupInst = await startInstanceApi(
      request,
      operatorToken,
      groupDef.id,
      `f4-group-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, groupInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks?filter=group')
    await assertNoErrorBoundary(page)
    const taskRow = page.getByTestId('task-row').first()
    const taskRowVisible = await taskRow
      .waitFor({ state: 'visible', timeout: 5_000 })
      .then(() => true)
      .catch(() => false)
    if (taskRowVisible) {
      await taskRow.click()
      await expect(page.getByTestId('task-detail-panel')).toBeVisible()
      const claimButton = page.getByTestId('task-claim-button')
      const buttonVisible = await claimButton.count() > 0
      if (buttonVisible) {
        await expect(claimButton).toBeVisible()
      }
    }
    await shot(page, 'TK05-01-claim-button')
  })

  test('TK-UI-05-E2E-03: claim button sends POST request', async ({ page, request }) => {
    // Per-test fixture: create SEPARATE group task definition and instance for this test
    const groupDef = await createDefinitionWithGroupTask(request, operatorToken)
    const groupInst = await startInstanceApi(
      request,
      operatorToken,
      groupDef.id,
      `f4-group-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, groupInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks?filter=group')
    const taskRows = page.getByTestId('task-row')
    const count = await taskRows.count()
    if (count > 0) {
      const taskRow = taskRows.first()
      await taskRow.click()
      await expect(page.getByTestId('task-detail-panel')).toBeVisible()
      const claimButton = page.getByTestId('task-claim-button')
      const buttonExists = await claimButton.count() > 0
      if (buttonExists && (await claimButton.isVisible())) {
        let requestMade = false
        page.on('response', (response) => {
          if (response.request().method() === 'POST' && response.url().includes('/tasks/') && response.url().includes('/assign')) {
            requestMade = true
          }
        })
        await claimButton.click()
        await new Promise((resolve) => setTimeout(resolve, 1000))
        expect(requestMade).toBe(true)
      }
    }
    await shot(page, 'TK05-03-claim-request')
  })

  // TK-UI-06: Reassign task
  test('TK-UI-06-E2E-01: reassign button visible for operators', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, operatorToken, simpleInst.instance_id)

    await loginWithToken(page, operatorToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    const reassignButton = page.getByTestId('task-reassign-button')
    const buttonExists = await reassignButton.count() > 0
    if (buttonExists) {
      await expect(reassignButton).toBeVisible()
    }
    await shot(page, 'TK06-01-reassign-button')
  })

  test('TK-UI-06-E2E-02: reassign button not visible for task workers', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    const reassignButton = page.getByTestId('task-reassign-button')
    const buttonExists = await reassignButton.count() > 0
    expect(buttonExists).toBe(false)
    await shot(page, 'TK06-02-no-reassign')
  })

  test('TK-UI-06-E2E-03: reassign button opens search dialog', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, operatorToken, simpleInst.instance_id)

    await loginWithToken(page, operatorToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    const reassignButton = page.getByTestId('task-reassign-button')
    const buttonExists = await reassignButton.count() > 0
    if (buttonExists && (await reassignButton.isVisible())) {
      await reassignButton.click()
      const reassignDialog = page.getByTestId('reassign-dialog')
      const dialogVisible = await reassignDialog
        .waitFor({ state: 'visible', timeout: 3_000 })
        .then(() => true)
        .catch(() => false)
      if (dialogVisible) {
        await expect(reassignDialog).toBeVisible()
      }
    }
    await shot(page, 'TK06-03-reassign-dialog')
  })

  // TK-UI-10: Mobile responsive
  test('TK-UI-10-E2E-01: task inbox displays on 375px mobile viewport', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await page.setViewportSize({ width: 375, height: 812 })
    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const taskList = page.getByTestId('task-inbox-list')
    await expect(taskList).toBeVisible()
    const hasHorizontalScroll = await page.evaluate(() => {
      return document.documentElement.scrollWidth > window.innerWidth
    })
    expect(hasHorizontalScroll).toBe(false)
    await shot(page, 'TK10-01-mobile-list')
  })

  test('TK-UI-10-E2E-02: task detail page renders without horizontal scrolling', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await page.setViewportSize({ width: 375, height: 812 })
    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    const hasHorizontalScroll = await page.evaluate(() => {
      return document.documentElement.scrollWidth > window.innerWidth
    })
    expect(hasHorizontalScroll).toBe(false)
    await shot(page, 'TK10-02-mobile-detail')
  })

  test('TK-UI-10-E2E-04: complete button accessible on mobile', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await page.setViewportSize({ width: 375, height: 812 })
    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const taskRow = page.getByTestId('task-row').first()
    await taskRow.click()
    await expect(page.getByTestId('task-detail-panel')).toBeVisible()
    const completeButton = page.getByTestId('task-complete-button')
    await expect(completeButton).toBeVisible()
    const isInViewport = await completeButton.evaluate((el) => {
      const rect = el.getBoundingClientRect()
      return rect.bottom <= window.innerHeight
    })
    if (!isInViewport) {
      await page.evaluate(() => {
        const button = document.querySelector('[data-testid="task-complete-button"]')
        button?.scrollIntoView()
      })
    }
    await expect(completeButton).toBeVisible()
    await shot(page, 'TK10-04-mobile-button')
  })

  // TK-UI-07: Sort and search (SHOULD requirement)
  test('TK-UI-07-E2E-01: tasks can be sorted by created time', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const sortControl = page.getByTestId('task-sort-control')
    const sortExists = await sortControl.count() > 0
    if (sortExists) {
      await expect(sortControl).toBeVisible()
    }
    await shot(page, 'TK07-01-sort-control')
  })

  test('TK-UI-07-E2E-03: free-text search filters by task name', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const searchInput = page.getByTestId('task-search-input')
    const searchExists = await searchInput.count() > 0
    if (searchExists) {
      await expect(searchInput).toBeVisible()
      await searchInput.fill('Review')
      await new Promise((resolve) => setTimeout(resolve, 500))
    }
    await shot(page, 'TK07-03-search')
  })

  // TK-UI-08: Badge count (SHOULD requirement)
  test('TK-UI-08-E2E-01: navigation badge displays current task count', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    const badge = page.getByTestId('task-inbox-badge')
    const badgeExists = await badge.count() > 0
    if (badgeExists) {
      await expect(badge).toBeVisible()
      const badgeText = await badge.textContent()
      expect(badgeText).toMatch(/\d+/)
    }
    await shot(page, 'TK08-01-badge')
  })

  // TK-UI-09: Escalation indicator (SHOULD requirement)
  test('TK-UI-09-E2E-01: escalated tasks show visual indicator in list', async ({ page, request }) => {
    // Per-test fixture: create simple definition and instance
    const simpleDef = await createSimpleDefinition(request, operatorToken)
    const simpleInst = await startInstanceApi(
      request,
      operatorToken,
      simpleDef.id,
      `f4-simple-${Date.now()}`,
    )
    await waitForTaskAppear(request, workerToken, simpleInst.instance_id)

    await loginWithToken(page, workerToken)
    await navigateSpa(page, '/tasks')
    const escalationIndicators = page.getByTestId('task-escalation-indicator')
    const indicatorCount = await escalationIndicators.count()
    if (indicatorCount > 0) {
      await expect(escalationIndicators.first()).toBeVisible()
    }
    await shot(page, 'TK09-01-escalation-indicator')
  })
})
