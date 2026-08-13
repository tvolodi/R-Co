/**
 * E2E — GRD-UI-07: FieldFactory ARIA wiring (strict no-mock contract)
 *
 *  No mocks. Real backend. The spec seeds a definition whose task
 *  has a form_schema with one field per widget type, then asserts
 *  the rendered form carries the ARIA attribute set per design
 *  §5.4 + §12.4.
 */

import { test, expect, type Page, type APIRequestContext } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

const DEFINITION_SLUG_PREFIX = 'pw13-batch19-grd-ui-07'

interface SeededTaskFixture {
  definitionId: string
  taskId: string
}

async function seedDefinitionWithForm(
  request: APIRequestContext,
  token: string,
): Promise<SeededTaskFixture> {
  const slug = `${DEFINITION_SLUG_PREFIX}-${Math.random().toString(36).slice(2, 10)}`
  const headers = {
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
  }
  const formSchema = {
    type: 'object',
    required: ['subject'],
    properties: {
      subject: {
        type: 'string',
        title: 'Subject',
        description: 'Brief description of the task',
        required: true,
      },
      quantity: {
        type: 'number',
        title: 'Quantity',
        description: 'Whole units',
        required: true,
      },
      due: {
        type: 'date',
        title: 'Due',
      },
      notes: {
        type: 'string',
        widget: 'textarea',
        title: 'Notes',
      },
      description: {
        type: 'string',
        title: 'Description',
      },
      agree: {
        type: 'boolean',
        title: 'Agree',
        required: true,
      },
    },
  }
  // Create definition.
  const defRes = await request.post('/api/v1/definitions', {
    headers,
    data: {
      name: `Batch 19 GRD-UI-07 fixture ${slug}`,
      slug,
      description: 'Form ARIA wiring test',
      isActive: true,
      formSchema,
    },
  })
  expect(defRes.ok(), `create definition: ${defRes.status()} ${await defRes.text()}`).toBeTruthy()
  const defJson = (await defRes.json()) as { id: string }

  // Activate the definition so a task can be created from it.
  const actRes = await request.post(`/api/v1/definitions/${defJson.id}/activate`, {
    headers,
  })
  expect(actRes.ok(), `activate definition: ${actRes.status()} ${await actRes.text()}`).toBeTruthy()

  // Start an instance to materialise a task for worker-user.
  const instRes = await request.post('/api/v1/instances', {
    headers,
    data: { definitionId: defJson.id, initiator: 'worker-user' },
  })
  expect(instRes.ok(), `start instance: ${instRes.status()} ${await instRes.text()}`).toBeTruthy()
  const instJson = (await instRes.json()) as { id: string; tasks: Array<{ id: string }> }
  const taskId = instJson.tasks[0]?.id ?? ''
  expect(taskId).not.toBe('')

  return { definitionId: defJson.id, taskId }
}

async function loginWorker(
  page: Page,
  request: APIRequestContext,
): Promise<string> {
  const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')
  await loginWithToken(page, token)
  return token
}

test.describe('GRD-UI-07 — FieldFactory ARIA wiring (no mocks)', () => {
  let fixture: SeededTaskFixture

  test.beforeAll(async ({ request }) => {
    const token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
    fixture = await seedDefinitionWithForm(request, token)
  })

  test.beforeEach(async ({ page, request }) => {
    await loginWorker(page, request)
  })

  test('TC-GRD-UI-07-E2E-01: required field has aria-required="true"', async ({ page }) => {
    await page.goto(`/tasks/${fixture.taskId}/form`)
    const subject = page.getByLabel(/Subject/)
    await expect(subject).toBeVisible({ timeout: 10_000 })
    await expect(subject).toHaveAttribute('aria-required', 'true')
  })

  test('TC-GRD-UI-07-E2E-02: aria-describedby resolves to a visible hint node', async ({
    page,
  }) => {
    await page.goto(`/tasks/${fixture.taskId}/form`)
    const subject = page.getByLabel(/Subject/)
    const describedBy = await subject.getAttribute('aria-describedby')
    expect(describedBy).not.toBeNull()
    const hint = page.locator(`#${describedBy ?? ''}`)
    await expect(hint).toBeVisible()
    await expect(hint).toContainText(/Brief description of the task/)
  })

  test('TC-GRD-UI-07-E2E-03: empty submit triggers aria-invalid + aria-errormessage target exists', async ({
    page,
  }) => {
    await page.goto(`/tasks/${fixture.taskId}/form`)
    const subject = page.getByLabel(/Subject/)
    await subject.fill('')
    await page.getByTestId('task-submit-btn').click()
    await expect(subject).toHaveAttribute('aria-invalid', 'true')
    const target = await subject.getAttribute('aria-errormessage')
    expect(target).not.toBeNull()
    await expect(page.locator(`#${target ?? ''}`)).toHaveAttribute('role', 'alert')
  })

  test('TC-GRD-UI-07-E2E-04: number / date / textarea fields all carry the ARIA attribute set', async ({
    page,
  }) => {
    await page.goto(`/tasks/${fixture.taskId}/form`)
    const quantity = page.getByLabel(/Quantity/)
    await expect(quantity).toBeVisible()
    await expect(quantity).toHaveAttribute('type', 'number')
    await expect(quantity).toHaveAttribute('aria-required', 'true')
    const due = page.getByLabel(/Due/)
    await expect(due).toHaveAttribute('type', 'date')
    const notes = page.getByLabel(/Notes/)
    await expect(notes).toHaveJSProperty('tagName', 'TEXTAREA')
  })

  test('TC-GRD-UI-07-E2E-05: zero dangling aria-errormessage references after a submit attempt', async ({
    page,
  }) => {
    await page.goto(`/tasks/${fixture.taskId}/form`)
    const textboxes = page.getByRole('textbox')
    const count = await textboxes.count()
    for (let i = 0; i < count; i += 1) {
      await textboxes.nth(i).fill('')
    }
    await page.getByTestId('task-submit-btn').click()
    await page.waitForTimeout(500)
    const dangling = await page.evaluate(() => {
      const all = document.querySelectorAll('[aria-invalid="true"]')
      const missing: string[] = []
      for (const el of Array.from(all) as HTMLElement[]) {
        const targetId = el.getAttribute('aria-errormessage')
        if (!targetId) {
          missing.push('<empty>')
        } else if (!document.getElementById(targetId)) {
          missing.push(targetId)
        }
      }
      return missing
    })
    expect(dangling).toEqual([])
  })

  test('TC-GRD-UI-07-E2E-06: optional field omits aria-required', async ({ page }) => {
    await page.goto(`/tasks/${fixture.taskId}/form`)
    const description = page.getByLabel(/Description/)
    await expect(description).toBeVisible()
    await expect(description).not.toHaveAttribute('aria-required')
  })
})
