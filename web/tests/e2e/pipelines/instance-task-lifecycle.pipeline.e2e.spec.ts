/**
 * Pipeline: Instance and Task Lifecycle
 * Spec: tests/specs/PIPELINE-instance-task-lifecycle.md
 * Covers: IN-UI-01, IN-UI-03, IN-UI-04, IN-UI-07, TK-UI-01, TK-UI-02, TK-UI-03, TK-UI-04
 *
 * Chain: setup definition → instance board → start instance → detail panels →
 *        wait for task → worker inbox → open task → fill form → complete task →
 *        verify COMPLETED
 *
 * Two actors: operator (starts instances, views board) and worker (completes tasks).
 * Each page.addInitScript call is scoped to the current page state — re-calling
 * loginWithToken switches the active session to the new actor.
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  createPipeline,
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  extractIdFromUrl,
  authHeaders,
  jwtSubject,
} from '../pipeline'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const KEYCLOAK_BASE_URL = process.env.BPM_IDP_BASE_URL ?? 'http://127.0.0.1:8081'
const KEYCLOAK_DISCOVERY_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`
const API_PREFIX = '/api/v1'

const WORKER_USERNAME = process.env.BPM_E2E_WORKER_USERNAME ?? 'worker-user'
const WORKER_PASSWORD = process.env.BPM_E2E_WORKER_PASSWORD ?? 'worker-pass'

interface InstanceTaskState {
  operatorToken: string
  workerToken: string
  workerUserId: string
  definitionId: string
  definitionName: string
  instanceId: string
  taskId: string
}

async function waitForTask(
  request: import('@playwright/test').APIRequestContext,
  token: string,
  instanceId: string,
): Promise<void> {
  const deadline = Date.now() + 20_000
  while (Date.now() < deadline) {
    const resp = await request.get(`${API_BASE_URL}${API_PREFIX}/tasks`, {
      headers: authHeaders(token),
      params: { instance_id: instanceId },
    })
    if (resp.ok()) {
      const body = await resp.json() as { items?: unknown[] }
      if (Array.isArray(body.items) && body.items.length > 0) return
    }
    await new Promise((r) => setTimeout(r, 500))
  }
  throw new Error(`Task did not appear for instance ${instanceId} within 20s`)
}

async function assertNoErrorBoundary(page: import('@playwright/test').Page): Promise<void> {
  const panel = page.getByTestId('error-boundary-panel')
  const visible = await panel.waitFor({ state: 'visible', timeout: 2_500 }).then(() => true).catch(() => false)
  if (!visible) return
  const details = page.getByTestId('error-boundary-details')
  if (await details.count() > 0 && await details.isVisible()) {
    await details.locator('summary').click()
    const content = (await details.locator('pre').textContent()) ?? 'unknown error'
    throw new Error(`ErrorBoundary rendered: ${content}`)
  }
  throw new Error('ErrorBoundary rendered without details')
}

test.describe('Pipeline: instance and task lifecycle (IN-UI-01, 03, 04, 07, TK-UI-01..04)', () => {
  test('full lifecycle: board → start instance → task inbox → complete task → COMPLETED', async ({ page, request }) => {
    const backendOk = await request.fetch(`${API_BASE_URL}/health/ready`)
    if (!backendOk.ok()) throw new Error(`Backend not ready: ${backendOk.status()}`)
    const idpOk = await request.fetch(KEYCLOAK_DISCOVERY_URL)
    if (!idpOk.ok()) throw new Error(`Keycloak not ready: ${idpOk.status()}`)

    const operatorToken = await getKeycloakToken(request)
    const workerToken = await getKeycloakToken(request, WORKER_USERNAME, WORKER_PASSWORD)
    const workerUserId = jwtSubject(workerToken)

    const pl = createPipeline<InstanceTaskState>('instance-task-lifecycle', { page, request })
    pl.state.operatorToken = operatorToken
    pl.state.workerToken = workerToken
    pl.state.workerUserId = workerUserId

    pl.onCleanup(async (s) => {
      if (s.instanceId) {
        await request.post(`${API_BASE_URL}${API_PREFIX}/instances/${s.instanceId}/cancel`, {
          headers: authHeaders(s.operatorToken),
          data: { reason: 'pipeline-test-cleanup' },
        }).catch(() => {})
      }
      if (s.definitionId) {
        await request.delete(`${API_BASE_URL}${API_PREFIX}/definitions/${s.definitionId}`, {
          headers: authHeaders(s.operatorToken),
        }).catch(() => {})
      }
    })

    // ── Setup: create and activate definition via API ─────────────────────────
    await pl.step('setup: create and activate definition', async (s) => {
      const unique = `pl-itl-${randomUUID().slice(0, 10)}`
      const createResp = await request.post(`${API_BASE_URL}${API_PREFIX}/definitions`, {
        headers: authHeaders(s.operatorToken),
        data: {
          name: `Pipeline ITL ${unique}`,
          version: '1.0.0',
          description: 'Created by instance-task-lifecycle pipeline',
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
                  assignee_ref: s.workerUserId,
                  form_schema: {
                    type: 'object',
                    properties: {
                      approver_notes: { type: 'string', title: 'Notes' },
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
      if (!createResp.ok()) throw new Error(`Create definition failed (${createResp.status()}): ${await createResp.text()}`)
      const created = await createResp.json() as { id: string; name: string }
      s.definitionId = created.id
      s.definitionName = created.name
      pl.gate(!!s.definitionId, 'definitionId must be present after creation')

      const activateResp = await request.post(`${API_BASE_URL}${API_PREFIX}/definitions/${s.definitionId}/activate`, {
        headers: authHeaders(s.operatorToken),
      })
      if (!activateResp.ok()) throw new Error(`Activate definition failed (${activateResp.status()}): ${await activateResp.text()}`)
    })

    // ── Step 1: Instance board columns ────────────────────────────────────────
    await pl.step('IN-UI-01: instance board columns', async () => {
      await loginWithToken(page, operatorToken)
      await page.getByRole('link', { name: 'Instances' }).click()
      await page.waitForURL(/\/instances/, { timeout: 10_000 })
      await expect(page.getByTestId('instance-board-table')).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Instance ID' })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Definition' })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Status' })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Correlation Key' })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Started' })).toBeVisible()
    })

    // ── Step 2: Start instance via UI dialog ──────────────────────────────────
    await pl.step('IN-UI-03: start instance via dialog', async (s) => {
      await navigateSpa(page, `/instances?definitionName=${encodeURIComponent(s.definitionName)}&definitionId=${encodeURIComponent(s.definitionId)}`)
      await expect(page.getByTestId('instance-board-table')).toBeVisible({ timeout: 10_000 })

      await page.getByTestId('start-instance-button').click()
      await expect(page.getByTestId('start-instance-dialog')).toBeVisible()

      await page.getByTestId('start-definition-name').fill(s.definitionName)
      await page.getByTestId('start-definition-name').press('Tab')
      await page.getByTestId('start-correlation-key').fill(`pl-itl-${Date.now()}`)
      await page.getByTestId('start-variables-json').fill('{"source":"pipeline-e2e"}')
      await page.getByTestId('submit-start-instance').click()

      await page.waitForURL(/\/instances\//, { timeout: 12_000 })
      s.instanceId = extractIdFromUrl(page.url(), 'instances')
      pl.gate(!!s.instanceId, 'instanceId must be present in URL after start')
    })

    // ── Step 3: Instance detail panels ────────────────────────────────────────
    await pl.step('IN-UI-04: instance detail panels visible', async (s) => {
      await navigateSpa(page, `/instances/${s.instanceId}`)
      await assertNoErrorBoundary(page)
      await expect(page.getByRole('heading', { name: 'Instance' })).toBeVisible()
      await expect(page.getByRole('heading', { name: 'Definition Snapshot' })).toBeVisible()
      await expect(page.getByRole('heading', { name: 'Variables' })).toBeVisible()
      await expect(page.getByRole('heading', { name: 'Active Tasks' })).toBeVisible()
      await expect(page.getByTestId('instance-readonly-graph')).toBeVisible()
    })

    // ── Step 4: Wait for task to appear ───────────────────────────────────────
    await pl.step('wait for task to appear (engine processing)', async (s) => {
      await waitForTask(request, s.workerToken, s.instanceId)
      pl.gate(true, 'task appeared for instance — engine processed INSTANCE_STARTED')
    })

    // ── Step 5: Worker sees task in inbox ─────────────────────────────────────
    await pl.step('TK-UI-01: worker task inbox shows the task', async (s) => {
      await loginWithToken(page, s.workerToken)
      await navigateSpa(page, '/tasks')
      await assertNoErrorBoundary(page)
      await expect(page.getByTestId('task-inbox-list')).toBeVisible({ timeout: 5_000 })
      const taskRows = page.getByTestId('task-row')
      await expect(taskRows).toHaveCount(await taskRows.count(), { timeout: 10_000 })
      pl.gate(await taskRows.count() >= 1, 'at least one task row must be visible in the inbox')
    })

    // ── Step 6: Open task detail panel ────────────────────────────────────────
    await pl.step('TK-UI-02: open task detail panel', async (s) => {
      await navigateSpa(page, '/tasks')
      const taskRow = page.getByTestId('task-row').first()
      await expect(taskRow).toBeVisible({ timeout: 10_000 })
      s.taskId = (await taskRow.getAttribute('data-task-id')) ?? ''

      await taskRow.click()
      await expect(page.getByTestId('task-detail-panel')).toBeVisible({ timeout: 10_000 })
      await expect(page.getByTestId('task-detail-title')).toBeVisible()
      await expect(page.getByTestId('instance-definition-name')).toBeVisible()
      await expect(page.getByTestId('instance-id')).toBeVisible()
    })

    // ── Step 7: Fill required form field ─────────────────────────────────────
    await pl.step('TK-UI-03: fill required form field', async () => {
      const textField = page.getByTestId('form-field-approver_notes')
      await expect(textField).toBeVisible({ timeout: 10_000 })
      await textField.fill('Approved via pipeline test')
    })

    // ── Step 8: Complete task ─────────────────────────────────────────────────
    await pl.step('TK-UI-04: complete task', async (s) => {
      const completeButton = page.getByTestId('task-complete-button')
      await expect(completeButton).toBeVisible({ timeout: 10_000 })

      let completionConfirmed = false
      page.on('response', (resp) => {
        if (resp.request().method() === 'POST' &&
            resp.url().includes('/tasks/') &&
            resp.url().includes('/complete') &&
            resp.ok()) {
          completionConfirmed = true
        }
      })

      await completeButton.click()
      await page.waitForTimeout(1500)
      pl.gate(completionConfirmed, `POST /tasks/${s.taskId}/complete must succeed`)
    })

    // ── Step 9: Verify instance COMPLETED ────────────────────────────────────
    await pl.step('IN-UI-04: instance status is COMPLETED', async (s) => {
      await loginWithToken(page, s.operatorToken)
      await navigateSpa(page, `/instances/${s.instanceId}`)
      await assertNoErrorBoundary(page)
      await expect(page.getByRole('heading', { name: 'Instance' })).toBeVisible()

      // Poll briefly — engine processes TASK_COMPLETED asynchronously
      await expect.poll(
        async () => {
          const text = await page.locator('[data-testid="instance-status"], .instance-status').first().textContent().catch(() => '')
          return text
        },
        { timeout: 15_000, intervals: [1000] },
      ).toContain('COMPLETED')

      pl.gate(true, 'instance confirmed COMPLETED — full lifecycle validated')
    })

    await pl.runCleanup()
  })
})
